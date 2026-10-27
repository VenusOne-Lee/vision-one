import Foundation

/// Everything the share page shows, saved as page.json in the share
/// bundle and inlined into index.html so the page also opens straight
/// from a folder. Times are in the exported video, after cuts.
public struct SharePageDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// One sentence of the transcript.
    public struct Line: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct Chapter: Codable, Equatable, Sendable {
        public var start: Double
        public var title: String

        public init(start: Double, title: String) {
            self.start = start
            self.title = title
        }
    }

    /// What viewers can do besides watch.
    public struct Features: Codable, Equatable, Sendable {
        public var ask: Bool
        public var react: Bool
        public var notes: Bool
        public var callToAction: Bool

        public init(ask: Bool = true, react: Bool = true, notes: Bool = true, callToAction: Bool = true) {
            self.ask = ask
            self.react = react
            self.notes = notes
            self.callToAction = callToAction
        }
    }

    /// The creator's button: "Try RankRide".
    public struct CallToAction: Codable, Equatable, Sendable {
        public var label: String
        public var url: URL

        public init(label: String, url: URL) {
            self.label = label
            self.url = url
        }
    }

    public var version = SharePageDocument.currentVersion
    /// The page's name in its link: "rankride-launch-k3f9".
    public var slug: String
    public var title: String
    public var author: String
    public var description: String?
    /// BCP 47, from the transcript.
    public var language: String
    public var duration: Double
    /// Files next to index.html.
    public var video: String
    public var poster: String?
    public var captions: String?
    public var lines: [Line]
    public var chapters: [Chapter]
    public var lookName: String
    public var transcriptPlace: SharePageLook.TranscriptPlace
    /// CSS custom properties from `SharePageLook.cssVariables`.
    public var theme: [String: String]
    public var features: Features
    public var callToAction: CallToAction?
    /// The interactive API (reactions, notes, watch progress). Nil for a
    /// static page: viewers can still watch, read and ask.
    public var api: URL?

    public init(slug: String, title: String, author: String, description: String? = nil,
                language: String = "en", duration: Double, video: String = "video.mp4",
                poster: String? = nil, captions: String? = nil,
                lines: [Line], chapters: [Chapter] = [], look: SharePageLook = SharePageLook(),
                features: Features = Features(), callToAction: CallToAction? = nil, api: URL? = nil) {
        self.slug = slug
        self.title = title
        self.author = author
        self.description = description
        self.language = language
        self.duration = duration
        self.video = video
        self.poster = poster
        self.captions = captions
        self.lines = lines
        self.chapters = chapters
        self.lookName = look.preset.title
        self.transcriptPlace = look.transcript
        self.theme = look.cssVariables
        self.features = features
        self.callToAction = callToAction
        self.api = api
    }

    /// Whether reactions and notes can reach the creator.
    public var isInteractive: Bool { api != nil }

    /// The page for a take: sentences that survive the edit, moved to
    /// export time; chapters, title and description from the Sharer's
    /// draft when there is one.
    public static func make(transcript: Transcript, edits: EditList? = nil, timeline: ExportTimeline? = nil,
                            pack: SharePack? = nil, fallbackTitle: String, author: String,
                            slug: String? = nil, look: SharePageLook = SharePageLook(),
                            features: Features = Features(), callToAction: CallToAction? = nil,
                            api: URL? = nil) -> SharePageDocument {
        let lines = Self.lines(from: transcript, edits: edits, timeline: timeline)
        let title = pack.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let duration = timeline?.duration ?? transcript.duration
        let chapters = (pack?.chapters ?? []).map { Chapter(start: $0.start, title: $0.title) }
        let description = pack.map(\.description).flatMap { $0.isEmpty ? nil : $0 }
        return SharePageDocument(slug: slug ?? Self.slug(for: title), title: title, author: author,
                                 description: description, language: transcript.language,
                                 duration: duration, captions: "captions.vtt", lines: lines,
                                 chapters: chapters, look: look, features: features,
                                 callToAction: callToAction, api: api)
    }

    /// Transcript sentences in export time. A sentence whose start was
    /// cut starts at its first word that survived.
    public static func lines(from transcript: Transcript, edits: EditList? = nil,
                             timeline: ExportTimeline? = nil) -> [Line] {
        let byID = Dictionary(uniqueKeysWithValues: transcript.words.map { ($0.id, $0) })
        return transcript.sentences(keeping: edits).compactMap { sentence in
            let words = sentence.wordIDs.compactMap { byID[$0] }
            guard let timeline else {
                return Line(start: sentence.start, end: sentence.end, text: sentence.text)
            }
            let kept = words.filter { timeline.outputTime(forSource: ($0.start + $0.end) / 2) != nil }
            guard let first = kept.first, let last = kept.last else { return nil }
            let start = timeline.outputTime(forSource: first.start) ?? timeline.outputTime(forSource: (first.start + first.end) / 2) ?? 0
            // Kept spans are half-open, so look just inside the last word's end.
            let end = timeline.outputTime(forSource: max(last.start, last.end - 0.001)) ?? start
            return Line(start: start, end: max(start, end), text: sentence.text)
        }
    }

    /// A link-safe name with a short random tail, so two videos with the
    /// same title never share a link: "rankride-launch-demo-k3f9".
    public static func slug(for title: String, tail: String? = nil) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var lastWasHyphen = true
        for scalar in folded.unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "video" }
        return out + "-" + (tail ?? randomTail())
    }

    static func randomTail(length: Int = 4) -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    public func write(to url: URL) throws {
        try JSONEncoder.sharePage.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SharePageDocument {
        try JSONDecoder().decode(SharePageDocument.self, from: Data(contentsOf: url))
    }
}

extension JSONEncoder {
    /// Stable, readable JSON for files people may open.
    static var sharePage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
