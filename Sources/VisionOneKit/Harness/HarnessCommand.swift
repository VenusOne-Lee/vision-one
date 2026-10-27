import Foundation

/// The / commands in the composer. Each one is a shortcut for something
/// you could also say in words.
public enum HarnessCommand: String, CaseIterable, Sendable {
    case record, cut, captions, clips, music, sound, edit, style, copy, review, share

    public var name: String { "/" + rawValue }

    /// One line in the / menu.
    public var summary: String {
        switch self {
        case .record: return "Record your screen"
        case .cut: return "Cut fillers, pauses and weak bits"
        case .captions: return "Add captions"
        case .clips: return "Find short clips"
        case .music: return "Add music under the voice"
        case .sound: return "Open the Sound mode"
        case .edit: return "Open the Editor mode"
        case .style: return "Apply a saved style"
        case .copy: return "Copy a video's style from a link"
        case .review: return "Show what needs your yes or no"
        case .share: return "Write the title, chapters and posts"
        }
    }

    /// What the field shows after the command is picked.
    public var hint: String {
        switch self {
        case .record: return "what you're recording, if you like"
        case .cut: return "a length, like 60s"
        case .captions: return "a style, if you like"
        case .clips: return "how many, like 3"
        case .music: return "a mood, like calm"
        case .sound, .edit, .review: return ""
        case .style: return "a style's name"
        case .copy: return "a video link"
        case .share: return "where, like Version One"
        }
    }

    /// Who does it, for the status line and the "No, and tell …" option.
    public var agent: AgentKind? {
        switch self {
        case .cut, .captions, .music, .style: return .editor
        case .clips: return .clipper
        case .share: return .sharer
        case .record, .copy: return .producer
        case .sound, .edit, .review: return nil
        }
    }

    /// Commands whose name starts with what was typed after the slash.
    public static func matching(_ prefix: String) -> [HarnessCommand] {
        let p = prefix.lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(p) }
    }
}

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

/// What the builder typed, read into a command, the words, and the takes
/// they @mentioned.
public struct ComposerInput: Equatable, Sendable {
    public var command: HarnessCommand?
    /// Everything that isn't the command or a mention.
    public var text: String
    public var mentions: [Take]

    public init(command: HarnessCommand? = nil, text: String, mentions: [Take] = []) {
        self.command = command
        self.text = text
        self.mentions = mentions
    }

    public var isEmpty: Bool { command == nil && text.isEmpty && mentions.isEmpty }

    /// "/clips 3 @launch-demo make them punchy".
    public static func parse(_ raw: String, candidates: [MentionCandidate]) -> ComposerInput {
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var command: HarnessCommand?
        if let first = tokens.first, first.hasPrefix("/"),
           let match = HarnessCommand(rawValue: String(first.dropFirst()).lowercased()) {
            command = match
            tokens.removeFirst()
        }
        var mentions: [Take] = []
        var words: [String] = []
        for token in tokens {
            if token.hasPrefix("@"), token.count > 1, let take = resolve(token, in: candidates) {
                if !mentions.contains(take) { mentions.append(take) }
            } else {
                words.append(token)
            }
        }
        return ComposerInput(command: command, text: words.joined(separator: " "), mentions: mentions)
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
    case commands([HarnessCommand])
    case takes([MentionCandidate])

    /// Looks at the last word: "/cl" offers /clips, "@rank" offers takes.
    /// Commands only complete as the first word.
    public static func suggest(for raw: String, candidates: [MentionCandidate], limit: Int = 6) -> ComposerCompletion? {
        guard let last = raw.last, !last.isWhitespace else { return nil }
        let word = String(raw.split(whereSeparator: \.isWhitespace).last ?? "")
        if word.hasPrefix("/"), raw.drop(while: \.isWhitespace) == word {
            let found = HarnessCommand.matching(String(word.dropFirst()))
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
