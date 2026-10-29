import AppKit
import SwiftUI
import VisionOneKit

/// Captures the production SwiftUI surfaces with an isolated Desk snapshot.
/// NSView caching captures our own window; it never requests screen recording,
/// camera, microphone, provider access or a user's library.
@MainActor
enum WorkspaceVerification {
    static func run(take: Take, in root: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        BundledFont.registerAll()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
                for state in ["new-task", "task", "editor", "sound", "delivery"] {
                    let page: HarnessPage = state == "new-task" ? .newTask : .task(task.id)
                    let model = HarnessModel(snapshot: snapshot, takes: [take], page: page)
                    if let workspace = model.workspace {
                        await workspace.load()
                        if state == "delivery" {
                            workspace.clips.addAtPlayhead()
                            model.updateLayout { $0.show(.clips) }
                        }
                    }
                    if state == "editor" { model.mode = .editor }
                    if state == "sound" { model.mode = .sound }
                    let name = "\(state)-\(dark ? "dark" : "light")-\(narrow ? "narrow" : "wide").png"
                    try await capture(HarnessView(model: model), size: size, to: root.appendingPathComponent(name))
                    model.workspace?.close()
                    names.append(name)
                }
            }
        }
        let report: [String: Any] = ["screenshots": names, "source": "production HarnessView with isolated fixture snapshot",
                                    "sizes": [[1512, 982], [900, 640]],
                                    "limits": ["Static renders require human inspection against approved PNGs", "Does not establish VoiceOver, keyboard navigation, hardware capture or permissions correctness", "AVPlayer layers may require separate media evidence"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("workspace-render.json"))
        print("Workspace renders saved: \(names.count)")
    }

    private static func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Let production .task loads, SwiftUI layout and AppKit drawing settle.
        try await Task.sleep(for: .milliseconds(700))
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
