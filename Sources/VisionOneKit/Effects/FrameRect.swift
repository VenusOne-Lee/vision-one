import Foundation

/// A box on the recorded frame in 0...1 of its width and height, origin
/// top left: the same space as events.json once divided by the display
/// size. Zooms, blurs and clip crops all use it, so they compose without
/// knowing the video's pixel size.
public struct FrameRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// The whole frame.
    public static let full = FrameRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }

    /// A box of `width` x `height` centred on a point, slid back inside
    /// the frame if it would hang off an edge.
    public static func centered(x cx: Double, y cy: Double, width: Double, height: Double) -> FrameRect {
        let w = min(max(width, 0), 1)
        let h = min(max(height, 0), 1)
        let x = min(max(cx - w / 2, 0), 1 - w)
        let y = min(max(cy - h / 2, 0), 1 - h)
        return FrameRect(x: x, y: y, width: w, height: h)
    }

    /// Clipped to the frame.
    public var clamped: FrameRect {
        let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
        let x1 = min(max(maxX, 0), 1), y1 = min(max(maxY, 0), 1)
        return FrameRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Shrunk by `dx` and `dy` on every side (negative values grow it),
    /// then clipped to the frame.
    public func insetBy(dx: Double, dy: Double) -> FrameRect {
        FrameRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy).clamped
    }

    public func union(_ other: FrameRect) -> FrameRect {
        let x0 = min(x, other.x), y0 = min(y, other.y)
        return FrameRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    public func intersection(_ other: FrameRect) -> FrameRect? {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return FrameRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Overlap over union, 0...1.
    public func iou(_ other: FrameRect) -> Double {
        guard let overlap = intersection(other) else { return 0 }
        let union = area + other.area - overlap.area
        return union > 0 ? overlap.area / union : 0
    }

    /// Straight-line blend towards `other`; `t` 0 is self, 1 is other.
    public func lerp(to other: FrameRect, _ t: Double) -> FrameRect {
        FrameRect(x: x + (other.x - x) * t,
                  y: y + (other.y - y) * t,
                  width: width + (other.width - width) * t,
                  height: height + (other.height - height) * t)
    }

    /// `inner` is given in this box's own 0...1 space (a clip crop inside
    /// a zoom); returns it in frame space.
    public func mapping(_ inner: FrameRect) -> FrameRect {
        FrameRect(x: x + inner.x * width, y: y + inner.y * height,
                  width: inner.width * width, height: inner.height * height)
    }
}

/// Where zooms and blurs come from and whether the user has said yes:
/// the same dashed (proposed) / solid (accepted) grammar as cuts.
public typealias ProposalState = Cut.State
