import Foundation

/// A take the composer can @mention.
public struct MentionCandidate: Equatable, Sendable {
    public var take: Take
    public var title: String

    public init(take: Take, title: String) {
        self.take = take
        self.title = title
    }

    /// "@rankride-launch-demo": the title in lowercase words joined by
    /// dashes, so it reads as one token.
    public var token: String { "@" + Self.slug(title) }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !($0.isLetter || $0.isNumber) }
        return words.joined(separator: "-")
    }
}

/// What the builder typed, with the takes they @mentioned taken out, so
/// the Desk gets the words and the window knows which take it's about.
public struct ComposerInput: Equatable, Sendable {
    /// Everything that isn't a mention, slash command included.
    public var text: String
    public var mentions: [Take]

    public init(text: String, mentions: [Take] = []) {
        self.text = text
        self.mentions = mentions
    }

    /// "/clips 3 @launch-demo make them punchy".
    public static func parse(_ raw: String, candidates: [MentionCandidate]) -> ComposerInput {
        var mentions: [Take] = []
        var words: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("@"), token.count > 1, let take = resolve(token, in: candidates) {
                if !mentions.contains(take) { mentions.append(take) }
            } else {
                words.append(token)
            }
        }
        return ComposerInput(text: words.joined(separator: " "), mentions: mentions)
    }

    /// An exact token wins; else the take's folder name; else the one
    /// take whose token starts with what was typed.
    static func resolve(_ token: String, in candidates: [MentionCandidate]) -> Take? {
        let typed = "@" + MentionCandidate.slug(String(token.dropFirst()))
        if let exact = candidates.first(where: { $0.token == typed }) { return exact.take }
        if let folder = candidates.first(where: { "@" + $0.take.name == token }) { return folder.take }
        let starts = candidates.filter { $0.token.hasPrefix(typed) }
        return starts.count == 1 ? starts[0].take : nil
    }
}

/// What the pop-up above the composer offers for the word being typed.
public enum ComposerCompletion: Equatable, Sendable {
    case commands([SlashCommand])
    case takes([MentionCandidate])

    /// Looks at the last word: "/cl" offers /clips, "@rank" offers takes.
    /// Commands only complete as the first word.
    public static func suggest(for raw: String, candidates: [MentionCandidate], limit: Int = 6) -> ComposerCompletion? {
        guard let last = raw.last, !last.isWhitespace else { return nil }
        let word = String(raw.split(whereSeparator: \.isWhitespace).last ?? "")
        if word.hasPrefix("/"), raw.drop(while: \.isWhitespace) == word {
            let found = SlashCommand.matching(word)
            return found.isEmpty ? nil : .commands(found)
        }
        if word.hasPrefix("@") {
            let typed = MentionCandidate.slug(String(word.dropFirst()))
            let found = candidates.filter { typed.isEmpty || MentionCandidate.slug($0.title).contains(typed) }
            return found.isEmpty ? nil : .takes(Array(found.prefix(limit)))
        }
        return nil
    }

    /// The text with the last word swapped for the picked item, and a space.
    public static func apply(_ replacement: String, to raw: String) -> String {
        var words = raw.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { return replacement + " " }
        words[words.count - 1] = replacement
        return words.joined(separator: " ") + " "
    }
}
