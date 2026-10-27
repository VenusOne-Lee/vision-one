import Foundation

/// One thing a viewer did on a share page. The page sends these with a
/// random per-visit id: no names, accounts or cookies. A note's name is
/// whatever the viewer chose to type, if anything.
public struct ViewerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The page opened.
        case view
        /// Still watching at `at`, sent every 5 s of playback.
        case progress
        /// Reached the end.
        case finish
        case reaction
        case question
    }

    public var kind: Kind
    /// One visit; a new id per tab.
    public var visit: String
    /// Seconds into the video, for progress, finish and reactions.
    public var at: Double?
    /// The emoji, for a reaction.
    public var emoji: String?
    /// What was asked, for a question.
    public var text: String?
    public var time: Date

    public init(kind: Kind, visit: String, at: Double? = nil, emoji: String? = nil,
                text: String? = nil, time: Date = Date()) {
        self.kind = kind
        self.visit = visit
        self.at = at
        self.emoji = emoji
        self.text = text
        self.time = time
    }
}

/// How many viewers are still watching at each second: the curve on the
/// Viewers panel and what the coach reads.
public struct WatchCurve: Equatable, Sendable {
    /// Seconds per point.
    public let step: Double
    /// 0...1 for each step from the start: the share of visits that got
    /// at least this far.
    public let stillWatching: [Double]
    /// Visits that pressed play.
    public let views: Int
    public let duration: Double

    public init(events: [ViewerEvent], duration: Double, step: Double = 1) {
        var furthest: [String: Double] = [:]
        for event in events {
            switch event.kind {
            case .progress, .reaction:
                let at = min(max(event.at ?? 0, 0), duration)
                furthest[event.visit] = max(furthest[event.visit] ?? 0, at)
            case .finish:
                furthest[event.visit] = duration
            case .view, .question:
                continue
            }
        }
        self.step = step
        self.duration = duration
        views = furthest.count
        let points = max(1, Int((duration / step).rounded(.down)) + 1)
        let reached = Array(furthest.values)
        stillWatching = (0..<points).map { i in
            guard !reached.isEmpty else { return 0 }
            let t = Double(i) * step
            return Double(reached.filter { $0 >= t }.count) / Double(reached.count)
        }
    }

    /// Average seconds watched per view.
    public var averageWatched: Double {
        // The area under the curve is the average time watched.
        guard views > 0 else { return 0 }
        return stillWatching.dropFirst().reduce(0) { $0 + $1 * step }
    }

    public func stillWatching(at t: Double) -> Double {
        guard !stillWatching.isEmpty else { return 0 }
        let i = min(stillWatching.count - 1, max(0, Int((t / step).rounded(.down))))
        return stillWatching[i]
    }

    /// Where the most viewers leave in one window, ignoring the last few
    /// seconds (leaving at the end is normal). Nil when there are too few
    /// views to say, or nobody really leaves anywhere.
    public func biggestDrop(window: Double = 5, ignoringLast: Double = 5,
                            minimumViews: Int = 5, minimumShare: Double = 0.15) -> DropOff? {
        guard views >= minimumViews, stillWatching.count > 1 else { return nil }
        let span = max(1, Int((window / step).rounded()))
        let lastStart = Int(((duration - ignoringLast) / step).rounded(.down))
        var best: DropOff?
        var i = 0
        while i + span < stillWatching.count && i <= lastStart {
            let before = stillWatching[i], after = stillWatching[i + span]
            if before - after > (best.map { $0.before - $0.after } ?? 0) {
                best = DropOff(from: Double(i) * step, to: Double(i + span) * step, before: before, after: after)
            }
            i += 1
        }
        guard let best, best.before - best.after >= minimumShare else { return nil }
        return best
    }
}

/// A stretch of the video where viewers leave.
public struct DropOff: Equatable, Sendable {
    public var from: Double
    /// The "most people stop at" time.
    public var to: Double
    /// Share still watching at `from` and at `to`.
    public var before: Double
    public var after: Double

    /// Share of all viewers who left in this stretch.
    public var left: Double { before - after }
}

/// What the coach says about a drop: "39% of viewers leave by 0:18".
/// The line is what's being said there, so the coach (or the Editor)
/// can propose a fix for that sentence.
public struct ViewerCoachHint: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// In the first 30 s or first third: the opening doesn't hold.
        case hook
        /// Later: one part drags.
        case middle
    }

    public var kind: Kind
    public var drop: DropOff
    public var line: SharePageDocument.Line?
    public var headline: String
    public var detail: String
    /// What to ask the Editor or the script coach, in the user's words.
    public var ask: String

    public static func from(curve: WatchCurve, lines: [SharePageDocument.Line]) -> ViewerCoachHint? {
        guard let drop = curve.biggestDrop() else { return nil }
        let line = lines.last { $0.start <= drop.to && $0.end > drop.from } ?? lines.last { $0.start <= drop.to }
        let percent = Int((drop.left * 100).rounded())
        let at = Timecode.short(from: drop.to)
        let kind: Kind = drop.to <= min(30, curve.duration / 3) ? .hook : .middle
        let quote = line.map { "“\($0.text)”" }
        switch kind {
        case .hook:
            return ViewerCoachHint(
                kind: kind, drop: drop, line: line,
                headline: "\(percent)% of viewers leave by \(at)",
                detail: "Most people stop during the opening\(quote.map { ", at \($0)" } ?? ""). Start with the problem or the result, and move the background later.",
                ask: "Viewers leave at \(at)\(quote.map { " during \($0)" } ?? ""). Propose a tighter opening that gets to the point in the first 10 seconds.")
        case .middle:
            return ViewerCoachHint(
                kind: kind, drop: drop, line: line,
                headline: "\(percent)% of viewers leave around \(at)",
                detail: "This part loses people\(quote.map { ": \($0)" } ?? ""). Shorten it or show the result sooner.",
                ask: "Viewers leave around \(at)\(quote.map { " during \($0)" } ?? ""). Propose cuts that tighten this part.")
        }
    }
}

/// Totals for the Viewers panel.
public struct ViewerSummary: Equatable, Sendable {
    public var views: Int
    public var averageWatched: Double
    public var finished: Int
    public var questions: [String]
    /// Emoji and how often, most first.
    public var reactions: [(emoji: String, count: Int)]

    public init(events: [ViewerEvent], duration: Double) {
        let curve = WatchCurve(events: events, duration: duration)
        views = Set(events.filter { $0.kind == .view }.map(\.visit)).count
        averageWatched = curve.averageWatched
        finished = Set(events.filter { $0.kind == .finish }.map(\.visit)).count
        questions = events.filter { $0.kind == .question }.compactMap(\.text)
        var counts: [String: Int] = [:]
        for event in events where event.kind == .reaction {
            if let emoji = event.emoji { counts[emoji, default: 0] += 1 }
        }
        reactions = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (emoji: $0.key, count: $0.value) }
    }

    public static func == (a: ViewerSummary, b: ViewerSummary) -> Bool {
        a.views == b.views && a.averageWatched == b.averageWatched && a.finished == b.finished
            && a.questions == b.questions
            && a.reactions.map(\.emoji) == b.reactions.map(\.emoji)
            && a.reactions.map(\.count) == b.reactions.map(\.count)
    }
}
