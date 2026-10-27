import Foundation

/// What you mean to say, split into lines. The teleprompter shows it and
/// follows your voice through it; after the take, every attempt at each
/// line is matched against it so the best one can be kept.
///
/// Saved in the take folder as script.json when a take is recorded from
/// a script.
public struct Script: Codable, Equatable, Sendable {
    public var version = 1
    public var text: String
    public private(set) var lines: [ScriptLine]

    public init(text: String) {
        self.text = text
        lines = Self.split(text)
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Every word in order, with the line it belongs to.
    public var words: [ScriptWord] {
        lines.flatMap { line in
            line.words.enumerated().map { ScriptWord(line: line.id, index: $0.offset, text: $0.element) }
        }
    }

    public var wordCount: Int { lines.reduce(0) { $0 + $1.words.count } }

    /// Seconds to say it, at `wordsPerMinute` (150 is a calm demo pace).
    public func estimatedSeconds(wordsPerMinute: Double = 150) -> Double {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(wordCount) / wordsPerMinute * 60
    }

    /// Lines are sentences: split at line breaks, then after . ! ? (and
    /// the following quote or bracket). Blank pieces are dropped. Audio
    /// tags for text to speech ("[pause]", "[upbeat]") are direction, not
    /// words, so they're left out of the lines.
    public static func split(_ text: String) -> [ScriptLine] {
        var pieces: [String] = []
        for paragraph in withoutAudioTags(text).components(separatedBy: .newlines) {
            var current = ""
            let characters = Array(paragraph)
            for (i, character) in characters.enumerated() {
                current.append(character)
                guard ".!?".contains(character) else { continue }
                let next = i + 1 < characters.count ? characters[i + 1] : " "
                // "v0.4" and "1.5" stay whole: only split before a space.
                if next == " " || next == "\"" || next == "”" || next == ")" {
                    pieces.append(current)
                    current = ""
                }
            }
            pieces.append(current)
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"”)"))) }
            .filter { !normalizedWords(in: $0).isEmpty }
            .enumerated()
            .map { ScriptLine(id: $0.offset, text: $0.element, words: normalizedWords(in: $0.element)) }
    }

    /// The text with [bracketed] audio tags taken out and the spaces
    /// around them closed up.
    public static func withoutAudioTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[[^\]\n]*\]"#, with: "", options: .regularExpression)
    }

    /// Lowercased words without punctuation, the way they're compared.
    public static func normalizedWords(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "–" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// "Rank," and "rank" compare equal; "v0.4" stays "v0.4".
    public static func normalize(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    // MARK: File

    public static func read(from url: URL) throws -> Script {
        try JSONDecoder().decode(Script.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct ScriptLine: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public var text: String
    /// Normalized words, for matching.
    public var words: [String]
}

/// One word of the script and where it sits.
public struct ScriptWord: Equatable, Sendable {
    public let line: Int
    /// Position within its line.
    public let index: Int
    public let text: String
}

extension Take {
    /// The script the take was recorded from, when there was one.
    public var scriptURL: URL { folder.appendingPathComponent("script.json") }
    /// Which attempt at each line was kept, written after transcription.
    public var scriptTakesURL: URL { folder.appendingPathComponent("script-takes.json") }
}
