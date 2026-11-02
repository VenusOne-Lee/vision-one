import AppKit
import AVFoundation
import SwiftUI
import VisionOneKit

/// One task's thread from the Desk: takes, asks, plans, replies,
/// receipts and approvals, the live status line and the queue, with the
/// composer at the bottom.
struct TaskThreadView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: HarnessModel
    let task: DeskTask
    @State private var showActivity = false

    private func isActivity(_ cell: TaskCell) -> Bool {
        switch cell.kind {
        case .log: return true
        case let .receipt(id, _, _):
            guard let job = model.snapshot.jobs.first(where: { $0.id == id }) else { return false }
            return job.state == .done || job.state == .undone
        case let .approval(card): return !card.isOpen
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                        let activity = task.cells.filter { isActivity($0) }
                        ForEach(task.cells.filter { !isActivity($0) && !isFirstTake($0) }) { cell in
                            ThreadCellView(cell: cell, task: task, model: model)
                                .id(cell.id)
                        }
                        if let workspace = model.workspace {
                            if [.clips, .thumbnail, .post].contains(model.layout.selected) {
                                DeliveryReview(workspace: workspace)
                            } else if workspace.editor.phase == .ready {
                                TaskProposals(editor: workspace.editor,
                                              review: { reviewChanges() },
                                              captions: { model.updateLayout { $0.show(.captions) } })
                            }
                        }
                        if !activity.isEmpty { completedSteps(activity) }
                        StatusCell(snapshot: model.snapshot, task: task) { model.stopRunning() }
                        if !task.queued.isEmpty {
                            QueuedCell(asks: task.queued) { model.editQueued(at: $0, to: nil) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: task.cells.count) { _, _ in
                    WorkspaceMotion.perform(reduced: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(model: model)
                .frame(maxWidth: 640)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.md)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }

    private func isFirstTake(_ cell: TaskCell) -> Bool {
        if case let .take(folder) = cell.kind { return folder == task.takeFolders.first }
        return false
    }

    /// Changes in the review column, Transcript | Changes set to Changes.
    private func reviewChanges() {
        UserDefaults.standard.set(EditorAside.changes.rawValue, forKey: "editorPanel.pane")
        model.updateLayout { $0.isHidden = false; $0.show(.video) }
    }

    /// "✓ 3 completed steps", folded.
    private func completedSteps(_ activity: [TaskCell]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            Button { showActivity.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 17))
                    Text("\(activity.count) completed \(activity.count == 1 ? "step" : "steps")")
                        .font(.custom(BundledFont.sansMedium, size: 14))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showActivity ? 180 : 0))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Space.sm)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showActivity ? "Shown" : "Hidden")
            if showActivity {
                ForEach(activity) { cell in
                    ThreadCellView(cell: cell, task: task, model: model)
                }
            }
        }
    }
}

/// Dashed starter chips: tap to send.
struct FlowChips: View {
    let chips: [String]
    let tap: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) { items }
            VStack(alignment: .leading, spacing: Theme.Space.sm) { items }
        }
    }

    private var items: some View {
        ForEach(chips, id: \.self) { chip in
            Button(chip) { tap(chip) }
                .buttonStyle(DashedChipStyle())
        }
    }
}

/// Dashed means proposed: these are only suggestions until you pick one.
struct DashedChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.label)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.md - 4)
            .frame(height: Theme.Size.control)
            .background(configuration.isPressed ? Theme.canvas : Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.hairline,
                                                                           dash: Theme.Stroke.dash)))
            .contentShape(Capsule())
    }
}

