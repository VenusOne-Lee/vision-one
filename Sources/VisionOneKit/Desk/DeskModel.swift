import Foundation

/// A project in the sidebar ("RankRide", "Weekly updates"): its tasks,
/// house notes the agents read (like a repo's AGENTS.md) and the tools the
/// Producer may read for scripts.
public struct DeskProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Read by every agent in this project: who it's for, words to use or avoid.
    public var notes: String
    /// Where the Producer looks for what's new: GitHub repos, Linear teams.
    public var sources: [ScriptSourceRef]
    /// The prompt preset agents use here, if not the app's default.
    public var presetName: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", sources: [ScriptSourceRef] = [],
                presetName: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.sources = sources
        self.presetName = presetName
        self.createdAt = createdAt
    }

    /// The letter on the project's tile.
    public var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// "Just do it" runs the agents straight away; "Plan first" shows the
/// Producer's plan for a yes before anything changes.
public enum AskMode: String, Codable, CaseIterable, Sendable {
    case justDoIt, planFirst

    public var title: String { self == .justDoIt ? "Just do it" : "Plan first" }
}

/// One numbered choice on an approval card. Return picks the preselected one.
public struct ApprovalOption: Codable, Equatable, Sendable {
    public enum Effect: String, Codable, Sendable {
        /// Yes, this once.
        case allowOnce
        /// Yes, and don't ask again for this in this project.
        case allowAlways
        /// No; the user can say what to do instead.
        case deny
    }

    public var label: String
    public var effect: Effect

    public init(_ label: String, _ effect: Effect) {
        self.label = label
        self.effect = effect
    }
}

/// A question in the thread with numbered answers: approving a plan, a
/// send to the cloud, or a post.
public struct ApprovalCard: Codable, Equatable, Identifiable, Sendable {
    public enum Subject: Codable, Equatable, Sendable {
        case plan
        /// An agent job's outbound request, answered through the job board.
        case job(UUID)
    }

    public let id: UUID
    public var subject: Subject
    public var question: String
    /// What exactly would happen: "Sends 1,240 words to ChatGPT (from your plan, R0)".
    public var detail: String?
    public var options: [ApprovalOption]
    public var preselected: Int
    /// The index picked, once answered.
    public var answer: Int?
    /// "Tell it what to do differently", when the answer was no.
    public var note: String?

    public init(id: UUID = UUID(), subject: Subject, question: String, detail: String? = nil,
                options: [ApprovalOption], preselected: Int = 0) {
        self.id = id
        self.subject = subject
        self.question = question
        self.detail = detail
        self.options = options
        self.preselected = min(max(preselected, 0), max(options.count - 1, 0))
    }

    public var isOpen: Bool { answer == nil }

    /// The three choices for a plan.
    public static func plan(_ summary: String) -> ApprovalCard {
        ApprovalCard(subject: .plan, question: "Go ahead with this plan?", detail: summary,
                     options: [ApprovalOption("Yes, do it", .allowOnce),
                               ApprovalOption("No, and tell the Producer what to change", .deny)])
    }

    /// The three choices for something leaving the Mac.
    public static func job(_ jobID: UUID, approval: AgentJob.Approval, agent: AgentKind,
                           project: String) -> ApprovalCard {
        let cost: String
        if approval.fromPlan { cost = "from your ChatGPT plan, R0" }
        else if let rand = approval.estimatedRand { cost = String(format: "about R%.2f", rand) }
        else { cost = "cost unknown" }
        if approval.isPost {
            return ApprovalCard(subject: .job(jobID), question: "Post this to \(approval.destination)?",
                                detail: approval.preview,
                                options: [ApprovalOption("Yes, post it", .allowOnce),
                                          ApprovalOption("No, and tell the \(agent.title) what to do differently", .deny)])
        }
        return ApprovalCard(
            subject: .job(jobID), question: "Send this to \(approval.providerName)?",
            detail: "\(approval.summary): \(approval.characters) characters to \(approval.destination), \(cost).",
            options: [ApprovalOption("Yes, send it", .allowOnce),
                      ApprovalOption("Yes, and don't ask again for \(approval.providerName) in \(project)", .allowAlways),
                      ApprovalOption("No, and tell the \(agent.title) what to do differently", .deny)])
    }
}

/// The Producer's plan for an ask: which agent does what, in order.
public struct DeskPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public enum Action: Codable, Equatable, Sendable {
            /// Cut to the ask ("make it 60s", "tighten the open").
            case edit(ask: String?)
            case clips(count: Int)
            case share(launch: Bool)
            /// Draft a script or talking points from the project's sources.
            case script
            /// Something the agents can't do yet; shown so nothing is silently dropped.
            case note(String)
        }

        public var agent: AgentKind
        public var title: String
        public var action: Action
        /// The job that ran it, once started.
        public var jobID: UUID?

        public init(agent: AgentKind, title: String, action: Action) {
            self.agent = agent
            self.title = title
            self.action = action
        }
    }

    public var steps: [Step]
    /// Run the Editor on a copy, so the main cut stays as it is.
    public var inCopy: Bool

    public init(steps: [Step], inCopy: Bool = false) {
        self.steps = steps
        self.inCopy = inCopy
    }

    public var summary: String {
        steps.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
    }
}

/// One entry in a task's thread.
public struct TaskCell: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// What the user typed.
        case ask(String, mode: AskMode)
        /// A take recorded or attached to the task.
        case take(URL)
        /// An agent's short reply.
        case reply(AgentKind, String)
        /// A quiet log line: "Transcribed 1:52 on this Mac".
        case log(String)
        case plan(DeskPlan)
        /// What a job did, with Keep and Undo until answered.
        case receipt(jobID: UUID, AgentKind, String)
        case approval(ApprovalCard)
        case failed(AgentKind, String)
    }

    public let id: UUID
    public var kind: Kind
    public var at: Date

    public init(id: UUID = UUID(), _ kind: Kind, at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.at = at
    }
}

