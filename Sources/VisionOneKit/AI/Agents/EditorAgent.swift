import Foundation

extension Cut.Reason {
    /// Cut by the Editor agent to tighten the take or hit a length.
    public static let trim = "trim"
}

/// The Editor agent: after auto-clean has taken out fillers and pauses, it
/// asks the ladder how much each sentence is worth keeping, then proposes
/// cutting the weakest ones: enough to hit a length ("make it 60s"), or
/// only the ones it's fairly sure about. Every cut lands dashed in the
/// changes list; nothing is applied until the user accepts it.
public struct EditorAgent: Sendable {
    public struct Goal: Equatable, Sendable {
        /// Seconds to aim for, or nil to only drop weak sentences.
        public var targetSeconds: Double?
        /// The user's own words from the ask bar, if any.
        public var ask: String?

        public init(targetSeconds: Double? = nil, ask: String? = nil) {
            self.targetSeconds = targetSeconds
            self.ask = ask
        }

        /// Reads a length out of an ask: "make it 60s", "under 2 minutes",
        /// "90 seconds", "1:30", "a minute".
        public static func parse(_ ask: String) -> Goal {
            let text = ask.lowercased()
            var seconds: Double?
            if let m = text.firstMatch(of: #/(\d+):(\d{2})/#) {
                seconds = Double(m.1)! * 60 + Double(m.2)!
            } else if let m = text.firstMatch(of: #/(\d+(?:\.\d+)?)\s*(seconds?|secs?|s\b|minutes?|mins?|m\b)/#) {
                let value = Double(m.1)!
                seconds = m.2.hasPrefix("m") ? value * 60 : value
            } else if text.contains("half a minute") || text.contains("half minute") {
                seconds = 30
            } else if text.contains("a minute") || text.contains("one minute") {
                seconds = 60
            }
            let trimmed = ask.trimmingCharacters(in: .whitespacesAndNewlines)
            return Goal(targetSeconds: seconds, ask: trimmed.isEmpty ? nil : trimmed)
        }
    }

    public let ladder: AILadder

    public init(ladder: AILadder) {
        self.ladder = ladder
    }

    /// The questions sent up the ladder: one "keep this?" per sentence.
    public static func request(for sentences: [SpokenSentence], brief: AgentBrief, goal: Goal) -> DecisionRequest {
        var context = [brief.instructions("You are editing a screen recording by its transcript.",
                                          parts: ["hook", "body", "outro"])]
        if let ask = goal.ask { context.append("The creator asked: \"\(ask)\"") }
        if let target = goal.targetSeconds { context.append("Target length: about \(Int(target)) seconds.") }
        let questions = sentences.map { s in
            DecisionQuestion.predicate("s\(s.index)",
                "Sentence \(s.index + 1) of \(sentences.count): \"\(s.text)\". Should it stay in the video?")
        }
        return DecisionRequest(task: .editorKeepCut, summary: "Decide which sentences to keep",
                               input: context.joined(separator: "\n"), questions: questions)
    }

    /// Picks the sentences to cut from their keep scores. With a target,
    /// drops the lowest first until the edit fits (never the last sentence
    /// standing); without one, drops those under `threshold`. Sentences the
    /// model refused to score are kept.
    public static func pick(_ sentences: [SpokenSentence], keep: [Int: Double], currentSeconds: Double,
                            goal: Goal, threshold: Double) -> [SpokenSentence] {
        let scored = sentences.compactMap { s in keep[s.index].map { (s, $0) } }
        if let target = goal.targetSeconds {
            var excess = currentSeconds - target
            guard excess > 0 else { return [] }
            var cut: [SpokenSentence] = []
            for (sentence, _) in scored.sorted(by: { $0.1 < $1.1 }) {
                guard excess > 0, cut.count < sentences.count - 1 else { break }
                cut.append(sentence)
                excess -= sentence.duration
            }
            return cut.sorted { $0.start < $1.start }
        }
        return scored.filter { $0.1 < threshold }.map(\.0)
    }

    /// Cuts for `pick`'s sentences, proposed (dashed), with neighbours merged.
    public static func cuts(for sentences: [SpokenSentence], all: [SpokenSentence]) -> [Cut] {
        let cutSet = Set(sentences.map(\.index))
        var cuts: [Cut] = []
        var run: [SpokenSentence] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            // Reach to the next kept sentence's start so the gap goes too.
            let next = all.first { $0.index == last.index + 1 && !cutSet.contains($0.index) }
            let end = next.map { min($0.start, last.end + 0.3) } ?? last.end
            cuts.append(Cut(span: TimeSpan(start: first.start, end: max(end, last.end)),
                            reason: Cut.Reason.trim, state: .proposed))
            run = []
        }
        for s in all {
            if cutSet.contains(s.index) { run.append(s) } else { flush() }
        }
        flush()
        return cuts
    }

    /// Proposes cuts for one take. Returns them without saving.
    public func propose(transcript: Transcript, edits: EditList, brief: AgentBrief, goal: Goal,
                        energy: Energy) async throws -> [Cut] {
        let sentences = transcript.sentences(keeping: edits)
        guard sentences.count > 1 else { return [] }
        let result = try await ladder.decide(Self.request(for: sentences, brief: brief, goal: goal))
        var keep: [Int: Double] = [:]
        for s in sentences {
            if let p = result["s\(s.index)"]?.probability { keep[s.index] = p }
        }
        let picked = Self.pick(sentences, keep: keep, currentSeconds: edits.outputDuration, goal: goal,
                               threshold: energy.profile.keepThreshold)
        return Self.cuts(for: picked, all: sentences)
    }

    /// Runs on a take folder and adds the proposals to edits.json, the way
    /// AutoClean does. Returns what was added.
    @discardableResult
    public func run(on take: Take, brief: AgentBrief, goal: Goal, energy: Energy) async throws -> [Cut] {
        let transcript = try Transcript.read(from: take.transcriptURL)
        var list = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
        let proposals = try await propose(transcript: transcript, edits: list, brief: brief, goal: goal, energy: energy)
        let added = list.propose(proposals)
        try list.write(to: take.editsURL)
        return added
    }
}
