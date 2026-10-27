import Foundation

/// Which agent runs a job.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case producer, editor, clipper, sharer
    /// Clicks through an app while Vision One records (Autopilot).
    case autopilot

    public var title: String {
        switch self {
        case .producer: return "Producer"
        case .editor: return "Editor"
        case .clipper: return "Clipper"
        case .sharer: return "Sharer"
        case .autopilot: return "Autopilot"
        }
    }
}

/// One video job in the Agent Desk: "Edit RankRide launch demo", "Make 3
/// clips", "Post to Version One". The app's task list, the after-Stop
/// cards and (later) the MCP server all read these.
public struct AgentJob: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued
        case running
        /// Paused until the user approves something leaving the Mac.
        case needsApproval
        /// Finished with dashed proposals to keep or undo.
        case needsReview
        /// Kept, or finished with nothing to review.
        case done
        /// The user pressed Undo; its changes are gone.
        case undone
        case failed
        case cancelled

        /// Shown under "Needs you".
        public var needsYou: Bool { self == .needsApproval || self == .needsReview }
        public var isActive: Bool { self == .queued || self == .running || self == .needsApproval }
    }

    public struct Step: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case pending, running, done, skipped, failed
        }

        public var title: String
        public var state: State

        public init(_ title: String, state: State = .pending) {
            self.title = title
            self.state = state
        }
    }

    /// Something the job wrote into the take, so Keep and Undo know what
    /// to touch.
    public enum Change: Codable, Hashable, Sendable {
        /// A proposed cut in edits.json.
        case cut(UUID)
        /// A proposed clip in clips.json.
        case clip(UUID)
        /// The Sharer's drafts in share.json.
        case sharePack
    }

    /// What's waiting for a yes, copied from the `OutboundRequest`.
    public struct Approval: Codable, Equatable, Sendable {
        public var id: UUID
        public var isPost: Bool
        public var summary: String
        public var providerName: String
        public var destination: String
        public var preview: String
        public var characters: Int
        public var estimatedRand: Double?
        public var fromPlan: Bool

        public init(_ request: OutboundRequest) {
            id = request.id
            isPost = request.kind == .post
            summary = request.summary
            providerName = request.providerName
            destination = request.destination
            preview = request.preview
            characters = request.characters
            estimatedRand = request.estimatedRand
            fromPlan = request.fromPlan
        }
    }

    public let id: UUID
    public var agent: AgentKind
    public var title: String
    /// The take folder it works on, if any.
    public var takeFolder: URL?
    /// What the user typed ("make it 60s"), if they asked.
    public var ask: String?
    public var state: State
    public var steps: [Step]
    /// One short line on what it did: "Cut 21 s across 3 sentences".
    public var receipt: String?
    public var changes: [Change]
    /// The edit list the cuts went into, when not the main cut (a copy).
    public var editsFile: String?
    public var approval: Approval?
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), agent: AgentKind, title: String, take: Take? = nil, ask: String? = nil,
                steps: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.title = title
        self.takeFolder = take?.folder
        self.ask = ask
        self.state = .queued
        self.steps = steps.map { Step($0) }
        self.changes = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var take: Take? { takeFolder.map(Take.init(folder:)) }

    /// The step running now, counted from 1.
    public var currentStep: Int? {
        steps.firstIndex { $0.state == .running }.map { $0 + 1 }
    }

    /// The line under the task's title: "Clipper · running, step 3 of 5".
    public var statusLine: String {
        "\(agent.title) · \(statusText)"
    }

    public var statusText: String {
        switch state {
        case .queued: return "waiting to start"
        case .running:
            if let n = currentStep { return "running, step \(n) of \(steps.count)" }
            return "running"
        case .needsApproval: return approval?.isPost == true ? "waiting to post" : "waiting for approval"
        case .needsReview: return "needs your review"
        case .done: return "done"
        case .undone: return "undone"
        case .failed: return "didn't finish"
        case .cancelled: return "stopped"
        }
    }
}

/// Short receipts, in the same words everywhere.
public enum AgentReceipt {
    public static func cuts(_ cuts: [Cut], ask: String? = nil) -> String {
        guard !cuts.isEmpty else { return "Nothing more to cut." }
        let seconds = cuts.reduce(0) { $0 + $1.span.duration }
        let what = cuts.count == 1 ? "1 part" : "\(cuts.count) parts"
        return "Cut \(duration(seconds)) across \(what)."
    }

    public static func clips(_ clips: [Clip]) -> String {
        guard !clips.isEmpty else { return "No moment stands on its own yet." }
        let titles = clips.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
        return "Found \(clips.count) \(clips.count == 1 ? "clip" : "clips"): \(titles)."
    }

    public static func share(_ pack: SharePack) -> String {
        var parts = ["a title"]
        if !pack.chapters.isEmpty { parts.append("\(pack.chapters.count) chapters") }
        if !pack.posts.isEmpty { parts.append("\(pack.posts.count) \(pack.posts.count == 1 ? "post" : "posts")") }
        if pack.launch != nil { parts.append("a Version One launch") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Wrote \(list)."
    }

    /// "21 s", "1 min 5 s".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s")
    }
}
