import Foundation

/// Where a task is up to, for its row in the sidebar.
public enum TaskState: String, Equatable, Sendable {
    /// An agent is working on it now.
    case working
    /// Waiting on a yes, or proposals to keep or undo.
    case needsYou
    /// Something didn't finish.
    case failed
    /// Nothing running and nothing waiting.
    case idle

    /// Needs you first, then working, then the rest.
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .failed: return 2
        case .idle: return 3
        }
    }
}

/// One task in the sidebar: a take and the jobs agents ran on it.
public struct TaskSummary: Equatable, Identifiable, Sendable {
    public var take: Take
    public var title: String
    public var state: TaskState
    /// "Clipper · running, step 2 of 4", or nil when idle.
    public var detail: String?
    public var updatedAt: Date?

    public var id: String { take.name }

    public init(take: Take, title: String, jobs: [AgentJob], recordedAt: Date? = nil) {
        self.take = take
        self.title = title
        let latest = jobs.max { $0.updatedAt < $1.updatedAt }
        self.updatedAt = [latest?.updatedAt, recordedAt].compactMap { $0 }.max()
        if let waiting = jobs.first(where: { $0.state.needsYou }) {
            state = .needsYou
            detail = waiting.statusLine
        } else if let running = jobs.first(where: { $0.state.isActive }) {
            state = .working
            detail = running.statusLine
        } else if let latest, latest.state == .failed {
            state = .failed
            detail = latest.statusLine
        } else {
            state = .idle
            detail = nil
        }
    }

    /// Needs you first, then working, then most recent.
    public static func sorted(_ tasks: [TaskSummary]) -> [TaskSummary] {
        tasks.enumerated().sorted { a, b in
            if a.element.state.rank != b.element.state.rank { return a.element.state.rank < b.element.state.rank }
            switch (a.element.updatedAt, b.element.updatedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

extension ApprovalAnswer {
    /// What the gate does with the answer.
    public var decision: OutboundDecision {
        switch self {
        case .yes: return .allowOnce
        case .yesAlways: return .allowForSession
        case .no: return .deny
        }
    }

    /// The note for the agent, from "No, and tell … what to do differently".
    public var feedback: String? {
        guard case let .no(note) = self else { return nil }
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// The words on an agent's approval card in a task.
public enum TaskApprovalText {
    public static func question(agent: AgentKind, approval: AgentJob.Approval) -> String {
        approval.isPost
            ? PostApprovalText.question(to: approval.destination)
            : "Send this to \(approval.providerName)?"
    }

    public static func options(agent: AgentKind, approval: AgentJob.Approval) -> [String] {
        [approval.isPost ? "Yes, post it" : "Yes",
         "Yes, and don't ask again",
         "No, and tell the \(agent.title) what to do differently"]
    }

    /// "Uses your OpenAI key · 1 240 characters · about R0.40".
    public static func detail(_ approval: AgentJob.Approval) -> String {
        var parts = [approval.summary]
        if !approval.isPost { parts.append("\(approval.characters) characters to \(approval.destination)") }
        if let rand = approval.estimatedRand { parts.append(String(format: "about R%.2f", rand)) }
        if approval.fromPlan { parts.append("covered by your plan") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One block in a task's thread, top to bottom.
public enum ThreadCell: Equatable, Identifiable, Sendable {
    /// The recording the task is about.
    case take(Take)
    /// What the builder asked for.
    case ask(jobID: UUID, text: String, at: Date)
    /// The agent's checklist.
    case plan(jobID: UUID, agent: AgentKind, steps: [AgentJob.Step])
    /// The live line while an agent works: "Clipper · Finding moments".
    case status(jobID: UUID, line: String, since: Date)
    /// Something waits for a yes before it leaves the Mac.
    case approval(jobID: UUID, agent: AgentKind, approval: AgentJob.Approval)
    /// What it did, with Keep and Undo while proposals are dashed.
    case receipt(jobID: UUID, agent: AgentKind, text: String, canKeep: Bool, canUndo: Bool, undone: Bool)
    case failed(jobID: UUID, agent: AgentKind, message: String)
    /// Asks typed while an agent was busy, sent when it finishes.
    case queued([String])

    public var id: String {
        switch self {
        case let .take(take): return "take-\(take.name)"
        case let .ask(id, _, _): return "ask-\(id)"
        case let .plan(id, _, _): return "plan-\(id)"
        case let .status(id, _, _): return "status-\(id)"
        case let .approval(id, _, approval): return "approval-\(id)-\(approval.id)"
        case let .receipt(id, _, _, _, _, _): return "receipt-\(id)"
        case let .failed(id, _, _): return "failed-\(id)"
        case .queued: return "queued"
        }
    }
}

public enum TaskThread {
    /// The take, then each job oldest first: the ask, the plan, then the
    /// status, approval, receipt or error; queued asks at the end.
    public static func cells(for take: Take?, jobs: [AgentJob], queued: [String] = []) -> [ThreadCell] {
        var cells: [ThreadCell] = []
        if let take { cells.append(.take(take)) }
        for job in jobs.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let ask = job.ask, !ask.isEmpty {
                cells.append(.ask(jobID: job.id, text: ask, at: job.createdAt))
            }
            if job.steps.count > 1 {
                cells.append(.plan(jobID: job.id, agent: job.agent, steps: job.steps))
            }
            switch job.state {
            case .queued, .running:
                cells.append(.status(jobID: job.id, line: statusLine(for: job), since: job.updatedAt))
            case .needsApproval:
                if let approval = job.approval {
                    cells.append(.approval(jobID: job.id, agent: job.agent, approval: approval))
                } else {
                    cells.append(.status(jobID: job.id, line: statusLine(for: job), since: job.updatedAt))
                }
            case .needsReview, .done, .undone:
                if let receipt = job.receipt {
                    let review = job.state == .needsReview
                    cells.append(.receipt(jobID: job.id, agent: job.agent, text: receipt,
                                          canKeep: review, canUndo: review && !job.changes.isEmpty,
                                          undone: job.state == .undone))
                }
            case .failed:
                cells.append(.failed(jobID: job.id, agent: job.agent, message: job.error ?? "It didn't finish."))
            case .cancelled:
                cells.append(.failed(jobID: job.id, agent: job.agent, message: "Stopped."))
            }
        }
        let asks = queued.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !asks.isEmpty { cells.append(.queued(asks)) }
        return cells
    }

    /// "Clipper · Finding moments", or "Clipper · waiting to start".
    public static func statusLine(for job: AgentJob) -> String {
        if job.state == .running, let n = job.currentStep {
            return "\(job.agent.title) · \(job.steps[n - 1].title)"
        }
        return job.statusLine
    }

    /// "12s", "1m 05s" for how long the agent has been at it.
    public static func elapsed(since start: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// True while any job on the task is queued or running, so new asks
    /// wait in the queue.
    public static func isBusy(_ jobs: [AgentJob]) -> Bool {
        jobs.contains { $0.state == .queued || $0.state == .running }
    }
}
