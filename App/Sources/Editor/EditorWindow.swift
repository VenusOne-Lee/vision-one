import AppKit
import SwiftUI
import VisionOneKit

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

/// Play and step through the take, see where you are and how long it'll
/// be, and zoom the timeline. Times are of the edited video, so they
/// match the export.
struct TransportBar<Accessory: View>: View {
    @ObservedObject var model: EditorModel
    @Binding var zoom: Double
    var showsZoom = true
    var isCompact = false
    @State private var showingDetails = false
    /// Extra controls at the right end, such as Show tracks.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        if isCompact {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    playback
                    timecode
                    Spacer(minLength: 0)
                    Button(showingDetails ? "Hide details" : "Details") { showingDetails.toggle() }
                        .buttonStyle(.secondary)
                }.frame(height: 36)
                if showingDetails {
                    HStack {
                        length
                        Spacer()
                        if showsZoom { zoomControls(slider: false) }
                    }
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) { accessory() }.fixedSize()
                    }.frame(height: 32)
                }
            }
        } else { adaptive }
    }

    private var adaptive: some View {
        ViewThatFits(in: .horizontal) {
            wide.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 6) {
                HStack(spacing: 8) { playback; timecode; Spacer(minLength: 0) }
                HStack(spacing: 8) {
                    length
                    Spacer(minLength: 0)
                    if showsZoom { zoomControls(slider: false) }
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) { accessory() }.fixedSize()
                }
                .frame(height: 32)
            }
            .padding(.vertical, 4)
        }
    }

    private var playback: some View {
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
    }

    private var wide: some View {
        HStack(spacing: Theme.Space.sm) {
            playback
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

    /// The take open in the editor, if any, for windows that act on it.
    var currentTake: Take? { model.workspace?.take }

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
        model.refreshTakes()
        model.open(take, mode: .editor)
        present()
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
