import Foundation

/// The Codex-style harness behind the main window and the menu bar:
/// projects, a task per video, each task's thread, the Producer's plans,
/// queued asks and numbered approvals. Agent work runs as jobs on the
/// `AgentJobBoard`; the Desk files each job under its task.
///
/// One instance for the app (`AIServices.shared.desk`); the MCP server
/// uses the same calls. Saved to desk.json.
public actor Desk {
    public private(set) var projects: [DeskProject] = []
    public private(set) var tasks: [DeskTask] = []
    public private(set) var jobs: [AgentJob] = []

    public let board: AgentJobBoard
    private let storeURL: URL?
    private var observers: [UUID: AsyncStream<DeskSnapshot>.Continuation] = [:]
    private var openObservers: [UUID: AsyncStream<UUID>.Continuation] = [:]
    private var watching: Task<Void, Never>?
    /// Tasks with a plan running now.
    private var busy: Set<UUID> = []

    /// A fresh runner for each plan, so new AI settings apply.
    private var makeRunner: (@Sendable () async -> AgentRunner)?
    /// The brief agents get for a take in a project.
    private var makeBrief: @Sendable (DeskProject, TakePlan) -> AgentBrief = { project, plan in
        var brief = plan.purpose.brief(preset: nil)
        if !project.notes.isEmpty {
            brief.houseStyle = [brief.houseStyle, project.notes].compactMap { $0 }.joined(separator: "\n")
        }
        return brief
    }
    private var sources: ScriptSources?

    public init(board: AgentJobBoard, storeURL: URL? = nil) {
        self.board = board
        self.storeURL = storeURL
        if let storeURL, let saved = Self.load(from: storeURL) {
            projects = saved.projects
            tasks = saved.tasks
        }
    }

    /// ~/Library/Application Support/Vision One/desk.json
    public static var standardURL: URL {
        AgentJobBoard.standardURL.deletingLastPathComponent().appendingPathComponent("desk.json")
    }

    /// Hooks the Desk to the app: how to get a runner, the brief and the
    /// sources; then starts following the job board.
    public func connect(runner: @escaping @Sendable () async -> AgentRunner,
                        brief: (@Sendable (DeskProject, TakePlan) -> AgentBrief)? = nil,
                        sources: ScriptSources? = nil) {
        makeRunner = runner
        if let brief { makeBrief = brief }
        self.sources = sources
        guard watching == nil else { return }
        let board = board
        watching = Task { [weak self] in
            for await jobs in await board.updates() {
                await self?.jobsChanged(jobs)
            }
        }
    }

    // MARK: Reading

    public var snapshot: DeskSnapshot { DeskSnapshot(projects: projects, tasks: tasks, jobs: jobs) }

    public func task(_ id: UUID) -> DeskTask? { tasks.first { $0.id == id } }
    public func project(_ id: UUID) -> DeskProject? { projects.first { $0.id == id } }

    /// The task a job is filed under, if any (archived tasks don't count,
    /// since their cards aren't in view). Decides whether an approval can
    /// wait on the task's card alone (`ApprovalSurface`).
    public func taskID(forJob jobID: UUID) -> UUID? {
        tasks.first { !$0.archived && $0.jobIDs.contains(jobID) }?.id
    }

    /// The current snapshot now, then after every change.
    public func updates() -> AsyncStream<DeskSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DeskSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.dropObserver(id) } }
        return stream
    }

    /// Task ids to show in the main window, from the menu bar, a
    /// notification or the MCP server.
    public func openRequests() -> AsyncStream<UUID> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        openObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropOpenObserver(id) } }
        return stream
    }

    public func requestOpen(_ taskID: UUID) {
        for observer in openObservers.values { observer.yield(taskID) }
    }

    private func dropObserver(_ id: UUID) { observers[id] = nil }
    private func dropOpenObserver(_ id: UUID) { openObservers[id] = nil }

    // MARK: Projects

    /// The project new recordings go into when none is picked.
    public func defaultProject() -> DeskProject {
        if let first = projects.first { return first }
        let project = DeskProject(name: "My videos")
        projects.append(project)
        changed()
        return project
    }

    @discardableResult
    public func newProject(_ name: String, notes: String = "", sources: [ScriptSourceRef] = []) -> DeskProject {
        let project = DeskProject(name: name, notes: notes, sources: sources)
        projects.append(project)
        changed()
        return project
    }

    public func updateProject(_ id: UUID, _ change: @Sendable (inout DeskProject) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
        changed()
    }

    // MARK: Tasks

    /// A new task. With an ask, the Producer starts on it straight away.
    @discardableResult
    public func newTask(in projectID: UUID? = nil, title: String? = nil, takes: [Take] = [], ask: String? = nil,
                        mode: AskMode = .justDoIt) -> DeskTask {
        let project = projectID.flatMap { self.project($0) } ?? defaultProject()
        let task = DeskTask(projectID: project.id, title: title ?? Self.title(for: ask, takes: takes),
                            takes: takes, mode: mode)
        tasks.append(task)
        for take in takes {
            do { try AppliedTemplate.stamp(project.mediaDefaults, on: take) }
            catch {
                update(task.id) { $0.cells.append(TaskCell(.log("Couldn't apply project defaults: \(error.localizedDescription)"))) }
            }
        }
        changed()
        if let ask, !ask.isEmpty { submit(ask, to: task.id, mode: mode) }
        return task
    }

    /// Stop → a task for the new take. With `runAgents`, the automatic
    /// agents (by the Energy dial) start once it's transcribed; call
    /// `transcribed(_:)` then.
    @discardableResult
    public func taskForRecording(_ take: Take, in projectID: UUID? = nil) -> DeskTask {
        if let existing = tasks.first(where: { $0.takeFolders.contains(take.folder) }) { return existing }
        return newTask(in: projectID, title: Self.title(for: nil, takes: [take]), takes: [take])
    }

    /// The take's transcript is ready: log it and start the automatic agents.
    public func transcribed(_ take: Take, duration: Double? = nil, runAgents: Bool = true) {
        let task = taskForRecording(take)
        update(task.id) { task in
            let length = duration.map { " " + Timecode.string(from: $0) } ?? ""
            task.cells.append(TaskCell(.log("Transcribed\(length) on this Mac")))
        }
        guard runAgents else { return }
        let plan = TakePlan.load(for: take) ?? TakePlan(purpose: .demo)
        let steps: [DeskPlan.Step] = AgentRunner.automaticAgents(for: plan).compactMap { agent in
            switch agent {
            case .editor: return AskRouter.edit(nil)
            case .clipper: return AskRouter.clips(3)
            case .sharer: return AskRouter.share(launch: plan.purposeID == "launch" || plan.purposeID == "update")
            case .producer, .autopilot: return nil
            }
        }
        start(DeskPlan(steps: steps), in: task.id)
    }

    public func addTake(_ take: Take, to taskID: UUID) {
        if let task = task(taskID), let project = project(task.projectID) {
            do { try AppliedTemplate.stamp(project.mediaDefaults, on: take) }
            catch { update(taskID) { $0.cells.append(TaskCell(.log("Couldn't apply project defaults: \(error.localizedDescription)"))) } }
        }
        update(taskID) { task in
            guard !task.takeFolders.contains(take.folder) else { return }
            task.takeFolders.append(take.folder)
            task.cells.append(TaskCell(.take(take.folder)))
        }
    }

    public func rename(_ taskID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(taskID) { $0.title = trimmed }
    }

    public func archive(_ taskID: UUID, _ archived: Bool = true) {
        update(taskID) { $0.archived = archived }
    }

    public func move(_ taskID: UUID, to projectID: UUID) {
        guard project(projectID) != nil else { return }
        update(taskID) { $0.projectID = projectID }
    }

    /// Files a job started elsewhere (the MCP server, a full-mode screen)
    /// under a task.
    public func attach(jobID: UUID, to taskID: UUID) {
        update(taskID) { task in
            if !task.jobIDs.contains(jobID) { task.jobIDs.append(jobID) }
        }
        syncCells()
    }

    /// Tags a task started by an agent over MCP.
    public func markRequested(_ taskID: UUID, by agent: String) {
        update(taskID) { $0.requestedBy = agent }
    }

    // MARK: Asking

    /// What the composer sends. Agents run now, after a plan approval
    /// ("Plan first"), or after what's running ("queued"). Commands the
    /// window handles itself come back as `.open`.
    @discardableResult
    public func submit(_ ask: String, to taskID: UUID, mode: AskMode? = nil) -> AskRoute {
        let route = AskRouter.route(ask)
        if case let .clarify(message) = route {
            update(taskID) { $0.cells.append(TaskCell(.log(message))) }
            return route
        }
        guard case let .plan(plan) = route, let task = self.task(taskID) else { return route }
        let chosen = mode ?? task.mode
        if busy.contains(taskID) {
            update(taskID) { $0.queued.append(ask) }
            return route
        }
        update(taskID) { task in
            task.mode = chosen
            task.cells.append(TaskCell(.ask(ask, mode: chosen)))
            task.cells.append(TaskCell(.plan(plan)))
            if chosen == .planFirst { task.cells.append(TaskCell(.approval(.plan(plan.summary)))) }
        }
        if chosen == .justDoIt { start(plan, in: taskID) }
        return route
    }

    /// ↑ in the composer: change or drop a queued ask.
    public func editQueued(_ taskID: UUID, at index: Int, to text: String?) {
        update(taskID) { task in
            guard task.queued.indices.contains(index) else { return }
            if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { task.queued[index] = text }
            else { task.queued.remove(at: index) }
        }
    }

    /// A numbered choice on an approval card. `note` is "tell it what to
    /// do differently" after a no.
    public func answer(_ cardID: UUID, in taskID: UUID, choice: Int, note: String? = nil) async {
        guard let task = self.task(taskID),
              let card = task.cells.compactMap({ cell -> ApprovalCard? in
                  if case let .approval(c) = cell.kind, c.id == cardID { return c } else { return nil }
              }).first, card.isOpen, card.options.indices.contains(choice) else { return }
        let effect = card.options[choice].effect
        setAnswer(cardID, in: taskID, choice: choice, note: note)
        switch card.subject {
        case .plan:
            if effect == .deny {
                if let note, !note.isEmpty { submit(note, to: taskID, mode: .planFirst) }
            } else if let plan = task.plan(before: cardID) {
                start(plan, in: taskID)
            }
        case let .job(jobID):
            let decision: OutboundDecision = effect == .deny ? .deny : (effect == .allowAlways ? .allowForSession : .allowOnce)
            // An outside agent's request (MCP): the note goes back to that
            // agent in its tool reply, not to Vision One's own agents.
            let fromAgent = jobs.first { $0.id == jobID }?.approval?.askedBy != nil
            if fromAgent {
                await board.resolveApproval(jobID: jobID, decision: decision, note: effect == .deny ? note : nil)
            } else {
                await board.resolveApproval(jobID: jobID, decision: decision)
                if effect == .deny, let note, !note.isEmpty { submit(note, to: taskID) }
            }
        }
    }

    /// Return on the card: the preselected choice.
    public func confirm(_ cardID: UUID, in taskID: UUID) async {
        guard let card = self.task(taskID)?.openApprovals.first(where: { $0.id == cardID }) else { return }
        await answer(cardID, in: taskID, choice: card.preselected)
    }

    /// Esc: stops what's running in the task and drops its queue.
    public func stop(_ taskID: UUID) async {
        guard let task = self.task(taskID) else { return }
        update(taskID) { $0.queued.removeAll() }
        for job in snapshot.jobs(for: task) where job.state.isActive { await board.cancel(job.id) }
    }

    // MARK: Keep and undo

    public func keep(_ jobID: UUID) async throws {
        try await board.keep(jobID)
        logOnTask(of: jobID, "Kept")
    }

    public func undo(_ jobID: UUID) async throws {
        try await board.undo(jobID)
        logOnTask(of: jobID, "Undone")
    }

    /// "Keep all" for a task.
    public func keepAll(in taskID: UUID) async throws {
        guard let task = self.task(taskID) else { return }
        for job in snapshot.jobs(for: task) where job.state == .needsReview { try await keep(job.id) }
    }

    private func logOnTask(of jobID: UUID, _ text: String) {
        guard let task = tasks.first(where: { $0.jobIDs.contains(jobID) }),
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        update(task.id) { $0.cells.append(TaskCell(.log("\(text): \(job.receipt ?? job.title)"))) }
    }

    // MARK: Running a plan

    private func start(_ plan: DeskPlan, in taskID: UUID) {
        guard !plan.steps.isEmpty, let makeRunner = self.makeRunner else { return }
        busy.insert(taskID)
        changed()
        Task {
            var runner = await makeRunner()
            runner.onJobAdded = { [weak self] job in await self?.attach(jobID: job.id, to: taskID) }
            await self.run(plan, in: taskID, with: runner)
        }
    }

    private func run(_ plan: DeskPlan, in taskID: UUID, with runner: AgentRunner) async {
        defer { Task { await self.finished(taskID) } }
        guard let task = self.task(taskID), let project = self.project(task.projectID) else { return }
        let take = task.take
        let takePlan = take.flatMap { TakePlan.load(for: $0) } ?? TakePlan(purpose: .demo)
        let brief = makeBrief(project, takePlan)

        // A locked main cut (already exported) is edited in a copy.
        var version: TakeVersion?
        if let take, plan.inCopy || TakeVersions.load(for: take).main.locked,
           plan.steps.contains(where: { $0.agent == .editor }) {
            var versions = TakeVersions.load(for: take)
            if let copy = try? versions.makeCopy(in: take) {
                try? versions.write(for: take)
                version = copy
                update(taskID) { $0.cells.append(TaskCell(.log("Working in \(copy.name); the main cut stays as it is"))) }
            }
        }

        for step in plan.steps {
            let job: AgentJob
            switch step.action {
            case let .edit(ask):
                guard let take else { note(taskID, "There's no take in this task yet. Record or add one first."); return }
                let goal = ask.map(EditorAgent.Goal.parse) ?? EditorAgent.Goal(targetSeconds: takePlan.targetSeconds)
                job = await runner.edit(take, brief: brief, goal: goal, energy: takePlan.energy, version: version)
            case let .clips(count):
                guard let take else { note(taskID, "There's no take in this task yet. Record or add one first."); return }
                let format = takePlan.purpose.formats.compactMap(ClipFormat.init(rawValue:)).first ?? .vertical
                job = await runner.clips(take, brief: brief, format: format, count: count)
            case let .share(launch):
                guard let take else { note(taskID, "There's no take in this task yet. Record or add one first."); return }
                job = await runner.share(take, brief: brief, launch: launch)
            case .script:
                let ask = self.task(taskID)?.cells.reversed().compactMap { cell -> String? in
                    if case let .ask(text, _) = cell.kind { return text } else { return nil }
                }.first
                let (done, script) = await runner.script(sources: sources, refs: project.sources, brief: brief, ask: ask)
                if let script {
                    update(taskID) { $0.cells.append(TaskCell(.reply(.producer, "**\(script.title)**\n\(script.text)"))) }
                }
                job = done
            case let .note(text):
                note(taskID, text)
                continue
            }
            // A "no" or a failure stops the rest of the plan.
            if job.state == .cancelled || job.state == .failed { return }
        }
    }

    private func note(_ taskID: UUID, _ text: String) {
        update(taskID) { $0.cells.append(TaskCell(.reply(.producer, text))) }
    }

    private func finished(_ taskID: UUID) {
        busy.remove(taskID)
        guard let task = self.task(taskID), let next = task.queued.first else { changed(); return }
        update(taskID) { $0.queued.removeFirst() }
        submit(next, to: taskID)
    }

    // MARK: Following jobs

    private func jobsChanged(_ jobs: [AgentJob]) {
        self.jobs = jobs
        syncCells()
    }

    /// Mirrors job state into threads: an approval card while a job waits,
    /// a receipt (or the error) when it ends.
    private func syncCells() {
        var dirty = false
        for t in tasks.indices {
            for jobID in tasks[t].jobIDs {
                guard let job = jobs.first(where: { $0.id == jobID }) else { continue }
                let cardIndex = tasks[t].cells.lastIndex {
                    if case let .approval(card) = $0.kind, card.subject == .job(jobID), card.isOpen { return true }
                    return false
                }
                if job.state == .needsApproval, let approval = job.approval {
                    if cardIndex == nil {
                        let project = projects.first { $0.id == tasks[t].projectID }?.name ?? "this project"
                        tasks[t].cells.append(TaskCell(.approval(.job(jobID, approval: approval, agent: job.agent, project: project))))
                        dirty = true
                    }
                } else if let i = cardIndex, case var .approval(card) = tasks[t].cells[i].kind {
                    // Answered elsewhere (the floating panel), or the job moved on.
                    card.answer = job.state == .cancelled ? card.options.lastIndex(where: { $0.effect == .deny }) : 0
                    tasks[t].cells[i].kind = .approval(card)
                    dirty = true
                }
                let ended = ([.needsReview, .done, .failed] as [AgentJob.State]).contains(job.state)
                let hasEnd = tasks[t].cells.contains {
                    switch $0.kind {
                    case let .receipt(id, _, _): return id == jobID
                    case .failed: return $0.id == jobID
                    default: return false
                    }
                }
                if ended, !hasEnd {
                    if job.state == .failed {
                        tasks[t].cells.append(TaskCell(id: jobID, .failed(job.agent, job.error ?? "Didn't finish")))
                    } else {
                        tasks[t].cells.append(TaskCell(.receipt(jobID: jobID, job.agent, job.receipt ?? job.title)))
                    }
                    tasks[t].updatedAt = Date()
                    dirty = true
                }
            }
        }
        if dirty { save() }
        publish()
    }

    private func setAnswer(_ cardID: UUID, in taskID: UUID, choice: Int, note: String?) {
        update(taskID) { task in
            guard let i = task.cells.firstIndex(where: { cell in
                if case let .approval(c) = cell.kind { return c.id == cardID } else { return false }
            }), case var .approval(card) = task.cells[i].kind else { return }
            card.answer = choice
            card.note = note
            task.cells[i].kind = .approval(card)
        }
    }

    // MARK: Store

    private func update(_ taskID: UUID, _ change: @Sendable (inout DeskTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        change(&tasks[i])
        tasks[i].updatedAt = Date()
        changed()
    }

    private func changed() {
        save()
        publish()
    }

    private func publish() {
        let snap = snapshot
        for observer in observers.values { observer.yield(snap) }
    }

    struct Stored: Codable {
        var version = 1
        var projects: [DeskProject]
        var tasks: [DeskTask]
    }

    private func save() {
        guard let storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(Stored(projects: projects, tasks: tasks)).write(to: storeURL, options: .atomic)
    }

    static func load(from url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var stored = try? decoder.decode(Stored.self, from: data) else { return nil }
        // Queued asks and open approvals can't survive a quit.
        for t in stored.tasks.indices {
            stored.tasks[t].queued = []
            for c in stored.tasks[t].cells.indices {
                if case var .approval(card) = stored.tasks[t].cells[c].kind, card.isOpen, card.subject != .plan {
                    card.answer = card.options.lastIndex(where: { $0.effect == .deny })
                    stored.tasks[t].cells[c].kind = .approval(card)
                }
            }
        }
        return stored
    }

    /// "Launch video · 27 Oct 14:52", or the ask's first words.
    static func title(for ask: String?, takes: [Take]) -> String {
        if let ask, !ask.isEmpty {
            let words = ask.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(separator: " ").prefix(6)
            let text = words.joined(separator: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        guard let take = takes.last else { return "New task" }
        if let title = take.customTitle() { return title }
        let purpose = TakePlan.load(for: take)?.purpose.title ?? "Recording"
        return "\(purpose) · \(take.name)"
    }
}
