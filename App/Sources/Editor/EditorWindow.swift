import AppKit
import SwiftUI
import VisionOneKit

/// The editor window's content until the Codex frame hosts the full
/// modes: a slim toolbar (back to the Library, the take, Editor or
/// Sound, Agents and Export) over the editor or sound full mode.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clips: ClipsModel
    @ObservedObject var thumbnail: ThumbnailModel
    @ObservedObject private var exports = ExportController.shared

    @AppStorage("editor.mode") private var modeRaw = Mode.editor.rawValue
    @AppStorage("editor.lane.waveform") private var showWaveform = true
    /// An export of this take exists: the ring before its name goes solid.
    @State private var isExported = false
    @State private var showExport = false
    @State private var showShortcuts = false

    enum Mode: String, CaseIterable {
        case editor, sound
        var title: String { self == .editor ? "Editor" : "Sound" }
    }

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .editor }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            switch mode {
            case .editor:
                EditorFullMode(model: model, clips: clips, thumbnail: thumbnail) {
                    EditorWindowController.shared.showLibrary()
                }
            case .sound:
                SoundFullMode(model: model) { modeRaw = Mode.editor.rawValue }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .onReceive(exports.$phase) { _ in refreshExported() }
    }

    private func refreshExported() {
        let take = model.take
        let exported = ExportPreset.allCases.contains {
            FileManager.default.fileExists(atPath: take.exportURL(for: $0).path)
        }
        if exported != isExported { isExported = exported }
    }

    // MARK: Toolbar (44 px)

    /// One black pill (Export); everything else is quieter.
    private var toolbar: some View {
        HStack(spacing: 10) {
            // Back to every take; the editor and Library share one window.
            Button {
                EditorWindowController.shared.showLibrary()
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Back to all your recordings (⇧⌘L)")
            HStack(spacing: 6) {
                // Dashed until this take has been exported, then solid.
                Circle()
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: isExported ? [] : [3, 2]))
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(isExported ? "Exported" : "Not exported yet")
                Text(model.take.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(-1)
            SegmentedTabs(selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue }),
                          options: Mode.allCases) { $0.title }
            Spacer(minLength: Theme.Space.sm)
            if model.phase == .ready {
                EditorExportStatus(exports: exports)
                if model.proposedChangeCount > 0 { suggestions }
                IconGroup {
                    ToolbarIcon(systemImage: "person.2", help: "Versions: a copy for each person on a list, with their name on the title card") {
                        VersionsWindowController.shared.show(for: model.take)
                    }
                    ToolbarIcon(systemImage: "globe", help: "Languages: captions in South Africa's languages, and an optional dub") {
                        LanguagesWindowController.shared.show(for: model.take)
                    }
                }
                Button("Agents") { AgentsWindowController.shared.show(for: model.take) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    .help("Pick what it's for, ask for a length, find clips, and write a title and posts")
                // Exports exactly what's on screen, even if saving failed.
                Button("Export") { showExport = true }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .fixedSize()
                    .help("Pick formats and captions, then export")
                    .sheet(isPresented: $showExport) {
                        ExportSheet(take: model.take,
                                    keep: model.edits.keptSpans.map { $0.start..<$0.end }) {
                            showExport = false
                        }
                    }
            }
            moreMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.paper)
    }

    /// Rare and destructive things live here, out of the way.
    private var moreMenu: some View {
        Menu {
            Button("Undo all changes") { model.undoAll() }
                .disabled(!model.canUndoAll)
                .help("Back to the take as you recorded it: your cuts go and every suggestion is turned off. Blurs stay. ⌘Z brings it all back.")
            Divider()
            Toggle("Waveform on the timeline", isOn: $showWaveform)
            Divider()
            Button("Keyboard shortcuts") { showShortcuts = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .popover(isPresented: $showShortcuts, arrowEdge: .bottom) { ShortcutsCard() }
    }

    /// The suggestions, compact, in the toolbar. Dashed, like the
    /// suggestions themselves, until you decide.
    private var suggestions: some View {
        HStack(spacing: 6) {
            Text("\(model.proposedChangeCount) suggested")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .fixedSize()
            Button("Accept all") { model.acceptAllChanges() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help("Dashed until you decide. Each one is in Changes. ⌘Z undoes Accept all.")
    }
}

/// A quiet square icon button for the toolbar and transport.
struct ToolbarIcon: View {
    let systemImage: String
    let help: String
    var isOn = true
    var size: CGFloat = 13
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isOn && isEnabled ? Theme.text : Theme.textMuted)
                .frame(width: 28, height: 26)
                .background(hovering && isEnabled ? Theme.canvas : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm + 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Icons that belong together, in one hairline capsule.
struct IconGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Theme.line))
    }
}

