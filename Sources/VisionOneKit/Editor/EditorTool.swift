import Foundation

/// The tools strip down the left of the full editor. One is picked at a
/// time; it decides what a drag on the video or the timeline does.
public enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    /// Click to seek, drag on the timeline to pick a stretch.
    case select
    /// Drag on the timeline and the stretch is cut when you let go.
    case cut
    /// Drag a box on the video: the camera zooms to it from the playhead.
    case zoom
    /// Drag a box on the video: it's blurred from the playhead.
    case blur

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .cut: return "Cut"
        case .zoom: return "Zoom"
        case .blur: return "Blur"
        }
    }

    /// The key that picks the tool, as on the strip's tooltip.
    public var key: Character {
        switch self {
        case .select: return "v"
        case .cut: return "c"
        case .zoom: return "z"
        case .blur: return "b"
        }
    }

    public var help: String {
        switch self {
        case .select: return "Click to move the playhead, drag on the timeline to pick a stretch"
        case .cut: return "Drag across the timeline to cut that stretch"
        case .zoom: return "Drag a box on the video to zoom there from the playhead"
        case .blur: return "Drag a box on the video to blur it from the playhead"
        }
    }

    public static func forKey(_ key: Character) -> EditorTool? {
        allCases.first { $0.key == Character(key.lowercased()) }
    }

    /// How long a zoom or blur drawn with a tool lasts, from the playhead,
    /// cut short at the end of the take.
    public static let drawnEffectLength = 3.0

    public static func drawnSpan(at t: Double, sourceDuration: Double) -> TimeSpan? {
        let start = min(max(0, t), sourceDuration)
        let end = min(sourceDuration, start + drawnEffectLength)
        guard end - start >= 0.25 else { return nil }
        return TimeSpan(start: start, end: end)
    }
}
