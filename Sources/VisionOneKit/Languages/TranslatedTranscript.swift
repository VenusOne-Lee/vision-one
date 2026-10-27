import Foundation

/// One sentence of the take in another language, timed on the source
/// clock (screen.mov) like the sentence it came from.
public struct TranslatedLine: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// What was said, kept so a fix survives translating again.
    public var source: String
    public var text: String
    /// True when the person fixed this line by hand.
    public var edited: Bool

    public init(start: Double, end: Double, source: String, text: String, edited: Bool = false) {
        self.start = start
        self.end = end
        self.source = source
        self.text = text
        self.edited = edited
    }
}

extension Transcript {
    /// A transcript in another language made from translated sentences.
    /// Each line keeps its sentence's time and its words are spread
    /// across it by length, so captions, cuts and subtitle files work
    /// exactly as they do for the spoken words. A word whose middle falls
    /// in a cut drops out like a spoken one would.
    public static func translated(_ lines: [TranslatedLine], language: SALanguage, engine: String,
                                  audioTrack: String = "mic", duration: Double, createdAt: Date = Date()) -> Transcript {
        var segments: [TranscriptSegment] = []
        var nextID = 0
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let tokens = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let span = max(0, line.end - line.start)
            guard !tokens.isEmpty, span > 0 else { continue }
            // Weight by letters plus one, so short words still get a moment.
            let weights = tokens.map { Double($0.count + 1) }
            let total = weights.reduce(0, +)
            var cursor = line.start
            var words: [TranscriptWord] = []
            for (token, weight) in zip(tokens, weights) {
                let length = span * weight / total
                words.append(TranscriptWord(id: nextID, text: token, start: cursor, end: cursor + length))
                nextID += 1
                cursor += length
            }
            if var last = words.popLast() {
                last.end = line.end
                words.append(last)
            }
            segments.append(TranscriptSegment(words: words))
        }
        return Transcript(language: language.code, engine: engine, audioTrack: audioTrack,
                          duration: duration, createdAt: createdAt, segments: segments)
    }
}

/// translation.<code>.json: the lines behind transcript.<code>.json, so a
/// hand-fixed line is kept when the take is translated again.
public struct TranslationFile: Codable, Equatable, Sendable {
    public var version = 1
    public var language: SALanguage
    /// The AI rung that wrote it, for the receipt: "ChatGPT plan".
    public var engine: String
    public var lines: [TranslatedLine]

    public init(language: SALanguage, engine: String, lines: [TranslatedLine]) {
        self.language = language
        self.engine = engine
        self.lines = lines
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> TranslationFile {
        try JSONDecoder().decode(TranslationFile.self, from: Data(contentsOf: url))
    }

    /// Lines a person fixed, by the sentence they translate, so a new
    /// translation keeps them.
    public var editedBySource: [String: TranslatedLine] {
        var map: [String: TranslatedLine] = [:]
        for line in lines where line.edited { map[line.source] = line }
        return map
    }
}

extension Take {
    /// transcript.zu.json for a translation; transcript.json (what was
    /// said) for nil.
    public func transcriptURL(language: SALanguage?) -> URL {
        guard let language else { return transcriptURL }
        return folder.appendingPathComponent("transcript.\(language.code).json")
    }

    /// translation.zu.json, the editable lines behind transcript.zu.json.
    public func translationURL(_ language: SALanguage) -> URL {
        folder.appendingPathComponent("translation.\(language.code).json")
    }

    /// Languages this take has translated captions for, in list order.
    public func captionLanguages(fileManager: FileManager = .default) -> [SALanguage] {
        (SALanguage.captionTargets + [.english])
            .filter { fileManager.fileExists(atPath: transcriptURL(language: $0).path) }
    }

    /// Saves translated lines and the transcript made from them.
    public func saveTranslation(_ file: TranslationFile, duration: Double, audioTrack: String = "mic") throws {
        try file.write(to: translationURL(file.language))
        let transcript = Transcript.translated(file.lines, language: file.language,
                                               engine: "translation: \(file.engine)",
                                               audioTrack: audioTrack, duration: duration)
        try transcript.write(to: transcriptURL(language: file.language))
    }

    /// Removes a language's captions.
    public func removeTranslation(_ language: SALanguage, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: translationURL(language))
        try? fileManager.removeItem(at: transcriptURL(language: language))
    }
}
