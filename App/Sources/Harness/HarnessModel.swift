import AppKit
import SwiftUI
import VisionOneKit

/// What the main window shows beside the sidebar.
enum HarnessPage: Equatable {
    /// "What should we make?" with the composer.
    case newTask
    /// Every take, to search and pick from.
    case library
    /// One task's thread and its panels.
    case task(UUID)

    var taskID: UUID? {
        if case let .task(id) = self { return id }
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

    init(take: Take, renderPhase: EditorModel.Phase? = nil) {
        self.take = take
        editor = EditorModel(take: take, renderPhase: renderPhase)
        clips = ClipsModel(take: take, editor: editor)
        thumbnail = ThumbnailModel(take: take, editor: editor, clips: clips)
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        await editor.loadIfNeeded()
        await clips.load()
    }

    func close() {
        editor.close()
        clips.close()
    }
}

/// The window's side of the Desk: what's open, the mode, the open take's
/// models and the panel layout for each task. Projects, tasks, threads,
/// queues and approvals all live in the Desk (AIServices.shared.desk),
/// which the menu bar and the MCP server share.
@MainActor
final class HarnessModel: ObservableObject {
    static let shared = HarnessModel()

    @Published private(set) var snapshot = DeskSnapshot()
    @Published private(set) var takes: [Take] = []
    @Published private(set) var titles: [String: String] = [:]
    @Published var page: HarnessPage = .newTask {
        didSet { pageChanged(from: oldValue) }
    }
    @Published var mode: HarnessMode = .tasks
    /// The project New task adds to; nil until the Desk has one.
    @Published var project: UUID?
    @Published private(set) var workspace: TaskWorkspace?
    @Published private(set) var panels: PanelLayoutBook
    @Published var problem: String?
    @Published var preparingRecording = false
    @Published var presentingExport = false
    @Published var clarification: String?
    /// What's typed in the composer.
    @Published var draft = ""
    /// Bumped to put the cursor in the composer.
    @Published var focusComposer = 0
    /// Just do it or Plan first, for the next ask. Follows the open task.
    @Published var askMode: AskMode = .justDoIt

    private var desk: Desk { AIServices.shared.desk }
    private var watching: [Task<Void, Never>] = []
    private var drafts: [String: String] = [:]

    /// Native render diagnostics use an isolated snapshot, never the live Desk.
    let isFixture: Bool

    init(snapshot: DeskSnapshot, takes: [Take], page: HarnessPage, renderPhase: EditorModel.Phase? = nil) {
        isFixture = true
        panels = PanelLayoutBook()
        self.snapshot = snapshot
        self.takes = takes
        titles = Dictionary(uniqueKeysWithValues: takes.map { ($0.name, $0.displayTitle()) })
        self.page = page
        project = snapshot.projects.first?.id
        workspace = snapshot.task(page.taskID ?? UUID())?.take.map { TaskWorkspace(take: $0, renderPhase: renderPhase) }
    }

    private init() {
        isFixture = false
        panels = PanelLayoutBook.decode(UserDefaults.standard.data(forKey: "harness.panels"))
        refreshTakes()
        watchDesk()
    }

    // MARK: Reading

    var task: DeskTask? { page.taskID.flatMap { snapshot.task($0) } }

    var currentProject: DeskProject? {
        project.flatMap { snapshot.project($0) } ?? snapshot.projects.first
    }

    func refreshTakes() {
        guard !isFixture else { return }
        let latest = TakeLibrary.standard.takes()
        var names: [String: String] = [:]
        for take in latest { names[take.name] = take.displayTitle() }
        if latest != takes { takes = latest }
        if names != titles { titles = names }
    }

    func title(of take: Take) -> String { titles[take.name] ?? take.shortLabel() }

    var mentionCandidates: [MentionCandidate] {
        takes.map { MentionCandidate(take: $0, title: title(of: $0)) }
    }

    // MARK: Opening

    func open(_ taskID: UUID, panel: PanelKind? = nil) {
        if page.taskID != taskID { page = .task(taskID) }
        if let panel { updateLayout { $0.show(panel) } }
    }

    /// A take's task, made if the take has none yet (one recorded before
    /// tasks existed, or picked from the Library).
    func open(_ take: Take, panel: PanelKind? = nil, then ask: String? = nil, mode: HarnessMode = .tasks) {
        let projectID = project
        let chosenAskMode = askMode
        Task {
            let task = await desk.taskForRecording(take, in: projectID)
            snapshot = await desk.snapshot
            open(task.id, panel: panel)
            self.mode = mode
            if let ask {
                self.askMode = chosenAskMode
                self.send(ask)
            }
        }
    }

