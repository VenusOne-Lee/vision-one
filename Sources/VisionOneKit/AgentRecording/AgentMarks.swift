import Foundation

/// What an agent recording draws into its export: a ring where each
/// click landed, and the agent's notes (`log_step`) as captions. Built
/// from actions.json and the recorded size in events.json.
public struct AgentMarks: Equatable, Sendable {
    /// A click, on the recording's clock, at a spot given as a share of
    /// the recorded width and height from the top left.
    public struct Click: Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    /// A ring being drawn now: where, and how far through (0 just
    /// clicked, 1 gone).
    public struct Ring: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var progress: Double
    }

    /// A note shown on the export's clock.
    public struct Step: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public var clicks: [Click]
    /// The agent's notes on the recording's clock.
    public var notes: [(t: Double, text: String)]

    /// How long a ring shows after a click.
    public static let ringSeconds = 0.6
    /// Longest a note stays up, and shortest.
    public static let longestStep = 5.0
    public static let shortestStep = 1.5

    public init(clicks: [Click], notes: [(t: Double, text: String)]) {
        self.clicks = clicks.sorted { $0.t < $1.t }
        self.notes = notes.sorted { $0.t < $1.t }
    }

    public static func == (a: AgentMarks, b: AgentMarks) -> Bool {
        a.clicks == b.clicks && a.notes.map(\.t) == b.notes.map(\.t) && a.notes.map(\.text) == b.notes.map(\.text)
    }

    /// Marks for a log, or nil when it has nothing to draw. Clicks need
    /// the recorded size (events.json) to be placed.
    public init?(log: AgentActionLog, recordedWidth: Double?, recordedHeight: Double?) {
        let clickKinds: Set<AgentAction.Kind> = [.click, .doubleClick, .rightClick]
        var clicks: [Click] = []
        if let w = recordedWidth, let h = recordedHeight, w > 0, h > 0 {
            clicks = log.actions.compactMap { action in
                guard clickKinds.contains(action.kind), let x = action.x, let y = action.y else { return nil }
                return Click(t: action.t, x: min(max(x / w, 0), 1), y: min(max(y / h, 0), 1))
            }
        }
        let notes = log.chapters.map { (t: $0.start, text: $0.title) }
        guard !clicks.isEmpty || !notes.isEmpty else { return nil }
        self.init(clicks: clicks, notes: notes)
    }

    /// Rings to draw at `t` seconds into the recording.
    public func rings(atSource t: Double) -> [Ring] {
        clicks.compactMap { click in
            let age = t - click.t
            guard age >= 0, age < Self.ringSeconds else { return nil }
            return Ring(x: click.x, y: click.y, progress: age / Self.ringSeconds)
        }
    }

    /// The notes on the export's clock: each from where it was said until
    /// the next one, kept between the shortest and longest time. Notes in
    /// a cut part are left out.
    public func steps(on timeline: ExportTimeline) -> [Step] {
        let placed: [(start: Double, text: String)] = notes.compactMap { note in
            timeline.outputTime(forSource: note.t).map { (start: $0, text: note.text) }
        }
        return placed.enumerated().map { index, note in
            let next = index + 1 < placed.count ? placed[index + 1].start : note.start + Self.longestStep
            let end = min(note.start + Self.longestStep, max(note.start + Self.shortestStep, next))
            return Step(start: note.start, end: min(end, timeline.duration), text: note.text)
        }.filter { $0.end > $0.start }
    }
}
