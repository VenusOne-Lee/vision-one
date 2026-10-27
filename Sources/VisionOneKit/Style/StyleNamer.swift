import Foundation

extension AITask {
    /// Name and describe a copied style, from its numbers only.
    public static let styleName = AITask("style.name")
}

/// Names a copied style with the AI ladder (on the Mac first). Only the
/// profile's numbers go in, never frames, words or sound from the video.
/// Without a model, `StyleProfile.suggestedTitle` is used.
public struct StyleNamer: Sendable {
    public struct Name: Equatable, Sendable {
        public var title: String
        public var summary: String?
    }

    public let ladder: AILadder

    public init(ladder: AILadder) {
        self.ladder = ladder
    }

    struct Reply: Decodable {
        var title: String
        var summary: String?
    }

    static let shape = #"{"title": "two to four words", "summary": "one short line"}"#

    public static func request(for profile: StyleProfile) -> AIRequest {
        AIRequest(
            task: .styleName, summary: "Name a template from a video's style numbers",
            instructions: "You name video templates. From the style measurements below, give a short, plain name (two to four words, no quotes, no emoji) that says how the video feels, and one short line describing it. South African English.",
            input: profile.summaryLines, format: .json(shape: shape))
    }

    public func name(_ profile: StyleProfile) async -> Name {
        guard let reply = try? await ladder.complete(Self.request(for: profile)),
              let parsed = try? reply.decode(Reply.self) else {
            return Name(title: profile.suggestedTitle, summary: nil)
        }
        return Self.clean(parsed, fallback: profile.suggestedTitle)
    }

    static func clean(_ reply: Reply, fallback: String) -> Name {
        let title = reply.title
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ .").union(.whitespacesAndNewlines))
        let summary = reply.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Name(title: title.isEmpty ? fallback : String(title.prefix(40)),
                    summary: (summary?.isEmpty ?? true) ? nil : summary.map { String($0.prefix(100)) })
    }
}
