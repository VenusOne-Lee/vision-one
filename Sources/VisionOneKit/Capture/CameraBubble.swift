import Foundation

/// Where the camera bubble floats and how big it is. The centre is kept
/// as a share of the screen, so the bubble stays in the same spot when the
/// resolution changes or it opens on another display. Rects here use one
/// screen's points with any origin; the app passes AppKit frames.
public struct BubblePlacement: Codable, Equatable, Sendable {
    /// Centre as a share of the screen's width and height, 0...1.
    public var centerX: Double
    public var centerY: Double
    /// Width and height of the bubble in points. It's always round.
    public var diameter: Double
    /// The display it was left on. Nil, or a display that's gone, means
    /// the main one.
    public var displayID: UInt32?

    public init(centerX: Double, centerY: Double, diameter: Double, displayID: UInt32? = nil) {
        self.centerX = centerX
        self.centerY = centerY
        self.diameter = diameter
        self.displayID = displayID
    }

    public static let minimumDiameter = 96.0
    /// The biggest bubble is half the screen's shorter side.
    public static let maximumShare = 0.5
    /// Gap kept between the bubble and the screen's edge.
    public static let margin = 16.0

    /// Sizes offered in the bubble's menu.
    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large

        public var title: String { rawValue.capitalized }

        public var diameter: Double {
            switch self {
            case .small: return 140
            case .medium: return 200
            case .large: return 300
            }
        }
    }

    /// Bottom left, medium, in AppKit's bottom-left-origin space: clear
    /// of the Dock's middle, notifications at the top right and most
    /// apps' main buttons at the bottom right.
    public static func standard(on screen: CaptureRect, displayID: UInt32? = nil) -> BubblePlacement {
        let diameter = clampedDiameter(Size.medium.diameter, on: screen)
        let inset = margin * 2 + diameter / 2
        return BubblePlacement(centerX: inset / screen.width, centerY: inset / screen.height,
                               diameter: diameter, displayID: displayID)
    }

    /// The bubble's square frame on `screen`, kept whole and on screen.
    public func frame(on screen: CaptureRect) -> CaptureRect {
        let side = Self.clampedDiameter(diameter, on: screen)
        let raw = CaptureRect(x: screen.x + centerX * screen.width - side / 2,
                              y: screen.y + centerY * screen.height - side / 2,
                              width: side, height: side)
        return Self.kept(raw, on: screen)
    }

    /// The placement for a frame the person dragged to.
    public init(frame: CaptureRect, on screen: CaptureRect, displayID: UInt32? = nil) {
        let side = Self.clampedDiameter(min(frame.width, frame.height), on: screen)
        let square = CaptureRect(x: frame.x, y: frame.y, width: side, height: side)
        let kept = Self.kept(square, on: screen)
        self.init(centerX: (kept.x + side / 2 - screen.x) / screen.width,
                  centerY: (kept.y + side / 2 - screen.y) / screen.height,
                  diameter: side, displayID: displayID)
    }

    /// The same spot at a new size, growing or shrinking about the centre.
    public func resized(to diameter: Double, on screen: CaptureRect) -> BubblePlacement {
        let current = frame(on: screen)
        let side = Self.clampedDiameter(diameter, on: screen)
        let grown = CaptureRect(x: current.x + current.width / 2 - side / 2,
                                y: current.y + current.height / 2 - side / 2,
                                width: side, height: side)
        return BubblePlacement(frame: grown, on: screen, displayID: displayID)
    }

    public static func clampedDiameter(_ diameter: Double, on screen: CaptureRect) -> Double {
        let largest = max(minimumDiameter, min(screen.width, screen.height) * maximumShare)
        return min(max(diameter, minimumDiameter), largest)
    }

    /// Slides a square back inside the screen, `margin` from each edge.
    static func kept(_ rect: CaptureRect, on screen: CaptureRect) -> CaptureRect {
        let minX = screen.x + margin, maxX = screen.x + screen.width - margin - rect.width
        let minY = screen.y + margin, maxY = screen.y + screen.height - margin - rect.height
        var out = rect
        out.x = maxX < minX ? screen.x + (screen.width - rect.width) / 2 : min(max(rect.x, minX), maxX)
        out.y = maxY < minY ? screen.y + (screen.height - rect.height) / 2 : min(max(rect.y, minY), maxY)
        return out
    }
}

