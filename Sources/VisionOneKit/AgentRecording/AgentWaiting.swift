import Foundation

extension Cut.Reason {
    /// The agent was thinking: nothing happened on screen and nobody spoke.
    public static let waiting = "agentWaiting"
}

/// Agents spend most of a recording thinking. "Skip the waiting" proposes
/// a cut for every long gap with no action and no speech, keeping a
/// moment either side so the result of the last action and the start of
/// the next one still show. Proposals stay dashed until kept.
public enum AgentWaiting {
    public struct Rules: Equatable, Sendable {
        /// Only gaps longer than this are proposed.
        public var longerThan = 4.0
        /// Kept after an action, so its result shows (a page loading).
        public var keepAfter = 1.5
        /// Kept before the next action, so the cursor is seen arriving.
        public var keepBefore = 0.8
        /// Shorter cuts than this aren't worth proposing.
        public var shortestCut = 1.0

        public init() {}
    }

    /// Proposed cuts, in source seconds. Nothing when no action was marked:
    /// with nothing to go on, every second might matter.
    public static func cuts(actions: [AgentAction], speech: [TimeSpan], duration: Double,
                            rules: Rules = Rules()) -> [Cut] {
        guard duration > 0, !actions.isEmpty else { return [] }
        var busy = actions.map { TimeSpan(start: $0.t, end: $0.finish) } + speech
        // The very start and end count as busy, so the opening frame and
        // the final screen are never cut away entirely.
        busy.append(TimeSpan(start: 0, end: 0))
        busy.append(TimeSpan(start: duration, end: duration))
        let sorted = busy
            .map { TimeSpan(start: min(max(0, $0.start), duration), end: min(max(0, $0.end), duration)) }
            .sorted { $0.start < $1.start }

        var cuts: [Cut] = []
        var reach = sorted[0].end
        for span in sorted.dropFirst() {
            let gap = span.start - reach
            if gap > rules.longerThan {
                let start = reach + rules.keepAfter
                let end = span.start - rules.keepBefore
                if end - start >= rules.shortestCut {
                    cuts.append(Cut(span: TimeSpan(start: start, end: end), reason: Cut.Reason.waiting, state: .proposed))
                }
            }
            reach = max(reach, span.end)
        }
        return cuts
    }

    /// How long the proposed cuts are together.
    public static func total(_ cuts: [Cut]) -> Double {
        cuts.reduce(0) { $0 + $1.span.duration }
    }

    /// Proposes the waiting cuts for an agent take into edits.json and
    /// returns the ones added. Takes without actions.json are left alone,
    /// and cuts already proposed, kept or turned down aren't repeated.
    @discardableResult
    public static func propose(on take: Take, transcript: Transcript?, sourceDuration duration: Double) throws -> [Cut] {
        guard let log = AgentActionLog.load(for: take), duration > 0 else { return [] }
        let speech = transcript?.words.map { TimeSpan(start: $0.start, end: $0.end) } ?? []
        let proposals = cuts(actions: log.actions, speech: speech, duration: duration)
        guard !proposals.isEmpty else { return [] }
        var edits = try EditList.load(from: take.editsURL, sourceDuration: duration)
        let added = edits.propose(proposals)
        if !added.isEmpty { try edits.write(to: take.editsURL) }
        return added
    }
}