    func importVideo() {
        let projectID = project
        VideoImporter.shared.choose { take in
            Task {
                let task = await self.desk.taskForRecording(take, in: projectID)
                self.snapshot = await self.desk.snapshot
                self.refreshTakes()
                self.open(task.id)
            }
        }
    }

    // MARK: Projects and tasks

    func addProject() {
        let desk = self.desk
        Task {
            let made = await desk.newProject("New project")
            self.project = made.id
            self.page = .newTask
        }
    }

    func renameProject(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let desk = self.desk
        Task { await desk.updateProject(id) { $0.name = clean } }
    }

    func renameTask(_ id: UUID, to name: String) {
        let desk = self.desk
        Task { await desk.rename(id, to: name) }
    }

    func move(_ taskID: UUID, to projectID: UUID) {
        let desk = self.desk
        Task { await desk.move(taskID, to: projectID) }
    }

    func archive(_ taskID: UUID) {
        if page.taskID == taskID { page = .newTask }
        let desk = self.desk
        Task { await desk.archive(taskID) }
    }

    func restore(_ taskID: UUID) {
        let desk = self.desk
        Task {
            await desk.archive(taskID, false)
            snapshot = await desk.snapshot
            open(taskID)
        }
    }

    // MARK: Panels

    var layout: PanelLayout {
        page.taskID.map { panels.layout(for: $0.uuidString) } ?? panels.last
    }

    func updateLayout(_ change: (inout PanelLayout) -> Void) {
        var next = layout
        change(&next)
        if let id = page.taskID {
            panels.set(next, for: id.uuidString)
        } else {
            panels.last = next
        }
        if !isFixture { UserDefaults.standard.set(panels.encoded(), forKey: "harness.panels") }
    }

    // MARK: Asking

    /// The composer's Send. @take points the ask at that take's task;
    /// on New task it starts a task. Commands the window handles itself
    /// (/record, /edit, /captions…) open here.
    func send(_ raw: String) {
        let input = ComposerInput.parse(raw, candidates: mentionCandidates)
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let desk = self.desk
        let route = AskRouter.route(text)
        if case let .clarify(message) = route {
            draft = raw
            clarification = message
            return
        }
        if case let .open(name) = route {
            if let take = input.mentions.first {
                let projectID = project
                Task {
                    let task = await desk.taskForRecording(take, in: projectID)
                    snapshot = await desk.snapshot
                    open(task.id)
                    openCommand(name, rest: text)
                }
            } else {
                openCommand(name, rest: text)
            }
            return
        }
        if let take = input.mentions.first {
            Task {
                let task = await desk.taskForRecording(take, in: self.project)
                await desk.submit(text, to: task.id, mode: self.askMode)
                self.open(task.id)
            }
        } else if let id = page.taskID {
            let mode = askMode
            Task { await desk.submit(text, to: id, mode: mode) }
        } else {
            // New task: with no take it's a plan or a script; the Producer
            // starts on it and the recording joins the task later.
            let mode = askMode
            let project = self.project
            Task {
                let task = await desk.newTask(in: project, ask: text, mode: mode)
                self.open(task.id)
            }
        }
    }

    private func openCommand(_ name: String, rest: String) {
        if ["edit", "sound", "review", "captions", "music", "export"].contains(name), workspace == nil {
            problem = "Open a task with a video, or import or record one first."
            return
        }
        switch name {
        case "export": presentingExport = true
        case "library": page = .library; mode = .tasks
        case "record":
            if ScreenRecorder.shared.phase.isLive {
                Task { await ScreenRecorder.shared.toggle() }
            } else { preparingRecording = true }
        case "import": importVideo()
        case "edit", "sound":
            guard workspace != nil else {
                problem = "Open a task with a video, or import or record one first."
                return
            }
            mode = name == "edit" ? .editor : .sound
        case "review":
            mode = .tasks
            updateLayout { $0.show(.changes) }
        case "captions":
            if let take = workspace?.take {
                var settings = take.loadCaptionSettings()
                settings.isOn = true
                do { try take.saveCaptionSettings(settings) }
                catch { problem = "Couldn't save captions: \(error.localizedDescription)" }
            }
            updateLayout { $0.show(.captions) }
        case "music":
            updateLayout { $0.show(.sound) }
        case "style":
            CopyStyleWindowController.shared.show()
        default:
            problem = "There's no /\(name) command. Type / to see them all."
        }
    }

