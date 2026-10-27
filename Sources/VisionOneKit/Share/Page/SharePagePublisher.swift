import Foundation

/// Turns a take into a share bundle: picks the export to play, builds
/// page.json from the transcript, edits and the Sharer's draft, writes
/// captions, and fills the template. The app then uploads the folder
/// (CloudflareShareHost) or shows it in Finder.
public enum SharePagePublisher {
    /// Exports a page can play, best first. Landscape before the phone
    /// shapes, since the page lays the transcript beside the video.
    public static let preferredExports: [ExportPreset] = [.hd1080, .hd720, .original, .whatsapp, .square, .vertical]

    /// The export to put on the page: the best one that exists and, when
    /// `maxBytes` is set, fits. Nil when nothing has been exported.
    public static func video(for take: Take, maxBytes: Int? = nil,
                             fileManager: FileManager = .default) -> (preset: ExportPreset, url: URL)? {
        for preset in preferredExports {
            let url = take.exportURL(for: preset)
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int else { continue }
            if let maxBytes, size > maxBytes { continue }
            return (preset, url)
        }
        return nil
    }

    /// Builds the bundle in the take's share-page folder and returns the
    /// page and the folder.
    public static func build(take: Take, record: SharePageRecord, author: String, api: URL?,
                             video: URL, frameRate: Double = 30, captionSettings: CaptionSettings? = nil,
                             template: String? = nil) throws -> SharePageDocument {
        let transcript = try Transcript.read(from: take.transcriptURL)
        let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
        let timeline = ExportTimeline(edits: edits, frameRate: frameRate)
        var look = record.look
        if !look.allowsAccent(look.accent) { look.accent = SharePageLook(look.preset).accent }

        let document = SharePageDocument.make(
            transcript: transcript, edits: edits, timeline: timeline, pack: SharePack.load(for: take),
            fallbackTitle: take.name, author: author, slug: record.slug, look: look,
            features: record.features, callToAction: record.callToAction, api: api)

        let settings = captionSettings ?? take.loadCaptionSettings()
        let cues = settings.builder.cues(for: transcript, timeline: timeline)
        let captions = cues.isEmpty ? nil : SubtitleFile.vtt(cues)

        try SharePageBundle.write(document, video: video, captions: captions, to: take.shareBundleFolder,
                                  template: template)
        return document
    }
}
