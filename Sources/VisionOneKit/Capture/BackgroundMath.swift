import Foundation

/// The numbers behind "Match my light": how much to tint and brighten the
/// person so they sit in the room's light instead of their own.
public enum LightMatch {
    public struct RGB: Equatable, Sendable {
        public var r, g, b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public static let one = RGB(r: 1, g: 1, b: 1)

        /// Rec. 709 luminance.
        public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    /// Gains never go past this either way, so a strong room colour tints
    /// a face without turning it orange or blue.
    public static let limit = 0.15

    /// Per channel gains to multiply the person's colours by. `person` and
    /// `room` are average colours, 0...1. Colour balance moves `strength`
    /// of the way to the room's, brightness half that, because a webcam
    /// already exposes for the face.
    public static func gains(person: RGB, room: RGB, strength: Double = 0.5) -> RGB {
        let s = min(max(strength, 0), 1)
        let pl = person.luminance, rl = room.luminance
        guard pl > 0.01, rl > 0.01 else { return .one }
        func balance(_ p: Double, _ q: Double) -> Double {
            guard p > 0.001 else { return 1 }
            // The room's colour per unit of brightness over the person's.
            let ratio = (q / rl) / (p / pl)
            return 1 + s * (ratio - 1)
        }
        let exposure = 1 + s * 0.5 * (rl / pl - 1)
        func clamp(_ v: Double) -> Double { min(max(v, 1 - limit), 1 + limit) }
        return RGB(r: clamp(balance(person.r, room.r) * exposure),
                   g: clamp(balance(person.g, room.g) * exposure),
                   b: clamp(balance(person.b, room.b) * exposure))
    }
}

/// Follows the person's head for "Move with me", smoothed so the room
/// glides instead of jittering with every face detection.
public struct HeadFollower: Sendable {
    /// Head centre, shares of the frame, origin bottom left (as Vision
    /// reports it). Starts in the middle.
    public private(set) var x = 0.5
    public private(set) var y = 0.5
    private var lastTime: Double?

    /// Seconds to cover about two thirds of a move.
    public var smoothing: Double

    public init(smoothing: Double = 0.35) {
        self.smoothing = smoothing
    }

    /// Feeds one frame's face centre (nil when no face was found, which
    /// keeps the last spot). A jump back in time, or a gap of over half a
    /// second (a seek in export), snaps straight to the new spot.
    public mutating func update(face: (x: Double, y: Double)?, at time: Double) {
        defer { lastTime = time }
        guard let face else { return }
        let fx = min(max(face.x, 0), 1), fy = min(max(face.y, 0), 1)
        guard let last = lastTime, time > last, time - last < 0.5 else {
            x = fx
            y = fy
            return
        }
        let a = 1 - exp(-(time - last) / max(smoothing, 0.001))
        x += (fx - x) * a
        y += (fy - y) * a
    }

    /// The biggest shift, at depth 1 with the head at the frame's edge, as
    /// a share of the frame's width.
    public static let maxShift = 0.04

    /// How far to move a layer, as shares of the frame's width and height,
    /// origin bottom left. The room moves against the head, as if the
    /// camera gently panned to follow; near layers move more.
    public func offset(depth: Double) -> (dx: Double, dy: Double) {
        let d = min(max(depth, 0), 1)
        return (dx: -(x - 0.5) * 2 * Self.maxShift * d,
                dy: -(y - 0.5) * Self.maxShift * d)
    }

    /// Layers are drawn this much bigger than the frame, so a shifted
    /// layer never shows its edge.
    public static let overscan = 1 + 2 * maxShift + 0.02
}

/// Where the person's soft shadow falls in a room.
public struct ShadowPlan: Equatable, Sendable {
    /// Offset as shares of the frame, origin bottom left.
    public let dx: Double
    public let dy: Double
    /// Blur radius as a share of the frame's width.
    public let softness: Double
    public let opacity: Double

    /// Light from the left throws the shadow right, and the other way;
    /// front light puts it straight behind, a little lower.
    public init(lightFrom side: LightSide) {
        switch side {
        case .left: dx = 0.045
        case .right: dx = -0.045
        case .front: dx = 0
        }
        dy = -0.02
        softness = side == .front ? 0.03 : 0.025
        opacity = side == .front ? 0.22 : 0.3
    }
}

/// Splits a depth map into layers for a picture background.
public enum DepthLayers {
    /// Depth for each layer, far to near. The first layer is the whole
    /// picture; later ones are the nearer parts cut out of it.
    public static let depths: [Double] = [0.15, 0.55, 1.0]

    /// Cut points for `depths.count - 1` near layers, as values in the
    /// map (bigger is nearer, as Depth Anything reports). The nearest
    /// third of the picture becomes the near layer, the next third the
    /// middle. Returns nil for a flat or empty map.
    public static func thresholds(_ values: [Float]) -> [Float]? {
        let finite = values.filter { $0.isFinite }
        guard finite.count >= 16 else { return nil }
        let sorted = finite.sorted()
        guard let lo = sorted.first, let hi = sorted.last, hi - lo > 1e-4 else { return nil }
        let cuts = depths.count - 1
        return (1...cuts).map { i in
            let q = Double(i) / Double(cuts + 1)
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))
            return sorted[index]
        }
    }

    /// Scale and bias for a colour matrix that turns a raw depth value
    /// into a soft 0...1 mask around `threshold`: `value * scale + bias`,
    /// then clamped. `softness` is the share of the depth range the edge
    /// fades over.
    public static func maskMatrix(threshold: Float, min lo: Float, max hi: Float,
                                  softness: Float = 0.08) -> (scale: Float, bias: Float) {
        let range = max(hi - lo, 1e-4)
        let k = 1 / max(softness, 1e-3)
        let scale = k / range
        let bias = -k * (threshold - lo) / range + 0.5
        return (scale, bias)
    }
}