/// One video job in a project: a thread of asks, plans, receipts and
/// approvals around one or more takes.
public struct DeskTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var projectID: UUID
    public var title: String
    public var takeFolders: [URL]
    public var cells: [TaskCell]
    /// Asks typed while agents were busy; they run next, in order. ↑ edits the last.
    public var queued: [String]
    public var mode: AskMode
    /// Agent jobs started from this task, oldest first.
    public var jobIDs: [UUID]
    /// Set by Archive; hidden from the sidebar.
    public var archived: Bool
    /// The agent that started it over MCP ("Claude Code"), for the
    /// "from Claude Code" tag; nil when the user started it.
    public var requestedBy: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, title: String, takes: [Take] = [], mode: AskMode = .justDoIt,
                createdAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.takeFolders = takes.map(\.folder)
        self.cells = takes.map { TaskCell(.take($0.folder), at: createdAt) }
        self.queued = []
        self.mode = mode
        self.jobIDs = []
        self.archived = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var takes: [Take] { takeFolders.map(Take.init(folder:)) }
    /// The take agents work on: the latest one.
    public var take: Take? { takes.last }

    public var openApprovals: [ApprovalCard] {
        cells.compactMap { if case let .approval(card) = $0.kind, card.isOpen { return card } else { return nil } }
    }

    public var pendingPlan: DeskPlan? {
        guard let card = openApprovals.first(where: { $0.subject == .plan }) else { return nil }
        return plan(before: card.id)
    }

    func plan(before cardID: UUID) -> DeskPlan? {
        guard let i = cells.firstIndex(where: { if case let .approval(card) = $0.kind { return card.id == cardID } else { return false } })
        else { return nil }
        return cells[..<i].reversed().compactMap { if case let .plan(plan) = $0.kind { return plan } else { return nil } }.first
    }
}

/// The ring next to a task in the sidebar and the menu bar.
public enum TaskStatus: String, Codable, Sendable {
    /// An approval or a plan is waiting on you.
    case needsYou
    /// An agent is working.
    case working
    /// Finished, with dashed proposals to keep or undo.
    case ready
    case done
    /// The last job didn't finish.
    case failed

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .ready: return "Ready"
        case .done: return "Done"
        case .failed: return "Didn't finish"
        }
    }
}

/// Everything the window and the menu bar show, in one value.
public struct DeskSnapshot: Equatable, Sendable {
    public var projects: [DeskProject]
    public var tasks: [DeskTask]
    public var jobs: [AgentJob]

    public init(projects: [DeskProject] = [], tasks: [DeskTask] = [], jobs: [AgentJob] = []) {
        self.projects = projects
        self.tasks = tasks
        self.jobs = jobs
    }

    public func task(_ id: UUID) -> DeskTask? { tasks.first { $0.id == id } }
    public func project(_ id: UUID) -> DeskProject? { projects.first { $0.id == id } }

    public func tasks(in project: DeskProject, includeArchived: Bool = false) -> [DeskTask] {
        tasks.filter { $0.projectID == project.id && (includeArchived || !$0.archived) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func jobs(for task: DeskTask) -> [AgentJob] {
        task.jobIDs.compactMap { id in jobs.first { $0.id == id } }
    }

    public func status(of task: DeskTask) -> TaskStatus {
        let jobs = jobs(for: task)
        if !task.openApprovals.isEmpty || jobs.contains(where: { $0.state == .needsApproval }) { return .needsYou }
        if jobs.contains(where: { $0.state == .queued || $0.state == .running }) || !task.queued.isEmpty { return .working }
        if jobs.contains(where: { $0.state == .needsReview }) { return .ready }
        if let last = jobs.last, last.state == .failed { return .failed }
        return .done
    }

    /// The line under the task's title: "Needs you · post to Version One",
    /// "Clipper · running, step 3 of 5", "3 clips ready".
    public func statusLine(of task: DeskTask) -> String {
        let jobs = jobs(for: task)
        switch status(of: task) {
        case .needsYou:
            if let job = jobs.last(where: { $0.state == .needsApproval }), let approval = job.approval {
                return "Needs you · " + (approval.isPost ? "post to \(approval.destination)" : "send to \(approval.providerName)")
            }
            return task.openApprovals.first?.subject == ApprovalCard.Subject.plan ? "Needs you · approve the plan" : "Needs you"
        case .working:
            return jobs.last(where: { $0.state == .running || $0.state == .queued })?.statusLine ?? "Working"
        case .ready:
            return jobs.last(where: { $0.state == .needsReview })?.receipt ?? "Ready to review"
        case .failed:
            return jobs.last?.error ?? "Didn't finish"
        case .done:
            return jobs.last?.receipt ?? "Done"
        }
    }

    /// Tasks waiting on the user, newest first: the "2 need you" count.
    public var needsYou: [DeskTask] {
        tasks.filter { !$0.archived && status(of: $0) == .needsYou }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The status bar under the thread: "Clipper is making clips (12 s · Esc to stop)".
    public func activity(of task: DeskTask, now: Date = Date()) -> String? {
        guard let job = jobs(for: task).last(where: { $0.state == .running }) else { return nil }
        let seconds = Int(now.timeIntervalSince(job.createdAt))
        return "\(job.agent.title) is \(job.agent.verb) (\(seconds) s · Esc to stop)"
    }
}

extension AgentKind {
    /// "is making clips".
    public var verb: String {
        switch self {
        case .producer: return "planning"
        case .editor: return "editing"
        case .clipper: return "making clips"
        case .sharer: return "writing the post"
        }
    }
}
