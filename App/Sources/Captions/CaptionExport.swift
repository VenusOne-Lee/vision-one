import CoreGraphics
import Foundation
import VisionOneKit

/// Burns captions into exports through the exporter's overlay hook.
extension CaptionRenderer: ExportOverlay {}

/// What an export needs from captions: an overlay to burn them in and
/// subtitle files next to the MP4, both from the take's captions.json and
/// both timed on the timeline the export actually rendered.
enum CaptionExport {
    /// The overlays for an export: the captions, when they are on, burned
    /// in, and the take has been transcribed. `timeline` is the
    /// frame-snapped one the export renders, so the words stay on their
    /// frames however many cuts there are. Times are the edited video's
    /// own clock (the compositor takes the intro off).
    static func overlays(for take: Take, timeline: ExportTimeline,
                         ringHex: UInt32 = CaptionRenderer.ringBlue) -> [ExportOverlay] {
        let settings = take.loadCaptionSettings()
        guard settings.isOn, settings.burnIn,
              let cues = try? take.captionCues(settings: settings, timeline: timeline), !cues.isEmpty else {
            return []
        }
        return [CaptionRenderer(track: CaptionTrack(cues: cues), settings: settings, ringHex: ringHex)]
    }

    /// Writes "<video name>.srt" and ".vtt" next to a finished export,
    /// when captions are on and files are wanted. Cues come from the
    /// export's own timeline and move later by `offset`, the brand
    /// intro's length, so they line up with the file. If writing fails
    /// (no transcript yet, say), no half set is left behind.
    static func writeFiles(for take: Take, video: URL, timeline: ExportTimeline, offset: Double) {
        let settings = take.loadCaptionSettings()
        guard settings.isOn, settings.writeFiles else { return }
        do {
            try take.writeCaptionFiles(
                settings: settings,
                timeline: timeline,
                offset: offset,
                to: video.deletingLastPathComponent(),
                name: video.deletingPathExtension().lastPathComponent
            )
        } catch {
            removeFiles(beside: video)
        }
    }

    /// Deletes the .srt and .vtt that belong to `video`, if there are any.
    static func removeFiles(beside video: URL) {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent
        for format in SubtitleFile.Format.allCases {
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
