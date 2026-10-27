import Foundation

/// One thing an AI agent did while Vision One recorded it: a click, some
/// typing, a key, a scroll, or a note the agent sent about what it's doing
/// ("Open the pricing page"). Saved in actions.json next to screen.mov.
public struct AgentAction: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case click, doubleClick, rightClick, drag, scroll, type, key
        /// A note from the agent (`log_step`), shown as a chapter.
        case step
    }

    /// How Vision One knows about it.
    public enum Source: String, Codable, Sendable {
        /// Vision One saw the input event and it wasn't made by a person.
        case seen
        /// The agent said so over MCP. Browser agents that click inside a
        /// page (Claude in Chrome, Playwright) are only known this way.
        case told
    }

    public let id: UUID
    public var kind: Kind
    public var source: Source
    /// Seconds from the take's first video frame, like events.json.
    public var t: Double
    /// When it finished, for typing, drags and scrolls.
    public var end: Double?
    /// Where, in points from the top left of what was recorded.
    public var x: Double?
    public var y: Double?
    /// Typed text (secrets masked), the key ("⌘C", "Return"), the scroll
    /// direction, or the agent's note.
    public var text: String?
    /// The typing went into a password field, so the text isn't kept.
    public var hidden: Bool
    /// The app it happened in ("Safari").
    public var app: String?

    public init(id: UUID = UUID(), kind: Kind, source: Source = .seen, t: Double, end: Double? = nil,
                x: Double? = nil, y: Double? = nil, text: String? = nil, hidden: Bool = false, app: String? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.t = t
        self.end = end
        self.x = x
        self.y = y
        self.text = text
        self.hidden = hidden
        self.app = app
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, source, t, end, x, y, text, hidden, app
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .seen
        t = try c.decode(Double.self, forKey: .t)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        app = try c.decodeIfPresent(String.self, forKey: .app)
    }

    public var hasPoint: Bool { x != nil && y != nil }

    /// When it was over: its end, or its start for instant actions.
    public var finish: Double { max(t, end ?? t) }

    /// The line the step list shows: "Clicked in Safari", "Typed “hello”".
    public var line: String {
        let place = app.map { " in \($0)" } ?? ""
        switch kind {
        case .click: return "Clicked\(place)"
        case .doubleClick: return "Double-clicked\(place)"
        case .rightClick: return "Right-clicked\(place)"
        case .drag: return "Dragged\(place)"
        case .scroll: return "Scrolled \(text ?? "down")\(place)"
        case .type:
            if hidden { return "Typed a password (hidden)" }
            return "Typed “\(text ?? "")”"
        case .key: return "Pressed \(text ?? "a key")"
        case .step: return text ?? "Step"
        }
    }
}

/// The actions.json file in a take folder: what an agent did while it was
/// recorded. Only an agent's input is in it, never the person's.
public struct AgentActionLog: Codable, Equatable, Sendable {
    public var version = 1
    /// Who was driving: an MCP client ("Claude Code") or the app that
    /// posted the input ("Claude").
    public var agent: String
    /// What the agent said it would do ("Sign up on staging").
    public var task: String?
    public var startedAt: Date
    public var actions: [AgentAction]

    public init(agent: String, task: String? = nil, startedAt: Date = Date(), actions: [AgentAction] = []) {
        self.agent = agent
        self.task = task
        self.startedAt = startedAt
        self.actions = actions
    }

    public static func url(in take: Take) -> URL { take.folder.appendingPathComponent("actions.json") }

    public static func load(for take: Take) -> AgentActionLog? {
        try? read(from: url(in: take))
    }

    public static func read(from url: URL) throws -> AgentActionLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentActionLog.self, from: Data(contentsOf: url))
    }

    public func write(for take: Take) throws {
        try write(to: Self.url(in: take))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Actions in time order. A note the agent sent and the click Vision
    /// One saw at the same moment are both kept: the note names the step,
    /// the click shows where.
    public var sorted: [AgentAction] { actions.sorted { $0.t < $1.t } }

    /// The agent's notes, as chapters: start time and title.
    public var chapters: [(start: Double, title: String)] {
        sorted.filter { $0.kind == .step }.compactMap { (action: AgentAction) -> (start: Double, title: String)? in
            let title = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (start: action.t, title: title)
        }
    }

    /// "14 actions: 6 clicks, 3 typed, 2 keys"
    public var summary: String {
        let done = actions.filter { $0.kind != .step }
        guard !done.isEmpty else {
            let steps = actions.count
            return steps == 0 ? "No actions marked" : "\(steps) \(steps == 1 ? "step" : "steps")"
        }
        let clickKinds: Set<AgentAction.Kind> = [.click, .doubleClick, .rightClick]
        let clicks = done.filter { clickKinds.contains($0.kind) }.count
        let typed = done.filter { $0.kind == .type }.count
        let keys = done.filter { $0.kind == .key }.count
        let other = done.count - clicks - typed - keys
        var parts: [String] = []
        if clicks > 0 { parts.append("\(clicks) \(clicks == 1 ? "click" : "clicks")") }
        if typed > 0 { parts.append("\(typed) typed") }
        if keys > 0 { parts.append("\(keys) \(keys == 1 ? "key" : "keys")") }
        if other > 0 { parts.append("\(other) more") }
        return "\(done.count) \(done.count == 1 ? "action" : "actions"): " + parts.joined(separator: ", ")
    }
}