/// "What should we make in RankRide launch?" with starters and the
/// composer. Typing something with nothing recorded keeps it for the
/// next take.
struct NewTaskView: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @ObservedObject private var ai = AIServices.shared
    /// "Clips from" or "Cut my last video" was picked with nothing recorded yet.
    @State private var clipsNeededTake = false
    /// nil until the ladder has been checked.
    @State private var anyRungReady: Bool?
    @AppStorage("harness.aiNoticeDismissed") private var aiNoticeDismissed = false

    /// Which of the four starts is picked; Start task runs it with what's typed.
    @State private var start: StartKind = .record
    @FocusState private var composerFocused: Bool
    @State private var showingProjectSettings = false

    enum StartKind: CaseIterable {
        case record, importVideo, script, autopilot

        var title: String {
            switch self {
            case .record: return "Record a walkthrough"
            case .importVideo: return "Import a video"
            case .script: return "Write a script"
            case .autopilot: return "Run an Autopilot demo"
            }
        }

        var detail: String {
            switch self {
            case .record: return "Capture your screen, camera, and audio."
            case .importVideo: return "Use an existing file from this Mac."
            case .script: return "Draft with AI and use a teleprompter."
            case .autopilot: return "Let AI record the demo for you."
            }
        }

        var icon: String {
            switch self {
            case .record: return "circle"
            case .importVideo: return "play.rectangle"
            case .script: return "doc.text"
            case .autopilot: return "sparkles"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 940
            HStack(spacing: 0) {
                introduction(compact: geometry.size.width < 720, showDefaults: !wide)
                    .frame(width: wide ? geometry.size.width - 341 : geometry.size.width)
                if wide {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    ScrollView {
                        contextRail.frame(width: 340 - 2 * Theme.Space.lg)
                            .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.lg)
                    }
                        .padding(.top, WindowChrome.titleBarHeight)
                        .frame(width: 340).background(Theme.paper)
                }
            }
        }
        .sheet(isPresented: $showingProjectSettings) {
            if let project = model.currentProject { ProjectSettingsSheet(project: project) { showingProjectSettings = false } }
        }
    }

    private func introduction(compact: Bool, showDefaults: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are we making?")
                        .font(.custom(BundledFont.sansBold, size: compact ? 28 : 36))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Start a new task with a recording, a video, a script, or Autopilot.")
                        .font(.custom(BundledFont.sansRegular, size: 16))
                        .foregroundStyle(Theme.textMuted)
                }
                if !recorder.phase.isLive {
                    startingActions(compact: compact)
                }
                if model.takes.isEmpty, clipsNeededTake {
                    FirstTakeHint(neededTake: true)
                }
                if AISetupNotice.isShown(anyRungReady: anyRungReady, dismissed: aiNoticeDismissed) {
                    AISetupNoticeRow { aiNoticeDismissed = true }
                }
                composerCard
                if showDefaults { contextRail }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, compact ? Theme.Space.lg : Theme.Space.xxl)
            .padding(.top, WindowChrome.titleBarHeight + (compact ? Theme.Space.lg : Theme.Space.xxl))
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
        .onChange(of: model.takes.isEmpty) { _, empty in if !empty { clipsNeededTake = false } }
        .task(id: AIReadinessKey(ai)) {
            // Not checked again once closed: the notice never comes back.
            guard !aiNoticeDismissed else { return }
            guard !model.isFixture else { anyRungReady = true; return }
            anyRungReady = await ai.ladder().provider(for: .custom) != nil
        }
        .onChange(of: model.focusComposer) { _, _ in composerFocused = true }
    }

    private func startingActions(compact: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: compact ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(StartKind.allCases, id: \.self) { kind in
                startCard(kind, compact: compact)
            }
        }
    }

    private func startCard(_ kind: StartKind, compact: Bool) -> some View {
        let isOn = start == kind
        return Button {
            start = kind
            composerFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if kind == .record {
                        RingLogo(size: 28)
                    } else {
                        Image(systemName: kind.icon).font(.system(size: 24, weight: .regular))
                    }
                }
                .frame(height: 32)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                Text(kind.title)
                    .font(.custom(BundledFont.sansSemiBold, size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind.detail)
                    .font(.custom(BundledFont.sansRegular, size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text)
            .padding(Theme.Space.md + 2)
            .frame(maxWidth: .infinity, minHeight: compact ? 120 : 190, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(isOn ? Theme.canvas : Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(isOn ? Theme.text : Theme.line, lineWidth: isOn ? 1.5 : Theme.Stroke.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .accessibilityLabel(kind.title)
        .accessibilityHint(kind.detail)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The big composer: what to make, attach and dictate, where it runs,
    /// and Start task.
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom(BundledFont.sansRegular, size: 17))
                .lineLimit(3...8)
                .focused($composerFocused)
                .onSubmit(startTask)
                .accessibilityLabel("Describe the task")
            HStack(spacing: Theme.Space.sm) {
                squareButton("Attach a video", "paperclip") { model.importVideo() }
                squareButton("Dictate", "mic") {
                    composerFocused = true
                    DispatchQueue.main.async { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.sm) {
                WhereMenu(model: model)
                Spacer(minLength: Theme.Space.sm)
                Button(action: startTask) {
                    HStack(spacing: 10) {
                        Text("Start task")
                        Image(systemName: "arrow.right")
                    }
                    .font(.custom(BundledFont.sansSemiBold, size: 16))
                    .foregroundStyle(Theme.onButton)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.button))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Start task (⌘Return)")
            }
        }
        .padding(Theme.Space.md + 4)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(composerFocused ? Theme.text : Theme.lineStrong, lineWidth: composerFocused ? 1.5 : Theme.Stroke.hairline))
        .onAppear { composerFocused = true }
    }

    private var placeholder: String {
        switch start {
        case .record: return "Describe what you'll record, or just press Start task"
        case .importVideo: return "What should we do with the video?"
        case .script: return "What's the script about?"
        case .autopilot: return "What should the demo show?"
        }
    }

    private func squareButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    /// Runs the picked start with whatever was typed: the words become the
    /// task's ask, then recording, import, Script Coach or Autopilot opens.
    private func startTask() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch start {
        case .record:
            if !text.isEmpty { model.draft = ""; model.send(text) }
            model.preparingRecording = true
        case .importVideo:
            if !text.isEmpty { model.draft = ""; model.send(text) }
            model.importVideo()
        case .script:
            if text.isEmpty {
                ScriptCoachWindowController.shared.show()
            } else {
                model.draft = ""
                model.send("/script " + text)
            }
        case .autopilot:
            AutopilotWindowController.shared.show()
        }
    }

    // MARK: Right rail

    private var contextRail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack {
                Text("Project defaults").font(.custom(BundledFont.sansBold, size: 20))
                Spacer()
                IconButton("Project settings", systemImage: "square.grid.2x2") { showingProjectSettings = true }
                    .disabled(model.currentProject == nil)
            }
            defaultsCard
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            recentVideo
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Script sources").font(.custom(BundledFont.sansSemiBold, size: 15))
                ForEach(model.currentProject?.sources.filter(\.enabled) ?? [], id: \.self) { source in
                    Label(source.title, systemImage: source.kind == .github ? "chevron.left.forwardslash.chevron.right" : "checklist")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                Button { showingProjectSettings = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 15))
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.canvas))
                        Text("Add a script or notes").font(.custom(BundledFont.sansRegular, size: 14))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.currentProject == nil)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var defaultsCard: some View {
        let defaults = model.currentProject?.mediaDefaults ?? ProjectMediaDefaults()
        let id = defaults.templateID
        let userLooks = UserTemplates.loadAll().map(\.look)
        let look = TemplateLook.builtIn.first { $0.id == id } ?? userLooks.first { $0.id == id }
        let format = (UserDefaults.standard.stringArray(forKey: "export.lastPicked") ?? [])
            .compactMap(ExportPreset.init(rawValue:)).first ?? .original
        return VStack(spacing: 0) {
            defaultRow("House style", value: look?.title ?? "None", icon: "doc.richtext") {
                Button { setDefaults { $0.templateID = nil } } label: { MenuCheck("None", isOn: id == nil) }
                ForEach(TemplateLook.builtIn + userLooks) { item in
                    Button { setDefaults { $0.templateID = item.id } } label: { MenuCheck(item.title, isOn: id == item.id) }
                }
            }
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline).padding(.leading, 64)
            defaultRow("Captions", value: defaults.captions ? (defaults.language ?? .english).name : "Off",
                       icon: "captions.bubble") {
                Button { setDefaults { $0.captions = false } } label: { MenuCheck("Off", isOn: !defaults.captions) }
                ForEach(SALanguage.allCases) { language in
                    Button { setDefaults { $0.captions = true; $0.language = language } } label: {
                        MenuCheck(language.name, isOn: defaults.captions && (defaults.language ?? .english) == language)
                    }
                }
            }
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline).padding(.leading, 64)
            defaultRow("Format", value: format.title, icon: "rectangle") {
                ForEach([ExportPreset.original, .hd1080, .vertical, .square, .portrait, .whatsapp], id: \.self) { preset in
                    Button { UserDefaults.standard.set([preset.rawValue], forKey: "export.lastPicked"); model.objectWillChange.send() }
                        label: { MenuCheck(preset.title, isOn: preset == format) }
                }
            }
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
        .disabled(model.currentProject == nil)
    }

    private func defaultRow<Items: View>(_ title: String, value: String, icon: String,
                                         @ViewBuilder items: () -> Items) -> some View {
        Menu { items() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.canvas))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.custom(BundledFont.sansMedium, size: 14))
                    Text(value).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(title): \(value)")
    }

    private func setDefaults(_ change: @escaping (inout ProjectMediaDefaults) -> Void) {
        guard let id = model.currentProject?.id else { return }
        let desk = AIServices.shared.desk
        Task {
            await desk.updateProject(id) { project in
                var defaults = project.mediaDefaults ?? ProjectMediaDefaults()
                change(&defaults)
                project.mediaDefaults = defaults
            }
        }
    }

    /// The newest take: its first frame with the length on it, the title,
    /// when and how big.
    @ViewBuilder
    private var recentVideo: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Recent video").font(.custom(BundledFont.sansSemiBold, size: 15))
            if let take = model.takes.first {
                RecentVideoCard(take: take, title: model.title(of: take)) { model.open(take) }
            } else {
                Text("Record or import a video to start your library.")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var projectSuffix: String {
        guard let project = model.currentProject else { return "" }
        return " in \(project.name)"
    }

    private func start(_ chip: String) {
        switch chip {
        case "Copy a style":
            model.send("/style")
        case "Clips from my last video":
            guard let newest = model.takes.first else {
                clipsNeededTake = true
                return
            }
            model.open(newest, then: "/clips 3")
        case "Cut my last video to 60 seconds":
            guard let newest = model.takes.first else {
                clipsNeededTake = true
                return
            }
            model.open(newest, then: "Cut it to 60 seconds")
        case "Write this week's update":
            model.send("/script what's new this week")
        default:
            model.send(chip)
        }
    }
}

/// The newest take on the New task rail: first frame, length badge,
/// title, when and how big, and "…".
struct RecentVideoCard: View {
    let take: Take
    let title: String
    let open: () -> Void
    @State private var frame: CGImage?
    @State private var length: Double?
    @State private var size: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button(action: open) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Theme.canvas)
                    .overlay {
                        if let frame {
                            Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let length {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill").font(.system(size: 9))
                                Text(Timecode.short(from: length)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(title)")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.custom(BundledFont.sansMedium, size: 14)).lineLimit(2)
                    Text(line).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Open", action: open)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.screenURL]) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 34, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(title)")
            }
        }
        .task(id: take.folder) {
            frame = await LibraryPreviews.shared.firstFrame(for: take)
            let asset = AVURLAsset(url: take.screenURL)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 { length = seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize) {
                size = CGSize(width: abs(natural.width), height: abs(natural.height))
            }
        }
    }

    private var line: String {
        let date = (take.recordedAt() ?? Date()).formatted(.dateTime.month(.abbreviated).day().year())
        guard let size else { return date }
        return "\(date)  ·  \(Int(size.width)) × \(Int(size.height))"
    }
}
