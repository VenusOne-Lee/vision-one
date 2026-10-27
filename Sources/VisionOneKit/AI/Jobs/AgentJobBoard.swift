import Foundation

/// Which job the current async work belongs to, so an approval asked for
/// deep inside the ladder lands on that job's task instead of a floating
/// panel. `AgentRunner` sets it; nothing else needs to.
public enum AgentJobContext {
    @TaskLocal public static var jobID: UUID?
}

/// Every agent job, newest first: the Agent Desk's task list. Saved to
/// jobs.json so the list survives a relaunch. The app wraps `updates()`
/// in its view model; the MCP server can read `jobs` directly.
public actor AgentJobBoard {
    public private(set) var jobs: [AgentJob] = []
    private let storeURL: URL?
    private var observers: [UUID: AsyncStream<[AgentJob]>.Continuation] = [:]
    private var waiting: [UUID: CheckedContinuation<OutboundDecision, Never>] = [:]
    /// "Tell it what to do instead" from a task's card, for an outside
    /// agent's request, until `takeNote(jobID:)` picks it up.
    private var notes: [UUID: String] = [:]

    /// Jobs are kept for this long after they finish.
    public static let keepFor: TimeInterval = 30 * 24 * 3600

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        if let storeURL, let loaded = Self.load(from: storeURL) { jobs = loaded }
    }

    /// ~/Library/Application Support/Vision One/jobs.json
    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("jobs.json")
    }

    // MARK: Reading

    public func job(_ id: UUID) -> AgentJob? { jobs.first { $0.id == id } }

    public var needsYou: [AgentJob] { jobs.filter { $0.state.needsYou } }

    public func jobs(for take: Take) -> [AgentJob] { jobs.filter { $0.takeFolder == take.folder } }

    /// The current list now, then again after every change.
    public func updates() -> AsyncStream<[AgentJob]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[AgentJob]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(jobs)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Changing

    @discardableResult
    public func add(_ job: AgentJob) -> AgentJob {
        jobs.insert(job, at: 0)
        changed()
        return job
    }

    public func update(_ id: UUID, _ change: @Sendable (inout AgentJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        jobs[i].updatedAt = Date()
        changed()
    }

    /// Marks step `index` (from 0) running and every earlier step done.
    public func step(_ id: UUID, _ index: Int) {
        update(id) { job in
            job.state = .running
            for i in job.steps.indices {
                if i < index, job.steps[i].state == .running || job.steps[i].state == .pending { job.steps[i].state = .done }
                if i == index { job.steps[i].state = .running }
            }
        }
    }

    public func finish(_ id: UUID, receipt: String, changes: [AgentJob.Change]) {
        update(id) { job in
            guard job.state != .cancelled else { return }
            for i in job.steps.indices where job.steps[i].state != .failed {
                job.steps[i].state = job.steps[i].state == .pending ? .skipped : .done
            }
            job.receipt = receipt
            job.changes = changes
            job.approval = nil
            job.state = changes.isEmpty ? .done : .needsReview
        }
    }

    public func fail(_ id: UUID, _ message: String) {
        update(id) { job in
            guard job.state != .cancelled else { return }
            for i in job.steps.indices where job.steps[i].state == .running { job.steps[i].state = .failed }
            job.error = message
            job.approval = nil
            job.state = .failed
        }
    }

    /// Stops a job. A pending approval is answered "no".
    public func cancel(_ id: UUID) {
        resolveApproval(jobID: id, decision: .deny)
        update(id) { job in
            guard job.state.isActive else { return }
            job.state = .cancelled
            job.approval = nil
        }
    }

    /// Takes a job off the list (its changes stay as they are).
    public func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        changed()
    }

    // MARK: Approvals

    /// Parks the request on the job and waits for the user's answer. With
    /// `alsoAsk`, that approver (the floating panel) asks too: both answer
    /// this one pending approval, and the one that didn't answer is
    /// cancelled so it can go away.
    public func requestApproval(jobID: UUID, request: OutboundRequest,
                         alsoAsk: (any OutboundApprover)? = nil) async -> OutboundDecision {
        var ask: (@Sendable () async -> OutboundDecision)?
        if let alsoAsk { ask = { await alsoAsk.approve(request) } }
        return await requestApproval(jobID: jobID, approval: AgentJob.Approval(request), alsoAsk: ask)
    }

    /// The same, for anything shown as an approval: an MCP agent asking
    /// to record or share. `alsoAsk` is another place to answer (the
    /// floating card); once either answers, the other is cancelled.
    public func requestApproval(jobID: UUID, approval: AgentJob.Approval,
                                alsoAsk: (@Sendable () async -> OutboundDecision)? = nil) async -> OutboundDecision {
        guard let job = job(jobID), job.state.isActive else { return .deny }
        let before = job.state
        update(jobID) { $0.state = .needsApproval; $0.approval = approval }
        var asker: Task<Void, Never>?
        let decision = await withCheckedContinuation { continuation in
            waiting[jobID] = continuation
            if let alsoAsk {
                asker = Task {
                    let answer = await alsoAsk()
                    // Answered on the task already: a late "no" from the
                    // panel going away mustn't touch a later approval.
                    guard !Task.isCancelled else { return }
                    self.resolveApproval(jobID: jobID, decision: answer)
                }
            }
        }
        asker?.cancel()
        update(jobID) { job in
            job.approval = nil
            if job.state == .needsApproval { job.state = decision == .deny ? .cancelled : before }
        }
        return decision
    }

    /// The answer from the task's approve card. `note` is "tell it what to
    /// do instead", kept for an outside agent's request (`takeNote`).
    public func resolveApproval(jobID: UUID, decision: OutboundDecision, note: String? = nil) {
        guard let continuation = waiting.removeValue(forKey: jobID) else { return }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            notes[jobID] = note
        }
        continuation.resume(returning: decision)
    }

    /// The note given with the last answer on this job's card, once.
    public func takeNote(jobID: UUID) -> String? {
        notes.removeValue(forKey: jobID)
    }

    /// An approver for the ladder's gate: requests made inside a job wait
    /// on that job's card; anything else goes to `fallback` (the floating
    /// approval panel in the app).
    /// `panelForJobs` keeps the fallback asking for job requests too.
    public nonisolated func approver(fallback: any OutboundApprover, panelForJobs: Bool = false) -> any OutboundApprover {
        JobApprover(board: self, fallback: fallback, panelFor: { _ in panelForJobs })
    }

    /// The same, deciding per job whether the fallback (the floating
    /// panel) asks as well as the job's card, so a request is asked in one
    /// place when the card is in view (`ApprovalSurface`).
    public nonisolated func approver(fallback: any OutboundApprover,
                                     panelFor: @escaping @Sendable (UUID) async -> Bool) -> any OutboundApprover {
        JobApprover(board: self, fallback: fallback, panelFor: panelFor)
    }

    // MARK: Keep and undo

    /// "Keep": the job's dashed cuts and clips become solid.
    public func keep(_ id: UUID) throws {
        guard let job = job(id) else { return }
        try apply(job, keep: true)
        update(id) { $0.state = .done }
    }

    /// "Undo": the job's cuts and clips are taken out and its drafts deleted.
    public func undo(_ id: UUID) throws {
        guard let job = job(id) else { return }
        try apply(job, keep: false)
        update(id) { $0.state = .undone }
    }

    private func apply(_ job: AgentJob, keep: Bool) throws {
        guard let take = job.take else { return }
        let cuts = job.changes.compactMap { if case let .cut(id) = $0 { return id } else { return nil } }
        let clips = job.changes.compactMap { if case let .clip(id) = $0 { return id } else { return nil } }
        let fm = FileManager.default
        let editsURL = job.editsFile.map { take.folder.appendingPathComponent($0) } ?? take.editsURL
        if !cuts.isEmpty, fm.fileExists(atPath: editsURL.path) {
            var list = try EditList.read(from: editsURL)
            for id in cuts {
                if keep { list.setState(.accepted, for: id) } else { list.remove(id: id) }
            }
            try list.write(to: editsURL)
        }
        if !clips.isEmpty, fm.fileExists(atPath: take.clipsURL.path) {
            var list = try ClipList.read(from: take.clipsURL)
            for id in clips {
                if keep { list.setState(.accepted, for: id) } else { list.remove(id: id) }
            }
            try list.write(to: take.clipsURL)
        }
        if !keep, job.changes.contains(.sharePack), fm.fileExists(atPath: take.shareURL.path) {
            try fm.removeItem(at: take.shareURL)
        }
    }

    // MARK: File

    private func changed() {
        for observer in observers.values { observer.yield(jobs) }
        save()
    }

    private func save() {
        guard let storeURL else { return }
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        let kept = jobs.filter { $0.state.isActive || $0.updatedAt > cutoff }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(kept).write(to: storeURL, options: .atomic)
    }

    /// Jobs that were running when the app quit can't pick up again.
    static func load(from url: URL) -> [AgentJob]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var jobs = try? decoder.decode([AgentJob].self, from: data) else { return nil }
        for i in jobs.indices where jobs[i].state.isActive {
            jobs[i].state = .failed
            jobs[i].approval = nil
            jobs[i].error = "Vision One closed before this finished. Run it again."
        }
        return jobs
    }
}

struct JobApprover: OutboundApprover {
    let board: AgentJobBoard
    let fallback: any OutboundApprover
    let panelFor: @Sendable (UUID) async -> Bool

    func approve(_ request: OutboundRequest) async -> OutboundDecision {
        if let id = AgentJobContext.jobID {
            let panel = await panelFor(id)
            return await board.requestApproval(jobID: id, request: request, alsoAsk: panel ? fallback : nil)
        }
        return await fallback.approve(request)
    }
}
