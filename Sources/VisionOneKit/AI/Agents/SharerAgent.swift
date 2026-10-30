import Foundation

/// Everything the Sharer drafts for one take, saved as share.json. All of
/// it is a draft: nothing is posted until the user approves that one post.
public struct SharePack: Codable, Equatable, Sendable {
    public struct Chapter: Codable, Equatable, Sendable {
        /// Seconds into the exported video (after cuts), not the take.
        public var start: Double
        public var title: String
    }

    public struct Post: Codable, Equatable, Sendable {
        /// "x", "linkedin", "whatsapp", "tiktok".
        public var network: String
        public var text: String
    }

    /// Fields for Version One's share_launch, so the launch can go up
    /// through its MCP or be pasted on the site.
    public struct Launch: Codable, Equatable, Sendable {
        public var name: String
        /// Up to 140 characters.
        public var oneLine: String
        public var whoItsFor: String?
        public var whatsNew: String?
    }

    public var title: String
    public var description: String
    public var chapters: [Chapter]
    public var posts: [Post]
    public var launch: Launch?
    public var provider: String?
    public var createdAt: Date

    public static func load(for take: Take) -> SharePack? {
        guard let data = try? Data(contentsOf: take.shareURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharePack.self, from: data)
    }

    public func write(for take: Take) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: take.shareURL, options: .atomic)
    }

    /// YouTube-style chapter lines ("0:00 Intro"), first at 0:00.
    public var chapterText: String {
        chapters.map { "\(Self.clock($0.start)) \($0.title)" }.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The Sharer agent: title, description, chapters, posts and a Version One
/// launch draft from the edited transcript, in one request.
public struct SharerAgent: Sendable {
    public let ladder: AILadder

    public init(ladder: AILadder) {
        self.ladder = ladder
    }

    /// Fewer kept words than this (about 15 seconds of talk) gives a
    /// model nothing true to say, and it invents a product demo instead.
    public static let minimumWords = 40

    /// The take has too little speech to write posts from.
    public struct TooLittleSaid: LocalizedError, Equatable, Sendable {
        public let words: Int

        public var recoveryMessage: String {
            "No post drafts generated: \(words) kept words; at least \(SharerAgent.minimumWords) are needed. Your video is unchanged. Open Post and expand a network to write your own copy."
        }

        public var errorDescription: String? {
            "Too little was said to write posts (\(words) word\(words == 1 ? "" : "s")). Talk through what you're showing for at least 15 seconds, or write the title yourself."
        }
    }

    struct Reply: Decodable {
        struct Chapter: Decodable {
            var sentence: Int
            var title: String
        }
        struct Post: Decodable {
            var network: String
            var text: String
        }
        struct Launch: Decodable {
            var name: String?
            var oneLine: String?
            var whoItsFor: String?
        }
        var title: String
        var description: String?
        var chapters: [Chapter]?
        var posts: [Post]?
        var launch: Launch?
    }

    static let shape = #"""
    {"title": "...", "description": "two or three sentences",
     "chapters": [{"sentence": 1, "title": "..."}, {"sentence": 7, "title": "..."}],
     "posts": [{"network": "x", "text": "..."}, {"network": "linkedin", "text": "..."}, {"network": "whatsapp", "text": "..."}],
     "launch": {"name": "...", "oneLine": "under 140 characters", "whoItsFor": "..."}}
    """#

    /// The transcript as numbered sentences, so chapters can point at a
    /// sentence and land on its exact time.
    public static func numbered(_ sentences: [SpokenSentence]) -> String {
        sentences.map { "[\($0.index + 1)] \($0.text)" }.joined(separator: "\n")
    }

    public func draft(transcript: Transcript, edits: EditList, brief: AgentBrief,
                      product: String? = nil, launch: Bool = false) async throws -> SharePack {
        let sentences = transcript.sentences(keeping: edits)
        let words = sentences.reduce(0) { $0 + $1.wordIDs.count }
        guard words >= Self.minimumWords else { throw TooLittleSaid(words: words) }
        var lead = "You write what goes with a screen recording when it's shared: a title, a short description, chapters for longer videos, and one post per network. Use only what the transcript says: every claim must come from it. Never invent a product, feature or demo the speaker didn't mention. A placeholder still in braces, like {product}, means that detail is unknown: leave it out rather than guess. South African English, plain and specific, no hype or emoji walls."
        if launch { lead += " Also fill the Version One launch fields." }
        if let product { lead += " The product is \(product)." }
        let reply = try await ladder.complete(AIRequest(
            task: .sharePack, summary: "Write a title, chapters and posts",
            instructions: brief.instructions(lead, parts: ["title", "post", "chapters"]),
            input: Self.numbered(sentences), format: .json(shape: Self.shape)))
        let parsed = try reply.decode(Reply.self)
        return Self.pack(from: parsed, sentences: sentences, edits: edits, launch: launch, provider: reply.provider)
    }

    static func pack(from reply: Reply, sentences: [SpokenSentence], edits: EditList, launch: Bool,
                     provider: AIProviderID) -> SharePack {
        var chapters: [SharePack.Chapter] = []
        for chapter in reply.chapters ?? [] {
            guard let s = sentences.first(where: { $0.index == chapter.sentence - 1 }),
                  let t = edits.outputTime(forSource: s.start) else { continue }
            if let last = chapters.last, t - last.start < 10 { continue }
            chapters.append(SharePack.Chapter(start: chapters.isEmpty ? 0 : t, title: chapter.title))
        }
        // Chapters only help with three or more; YouTube wants that too.
        if chapters.count < 3 { chapters = [] }
        let posts = (reply.posts ?? []).map { SharePack.Post(network: $0.network.lowercased(), text: $0.text) }
        var draft: SharePack.Launch?
        if launch, let l = reply.launch, let name = l.name, let line = l.oneLine {
            draft = SharePack.Launch(name: String(name.prefix(60)), oneLine: String(line.prefix(140)),
                                     whoItsFor: l.whoItsFor.map { String($0.prefix(140)) }, whatsNew: nil)
        }
        return SharePack(title: reply.title, description: reply.description ?? "", chapters: chapters,
                         posts: posts, launch: draft, provider: provider.rawValue, createdAt: Date())
    }

    /// The outbound request for one post, as the gate records it.
    public static func postRequest(_ text: String, to destination: String, network: String) -> OutboundRequest {
        OutboundRequest(
            kind: .post, provider: AIProviderID("post.\(network)"), providerName: network.capitalized,
            destination: destination, task: AITask("sharer.post"), summary: "Post to \(network.capitalized)",
            payload: text)
    }

    /// The gate check before a post goes out. Each post is approved on its
    /// own; "Allow for this session" never covers posts.
    public static func approvePost(_ text: String, to destination: String, network: String,
                                   gate: OutboundGate) async throws {
        try await gate.check(postRequest(text, to: destination, network: network))
    }
}
