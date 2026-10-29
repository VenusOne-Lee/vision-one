import AppKit
import SwiftUI
import VisionOneKit

/// One task's thread from the Desk: takes, asks, plans, replies,
/// receipts and approvals, the live status line and the queue, with the
/// composer at the bottom.
struct TaskThreadView: View {
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
                        ForEach(task.cells.filter { !isActivity($0) }) { cell in
                            ThreadCellView(cell: cell, task: task, model: model)
                                .id(cell.id)
                        }
                        if !activity.isEmpty {
                            DisclosureGroup("\(activity.count) completed updates", isExpanded: $showActivity) {
                                ForEach(activity) { cell in
                                    ThreadCellView(cell: cell, task: task, model: model)
                                }
                            }
                            .textStyle(.caption)
                            .foregroundStyle(Theme.textMuted)
                        }
                        if task.cells.count <= 2, task.take != nil { firstSteps }
                        StatusCell(snapshot: model.snapshot, task: task) { model.stopRunning() }
                        if !task.queued.isEmpty {
                            QueuedCell(asks: task.queued) { model.editQueued(at: $0, to: nil) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: task.cells.count) { _, _ in
                    withAnimation(Theme.Motion.enter) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(model: model)
                .frame(maxWidth: 720)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.md)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
    }

    /// Before any agent has run: the asks most people start with, dashed
    /// because they're only suggestions.
    private var firstSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Try").textStyle(.label).foregroundStyle(Theme.textFaint)
            FlowChips(chips: ["Make it 60 seconds", "/clips 3", "/captions", "/share Version One"]) { chip in
                model.send(chip)
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

    var body: some View {
        ScrollView {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: Theme.Space.lg)
            Text("What should we make\(projectSuffix)?")
                .textStyle(.display)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Start with a recording, a video, a script or an Autopilot demo.")
                .textStyle(.body).foregroundStyle(Theme.textMuted)
            if !recorder.phase.isLive {
                startingActions
            }
            FlowChips(chips: ["Clips from my last video", "Cut my last video to 60 seconds",
                              "Copy a style", "Write this week's update"]) { chip in
                start(chip)
            }
            if model.takes.isEmpty, clipsNeededTake {
                FirstTakeHint(neededTake: true)
            }
            VStack(spacing: Theme.Space.sm) {
                if AISetupNotice.isShown(anyRungReady: anyRungReady, dismissed: aiNoticeDismissed) {
                    AISetupNoticeRow { aiNoticeDismissed = true }
                }
                Composer(model: model, placeholder: "Describe a video, or press record")
                    .frame(maxWidth: 640)
            }
            projectDefaults
            Spacer(minLength: Theme.Space.lg)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        }
        .onChange(of: model.takes.isEmpty) { _, empty in if !empty { clipsNeededTake = false } }
        .task(id: AIReadinessKey(ai)) {
            // Not checked again once closed: the notice never comes back.
            guard !aiNoticeDismissed else { return }
            anyRungReady = await ai.ladder().provider(for: .custom) != nil
        }
    }

    private var startingActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: Theme.Space.sm) {
            startCard("Record a walkthrough", detail: "Screen, camera and audio", icon: "record.circle") {
                model.preparingRecording = true
            }
            startCard("Import a video", detail: "Edit a file from this Mac", icon: "video.badge.plus") { model.importVideo() }
            startCard("Write a script", detail: "Script Coach and teleprompter", icon: "doc.text") {
                ScriptCoachWindowController.shared.show()
            }
            startCard("Autopilot demo", detail: "Review setup before it runs", icon: "sparkles") {
                AutopilotWindowController.shared.show()
            }
        }
        .frame(maxWidth: 760)
    }

    private func startCard(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Image(systemName: icon).font(.system(size: 24)).accessibilityHidden(true)
                Text(title).textStyle(.bodyStrong)
                Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .panelStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    @State private var showingProjectSettings = false
    private var projectDefaults: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Project defaults").textStyle(.bodyStrong)
                Spacer()
                Button("Edit…") { showingProjectSettings = true }.buttonStyle(.secondary)
                    .disabled(model.currentProject == nil)
            }
            let defaults = model.currentProject?.mediaDefaults
            let id = defaults?.templateID
            let look = TemplateLook.builtIn.first { $0.id == id } ?? UserTemplates.loadAll().map(\.look).first { $0.id == id }
            Text("\(look?.title ?? "No template") · Captions \(defaults?.captions == false ? "off" : "on") · Saved on this Mac")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
            if let newest = model.takes.first {
                Button("Resume \(model.title(of: newest))") { model.open(newest) }.buttonStyle(.quiet)
            }
        }
        .panelStyle().frame(maxWidth: 640)
        .sheet(isPresented: $showingProjectSettings) {
            if let project = model.currentProject { ProjectSettingsSheet(project: project) { showingProjectSettings = false } }
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