/// Play and step through the take, see where you are and how long it'll
/// be, and zoom the timeline. Times are of the edited video, so they
/// match the export.
struct TransportBar<Accessory: View>: View {
    @ObservedObject var model: EditorModel
    @Binding var zoom: Double
    var showsZoom = true
    /// Extra controls at the right end, such as Show tracks.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: 2) {
                ToolbarIcon(systemImage: "backward.end.fill", help: "Go to the start") { model.seekToStart() }
                ToolbarIcon(systemImage: "backward.frame.fill", help: "Back one frame (← in the timeline)") {
                    model.stepFrames(-1)
                }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.text))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                ToolbarIcon(systemImage: "forward.frame.fill", help: "Forward one frame (→ in the timeline)") {
                    model.stepFrames(1)
                }
                ToolbarIcon(systemImage: "forward.end.fill", help: "Go to the end") { model.seekToEnd() }
            }
            timecode
            length
            if let span = model.selection {
                Button("Cut \(EditorTimeline.seconds(span.duration))") { model.cutSelection() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    .help("Cut the stretch you picked on the timeline (Delete)")
            }
            Spacer(minLength: 0)
            if showsZoom {
                ViewThatFits(in: .horizontal) {
                    zoomControls(slider: true)
                    zoomControls(slider: false)
                }
            }
            accessory()
        }
        .frame(height: 36)
    }

    private var timecode: some View {
        HStack(spacing: 0) {
            Text(Timecode.precise(from: model.edits.outputTime(forSource: model.sourceTime) ?? 0))
            Text(" / \(Timecode.precise(from: model.edits.outputDuration))")
                .foregroundStyle(Theme.textMuted)
        }
        .font(.system(size: 13, design: .monospaced).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// "0:37 → 0:21", and what accepting every suggestion would make it,
    /// dashed, as a button that does just that.
    @ViewBuilder
    private var length: some View {
        let source = model.edits.sourceDuration
        let kept = model.edits.outputDuration
        let ifAccepted = model.lengthIfAccepted
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("\(Timecode.short(from: source)) → ")
                    .foregroundStyle(Theme.textMuted)
                Text(Timecode.short(from: kept)).fontWeight(.semibold)
            }
            .help("Length of the take → length after your cuts")
            if ifAccepted < kept - 0.5 {
                Button {
                    model.acceptAllChanges()
                } label: {
                    Text("\(Timecode.short(from: ifAccepted)) if you accept")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Accept every suggestion. ⌘Z undoes it.")
            }
        }
        .font(.system(size: 12, design: .monospaced).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    private func zoomControls(slider: Bool) -> some View {
        HStack(spacing: 4) {
            ToolbarIcon(systemImage: "minus.magnifyingglass", help: "Zoom out (⌘−)") {
                zoom = max(1, zoom / 1.5)
            }
            .keyboardShortcut("-", modifiers: .command)
            if slider {
                Slider(value: Binding(get: { log2(max(1, zoom)) }, set: { zoom = pow(2, $0) }), in: 0...7)
                    .controlSize(.mini)
                    .tint(Theme.text)
                    .frame(width: 90)
                    .accessibilityLabel("Timeline zoom")
            }
            ToolbarIcon(systemImage: "plus.magnifyingglass", help: "Zoom in (⌘+)") {
                zoom = min(128, zoom * 1.5)
            }
            .keyboardShortcut("=", modifiers: .command)
            Button("Fit") { zoom = 1 }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .controlSize(.small)
                .fixedSize()
                .disabled(zoom <= 1.001)
                .help("Show the whole take")
        }
    }
}

extension TransportBar where Accessory == EmptyView {
    init(model: EditorModel, zoom: Binding<Double>) {
        self.init(model: model, zoom: zoom) { EmptyView() }
    }
}

/// The keys, for the ⋯ menu.
private struct ShortcutsCard: View {
    private let rows: [(String, String)] = [
        ("Space", "Play or pause; hold it to talk"),
        ("J  K  L", "Back 5 s, stop, play (in the transcript)"),
        ("←  →", "One frame (timeline selected)"),
        ("⇧←  ⇧→", "One second (timeline selected)"),
        ("I  O", "Start and end of a stretch at the playhead"),
        ("⌫", "Cut the selected words or stretch"),
        ("⌘+  ⌘−", "Zoom the timeline"),
        ("⌘Z  ⇧⌘Z", "Undo and redo"),
        ("V  C  Z  B  D", "Select, Cut, Zoom, Blur and Draw tools"),
        ("⌘2", "Side pane"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.system(size: 12, design: .monospaced))
                    Text(row.1).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(16)
        .background(Theme.paper)
        .themed()
    }
}

/// Tint plus a bold lead sentence, per the design's alerts.
struct EditorNotice: View {
    let title: String
    let message: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(isError ? Theme.error : Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: 360, alignment: .leading)
        .background(isError ? Theme.errorSoft : Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: isError ? [] : [4, 3])))
    }
}

