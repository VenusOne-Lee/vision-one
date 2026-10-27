import Foundation

/// One filler word or phrase the cleanup pass can propose cutting.
public struct FillerEntry: Equatable, Sendable {
    public enum Strength: String, Sendable {
        /// Never a real word (um, uh). Always proposed.
        case sure
        /// Also a real word (like, so, ja). Only proposed when it stands
        /// on its own, between pauses or punctuation.
        case maybe
    }

    public enum Position: String, Sendable {
        case anywhere
        /// A tag at the end of a sentence ("it's lekker, hey."). Never the
        /// first word, so "Hey, everyone" is left alone.
        case endOfSentence
    }

    /// Normalised words, as `FillerLexicon.normalize` returns them.
    public let tokens: [String]
    public let strength: Strength
    public let position: Position

    public init(_ phrase: String, _ strength: Strength, position: Position = .anywhere) {
        self.tokens = phrase.split(separator: " ").map { FillerLexicon.normalize(String($0)) }
        self.strength = strength
        self.position = position
    }
}

/// The words Vision One treats as fillers. Kept as data so Mzansi
/// captions can add isiZulu and Afrikaans fillers later without code.
///
/// Left out on purpose because they carry meaning in South African
/// English: "now now", "just now", "shame", "is it".
public struct FillerLexicon: Sendable {
    public var entries: [FillerEntry]

    public init(entries: [FillerEntry]) {
        self.entries = entries
    }

    /// Hesitations Whisper and Parakeet write in many spellings. Matched
    /// after `collapse`, so "ummm", "uhhh" and "hmmm" all count.
    static let hesitations: Set<String> = ["um", "uhm", "uh", "er", "erm", "ehm", "ah", "eh", "hm", "m"]

    public static let standard = FillerLexicon(entries: [
        // General English
        FillerEntry("you know", .maybe),
        FillerEntry("i mean", .maybe),
        FillerEntry("kind of", .maybe),
        FillerEntry("sort of", .maybe),
        FillerEntry("like", .maybe),
        FillerEntry("so", .maybe),
        FillerEntry("basically", .maybe),
        FillerEntry("actually", .maybe),
        FillerEntry("literally", .maybe),
        FillerEntry("well", .maybe),
        FillerEntry("right", .maybe),
        FillerEntry("okay", .maybe),
        FillerEntry("ok", .maybe),
        // South African English. Whisper often writes ja as yeah or yah.
        FillerEntry("ja", .maybe),
        FillerEntry("yah", .maybe),
        FillerEntry("yeah", .maybe),
        FillerEntry("ag", .maybe),
        FillerEntry("eish", .maybe),
        FillerEntry("yoh", .maybe),
        FillerEntry("haai", .maybe),
        FillerEntry("sho", .maybe),
        FillerEntry("ne", .maybe, position: .endOfSentence),
        FillerEntry("neh", .maybe, position: .endOfSentence),
        FillerEntry("hey", .maybe, position: .endOfSentence),
    ])

    /// Lowercased, accents folded ("nè" -> "ne"), punctuation trimmed from
    /// both ends ("Um," -> "um", "I-" -> "i"). Apostrophes inside stay.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let trim = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return folded.trimmingCharacters(in: trim).lowercased()
    }

    /// Squeezes repeated letters: "ummm" -> "um", "hmmm" -> "hm".
    static func collapse(_ word: String) -> String {
        var out = ""
        for ch in word where ch != out.last {
            out.append(ch)
        }
        return out
    }

    /// True for a hesitation sound in any spelling.
    public static func isHesitation(_ normalized: String) -> Bool {
        !normalized.isEmpty && hesitations.contains(collapse(normalized))
    }

    /// Phrases longest first, so "you know" wins over a shorter match.
    var entriesLongestFirst: [FillerEntry] {
        entries.sorted { $0.tokens.count > $1.tokens.count }
    }
}
