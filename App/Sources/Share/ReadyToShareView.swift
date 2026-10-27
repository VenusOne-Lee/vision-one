import AVKit
import AppKit
import SwiftUI
import VisionOneKit

/// What Stop opens, after Loom: the take is saved and one click from a
/// chat. Copy video exports the format the take is for (if it isn't
/// already) and puts the file on the clipboard; Edit opens the editor;
/// the Post panel sits beside it. The two halves are split by a divider
/// you can drag.
struct ReadyToShareView: View {
    let take: Take
    let onEdit: () -> Void

    @ObservedObject private var queue = ExportQueue.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @AppStorage(AfterStop.key) private var afterStop = AfterStop.ready.rawValue
    @State private var player: AVPlayer
    @State private var copyWhenDone = false
    @State private var copied = false

    init(take: Take, onEdit: @escaping () -> Void) {
        self.take = take
        self.onEdit = onEdit
        _player = State(initialValue: AVPlayer(url: take.screenURL))
    }

    var body: some View {
        HSplitView {
            left
                .frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity)
            PostPanel(take: take)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
        }
        .background(Theme.canvas)
        .onChange(of: queue.batch) { _, _ in
            guard copyWhenDone, let file = quickFile else { return }
            copyWhenDone = false
            copy(file)
        }
        .onDisappear { player.pause() }
    }

    // MARK: Left half

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                VideoPlayer(player: player)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                actions
                checklist
                afterStopPicker
            }
            .padding(Theme.Space.lg)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            BuilderRing(state: ringState, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to share")
                    .textStyle(.title)
                    .foregroundStyle(Theme.text)
                Text(take.name)
                    .textStyle(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(copyTitle) { copyVideo() }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyWhenDone || (queue.isRunning && quickFile == nil && !isQuickExport))
                .help("Copy the \(quickPreset.title) video, then paste it into WhatsApp, Slack or Mail")
            Button("Edit") { onEdit() }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .large))
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .help("Open the editor: cuts, captions, zooms and more")
            Spacer(minLength: 0)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([quickFile ?? take.screenURL])
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
        }
    }

    /// The Producer's plan for a fresh take, Codex-style: what's done,
    /// what's running, what's next. Solid when done, dashed while waiting.
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            step("Take saved", done: true)
            step(hasTranscript ? "Transcript ready" : "Writing the transcript on this Mac…", done: hasTranscript)
            step(hasDraft ? "Sharer drafted your posts" : "Posts not drafted yet", done: hasDraft)
            step(exportLine, done: quickFile != nil)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
    }

    private func step(_ title: String, done: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.ring,
                                                             dash: done ? [] : Theme.Stroke.dashSmall))
                .background(Circle().fill(done ? Theme.text : Color.clear).padding(4))
                .frame(width: 14, height: 14)
            Text(title)
                .textStyle(.body)
                .foregroundStyle(done ? Theme.text : Theme.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not done")
    }

    private var afterStopPicker: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("After Stop, open")
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
            SegmentedTabs(selection: Binding(
                get: { AfterStop(rawValue: afterStop) ?? .ready },
                set: { afterStop = $0.rawValue }),
                options: AfterStop.allCases) { $0.title }
            .fixedSize()
        }
    }

    // MARK: State

    private var hasTranscript: Bool { FileManager.default.fileExists(atPath: take.transcriptURL.path) }
    private var hasDraft: Bool { FileManager.default.fileExists(atPath: take.shareURL.path) }

    /// The one format the take is for: the first of its purpose's picks.
    private var quickPreset: ExportPreset {
        let purpose = TakePlan.load(for: take)?.purpose ?? .demo
        return ExportPreset.suggested(for: purpose).first ?? .hd1080
    }

    private var quickFile: URL? {
        if case let .done(url, _)? = queue.batch(for: take)?.status(of: quickPreset) { return url }
        let url = take.exportURL(for: quickPreset)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var isQuickExport: Bool {
        guard let batch = queue.batch(for: take) else { return false }
        return batch.isRunning && batch.presets.contains(quickPreset)
    }

    private var ringState: BuilderRing.State {
        if let batch = queue.batch(for: take), batch.isRunning {
            return .exporting(ExportProgress.overall(batch) { _ in 1 })
        }
        return quickFile == nil ? .draft : .exported
    }

    private var exportLine: String {
        if quickFile != nil { return "\(quickPreset.title) video exported" }
        if isQuickExport { return "Exporting \(quickPreset.title)…" }
        return "\(quickPreset.title) not exported yet"
    }

    private var copyTitle: String {
        if copied { return "Copied" }
        if copyWhenDone || isQuickExport { return "Exporting…" }
        return quickFile == nil ? "Export and copy" : "Copy video"
    }

    // MARK: Actions

    private func copyVideo() {
        if let file = quickFile {
            copy(file)
            return
        }
        copyWhenDone = true
        if !isQuickExport {
            queue.reset()
            queue.export(take, presets: [quickPreset], keep: nil)
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// What Stop opens: Ready to share (the default) or straight to the editor.
enum AfterStop: String, CaseIterable, Hashable {
    case ready, editor

    static let key = "afterStop"

    var title: String {
        switch self {
        case .ready: "Ready to share"
        case .editor: "Editor"
        }
    }

    static var current: AfterStop {
        UserDefaults.standard.string(forKey: key).flatMap(AfterStop.init(rawValue:)) ?? .ready
    }
}

/// The Ready to share window. Stop calls `afterStop(_:)`, which opens
/// this or the editor, as the builder chose.
@MainActor
final class ReadyToShareWindowController: NSObject, NSWindowDelegate {
    static let shared = ReadyToShareWindowController()

    private var window: NSWindow?

    /// What ScreenRecorder.stop() calls once the take is saved.
    func afterStop(_ take: Take) {
        // The take's task, with the Post panel in front, or straight
        // into the editor.
        switch AfterStop.current {
        case .ready: EditorWindowController.shared.open(take, panel: .post)
        case .editor: EditorWindowController.shared.edit(take)
        }
    }

    func open(_ take: Take) {
        let view = ReadyToShareView(take: take) { [weak self] in
            EditorWindowController.shared.open(take)
            self?.window?.close()
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Ready to share"
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("VisionOneReadyToShare")
            self.window = window
        }
        window?.subtitle = take.name
        let frame = window?.frame
        window?.contentViewController = NSHostingController(rootView: view.themed())
        if let frame { window?.setFrame(frame, display: false) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drops the player, so the take's file isn't held open.
        window?.contentViewController = nil
    }
}
