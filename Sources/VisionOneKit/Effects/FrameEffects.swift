import Foundation

/// Everything that changes the picture itself before it's scaled and
/// overlaid, for one export or one preview: blurs first (on the whole
/// frame, so a secret can't slip out through a zoom or a crop), then the
/// zoom viewport. Times come in on the edited timeline and are mapped back
/// to the take's own clock, where zooms and blurs live.
public struct FrameEffects: Sendable {
    public var zoom: ZoomTrack
    public var blur: BlurTrack
    /// Output (edited) time to take time.
    public var sourceTime: @Sendable (Double) -> Double

    public init(zoom: ZoomTrack, blur: BlurTrack, sourceTime: @escaping @Sendable (Double) -> Double) {
        self.zoom = zoom
        self.blur = blur
        self.sourceTime = sourceTime
    }

    public var isEmpty: Bool { zoom.isEmpty && blur.isEmpty }

    /// Boxes to hide at an output time.
    public func blurs(atOutput t: Double) -> [FrameRect] {
        blur.isEmpty ? [] : blur.rects(atSource: sourceTime(t))
    }

    /// The part of the frame on screen at an output time.
    public func viewport(atOutput t: Double) -> FrameRect {
        zoom.isEmpty ? .full : zoom.viewport(atSource: sourceTime(t))
    }

    /// The effects for an export of `edits`, with the timeline export
    /// actually renders (edges snapped to frames).
    public static func export(zooms: ZoomList, blurs: BlurList, cursor: [CursorPoint],
                              timeline: ExportTimeline) -> FrameEffects {
        FrameEffects(zoom: zooms.track(cursor: cursor), blur: blurs.track) { t in
            timeline.sourceTime(forOutput: t) ?? timeline.segments.last?.source.upperBound ?? t
        }
    }

    /// The effects for the editor's preview, which plays the kept spans
    /// of `edits` back to back.
    public static func preview(zooms: ZoomList, blurs: BlurList, cursor: [CursorPoint],
                               edits: EditList) -> FrameEffects {
        FrameEffects(zoom: zooms.track(cursor: cursor), blur: blurs.track) { t in
            edits.sourceTime(forOutput: t)
        }
    }
}
