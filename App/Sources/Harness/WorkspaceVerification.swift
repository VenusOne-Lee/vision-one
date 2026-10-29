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
                for state in ["new-task", "task", "editor", "sound", "delivery", "pending", "error", "loading"] {
                    let page: HarnessPage = state == "new-task" ? .newTask : .task(task.id)
                    var stateSnapshot = snapshot
                    if state == "pending" {
                        stateSnapshot.tasks[0].cells.append(TaskCell(.plan(DeskPlan(steps: [.init(agent: .editor, title: "Tighten the opening", action: .edit(ask: "Remove long pauses")), .init(agent: .clipper, title: "Prepare two clips", action: .clips(count: 2))])), at: date))
                        stateSnapshot.tasks[0].cells.append(TaskCell(.approval(.plan("Review edits and two clip proposals. Nothing is posted.")), at: date))
                    }
                    if state == "error" {
                        stateSnapshot.tasks[0].cells.append(TaskCell(.failed(.editor, "The provider is unavailable. Your original and saved changes are safe. Try again or choose an on-device provider."), at: date))
                    }
                    let model = HarnessModel(snapshot: stateSnapshot, takes: [take], page: page,
                                             renderPhase: state == "loading" ? .loading : nil)
                    if let workspace = model.workspace {
                        await workspace.load()
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
                                      requiresFrame: ["task", "editor", "delivery"].contains(state) || (state == "sound" && !narrow) || (["pending", "error"].contains(state) && !narrow))
                    model.workspace?.close()
                    names.append(name)
                }
                let model = HarnessModel(snapshot: snapshot, takes: [take], page: .task(task.id))
                let suffix = "\(dark ? "dark" : "light")-\(narrow ? "narrow" : "wide")"
                let tools: [(String, AnyView)] = [
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
        let report: [String: Any] = ["screenshots": names, "source": "production HarnessView with isolated fixture snapshot",
                                    "sizes": [[1512, 982], [900, 640]],
                                    "limits": ["Static renders require human inspection against approved PNGs", "Does not establish VoiceOver, keyboard navigation, hardware capture or permissions correctness", "Verification-only video areas use decoded fixture frames from the actual AVPlayerItem composition because bitmap caching omits AVPlayer layers; live playback is unverified"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("workspace-render.json"))
        print("Workspace renders saved: \(names.count)")
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
