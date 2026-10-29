import AppKit
import SwiftUI
import VisionOneKit

/// The Autopilot window: demos on the left; the chosen demo's app, steps
/// in plain words, pace and release settings on the right, with Record
/// steps and Run Autopilot. The last run's receipt sits under the steps,
/// and a step that broke offers its suggested fix, dashed, to keep.
@MainActor
final class AutopilotModel: ObservableObject {
    @Published private(set) var files: [DemoFile] = []
    @Published var selected: URL? { didSet { load() } }

    // The demo being edited.
    @Published var name = ""
    @Published var bundleID = ""
    @Published var openFirst = ""
    @Published var stepsText = ""
    @Published var pace: Pace = .normal
    @Published var repo = ""
    @Published var rerecordOnRelease = false
    @Published private(set) var stepIDs: [UUID] = []
    @Published private(set) var parseError: String?
    @Published private(set) var lastRun: AutopilotRun?
    @Published private(set) var saved = true

    let service = AutopilotService.shared
    let recorder = StepRecorder.shared

    init() {
        reload()
        selected = files.first?.url
        load()
    }

    var current: DemoFile? { files.first { $0.url == selected } }

    func reload() {
        files = service.library.all()
    }

    struct DrivableApp: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Apps that can be driven: open, regular apps, never the blocked ones.
    var apps: [DrivableApp] {
        var list = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> DrivableApp? in
                guard let id = app.bundleIdentifier, !AutopilotPolicy.alwaysBlocked.contains(id) else { return nil }
                return DrivableApp(id: id, name: app.localizedName ?? AutopilotPolicy.appName(id))
            }
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }
        if !bundleID.isEmpty, !list.contains(where: { $0.id == bundleID }) {
            list.append(DrivableApp(id: bundleID, name: AutopilotPolicy.appName(bundleID)))
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load() {
        guard let demo = current?.demo else { return }
        name = demo.name
        bundleID = demo.app.bundleID
        openFirst = demo.app.open ?? ""
        stepsText = StepWords.text(for: demo.steps)
        stepIDs = demo.steps.map(\.id)
        pace = demo.pace
        repo = demo.repo ?? ""
        rerecordOnRelease = demo.rerecordOnRelease && demo.repo != nil
        parseError = nil
        lastRun = service.lastRun(of: demo)
        saved = true
    }

    func edited() {
        saved = false
        do {
            _ = try StepWords.parse(stepsText)
            parseError = nil
        } catch {
            parseError = error.localizedDescription
        }
    }

    /// The demo as edited, or nil while the steps don't read.
    func draft() -> DemoScript? {
        guard var steps = try? StepWords.parse(stepsText) else { return nil }
        // Keep step ids (and their run history) where the line count lines up.
        for i in steps.indices where stepIDs.indices.contains(i) { steps[i].id = stepIDs[i] }
        let base = current?.demo
        var demo = base ?? DemoScript(name: name, app: DemoApp(bundleID: bundleID))
        demo.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled demo" : name
        demo.app = DemoApp(bundleID: bundleID, name: apps.first { $0.id == bundleID }?.name,
                           open: openFirst.trimmingCharacters(in: .whitespaces).isEmpty ? nil : openFirst)
        demo.steps = steps
        demo.pace = pace
        let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
        demo.repo = trimmedRepo.isEmpty ? nil : trimmedRepo
        demo.rerecordOnRelease = rerecordOnRelease && demo.repo != nil
        return demo
    }

    @discardableResult
    func save() -> DemoFile? {
        guard let demo = draft() else { return nil }
        let url = current?.url ?? service.library.newURL(for: demo.name)
        do {
            try demo.write(to: url)
        } catch {
            parseError = "Couldn't save: \(error.localizedDescription)"
            return nil
        }
        // Turning on "re-record on release" is the yes for these steps.
        if demo.rerecordOnRelease { service.approve(demo) }
        reload()
        if selected != url { selected = url } else { load() }
        saved = true
        return DemoFile(url: url, demo: demo)
    }

    func newDemo() {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let id = (app == Bundle.main.bundleIdentifier ? nil : app) ?? "com.apple.Safari"
        let demo = DemoScript(name: "New demo", app: DemoApp(bundleID: id), steps: [DemoStep(.wait, seconds: 1)])
        let url = service.library.newURL(for: demo.name)
        try? demo.write(to: url)
        reload()
        selected = url
    }

    func linkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Pick your app's repo. Vision One reads demos from its .visionone/demos folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !service.linkedFolders.contains(url) { service.linkedFolders.append(url) }
        reload()
    }

    func run() {
        guard let file = save() else { return }
        service.run(file)
    }

    func recordSteps() {
        guard !bundleID.isEmpty else { return }
        let appName = apps.first { $0.id == bundleID }?.name ?? AutopilotPolicy.appName(bundleID)
        recorder.start(appBundleID: bundleID, appName: appName) { [weak self] steps in
            guard let self, !steps.isEmpty else { return }
            let lines = StepWords.text(for: steps)
            let keep = self.stepsText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.stepsText = keep.isEmpty || keep == "Wait 1s" ? lines : keep + "\n" + lines
            self.edited()
        }
    }

    /// Keeps the suggested fix for the step that broke, then saves.
    func useFix(at index: Int, _ target: UITarget) {
        guard var demo = draft(), demo.steps.indices.contains(index) else { return }
        demo.steps[index].target = target
        stepsText = StepWords.text(for: demo.steps)
        stepIDs = demo.steps.map(\.id)
        save()
    }
}