/// The camera.json file in a take folder: how camera.mov lines up with
/// screen.mov, and where the bubble sat over the recording, so export can
/// draw the camera where the person saw it (and the editor can move it).
public struct CameraTrack: Codable, Equatable, Sendable {
    public var version = 1
    /// The camera's name, for the editor ("FaceTime HD Camera").
    public var cameraName: String
    /// Seconds from screen.mov's first frame to camera.mov's first frame.
    /// Positive when the camera started after the screen.
    public var startOffset: Double
    /// The bubble was shown mirrored, like a mirror. camera.mov itself is
    /// never mirrored.
    public var previewMirrored: Bool
    /// Where the bubble was, in time order. The first is where it started.
    public var placements: [Placement]

    public init(cameraName: String, startOffset: Double, previewMirrored: Bool = true, placements: [Placement] = []) {
        self.cameraName = cameraName
        self.startOffset = startOffset
        self.previewMirrored = previewMirrored
        self.placements = placements
    }

    /// The bubble's square as shares of what was recorded, top left
    /// origin, like events.json. Can fall outside 0...1 when the bubble
    /// sat outside a recorded window or area; export pulls it inside.
    public struct Placement: Codable, Equatable, Sendable {
        /// Seconds from screen.mov's first frame.
        public var t: Double
        public var x: Double
        public var y: Double
        /// Diameter as a share of the recorded width.
        public var size: Double

        public init(t: Double, x: Double, y: Double, size: Double) {
            self.t = t
            self.x = x
            self.y = y
            self.size = size
        }

        /// `bubble` and `recorded` in the same top-left-origin points
        /// (Core Graphics global coordinates in the app).
        public init?(t: Double, bubble: CaptureRect, recorded: CaptureRect) {
            guard recorded.width > 0, recorded.height > 0 else { return nil }
            self.init(t: t,
                      x: (bubble.x - recorded.x) / recorded.width,
                      y: (bubble.y - recorded.y) / recorded.height,
                      size: bubble.width / recorded.width)
        }
    }

    /// The bubble's square on a frame showing the recording, in that
    /// frame's pixels with the origin at the bottom left (Core Image and
    /// Core Graphics), kept whole inside the frame.
    public static func outputRect(for placement: Placement, in frame: CaptureRect) -> CaptureRect {
        let side = min(max(placement.size * frame.width, 16), min(frame.width, frame.height))
        let left = min(max(frame.x + placement.x * frame.width, frame.x), frame.x + frame.width - side)
        let top = min(max(placement.y * frame.height, 0), frame.height - side)
        return CaptureRect(x: left, y: frame.y + frame.height - top - side, width: side, height: side)
    }

    /// Adds a placement, skipping it when the bubble hasn't really moved,
    /// and replacing the last one when it's from the same instant.
    public mutating func record(_ placement: Placement) {
        if let last = placements.last {
            let still = abs(last.x - placement.x) < 0.001 && abs(last.y - placement.y) < 0.001
                && abs(last.size - placement.size) < 0.001
            if still { return }
            if placement.t - last.t < 1.0 / 30 {
                placements[placements.count - 1] = placement
                return
            }
        }
        placements.append(placement)
    }

    /// Where the bubble was at `t` seconds into the recording.
    public func placement(at t: Double) -> Placement? {
        placements.last { $0.t <= t } ?? placements.first
    }

    /// The moment of camera.mov that matches `t` seconds into screen.mov.
    public func cameraTime(forScreen t: Double) -> Double { t - startOffset }

    /// Where the bubble sits at a moment of an export, following the
    /// recording's clock through the cuts.
    public func placement(atOutput t: Double, timeline: ExportTimeline) -> Placement? {
        let source = timeline.sourceTime(forOutput: t)
            ?? timeline.segments.last(where: { $0.outputStart <= t })?.source.upperBound
            ?? 0
        return placement(at: source)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CameraTrack {
        try JSONDecoder().decode(CameraTrack.self, from: Data(contentsOf: url))
    }
}
