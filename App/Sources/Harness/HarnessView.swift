import AppKit
import SwiftUI
import VisionOneKit

/// The main window, in the agent-harness look: projects and their tasks
/// on the left, the task's thread in the middle, swappable components on
/// the right, and Tasks / Editor / Sound up top. Every divider drags; the
/// sidebar and the panel fold away. All colour and size come from Theme,
/// so a preset look restyles the lot.
struct HarnessView: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var importer = VideoImporter.shared

    @AppStorage("harness.showSidebar") private var showSidebar = true
    @AppStorage("harness.sidebarWidth") private var sidebarWidth = 248.0
    /// A component filling the window (⤢), with the task rail beside it.
    @State private var fullPanel: PanelKind?
    @AppStorage("harness.stageFraction") private var stageFraction = 0.58
    /// Editor or Sound picked with no takes yet: their empty state shows.
    @State private var noTakesMode: HarnessMode?
    @State private var showingTemplate = false
    @State private var showingTools = false
    @State private var compactPane = "Review"

    init(model: HarnessModel, compactPane: String = "Review") {
        self.model = model
        _compactPane = State(initialValue: compactPane)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if importer.isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Importing video on this Mac…").textStyle(.caption)
                    Spacer()
                    Button("Cancel") { importer.cancel() }.buttonStyle(.quiet)
                }.padding(Theme.Space.sm)
            }
            if let message = importer.problem {
                HStack {
                    Text(message).textStyle(.caption).foregroundStyle(Theme.error)
                    Spacer()
                    Button("Dismiss") { importer.clearProblem() }.buttonStyle(.quiet)
                }.padding(Theme.Space.sm)
            }
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            GeometryReader { outer in
            HStack(spacing: 0) {
                if showSidebar && model.mode != .editor && fullPanel == nil {
                    HarnessSidebar(model: model)
                        .frame(width: min(sidebarWidth, max(200, outer.size.width * 0.28)))
                    DragDivider(axis: .vertical, value: $sidebarWidth, range: 200...420)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .background(shortcuts)
        .sheet(isPresented: $showingTools) {
            WorkspaceToolsSheet(model: model) { showingTools = false }
        }
        .sheet(isPresented: $showingTemplate) {
            if let workspace = model.workspace { ApplyTemplateSheet(workspace: workspace) { showingTemplate = false } }
        }
        .sheet(isPresented: $model.preparingRecording) {
            RecordingPreparationView(model: model, availableHeight: NSApp.keyWindow?.contentLayoutRect.height)
        }
        .sheet(isPresented: $model.presentingExport) {
            if let workspace = model.workspace {
                ExportSheet(take: workspace.take, keep: nil) { model.presentingExport = false }
            }
        }
        .onReceive(recorder.$lastTake) { _ in model.refreshTakes() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshTakes()
        }
        .onChange(of: model.task?.openApprovals.count) { _, count in
            if let count, count > 0 { compactPane = "Task" }
        }
        .onChange(of: model.page) { _, _ in
            fullPanel = nil
            noTakesMode = nil
        }
        .onChange(of: model.takes.isEmpty) { _, empty in if !empty { noTakesMode = nil } }
        .alert(model.clarification == nil ? "Something went wrong" : "Clarify request",
               isPresented: Binding(get: { model.problem != nil || model.clarification != nil }, set: {
                   if !$0 { model.problem = nil; model.clarification = nil }
               })) {
            Button("OK") { model.problem = nil; model.clarification = nil }
        } message: { Text(model.clarification ?? model.problem ?? "") }

    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Space.sm) {
            IconButton(showSidebar ? "Hide sidebar" : "Show sidebar", systemImage: "sidebar.left",
                       shortcut: ShortcutMap.toggleSidebar.display, isOn: showSidebar) { showSidebar.toggle() }
                .disabled(model.mode != .tasks)
            breadcrumb
                .layoutPriority(-1)
            Spacer(minLength: Theme.Space.sm)
            SegmentedTabs(selection: modeBinding, options: HarnessMode.allCases) { $0.title }
                .help("Tasks shows the thread; Editor and Sound fill the window. Esc comes back.")
            Spacer(minLength: Theme.Space.sm)
            if model.workspace != nil {
                Button("Export…") { model.presentingExport = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            contextualTools
            IconButton(theme.palette.isDark ? "Use light appearance" : "Use dark appearance",
                       systemImage: theme.palette.isDark ? "sun.max" : "moon") {
                theme.appearance.toggleMode()
            }
            if recorder.phase.isLive {
                HStack(spacing: 6) {
                    LiveDot()
                    Text("Recording").textStyle(.label).foregroundStyle(Theme.text)
                }
            }
            if model.mode == .tasks, model.workspace != nil {
                IconButton(model.layout.isHidden ? "Show panel" : "Hide panel", systemImage: "sidebar.right",
                           shortcut: ShortcutMap.togglePanel.display, isOn: !model.layout.isHidden) {
                    model.updateLayout { $0.isHidden.toggle() }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md - 2)
        .frame(height: Theme.Size.toolbar)
        .background(Theme.paper)
    }

    private var contextualTools: some View {
        Menu {
            Button("All task tools…") { showingTools = true }
            Divider()
            Button("Prepare a recording…") { model.preparingRecording = true }
            Button("Import a video…") { model.importVideo() }
            Divider()
            Button("Script Coach…") { ScriptCoachWindowController.shared.show() }
            Button("Rehearse…") { RehearseWindowController.shared.show() }
            Button("Voice tools…") { VoiceToolsWindowController.shared.show(for: model.workspace?.take) }
            Button("Autopilot…") { AutopilotWindowController.shared.show() }
            Button("Agent recording and MCP…") { SettingsWindowController.shared.show(.agents) }
            Divider()
            Button("Apply a reusable style…") { showingTemplate = true }.disabled(model.workspace == nil)
            Button("Copy a style…") { CopyStyleWindowController.shared.show() }
            Button("Languages and dubbing…") {
                if let take = model.workspace?.take { LanguagesWindowController.shared.show(for: take) }
            }
                .disabled(model.workspace == nil)
        } label: {
            Image(systemName: "ellipsis").frame(width: Theme.Size.control, height: Theme.Size.control)
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task tools")
    }

    /// "My videos › RankRide launch demo"
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text(model.currentProject?.name ?? "My videos")
                .textStyle(.label)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
            Text(pageTitle)
                .textStyle(.bodyStrong)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    private var pageTitle: String {
        switch model.page {
        case .newTask: return "New task"
        case .library: return "Library"
        case .task: return model.task?.title ?? "Task"
        }
    }

    /// Editor and Sound need a take: with none open, they open the newest.
    /// With no takes at all, they say so and offer to record one.
    private var modeBinding: Binding<HarnessMode> {
        Binding(get: { noTakesMode ?? model.mode }, set: { next in
            noTakesMode = nil
            if next != .tasks, model.workspace == nil {
                guard let newest = model.takes.first else {
                    noTakesMode = next
                    return
                }
                model.open(newest, mode: next)
                return
            }
            fullPanel = nil
            model.mode = next
        })
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let noTakesMode {
            NoTakesYetView(mode: noTakesMode)
        } else {
            modeContent
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch model.mode {
        case .tasks:
            if let fullPanel, let workspace = model.workspace {
                HStack(spacing: 0) {
                    PanelContent(kind: fullPanel, workspace: workspace, model: model)
                        .background(Theme.paper)
                    TaskRail(model: model) { self.fullPanel = nil }
                }
            } else {
                tasksPage
            }
        case .editor:
            if let workspace = model.workspace {
                EditorFullMode(model: workspace.editor, clips: workspace.clips, thumbnail: workspace.thumbnail,
                               onBack: { model.mode = .tasks }) {
                    TaskRail(model: model) { model.mode = .tasks }
                }
                .id(workspace.take.name)
                .task(id: workspace.take.name) { await workspace.load() }
            }
        case .sound:
            if let workspace = model.workspace {
                SoundFullMode(model: workspace.editor, onBack: { model.mode = .tasks })
                .id(workspace.take.name)
                .task(id: workspace.take.name) { await workspace.load() }
            }
        }
    }

    @ViewBuilder
    private var tasksPage: some View {
        switch model.page {
        case .newTask:
            NewTaskView(model: model)
        case .library:
            LibraryView { model.open($0) }
        case .task:
            if let task = model.task {
                GeometryReader { geometry in
                let narrow = geometry.size.width < 720
                let stageWidth = min(max(geometry.size.width * stageFraction, 320), max(320, geometry.size.width - 340))
                if narrow, let workspace = model.workspace, !model.layout.isHidden {
                    VStack(spacing: 0) {
                        HStack {
                            SegmentedTabs(selection: $compactPane, options: ["Task", "Review"]) { $0 }
                            Spacer()
                        }.padding(8).background(Theme.paper)
                        Divider().overlay(Theme.line)
                        if compactPane == "Task" {
                            TaskThreadView(model: model, task: task).id(task.id)
                        } else {
                            PanelHost(model: model, workspace: workspace) { fullPanel = $0 }
                                .task(id: workspace.take.name) { await workspace.load() }
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        TaskThreadView(model: model, task: task).id(task.id)
                            .frame(minWidth: 340, maxWidth: .infinity)
                        if let workspace = model.workspace, !model.layout.isHidden {
                            DragDivider(axis: .vertical, value: Binding(
                                get: { Double(stageWidth) },
                                set: { stageFraction = $0 / max(1, geometry.size.width) }),
                                range: 320...max(320, Double(geometry.size.width - 340)), inverted: true)
                            PanelHost(model: model, workspace: workspace) { fullPanel = $0 }
                                .frame(width: stageWidth)
                                .task(id: workspace.take.name) { await workspace.load() }
                        }
                    }
                }
                }
            }
        }
    }

    private var panelWidth: Binding<Double> {
        Binding(get: { model.layout.width }, set: { value in model.updateLayout { $0.setWidth(value) } })
    }

    // MARK: Keys

    /// Esc back to Tasks (or stop the agent that's working). ⌘N, ⌘B and
    /// ⌥⌘B are menu commands (AppCommands in VisionOneApp.swift), routed
    /// through EditorWindowController.
    private var shortcuts: some View {
        ZStack {
            Button("Back") { escape() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func escape() {
        if noTakesMode != nil {
            noTakesMode = nil
        } else if model.mode != .tasks {
            model.mode = .tasks
        } else if fullPanel != nil {
            fullPanel = nil
        } else {
            model.stopRunning()
        }
    }
}

/// A thin line that drags to resize what's beside it.
struct DragDivider: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The panel is on the far side of the line, so dragging right shrinks it.
    var inverted = false

    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? Theme.lineStrong : Theme.line)
            .frame(width: axis == .vertical ? Theme.Stroke.hairline : nil,
                   height: axis == .horizontal ? Theme.Stroke.hairline : nil)
            .padding(axis == .vertical ? .horizontal : .vertical, 3)
            .contentShape(Rectangle())
            .padding(axis == .vertical ? .horizontal : .vertical, -3)
            .onHover { inside in
                hovering = inside
                let cursor: NSCursor = axis == .vertical ? .resizeLeftRight : .resizeUpDown
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let begin = start ?? value
                        start = begin
                        let moved = Double(axis == .vertical ? drag.translation.width : drag.translation.height)
                        value = min(range.upperBound, max(range.lowerBound, begin + (inverted ? -moved : moved)))
                    }
                    .onEnded { _ in start = nil }
            )
            .zIndex(1)
            .accessibilityLabel("Drag to resize")
    }
}