/// Owns the main window: the Library when no take is open, the editor
/// when one is. Made on demand, kept when closed, and its frame is saved.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()
    private var window: NSWindow?
    private var model: HarnessModel { HarnessModel.shared }

    /// Opens the newest take. With none, there's nothing to open: the
    /// menu only offers Review once a take exists.
    func openLatest() {
        guard let take = TakeLibrary.standard.takes().first else { return }
        open(take)
    }

    /// Brings the window forward as it was, or on New task once it has
    /// been closed (closing ends the open task).
    func show() {
        if let window, window.isVisible || window.isMiniaturized {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            model.page = .newTask
            present()
        }
    }

    /// The window on New task with the cursor in the composer: where
    /// launch, the end of setup and ⌘N land.
    func showNewTask() {
        model.mode = .tasks
        model.page = .newTask
        model.focusComposer += 1
        present()
    }

    /// ⌘B: folds the projects sidebar, when this window is in front on
    /// Tasks. HarnessView reads the same key with @AppStorage.
    func toggleSidebar() {
        guard window?.isKeyWindow == true, model.mode == .tasks else { return }
        let key = "harness.showSidebar"
        let shown = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        UserDefaults.standard.set(!shown, forKey: key)
    }

    /// ⌥⌘B: folds the panel beside the thread, when this window is in front.
    func togglePanel() {
        guard window?.isKeyWindow == true, model.mode == .tasks else { return }
        model.updateLayout { $0.isHidden.toggle() }
    }

    /// Every take, to search and pick from.
    func showLibrary() {
        model.mode = .tasks
        model.page = .library
        present()
    }

    /// The take's task, with `panel` in front if given.
    func open(_ take: Take, panel: PanelKind? = nil) {
        model.refreshTakes()
        model.open(take, panel: panel)
        present()
    }

    /// The take in the editor full mode.
    func edit(_ take: Take) {
        open(take)
        model.mode = .editor
    }

    private func present() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Vision One"
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: HarnessView(model: model))
            window.center()
            // After center(), so a saved frame wins over the default.
            window.setFrameAutosaveName("VisionOneEditor")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        model.mode = .tasks
        model.page = .newTask
    }
}

/// The ring and percentage beside the Export pill while exporting, and
/// a solid ring with Show once the file is ready.
struct EditorExportStatus: View {
    @ObservedObject var exports: ExportController

    var body: some View {
        switch exports.phase {
        case let .exporting(preset, progress):
            HStack(spacing: 6) {
                ExportRing(progress: progress)
                Text("\(preset.title) \(Int(progress * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Button("Cancel") { exports.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        case let .done(_, _, bytes):
            HStack(spacing: 6) {
                ExportRing(progress: 1)
                Button("Show · \(ExportPhase.size(bytes))") { exports.revealExport() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        case let .failed(message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.error)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
        case .idle:
            EmptyView()
        }
    }
}
