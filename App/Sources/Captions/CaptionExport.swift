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
    /// `language` swaps in that translation for this export only (a
    /// personalised version in the person's language).
    static func overlays(for take: Take, timeline: ExportTimeline,
                         ringHex: UInt32 = CaptionRenderer.ringBlue, language: SALanguage? = nil) -> [ExportOverlay] {
        var settings = take.loadCaptionSettings()
        if let language { settings.language = language }
        guard settings.isOn, settings.burnIn,
              let cues = try? take.captionCues(settings: settings, timeline: timeline), !cues.isEmpty else {
            return []
        }
        return [CaptionRenderer(track: CaptionTrack(cues: cues), settings: settings, ringHex: ringHex)]
    }

    /// Expected absence is an explanation, not a sidecar-write failure.
    static func omissionReason(for take: Take) -> String? {
        let settings = take.loadCaptionSettings()
        guard settings.isOn else { return nil }
        let translated = settings.language.map { take.transcriptURL(language: $0) }
        let source = translated.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? take.transcriptURL
        guard !FileManager.default.fileExists(atPath: source.path) else { return nil }
        if (try? TranscriptFailure.read(from: take.transcriptFailedURL))?.reason == .noAudio {
            return "No captions: this video has no audio."
        }
        return "No captions: a transcript is not available yet."
    }

    /// Writes "<video name>.srt" and ".vtt" next to a finished export,
    /// when captions are on and files are wanted. Cues come from the
    /// export's own timeline and move later by `offset`, the brand
    /// intro's length, so they line up with the file. If writing fails
    /// (a permissions, corrupt-data or disk error), no half set is left behind.
    @discardableResult
    static func writeFiles(for take: Take, video: URL, timeline: ExportTimeline, offset: Double) -> String? {
        let settings = take.loadCaptionSettings()
        guard settings.isOn, settings.writeFiles else { removeFiles(beside: video); return nil }
        guard omissionReason(for: take) == nil else { removeFiles(beside: video); return nil }
        do {
            try take.writeCaptionFiles(
                settings: settings,
                timeline: timeline,
                offset: offset,
                to: video.deletingLastPathComponent(),
                name: video.deletingPathExtension().lastPathComponent
            )
            return nil
        } catch {
            removeFiles(beside: video)
            return "The video was exported, but subtitle files couldn't be written: \(error.localizedDescription)"
        }
    }

    /// Deletes the .srt and .vtt that belong to `video`, translated ones
    /// included, if there are any.
    static func removeFiles(beside video: URL) {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent
        for format in SubtitleFile.Format.allCases {
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            try? FileManager.default.removeItem(at: url)
        }
        for file in Take.translatedSubtitleNames(for: name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
}