    func retryRequest(before cellID: UUID, in taskID: UUID) {
        guard let task = snapshot.task(taskID), let index = task.cells.firstIndex(where: { $0.id == cellID }) else { return }
        let ask = task.cells[..<index].reversed().compactMap { cell -> (String, AskMode)? in
            if case let .ask(text, mode) = cell.kind { return (text, mode) }
            return nil
        }.first
        guard let (text, mode) = ask else { return }
        let desk = self.desk
        Task { await desk.submit(text, to: taskID, mode: mode) }
    }

    /// ↑ in the composer, or × on a queued ask.
    func editQueued(at index: Int, to text: String?) {
        guard let id = page.taskID else { return }
        let desk = self.desk
        Task { await desk.editQueued(id, at: index, to: text) }
    }

    // MARK: Approvals, keep and undo

    /// A numbered answer on a card, with the note after a no.
    func answer(_ card: ApprovalCardModel, _ answer: ApprovalAnswer) {
        guard let taskID = page.taskID else { return }
        let effect: ApprovalOption.Effect
        let note: String?
        switch answer {
        case .yes: effect = .allowOnce; note = nil
        case .yesAlways: effect = .allowAlways; note = nil
        case let .no(feedback): effect = .deny; note = feedback.isEmpty ? nil : feedback
        }
        // An agent driving the Mac can't say yes for you (see PersonInput).
        if effect != .deny, !PersonInput.pressedByPerson() {
            NSSound.beep()
            return
        }
        let choice = card.options.firstIndex { $0.effect == effect } ?? card.preselected
        let desk = self.desk
        Task { await desk.answer(card.id, in: taskID, choice: choice, note: note) }
    }

    /// Keep makes the job's dashed proposals solid; Undo takes them out.
    /// With the take open, the cuts go through its editor first, so ⌘Z
    /// brings them back and the editor never writes stale cuts over them.
    func settle(_ jobID: UUID, keep: Bool) {
        guard let job = snapshot.jobs.first(where: { $0.id == jobID }) else { return }
        let here = workspace.flatMap { $0.take.folder.lastPathComponent == job.takeFolder?.lastPathComponent ? $0 : nil }
        if let here {
            let cuts = job.changes.compactMap { change -> UUID? in
                if case let .cut(id) = change { return id }
                return nil
            }
            here.editor.settleAgentCuts(cuts, keep: keep, agent: job.agent.title)
        }
        let desk = self.desk
        Task {
            do {
                if keep { try await desk.keep(jobID) } else { try await desk.undo(jobID) }
            } catch {
                self.problem = "Couldn't \(keep ? "keep" : "undo") it: \(error.localizedDescription)"
            }
            if let here { await here.clips.load() }
        }
    }

    /// Esc: stops what's running on the open task and drops its queue.
    func stopRunning() {
        guard let id = page.taskID,
              let task, snapshot.status(of: task) == .working else { return }
        let desk = self.desk
        Task { await desk.stop(id) }
    }

    // MARK: Private

    private func watchDesk() {
        let desk = self.desk
        watching.append(Task { [weak self] in
            for await snapshot in await desk.updates() {
                guard let self else { return }
                self.snapshot = snapshot
                if self.project == nil { self.project = snapshot.projects.first?.id }
                self.syncWorkspace()
            }
        })
        watching.append(Task { [weak self] in
            for await id in await desk.openRequests() {
                guard let self else { return }
                self.mode = .tasks
                self.open(id)
                EditorWindowController.shared.show()
            }
        })
    }

    private func pageChanged(from old: HarnessPage) {
        func key(_ page: HarnessPage) -> String {
            switch page {
            case .newTask: return "new"
            case .library: return "library"
            case let .task(id): return id.uuidString
            }
        }
        drafts[key(old)] = draft
        draft = drafts[key(page)] ?? ""
        if page.taskID == nil { mode = .tasks }
        if let task {
            project = task.projectID
            askMode = task.mode
        }
        syncWorkspace()
    }

    /// The open task's latest take gets an editor; nothing else does.
    private func syncWorkspace() {
        let take = task?.take
        guard workspace?.take != take else { return }
        workspace?.close()
        workspace = take.map { TaskWorkspace(take: $0) }
        if workspace == nil, mode != .tasks { mode = .tasks }
    }

    /// For the window's ⌘Z.
    var undoManager: UndoManager? { workspace?.editor.undoManager }
}

/// The Desk's approval card, named apart from the share thread's
/// ApprovalCard view that draws it.
typealias ApprovalCardModel = VisionOneKit.ApprovalCard