struct AutopilotView: View {
    @StateObject private var model = AutopilotModel()
    @ObservedObject private var service = AutopilotService.shared
    @ObservedObject private var recorder = StepRecorder.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Autopilot demos").textStyle(.title)
                    Text("Review each demo before running. Capture needs Screen Recording and Accessibility access.")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Permissions…") { SettingsWindowController.shared.show(.access) }.buttonStyle(.secondary)
            }.padding(16).background(Theme.paper)
            Divider().overlay(Theme.line)
            HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            Group {
                if model.current != nil {
                    editor
                } else {
                    EmptyState("No demos yet",
                               message: "Make a demo once and Autopilot records it again whenever you ship.",
                               action: ("New Demo", { model.newDemo() }))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("DEMOS").textStyle(.label).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.Space.sm)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.files) { file in
                        let release = service.state[file.demo].lastRelease
                        ListRow(file.demo.name, subtitle: AutopilotPolicy.appName(file.demo.app.bundleID),
                                isSelected: model.selected == file.url) {
                            if let release { Mono(release, small: true).foregroundStyle(Theme.textMuted) }
                        }
                        .onTapGesture { model.selected = file.url }
                    }
                }
            }
            Divider()
            Button("New Demo") { model.newDemo() }.buttonStyle(.quiet)
            Button("Link a Repo…") { model.linkFolder() }.buttonStyle(.quiet)
                .help("Read demos from a repo's .visionone/demos folder, so they change with your code.")
        }
        .padding(Theme.Space.sm)
        .background(Theme.canvas)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    TextField("Demo name", text: $model.name)
                        .textFieldStyle(.ink)
                        .onChange(of: model.name) { model.edited() }
                    Button(recorder.isRecording ? "Recording…" : "Record Steps") { model.recordSteps() }
                        .buttonStyle(.secondary)
                        .disabled(recorder.isRecording || service.isBusy)
                        .help("Click through your app once; each click becomes a step.")
                    Button(service.isBusy ? "Running…" : "Run Autopilot") { model.run() }
                        .buttonStyle(.primary)
                        .disabled(service.isBusy || model.parseError != nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        Text("App").textStyle(.label).foregroundStyle(Theme.textMuted)
                        Picker("App", selection: $model.bundleID) {
                            ForEach(model.apps) { app in Text(app.name).tag(app.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: model.bundleID) { model.edited() }
                        TextField("Open first (a web address, optional)", text: $model.openFirst)
                            .textFieldStyle(.ink)
                            .onChange(of: model.openFirst) { model.edited() }
                    }
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        Text("STEPS").textStyle(.label).foregroundStyle(Theme.textMuted)
                        Spacer()
                        if let demo = model.draft() {
                            Mono("\(demo.steps.count) steps · about \(Timecode.short(from: demo.estimatedSeconds))", small: true)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    TextEditor(text: $model.stepsText)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                        .padding(Theme.Space.xs)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.lineStrong))
                        .onChange(of: model.stepsText) { model.edited() }
                    if let error = model.parseError {
                        Text(error).textStyle(.caption).foregroundStyle(Theme.error)
                    } else {
                        Text("One step per line: Open, Click \"…\", Point at \"…\", Type \"…\" into \"…\", Press cmd+k, Scroll down, Wait 2s. A Say \"…\" line is the script for the step above it.")
                            .textStyle(.caption).foregroundStyle(Theme.textMuted)
                    }
                }
                .panelStyle()

                if let run = service.running ?? model.lastRun {
                    lastRunPanel(run, live: service.running != nil)
                }

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        Text("PACE").textStyle(.label).foregroundStyle(Theme.textMuted)
                        SegmentedTabs(selection: $model.pace, options: Pace.allCases) { $0.title }
                            .onChange(of: model.pace) { model.edited() }
                    }
                    HStack {
                        Text("RELEASES").textStyle(.label).foregroundStyle(Theme.textMuted)
                        TextField("owner/repo on GitHub", text: $model.repo)
                            .textFieldStyle(.ink)
                            .frame(maxWidth: 240)
                            .onChange(of: model.repo) { model.edited() }
                        Toggle("Re-record when I ship a release", isOn: $model.rerecordOnRelease)
                            .toggleStyle(.ink)
                            .disabled(model.repo.trimmingCharacters(in: .whitespaces).isEmpty)
                            .onChange(of: model.rerecordOnRelease) { model.edited() }
                    }
                    Text("Autopilot only acts in this demo's app, never in Settings, Terminal or password managers, and never types into password fields. Esc stops it; moving the mouse pauses it.")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                .panelStyle()

                HStack {
                    Spacer()
                    if !model.saved {
                        Button("Save") { model.save() }
                            .buttonStyle(.secondary)
                            .disabled(model.parseError != nil)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    private func lastRunPanel(_ run: AutopilotRun, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(live ? "RUNNING" : "LAST RUN").textStyle(.label).foregroundStyle(Theme.textMuted)
                if let release = run.release { Mono(release, small: true) }
                Spacer()
                if live {
                    Button("Stop") { service.stop() }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                }
            }
            Text(live ? "Step \(run.doneCount + 1) of \(run.steps.count)" : run.receipt)
                .textStyle(.transcript)
            if !live, let index = run.failedIndex, let fix = run.steps[index].suggestion {
                HStack(spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Step \(index + 1) could be \(fix.label)").textStyle(.bodyStrong)
                        Text("Same kind of thing, near where the old one was.").textStyle(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    StateChip(.proposed, "Suggested")
                    Button("Use It") { model.useFix(at: index, fix) }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                }
                .padding(Theme.Space.sm)
                .statusOutline(.proposed)
            }
        }
        .panelStyle()
    }
}

@MainActor
final class AutopilotWindowController {
    static let shared = AutopilotWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Autopilot"
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            window.setFrameAutosaveName("VisionOneAutopilot")
            window.contentViewController = NSHostingController(rootView: AutopilotView())
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
