import CoreGraphics
import Foundation
import VisionOneKit

/// Burns captions into exports through the exporter's overlay hook.
extension CaptionRenderer: ExportOverlay {}

/// What an export needs from captions: an overlay to burn them in and
/// subtitle files next to the MP4, both from the take's captions.json.
enum CaptionExport {
    /// The overlays to pass to the exporter: the captions, when they are
    /// on, burned in, and the take has been transcribed.
    static func overlays(for take: Take, ringHex: UInt32 = CaptionRenderer.ringBlue) -> [ExportOverlay] {
        let settings = take.loadCaptionSettings()
        guard settings.isOn, settings.burnIn, let cues = try? take.captionCues(settings: settings), !cues.isEmpty else {
            return []
        }
        return [CaptionRenderer(track: CaptionTrack(cues: cues), settings: settings, ringHex: ringHex)]
    }

    /// Writes "<video name>.srt" and ".vtt" next to the export, when
    /// captions are on and files are wanted. Quietly does nothing for a
    /// take without a transcript.
    static func writeFiles(for take: Take, preset: ExportPreset) {
        let settings = take.loadCaptionSettings()
        guard settings.isOn, settings.writeFiles else { return }
        let video = take.exportURL(for: preset)
        try? take.writeCaptionFiles(
            settings: settings,
            to: video.deletingLastPathComponent(),
            name: video.deletingPathExtension().lastPathComponent
        )
    }
}
