import Foundation

/// A rectangle inside a frame, 0...1 with the origin at the top left, so
/// it doesn't depend on pixel sizes. For reframing it is the part of the
/// source frame to show; the compositor maps it onto real pixels as
/// `viewport.origin + rect * viewport.size`.
public struct NormalisedRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = NormalisedRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A rect of the given size centred on a point, moved (not shrunk) so
    /// it stays inside the frame.
    public init(centerX: Double, centerY: Double, width: Double, height: Double) {
        let w = min(max(width, 0), 1)
        let h = min(max(height, 0), 1)
        self.init(x: min(max(centerX - w / 2, 0), 1 - w),
                  y: min(max(centerY - h / 2, 0), 1 - h),
                  width: w, height: h)
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// The shapes a video can be exported in. Presets (ExportPreset) decide
/// size and bitrate; the format decides the shape, so a WhatsApp export
/// can be vertical too.
public enum VideoFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 16:9, YouTube and most screens.
    case landscape
    /// 9:16, TikTok, Reels, Shorts, WhatsApp Status.
    case vertical
    /// 1:1, X and the Instagram grid.
    case square
    /// 4:5, LinkedIn and the Instagram feed.
    case portrait

    public var id: String { rawValue }

    /// Width over height.
    public var aspect: Double {
        switch self {
        case .landscape: return 16.0 / 9.0
        case .vertical: return 9.0 / 16.0
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        }
    }

    public var ratio: String {
        switch self {
        case .landscape: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .portrait: return "4:5"
        }
    }

    public var title: String {
        switch self {
        case .landscape: return "Landscape"
        case .vertical: return "Vertical"
        case .square: return "Square"
        case .portrait: return "Portrait"
        }
    }

    public var detail: String {
        switch self {
        case .landscape: return "YouTube, LinkedIn, X"
        case .vertical: return "TikTok, Reels, Shorts, Status"
        case .square: return "X, Instagram grid"
        case .portrait: return "LinkedIn and Instagram feed"
        }
    }

    /// Output size with the given short edge. Both sides even, which
    /// H.264 needs. 1080 gives 1920×1080, 1080×1920, 1080×1080, 1080×1350.
    public func outputSize(shortEdge: Int) -> (width: Int, height: Int) {
        let short = Double(max(2, shortEdge))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if aspect >= 1 {
            return (even(short * aspect), even(short))
        } else {
            return (even(short), even(short / aspect))
        }
    }

    /// The format closest to a frame's shape, for recordings that are
    /// already vertical or square.
    public static func nearest(width: Int, height: Int) -> VideoFormat {
        guard width > 0, height > 0 else { return .landscape }
        let aspect = Double(width) / Double(height)
        return allCases.min { abs(log($0.aspect / aspect)) < abs(log($1.aspect / aspect)) } ?? .landscape
    }
}
