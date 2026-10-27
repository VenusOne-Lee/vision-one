import Foundation

/// The three answers on a Codex-style approval card, numbered 1, 2, 3:
/// yes once, yes and stop asking for this kind of post, or no with a
/// note for the agent.
public enum ApprovalAnswer: Equatable, Sendable {
    case yes
    case yesAlways
    case no(feedback: String)

    /// The card's option for `number` (1, 2 or 3).
    public init?(number: Int, feedback: String = "") {
        switch number {
        case 1: self = .yes
        case 2: self = .yesAlways
        case 3: self = .no(feedback: feedback)
        default: return nil
        }
    }

    public var isYes: Bool {
        if case .no = self { return false }
        return true
    }
}

/// Which option the card has picked as you press ↑ and ↓. Kept apart
/// from the view so the keys are tested.
public struct ApprovalSelection: Equatable, Sendable {
    public private(set) var index: Int
    public let count: Int

    public init(count: Int, index: Int = 0) {
        self.count = max(count, 1)
        self.index = min(max(index, 0), self.count - 1)
    }

    /// Stops at the ends, like a Codex list, so a held key doesn't wrap.
    public mutating func up() { index = max(index - 1, 0) }
    public mutating func down() { index = min(index + 1, count - 1) }

    /// "1" to "9" picks that option.
    public mutating func pick(_ number: Int) -> Bool {
        guard (1...count).contains(number) else { return false }
        index = number - 1
        return true
    }

    public var number: Int { index + 1 }
}

/// The posts you said not to ask about again ("Yes, and don't ask again
/// for RankRide posts"): one rule per product and place. Saved as
/// post-rules.json, so the MCP server reads the same rules. A rule only
/// skips the card; the post still opens in the network's own composer
/// (or Version One), where you press post yourself.
public struct PostRules: Codable, Equatable, Sendable {
    public struct Rule: Codable, Hashable, Sendable {
        /// The product's name from the brand kit, or "" for any take.
        public var scope: String
        /// Host it goes to ("versionone.co.za", "x.com").
        public var destination: String

        public init(scope: String, destination: String) {
            self.scope = Self.normalise(scope)
            self.destination = destination.lowercased()
        }

        static func normalise(_ scope: String) -> String {
            scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public private(set) var rules: Set<Rule>

    public init(rules: Set<Rule> = []) {
        self.rules = rules
    }

    public func allows(scope: String, destination: String) -> Bool {
        rules.contains(Rule(scope: scope, destination: destination))
    }

    public mutating func allow(scope: String, destination: String) {
        rules.insert(Rule(scope: scope, destination: destination))
    }

    public mutating func forget(scope: String, destination: String) {
        rules.remove(Rule(scope: scope, destination: destination))
    }

    /// ~/Library/Application Support/Vision One/post-rules.json
    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("post-rules.json")
    }

    public static func load(from url: URL = standardURL) -> PostRules {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(PostRules.self, from: data) else { return PostRules() }
        return rules
    }

    public func write(to url: URL = standardURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The card's words for a post, from the harness spec: "Post this to
/// Version One?" and its three options.
public enum PostApprovalText {
    public static func question(to place: String) -> String { "Post this to \(place)?" }

    public static func options(scope: String) -> [String] {
        let name = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Yes, post it",
            name.isEmpty ? "Yes, and don't ask again for these posts" : "Yes, and don't ask again for \(name) posts",
            "No, and tell the Sharer what to do differently",
        ]
    }

    public static let keys = "↑↓ to choose · Return to confirm · Esc to decide later"
}

extension SharePack.Launch {
    /// The launch as one post: name, one line, who it's for and what's
    /// new, each on its own line. What goes on the clipboard for Version One.
    public var postText: String {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return [clean(name), clean(oneLine), clean(whoItsFor).map { "For: \($0)" }, clean(whatsNew).map { "New: \($0)" }]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}
