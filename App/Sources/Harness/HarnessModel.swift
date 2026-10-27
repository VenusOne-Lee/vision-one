import AppKit
import SwiftUI
import VisionOneKit

/// What the main window shows beside the sidebar.
enum HarnessPage: Equatable {
    /// "What should we make?" with the composer.
    case newTask
    /// Every take, to search and pick from.
    case library
    /// One take's thread and its panels.
    case task(Take)

    var take: Take? {
        if case let .task(take) = self { return take }
        return nil
    }
}

/// The switch in the top bar. Editor and Sound fill the window with a
/// slim task rail; Esc comes back to Tasks.
enum HarnessMode: String, CaseIterable, Identifiable {
    case tasks, editor, sound
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: return "Tasks"
        case .editor: return "Editor"
        case .sound: return "Sound"
        }
    }
}

/// The open take's editor, clips and thumbnail models, made when a task
/// is opened and closed when another one is.
@MainActor
final class TaskWorkspace: ObservableObject {
    let take: Take
    let editor: EditorModel
    let clips: ClipsModel
    let thumbnail: ThumbnailModel
    private var loaded = false

    init(take: Take) {
        self.take = take
        editor = EditorModel(take: take)
        clips = ClipsModel(take: take, editor: editor)
        thumbnail = ThumbnailModel(take: take, editor: editor, clips: clips)
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        await editor.load()
        await clips.load()
    }

    func close() {
        editor.close()
        clips.close()
    }
}

/// The Codex-style frame's state: projects and their tasks, the agents'
/// jobs, what's open, the panel layout for each task and the asks
/// waiting for an agent to finish.
@MainActor
final class HarnessModel: ObservableObject {
    static let shared = HarnessModel()

    @Published private(set) var book: ProjectBook
    @Published private(set) var takes: [Take] = []
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var jobs: [AgentJob] = []
    @Published var page: HarnessPage = .newTask {
        didSet { pageChanged(from: oldValue) }
    }
    @Published var mode: HarnessMode = .tasks
    /// The project "New task" adds to.
    @Published var project: UUID = ProjectBook.defaultID
    @Published private(set) var workspace: TaskWorkspace?
    @Published private(set) var panels: PanelLayoutBook
    /// Asks typed while an agent was busy, by take folder name.
    @Published private(set) var queued: [String: [String]] = [:]
    /// Asks typed on New task, for the next recording.
    @Published private(set) var nextTakeAsks: [String] = []
    @Published var problem: String?
    /// What's typed in the composer, kept per window so approval cards
    /// can start a reply ("No, and tell Sharer…").
    @Published var draft = ""
    /// Bumped to put the cursor in the composer.
    @Published var focusComposer = 0

    private var watching: Task<Void, Never>?
    private var knownTakes: Set<String> = []

    private init() {
        book = ProjectBook.load()
        panels = PanelLayoutBook.decode(UserDefaults.standard.data(forKey: "harness.panels"))
        refreshTakes()
        knownTakes = Set(takes.map(\.name))
        watchJobs()
    }

    // MARK: Takes and tasks

    func refreshTakes() {
        let latest = TakeLibrary.standard.takes()
        var names: [String: String] = [:]
        for take in latest { names[take.name] = take.displayTitle() }
        if latest != takes { takes = latest }
        if names != titles { titles = names }
        adoptNewTakes()
        flushQueued()
    }

    func title(of take: Take) -> String { titles[take.name] ?? take.shortLabel() }

    func jobs(for take: Take) -> [AgentJob] { jobs.filter { $0.takeFolder?.lastPathComponent == take.name } }

    func tasks(in project: UUID) -> [TaskSummary] {
        TaskSummary.sorted(book.takes(in: project, from: takes).map { take in
            TaskSummary(take: take, title: title(of: take), jobs: jobs(for: take), recordedAt: take.recordedAt())
        })
    }

    var needsYouCount: Int { Set(jobs.filter { $0.state.needsYou }.compactMap(\.takeFolder)).count }

    var mentionCandidates: [MentionCandidate] {
        takes.map { MentionCandidate(take: $0, title: title(of: $0)) }
    }

