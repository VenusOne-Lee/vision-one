import AppKit
import SwiftUI
import VisionOneKit

/// Captures the production SwiftUI surfaces with an isolated Desk snapshot.
/// NSView caching captures our own window; it never requests screen recording,
/// camera, microphone or provider access. Run in a clean CI account; advanced
/// tools read that account's empty settings/library without starting services.
private struct WorkspaceRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workspaceRender: Bool {
        get { self[WorkspaceRenderKey.self] }
        set { self[WorkspaceRenderKey.self] = newValue }
    }
}

@MainActor
enum WorkspaceRenderEvidence {
    static weak var captionOwner: DeliveryCaptionControl?
    static var generation = 0
    static var frames = 0
    static var failures: [String] = []
}

@MainActor
enum WorkspaceVerification {
    static func run(take source: Take, in root: URL) async throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(["script.text": "Introduce the launch. Show the new workspace. End with the next step.",
                                    "mcp.enabled": true, "harness.aiNoticeDismissed": true], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        BundledFont.registerAll()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("fixture-take")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: source.folder, to: folder)
        let take = Take(folder: folder)
        try take.setTitle("Launch walkthrough")
        let text = "Welcome to the producer workspace. Start a recording or import a video, then review every proposed change beside the transcript. Keep your original, prepare a vertical clip, and check captions before sharing."
        let words = text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(id: index, text: String(word), start: Double(index) * 0.075, end: Double(index + 1) * 0.075)
        }
        try Transcript(language: "en", engine: "workspace fixture", duration: 3, segments: [.init(words: words)]).write(to: take.transcriptURL)
        try WorkspaceMotion.verify()
        try await ExportControllerVerification.run(in: root)
        try await ExportControllerVerification.verifyQueue(in: root)
        try verifyCaptionPaneUpdates(in: root)
        try await verifyTakeSwitch(source: take, in: root)
        try await TranscriptViewVerification.run(source: take, in: root)
        let transcriptFixtures = try TranscriptViewVerification.stateFixtures(source: take, in: root)
        let original = ThemeStore.shared.appearance
        defer { ThemeStore.shared.renderAppearance(original) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let project = DeskProject(name: "Producer workspace", sources: [.init(.github, "VenusOne-Lee/vision-one")], createdAt: date)
        var task = DeskTask(projectID: project.id, title: "Launch walkthrough", takes: [take], createdAt: date)
        task.cells += [TaskCell(.ask("Tighten this walkthrough and prepare clips for launch.", mode: .planFirst), at: date),
                       TaskCell(.reply(.producer, "Review the transcript and proposed edits beside this thread. Keep each change before delivery."), at: date)]
        let snapshot = DeskSnapshot(projects: [project], tasks: [task])
        var names: [String] = []
        for dark in [false, true] {
            var appearance = Appearance.standard
            appearance.mode = dark ? .dark : .light
            ThemeStore.shared.renderAppearance(appearance)
            for narrow in [false, true] {
                let size = narrow ? CGSize(width: 900, height: 640) : CGSize(width: 1512, height: 982)
                for state in ["new-task", "library", "task", "editor", "sound", "delivery", "pending", "error", "loading", "transcript-missing", "transcript-failed", "transcript-empty"] {
                    let stateTake = transcriptFixtures.first(where: { $0.0 == state })?.1 ?? take
                    let selectedTask = stateTake == take ? task : DeskTask(projectID: project.id, title: "Transcript recovery",
                                                                          takes: [stateTake], createdAt: date)
                    let page: HarnessPage = state == "new-task" ? .newTask : (state == "library" ? .library : .task(selectedTask.id))
                    var stateSnapshot = stateTake == take ? snapshot : DeskSnapshot(projects: [project], tasks: [selectedTask])
                    if state == "pending" {
                        stateSnapshot.tasks[0].cells.append(TaskCell(.plan(DeskPlan(steps: [.init(agent: .editor, title: "Tighten the opening", action: .edit(ask: "Remove long pauses")), .init(agent: .clipper, title: "Prepare two clips", action: .clips(count: 2))])), at: date))
                        stateSnapshot.tasks[0].cells.append(TaskCell(.approval(.plan("Review edits and two clip proposals. Nothing is posted.")), at: date))
                    }
                    if state == "error" {
                        stateSnapshot.tasks[0].cells.append(TaskCell(.failed(.editor, "The provider is unavailable. Your original and saved changes are safe. Try again or choose an on-device provider."), at: date))
                    }
                    let model = HarnessModel(snapshot: stateSnapshot, takes: [stateTake], page: page,
                                             renderPhase: state == "loading" ? .loading : nil)
                    if let workspace = model.workspace {
                        await workspace.load()
                        if state.hasPrefix("transcript-") { try TranscriptViewVerification.verifyState(state, editor: workspace.editor) }
                        if state == "delivery" {
                            try ClipList().write(to: take.clipsURL)
                            await workspace.clips.load()
                            workspace.clips.addAtPlayhead()
                            if let clip = workspace.clips.selected {
                                workspace.clips.export(clip)
                                while workspace.clips.isExporting { try await Task.sleep(for: .milliseconds(50)) }
                            }
                            model.updateLayout { $0.show(.clips) }
                        }
                    }
                    model.workspace?.editor.seek(toSource: 0.5)
                    if state == "editor" { model.mode = .editor }
                    if state == "sound" { model.mode = .sound }
                    let name = "\(state)-\(dark ? "dark" : "light")-\(narrow ? "narrow" : "wide").png"
                    try await capture(HarnessView(model: model, compactPane: ["pending", "error"].contains(state) ? "Task" : "Review"), size: size, to: root.appendingPathComponent(name),
                                      requiresFrame: state.hasPrefix("transcript-") || ["task", "editor", "delivery"].contains(state) || (state == "sound" && !narrow) || (["pending", "error"].contains(state) && !narrow))
                    model.workspace?.close()
                    names.append(name)
                }
                let model = HarnessModel(snapshot: snapshot, takes: [take], page: .task(task.id))
                let suffix = "\(dark ? "dark" : "light")-\(narrow ? "narrow" : "wide")"
                let tools: [(String, AnyView)] = [
                    ("library-filter-empty", AnyView(LibraryView(library: model.library, initialQuery: LibraryQuery(filter: .exported), open: { _ in }))),
                    ("task-tools", AnyView(WorkspaceToolsSheet(model: model, close: {}))),
                    ("recording", AnyView(RecordingPreparationView(model: model, availableHeight: size.height))),
                    ("script-coach", AnyView(ScriptCoachView(model: ScriptCoachModel(learnPace: false)))),
                    ("rehearse", AnyView(RehearseView(model: RehearseModel(), talk: CoachConversation()))),
                    ("voice-tools", AnyView(VoiceToolsView(model: VoiceToolsModel(take: take)))),
                    ("autopilot", AnyView(AutopilotView())),
                    ("agents", AnyView(AgentsSettingsView(service: MCPService.shared)))
                ]
                for (tool, view) in tools {
                    let name = "\(tool)-\(suffix).png"
                    try await capture(view, size: size, to: root.appendingPathComponent(name))
                    names.append(name)
                }
            }
        }
        // Exercise the actual window minimum as well as the two reference sizes.
        for dark in [false, true] {
            var appearance = Appearance.standard
            appearance.mode = dark ? .dark : .light
            ThemeStore.shared.renderAppearance(appearance)
            for state in ["new-task", "library", "library-filter-empty", "recording", "editor", "sound"] {
                let model = HarnessModel(snapshot: snapshot, takes: [take], page: state == "new-task" ? .newTask : (state.hasPrefix("library") ? .library : .task(task.id)))
                if let workspace = model.workspace { await workspace.load(); workspace.editor.seek(toSource: 0.5) }
                if state == "editor" { model.mode = .editor }
                if state == "sound" { model.mode = .sound }
                let name = "\(state)-\(dark ? "dark" : "light")-minimum.png"
                if state == "recording" {
                    try await capture(RecordingPreparationView(model: model, availableHeight: 520),
                                      size: CGSize(width: 760, height: 520), to: root.appendingPathComponent(name))
                } else if state == "library-filter-empty" {
                    try await capture(LibraryView(library: model.library, initialQuery: LibraryQuery(filter: .exported), open: { _ in }),
                                      size: CGSize(width: 760, height: 520), to: root.appendingPathComponent(name))
                } else {
                    try await capture(HarnessView(model: model), size: CGSize(width: 760, height: 520),
                                      to: root.appendingPathComponent(name), requiresFrame: state == "editor")
                }
                model.workspace?.close()
                names.append(name)
            }
        }
        let report: [String: Any] = ["screenshots": names, "source": "production HarnessView with isolated fixture snapshot",
                                    "sizes": [[1512, 982], [900, 640], [760, 520]],
                                    "limits": ["Static renders require human inspection against approved PNGs", "Does not establish VoiceOver, keyboard navigation, hardware capture or permissions correctness", "Verification-only video areas use decoded fixture frames from the actual AVPlayerItem composition because bitmap caching omits AVPlayer layers; live playback is unverified"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("workspace-render.json"))
        print("Workspace renders saved: \(names.count)")
    }

    /// Mount the real HarnessView, retain it across a task switch with Clips
    /// active, then operate the exact state owner used by the visible toggle.
    private static func verifyTakeSwitch(source: Take, in root: URL) async throws {
        let a = Take(folder: root.appendingPathComponent("switch-A"))
        let b = Take(folder: root.appendingPathComponent("switch-B"))
        for take in [a, b] {
            if FileManager.default.fileExists(atPath: take.folder.path) { try FileManager.default.removeItem(at: take.folder) }
            try FileManager.default.copyItem(at: source.folder, to: take.folder)
            try ClipList(clips: [.init(title: "Switch fixture", span: TimeSpan(start: 0, end: 3), state: .accepted)])
                .write(to: take.clipsURL)
        }
        try a.setTitle("First imported video")
        try b.setTitle("Second imported video")
        try a.saveCaptionSettings(CaptionSettings(isOn: true, style: .subtitle, position: 0.25))
        try b.saveCaptionSettings(CaptionSettings(isOn: false, style: .keyword, position: 0.4, language: .zulu))
        let originalA = try Data(contentsOf: a.captionSettingsURL)
        let project = DeskProject(name: "Take-switch verification")
        let first = DeskTask(projectID: project.id, title: "A", takes: [a])
        let second = DeskTask(projectID: project.id, title: "B", takes: [b])
        let model = HarnessModel(snapshot: DeskSnapshot(projects: [project], tasks: [first, second]),
                                 takes: [a, b], page: .task(first.id))
        model.updateLayout { $0.show(.clips) }
        await model.workspace?.load()
        let host = NSHostingView(rootView: HarnessView(model: model)
            .frame(width: 1512, height: 982).environment(\.workspaceRender, true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            model.workspace?.close()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        try requireCaptionOwner(a)
        model.page = .task(second.id)
        await model.workspace?.load()
        try await Task.sleep(for: .milliseconds(500))
        try requireCaptionOwner(b)
        guard let control = WorkspaceRenderEvidence.captionOwner else { throw MediaVerification.Failure(message: "B caption control missing") }
        try MediaVerification.require(!control.isOn, "B did not show its own caption flag")
        control.set(true)
        try MediaVerification.require(b.loadCaptionSettings().isOn && b.loadCaptionSettings().language == .zulu,
                                      "Switching to B did not toggle B's current settings")
        try MediaVerification.require(try Data(contentsOf: a.captionSettingsURL) == originalA,
                                      "Toggling B changed A's caption file")
        model.page = .task(first.id)
        await model.workspace?.load()
        try await Task.sleep(for: .milliseconds(500))
        try requireCaptionOwner(a)
    }

    private static func requireCaptionOwner(_ take: Take) throws {
        try MediaVerification.require(WorkspaceRenderEvidence.captionOwner?.take.folder == take.folder,
                                      "Mounted delivery caption control retained a different take")
    }

    private static func verifyCaptionPaneUpdates(in root: URL) throws {
        let take = Take(folder: root.appendingPathComponent("caption-regression"))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        try take.saveCaptionSettings(CaptionSettings())
        let control = DeliveryCaptionControl(take: take)
        var external = CaptionSettings(isOn: false, style: .keyword, sizeScale: 1.5, position: 0.3, language: .zulu)
        try take.saveCaptionSettings(external)
        NotificationCenter.default.post(name: .takeStyleChanged, object: take.folder)
        try MediaVerification.require(!control.isOn, "Delivery did not reload an external caption notification")
        control.set(true)
        external.isOn = true
        try MediaVerification.require(take.loadCaptionSettings() == external && control.problem == nil,
                                      "Delivery caption toggle overwrote newer settings")
        let bytes = try Data(contentsOf: take.captionSettingsURL)
        NotificationCenter.default.post(name: .takeStyleChanged, object: take.folder)
        try MediaVerification.require(try Data(contentsOf: take.captionSettingsURL) == bytes,
                                      "Delivery caption reload wrote settings after its own notification")
        let reopened = DeliveryCaptionControl(take: take)
        try MediaVerification.require(reopened.isOn, "Reopened delivery pane did not load saved visibility")
    }

    private static func capture<V: View>(_ view: V, size: CGSize, to url: URL, requiresFrame: Bool = false) async throws {
        WorkspaceRenderEvidence.generation += 1
        WorkspaceRenderEvidence.frames = 0
        WorkspaceRenderEvidence.failures = []
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Theme.canvas).foregroundStyle(Theme.text).themed()
            .environment(\.workspaceRender, true))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Let production .task loads, SwiftUI layout and AppKit drawing settle.
        try await Task.sleep(for: .milliseconds(700))
        if requiresFrame {
            for _ in 0..<40 where WorkspaceRenderEvidence.frames == 0 && WorkspaceRenderEvidence.failures.isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            try MediaVerification.require(WorkspaceRenderEvidence.frames > 0 && WorkspaceRenderEvidence.failures.isEmpty,
                                          "Fixture media frame unavailable in \(url.lastPathComponent): \(WorkspaceRenderEvidence.failures)")
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MediaVerification.Failure(message: "Native workspace bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 5000 else {
            throw MediaVerification.Failure(message: "Native workspace render is empty")
        }
        try png.write(to: url, options: .atomic)
    }
}
