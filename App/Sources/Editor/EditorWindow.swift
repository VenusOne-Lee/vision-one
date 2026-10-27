import AppKit
import SwiftUI
import VisionOneKit

/// The editor: takes sidebar, stage (video, timeline, transport) and the
/// transcript. Every divider drags, the sidebar, transcript and sound
/// panel fold away, "Focus video" hides them all, and the transcript can
/// sit on either side.
/// Narrow windows drop the sidebar; very narrow ones stack the panes.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clips: ClipsModel
    @ObservedObject var thumbnail: ThumbnailModel
    @ObservedObject private var exports = ExportController.shared
    let open: (Take) -> Void
    /// Read again whenever the window comes forward or a take finishes,
    /// so a new recording shows up in the sidebar.
    @State private var takes: [Take] = TakeLibrary.standard.takes()

    @AppStorage("editor.showTakes") private var showTakes = true
    @AppStorage("editor.showTranscript") private var showTranscript = true
    @AppStorage("editor.transcriptOnLeft") private var transcriptOnLeft = false
    @AppStorage("editor.showSound") private var showSound = true
    /// A new key, so everyone starts on Changes once.
    @AppStorage("editor.sideTab") private var sidePaneRaw = SidePane.changes.rawValue
    /// An export of this take exists: the ring before its name goes solid.
    @State private var isExported = false
    @State private var showExport = false

    /// What the pane beside the video shows.
    enum SidePane: String, CaseIterable, Identifiable {
        case changes, transcript, clips, thumbnail
        var id: String { rawValue }
        var title: String {
            switch self {
            case .changes: return "Changes"
            case .transcript: return "Transcript"
            case .clips: return "Clips"
            case .thumbnail: return "Thumbnail"
            }
        }
    }

    private var sidePane: SidePane { SidePane(rawValue: sidePaneRaw) ?? .changes }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            GeometryReader { geometry in
                let width = geometry.size.width
                if width < 640 {
                    VSplitView {
                        stage.frame(minHeight: 220)
                        if showTranscript { sidePanel.frame(minHeight: 160) }
                    }
                } else {
                    HSplitView {
                        if showTakes && width >= 1000 {
                            TakesSidebar(takes: takes, current: model.take, open: open)
                                .frame(minWidth: 160, idealWidth: 200, maxWidth: 320)
                        }
                        if transcriptOnLeft && showTranscript {
                            sidePanel.frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity)
                        }
                        stage
                            .frame(minWidth: 320, maxWidth: .infinity)
                            .layoutPriority(1)
                        if !transcriptOnLeft && showTranscript {
                            sidePanel.frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
        .task(id: model.take.folder) {
            await model.load()
            await clips.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshTakes()
        }
        .onReceive(ScreenRecorder.shared.$lastTake) { _ in refreshTakes() }
        .onReceive(exports.$phase) { _ in refreshExported() }
    }

    private func refreshExported() {
        let take = model.take
        let exported = ExportPreset.allCases.contains {
            FileManager.default.fileExists(atPath: take.exportURL(for: $0).path)
        }
        if exported != isExported { isExported = exported }
    }

    private func refreshTakes() {
        let latest = TakeLibrary.standard.takes()
        if latest != takes { takes = latest }
    }

    // MARK: Toolbar (44 px)

    private var toolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            // Back to every take; the editor and Library share one window.
            Button {
                EditorWindowController.shared.showLibrary()
            } label: {
                Label("Library", systemImage: "chevron.left")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Back to all your recordings (⇧⌘L)")
            PanelToggle(systemImage: "sidebar.left", label: "Takes", isOn: $showTakes)
                .keyboardShortcut("1", modifiers: .command)
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
            Spacer(minLength: Theme.Space.sm)
            if model.phase == .ready {
                // The Changes tab covers this; keep it in reach when the
                // side pane is hidden (Focus video).
                if !showTranscript && model.proposedChangeCount > 0 { suggestions }
                EditorExportStatus(exports: exports)
                Button("Undo all") { model.undoAll() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(!model.canUndoAll)
                    .help("Back to the take as you recorded it: your cuts go and every suggestion is turned off. Blurs stay. ⌘Z brings it all back.")
                Button("Agents") { AgentsWindowController.shared.show(for: model.take) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Pick what it's for, ask for a length, find clips, and write a title and posts")
                // Exports exactly what's on screen, even if saving failed.
                Button("Export") { showExport = true }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .help("Pick formats and captions, then export")
                    .sheet(isPresented: $showExport) {
                        ExportSheet(take: model.take,
                                    keep: model.edits.keptSpans.map { $0.start..<$0.end }) {
                            showExport = false
                        }
                    }
            }
            Button("Undo") { model.undoManager.undo() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(!model.undoManager.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { model.undoManager.redo() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(!model.undoManager.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button(focusVideo ? "Show panels" : "Focus video") {
                let show = focusVideo
                showTakes = show
                showTranscript = show
                showSound = show
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .keyboardShortcut("0", modifiers: .command)
            .help("Hide the takes and transcript so the video fills the window (⌘0)")
            Button {
                transcriptOnLeft.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Move the transcript to the other side of the video")
            PanelToggle(systemImage: "music.note", label: "Sound", isOn: $showSound)
                .keyboardShortcut("3", modifiers: .command)
            PanelToggle(systemImage: "sidebar.right", label: "Transcript", isOn: $showTranscript)
                .keyboardShortcut("2", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.paper)
    }

    private var focusVideo: Bool { !showTakes && !showTranscript && !showSound }

    /// The suggestions, compact, in the toolbar while the side pane is
    /// hidden. Dashed, like the suggestions themselves, until you decide.
    private var suggestions: some View {
        HStack(spacing: 6) {
            Text("\(model.proposedChangeCount) suggested")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Button("Accept all") { model.acceptAllChanges() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help("Dashed until you decide. Show the panels (⌘0) to switch each kind on or off in Changes.")
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        VStack(spacing: Theme.Space.md) {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                EditorNotice(title: "Can't open this take", message: message, isError: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                PlayerSurface(player: model.player)
                    .overlay { CaptionLayer(model: model) }
                    .background(Theme.text)
                    .onTapGesture { model.togglePlay() }
                    .overlay { EffectsLayer(model: model, effects: model.effects) }
                    .overlay {
                        // The selected clip's window, draggable to reframe.
                        if showTranscript, sidePane == .clips, let clip = clips.selected, clip.format != .landscape {
                            ClipWindowOverlay(model: clips, clip: clip)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorTimeline(model: model)
                EffectsLane(model: model, effects: model.effects)
                if showSound { SoundLane(model: model) }
                TransportBar(model: model)
                if showSound { SoundPanel(model: model) }
                EditSummaryLine(model: model, effects: model.effects)
                AskBar(model: model)
            }
            if let saveError = model.saveError {
                EditorNotice(title: "Edits not saved", message: saveError, isError: true)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.canvas)
    }

    // MARK: Side pane

    /// Changes, Transcript, Clips and Thumbnail share the pane beside the video.
    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SidePane.allCases) { pane in
                    Button(pane.title) { sidePaneRaw = pane.rawValue }
                        .buttonStyle(TabPillStyle(isOn: pane == sidePane))
                        .accessibilityAddTraits(pane == sidePane ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line)
            switch sidePane {
            case .changes: ChangesPanel(model: model, effects: model.effects)
            case .transcript: transcriptPane
            case .clips: ClipsPane(model: clips)
            case .thumbnail:
                ThumbnailPane(model: thumbnail)
                    .task { await thumbnail.loadIfNeeded() }
            }
        }
        .background(Theme.paper)
    }

    // MARK: Transcript

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            switch model.transcriptState {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .waiting:
                EditorNotice(title: "Transcript on its way",
                             message: "Vision One is writing out what you said. The words appear here as soon as it's done, and you can play the take meanwhile.",
                             isError: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                EditorNotice(title: "Transcript unavailable", message: message, isError: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if model.words.isEmpty {
                    EditorNotice(title: "No words found",
                                 message: "Nothing was said in this take, or the mic was off. You can still play it and export it as it is.",
                                 isError: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TranscriptTextView(model: model)
                }
            }
        }
        .background(Theme.paper)
    }
}

/// A tab in the side pane: a black pill when selected, muted text when not.
private struct TabPillStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Theme.paper : Theme.textMuted)
            .background(Capsule().fill(isOn ? Theme.text : .clear))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PanelToggle: View {
    let systemImage: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
        .accessibilityLabel(isOn ? "Hide \(label)" : "Show \(label)")
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.space, modifiers: [])
            Text("\(Timecode.string(from: model.edits.outputTime(forSource: model.sourceTime) ?? 0)) / \(Timecode.string(from: model.edits.outputDuration))")
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
            Spacer()
            Text("Space play · J K L · ⌫ cut · ⌘Z undo")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }
}

struct TakesSidebar: View {
    let takes: [Take]
    let current: Take
    let open: (Take) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("TAKES")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                if takes.isEmpty {
                    Text("Recordings you make show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(6)
                }
                ForEach(takes, id: \.folder) { take in
                    Button { open(take) } label: {
                        HStack(spacing: Theme.Space.sm) {
                            // Dashed until exported, the app's one grammar.
                            Circle()
                                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 18, height: 18)
                            Text(take.name.replacingOccurrences(of: "Vision One ", with: ""))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(take == current ? Theme.canvas : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.sm)
        }
        .background(Theme.paper)
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
    private var model: EditorModel?
    private var clips: ClipsModel?

    /// Opens the newest take. With none, there's nothing to open: the
    /// menu only offers Review once a take exists.
    func openLatest() {
        guard let take = TakeLibrary.standard.takes().first else { return }
        open(take)
    }

    /// Brings the window forward as it was, or on the Library once it
    /// has been closed (closing ends the open take).
    func show() {
        if let window, window.isVisible || window.isMiniaturized {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            showLibrary()
        }
    }

    /// The Library: a Record button and every take, newest first.
    func showLibrary() {
        closeTake()
        let view = LibraryView { [weak self] take in
            self?.open(take)
        }
        present(NSHostingController(rootView: view), subtitle: "")
    }

    func open(_ take: Take) {
        closeTake()
        let model = EditorModel(take: take)
        let clips = ClipsModel(take: take, editor: model)
        let thumbnail = ThumbnailModel(take: take, editor: model, clips: clips)
        self.model = model
        self.clips = clips
        let view = EditorView(model: model, clips: clips, thumbnail: thumbnail) { [weak self] next in
            self?.open(next)
        }
        present(NSHostingController(rootView: view), subtitle: take.name)
    }

    private func present(_ content: NSViewController, subtitle: String) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.title = "Vision One"
            window.delegate = self
            window.center()
            // After center(), so a saved frame wins over the default.
            window.setFrameAutosaveName("VisionOneEditor")
            self.window = window
        }
        window?.subtitle = subtitle
        // Swapping the content can resize the window to the new view's
        // ideal size; keep the frame the user chose.
        let frame = window?.frame
        window?.contentViewController = content
        if let frame { window?.setFrame(frame, display: false) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func closeTake() {
        model?.close()
        clips?.close()
        model = nil
        clips = nil
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        closeTake()
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