    func open(_ take: Take, panel: PanelKind? = nil) {
        if page.take != take { page = .task(take) }
        if let panel { updateLayout { $0.show(panel) } }
    }

    func rename(_ take: Take, to name: String) {
        try? take.setTitle(name)
        refreshTakes()
    }

    /// Takes recorded since launch land in the project New task was on.
    private func adoptNewTakes() {
        let fresh = takes.filter { !knownTakes.contains($0.name) }
        guard !fresh.isEmpty else { return }
        knownTakes.formUnion(fresh.map(\.name))
        if project != ProjectBook.defaultID {
            for take in fresh { book.move(take, to: project) }
            saveBook()
        }
        if let newest = fresh.first, !nextTakeAsks.isEmpty {
            queued[newest.name, default: []].append(contentsOf: nextTakeAsks)
            nextTakeAsks = []
        }
    }

    // MARK: Projects

    func addProject() {
        let added = book.add(named: "New project")
        saveBook()
        project = added.id
        page = .newTask
    }

    func renameProject(_ id: UUID, to name: String) {
        book.rename(id, to: name)
        saveBook()
    }

    func deleteProject(_ id: UUID) {
        book.delete(id)
        if project == id { project = ProjectBook.defaultID }
        saveBook()
    }

    func move(_ take: Take, to id: UUID) {
        book.move(take, to: id)
        saveBook()
    }

    func reorderProjects(from source: IndexSet, to destination: Int) {
        book.reorder(from: source, to: destination)
        saveBook()
    }

    private func saveBook() {
        do { try book.save() } catch { problem = "Couldn't save your projects: \(error.localizedDescription)" }
    }

    // MARK: Panels

    var layout: PanelLayout {
        page.take.map { panels.layout(for: $0.name) } ?? panels.last
    }

    func updateLayout(_ change: (inout PanelLayout) -> Void) {
        var next = layout
        change(&next)
        if let take = page.take {
            panels.set(next, for: take.name)
        } else {
            panels.last = next
        }
        UserDefaults.standard.set(panels.encoded(), forKey: "harness.panels")
    }

    // MARK: Asking

    /// Reads the composer: / commands, @takes, or plain words for the
    /// Editor. Agents busy on the task? The ask waits in the queue.
    func send(_ raw: String) {
        let input = ComposerInput.parse(raw, candidates: mentionCandidates)
        guard !input.isEmpty else { return }
        let take = input.mentions.first ?? page.take
        if let take, page.take != take { page = .task(take) }

        switch input.command {
        case .record:
            if !input.text.isEmpty { nextTakeAsks.append(input.text) }
            Task { await ScreenRecorder.shared.toggle() }
        case .edit:
            mode = .editor
        case .sound:
            mode = .sound
        case .review:
            mode = .tasks
            updateLayout { $0.show(.changes) }
        case .copy:
            CopyStyleWindowController.shared.show()
        case .captions:
            if let take {
                var settings = take.loadCaptionSettings()
                settings.isOn = true
                try? take.saveCaptionSettings(settings)
                updateLayout { $0.show(.captions) }
            }
        case .music:
            // The music picker lives in the Sound panel.
            updateLayout { $0.show(.sound) }
        case .style:
            updateLayout { $0.show(.formats) }
        case .clips, .share, .cut, nil:
            guard let take else {
                // Nothing recorded yet: keep it for the next take.
                nextTakeAsks.append(raw.trimmingCharacters(in: .whitespaces))
                return
            }
            enqueueOrRun(raw, on: take)
        }
    }

    private func enqueueOrRun(_ raw: String, on take: Take) {
        let busy = TaskThread.isBusy(jobs(for: take))
        let ready = FileManager.default.fileExists(atPath: take.transcriptURL.path)
        if busy || !ready {
            queued[take.name, default: []].append(raw)
        } else {
            run(raw, on: take)
        }
    }

    /// Sends the oldest waiting ask of each task whose agents are free and
    /// whose transcript is in.
    private func flushQueued() {
        for (name, asks) in queued where !asks.isEmpty {
            guard let take = takes.first(where: { $0.name == name }),
                  !TaskThread.isBusy(jobs(for: take)),
                  FileManager.default.fileExists(atPath: take.transcriptURL.path) else { continue }
            var rest = asks
            let next = rest.removeFirst()
            queued[name] = rest.isEmpty ? nil : rest
            run(next, on: take)
        }
    }

