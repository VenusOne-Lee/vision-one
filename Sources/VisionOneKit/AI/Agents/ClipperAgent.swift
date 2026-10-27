import Foundation

/// A stretch of the take that could stand alone as a clip.
public struct ClipCandidate: Equatable, Sendable {
    public var span: TimeSpan
    public var text: String

    public init(span: TimeSpan, text: String) {
        self.span = span
        self.text = text
    }
}

/// A clip the Clipper suggests, proposed until the user accepts it. Maps
/// one to one onto the clips feature's `Clip` (origin "agent").
public struct ClipPick: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// 0...1, how strong it is on its own.
    public var score: Double
    public var title: String
    public var hook: String?
    public var format: String

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
}

/// The Clipper agent: scores candidate clips with one score question each
/// (Decisions API when it's set up, any rung otherwise), keeps the best
/// ones that don't overlap, then writes a title and hook for each.
public struct ClipperAgent: Sendable {
    public let ladder: AILadder

    public init(ladder: AILadder) {
        self.ladder = ladder
    }

    static let levels: [DecisionQuestion.Level] = [
        .init(label: "weak", description: "Needs the rest of the video to make sense."),
        .init(label: "fine", description: "Makes sense alone but isn't interesting."),
        .init(label: "good", description: "Stands alone and shows something useful."),
        .init(label: "great", description: "Stands alone, opens strong and someone would share it."),
    ]

    /// Windows of whole sentences between `minSeconds` and `maxSeconds`,
    /// one starting at each sentence. Used when the clips feature's
    /// ClipFinder hasn't supplied candidates.
    public static func candidates(from sentences: [SpokenSentence], minSeconds: Double = 15,
                                  maxSeconds: Double = 60) -> [ClipCandidate] {
        var result: [ClipCandidate] = []
        for (i, first) in sentences.enumerated() {
            var texts: [String] = []
            for s in sentences[i...] {
                guard s.end - first.start <= maxSeconds else { break }
                texts.append(s.text)
                if s.end - first.start >= minSeconds {
                    result.append(ClipCandidate(span: TimeSpan(start: first.start, end: s.end),
                                                text: texts.joined(separator: " ")))
                    break
                }
            }
        }
        return result
    }

    /// The best `count` candidates that don't overlap, by score.
    public static func best(_ scored: [(ClipCandidate, Double)], count: Int) -> [(ClipCandidate, Double)] {
        var picked: [(ClipCandidate, Double)] = []
        for item in scored.sorted(by: { $0.1 > $1.1 }) {
            guard picked.count < count else { break }
            if picked.contains(where: { $0.0.span.overlaps(item.0.span) }) { continue }
            picked.append(item)
        }
        return picked.sorted { $0.0.span.start < $1.0.span.start }
    }

    struct Titles: Decodable {
        struct Item: Decodable {
            var n: Int
            var title: String
            var hook: String?
        }
        var clips: [Item]
    }

    public func pick(from candidates: [ClipCandidate], brief: AgentBrief, count: Int = 3,
                     format: String = "vertical") async throws -> [ClipPick] {
        guard !candidates.isEmpty else { return [] }
        let questions = candidates.enumerated().map { i, c in
            DecisionQuestion.score("c\(i)", "How well does this work as a short clip on its own? \"\(c.text)\"", Self.levels)
        }
        let decision = try await ladder.decide(DecisionRequest(
            task: .clipScore, summary: "Score possible clips",
            input: brief.instructions("You pick short clips from a screen recording.", parts: ["clip"]),
            questions: questions))
        let maxLevel = Double(Self.levels.count - 1)
        let scored = candidates.enumerated().compactMap { i, c -> (ClipCandidate, Double)? in
            guard let s = decision["c\(i)"]?.score else { return nil }
            return (c, s / maxLevel)
        }
        let best = Self.best(scored, count: count)
        guard !best.isEmpty else { return [] }

        let list = best.enumerated().map { "\($0.offset + 1). \($0.element.0.text)" }.joined(separator: "\n\n")
        let titles = try? await ladder.complete(AIRequest(
            task: .clipTitle, summary: "Title \(best.count) clips",
            instructions: brief.instructions("Write a short title and a first-line hook for each clip.",
                                             parts: ["title", "hook"]),
            input: list,
            format: .json(shape: #"{"clips": [{"n": 1, "title": "...", "hook": "..."}]}"#))).decode(Titles.self)
        return best.enumerated().map { i, item in
            let t = titles?.clips.first { $0.n == i + 1 }
            let fallback = item.0.text.split(separator: " ").prefix(6).joined(separator: " ")
            return ClipPick(start: item.0.span.start, end: item.0.span.end, score: item.1,
                            title: t?.title ?? fallback, hook: t?.hook, format: format)
        }
    }
}

extension ClipCandidate {
    /// A window the clips feature's on-device finder already liked.
    public init(_ candidate: ClipFinder.Candidate) {
        self.init(span: candidate.span, text: candidate.sentences.map(\.text).joined(separator: " "))
    }
}

extension ClipPick {
    /// The pick as a proposed clip for clips.json, so it shows dashed in
    /// the editor's Clips tab.
    public var clip: Clip {
        Clip(title: title, hook: hook, span: span, score: score, reason: "Picked by the Clipper",
             origin: Clip.Origin.agent, state: .proposed, format: ClipFormat(rawValue: format) ?? .vertical)
    }
}