    func dropQueued(_ ask: String, on take: Take) {
        queued[take.name]?.removeAll { $0 == ask }
        if queued[take.name]?.isEmpty == true { queued[take.name] = nil }
    }

    private func run(_ raw: String, on take: Take) {
        let input = ComposerInput.parse(raw, candidates: mentionCandidates)
        let ai = AIServices.shared
        let plan = ai.plan(for: take)
        let brief = ai.brief(for: plan)
        let runner = ai.runner()
        let text = input.text
        Task {
            switch input.command {
            case .clips:
                let count = text.firstMatch(of: #/\d+/#).flatMap { Int($0.output) }.map { min(10, max(1, $0)) } ?? 3
                _ = await runner.clips(take, brief: brief, count: count)
            case .share:
                let lowered = text.lowercased()
                _ = await runner.share(take, brief: brief, launch: lowered.contains("version one") || lowered.contains("launch"))
            default:
                _ = await runner.edit(take, brief: brief, goal: EditorAgent.Goal.parse(text.isEmpty ? raw : text),
                                  energy: plan.energy, title: text.isEmpty ? nil : Self.short(text))
            }
        }
    }

    static func short(_ text: String) -> String {
        let one = text.prefix(1).uppercased() + text.dropFirst()
        return one.count > 48 ? String(one.prefix(47)) + "…" : one
    }

    // MARK: Approvals, keep and undo

    /// Keep makes the job's dashed proposals solid; Undo takes them out.
    /// With the take open, the cuts go through its editor first, so ⌘Z
    /// brings them back and the editor never writes stale cuts over them.
    func settle(_ jobID: UUID, keep: Bool) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        if let workspace, workspace.take.name == job.takeFolder?.lastPathComponent {
            let cuts = job.changes.compactMap { change -> UUID? in
                if case let .cut(id) = change { return id }
                return nil
            }
            workspace.editor.settleAgentCuts(cuts, keep: keep, agent: job.agent.title)
        }
        let board = AIServices.shared.jobs
        Task {
            do {
                if keep { try await board.keep(jobID) } else { try await board.undo(jobID) }
            } catch {
                problem = "Couldn't \(keep ? "keep" : "undo") it: \(error.localizedDescription)"
            }
            if let workspace, workspace.take.name == job.takeFolder?.lastPathComponent { await workspace.clips.load() }
        }
    }

    /// An answer on a task's approval card. "No" with a note sends the
    /// note back to the same agent as a new ask; without one, the cursor
    /// goes to the composer.
    func answer(_ jobID: UUID, _ answer: ApprovalAnswer, agent: AgentKind) {
        let board = AIServices.shared.jobs
        Task { await board.resolveApproval(jobID: jobID, decision: answer.decision) }
        guard !answer.isYes else { return }
        if let note = answer.feedback, let take = page.take {
            let prefix = agent == .clipper ? "/clips " : (agent == .sharer ? "/share " : "")
            enqueueOrRun(prefix + note, on: take)
        } else {
            focusComposer += 1
        }
    }

    func stop(_ jobID: UUID) {
        let board = AIServices.shared.jobs
        Task { await board.cancel(jobID) }
    }

    /// Stops whatever is running on the open task (Esc in the thread).
    func stopRunning() {
        guard let take = page.take else { return }
        for job in jobs(for: take) where job.state == .queued || job.state == .running { stop(job.id) }
    }

    // MARK: Private

    private func watchJobs() {
        let board = AIServices.shared.jobs
        watching = Task { [weak self] in
            for await jobs in await board.updates() {
                guard let self else { return }
                self.jobs = jobs
                self.flushQueued()
            }
        }
    }

    private func pageChanged(from old: HarnessPage) {
        guard old.take != page.take else { return }
        workspace?.close()
        workspace = page.take.map(TaskWorkspace.init(take:))
        if page.take == nil { mode = .tasks }
        if let take = page.take { project = book.projectID(for: take) }
    }

    /// For the window's ⌘Z.
    var undoManager: UndoManager? { workspace?.editor.undoManager }
}
