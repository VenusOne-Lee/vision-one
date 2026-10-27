import AppKit
import SwiftUI
import VisionOneKit

/// The editor: takes sidebar, stage (video, timeline, transport) and the
/// transcript. Every divider drags, the sidebar and transcript fold away,
/// "Focus video" hides both, and the transcript can sit on either side.
/// Narrow windows drop the sidebar; very narrow ones stack the panes.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clips: ClipsModel
    @ObservedObject var thumbnail: ThumbnailModel
    @ObservedObject private var exports = ExportController.shared
    let takes: [Take]
    let open: (Take) -> Void

    @AppStorage("editor.showTakes") private var showTakes = true
    @AppStorage("editor.showTranscript") private var showTranscript = true
    @AppStorage("editor.transcriptOnLeft") private var transcriptOnLeft = false
    @AppStorage("editor.sidePane") private var sidePaneRaw = SidePane.transcript.rawValue

    /// What the pane beside the video shows.
    enum SidePane: String, CaseIterable, Identifiable {
        case transcript, clips, thumbnail
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: return "Transcript"
            case .clips: return "Clips"
            case .thumbnail: return "Thumbnail"
            }
        }
    }

    private var sidePane: SidePane { SidePane(rawValue: sidePaneRaw) ?? .transcript }

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
    }

    // MARK: Toolbar (44 px)

    private var toolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            PanelToggle(systemImage: "sidebar.left", label: "Takes", isOn: $showTakes)
                .keyboardShortcut("1", modifiers: .command)
            Text(model.take.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.sm)
            if model.phase == .ready {
                Text("\(Timecode.string(from: model.edits.sourceDuration)) → \(Timecode.string(from: model.edits.outputDuration))")
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .help("Length of the take → length after your cuts")
                EditorExportStatus(exports: exports)
                // Exports exactly what's on screen, even if saving failed.
                ExportMenu(take: model.take,
                           keep: model.edits.keptSpans.map { $0.start..<$0.end },
                           exports: exports)
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
            PanelToggle(systemImage: "sidebar.right", label: "Transcript", isOn: $showTranscript)
                .keyboardShortcut("2", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.paper)
    }

    private var focusVideo: Bool { !showTakes && !showTranscript }

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
                    .background(Theme.text)
                    .onTapGesture { model.togglePlay() }
                    .overlay {
                        // The selected clip's window, draggable to reframe.
                        if showTranscript, sidePane == .clips, let clip = clips.selected, clip.format != .landscape {
                            ClipWindowOverlay(model: clips, clip: clip)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorTimeline(model: model)
                TransportBar(model: model)
            }
            if let saveError = model.saveError {
                EditorNotice(title: "Edits not saved", message: saveError, isError: true)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.canvas)
    }

    // MARK: Side pane

    /// Transcript, Clips and Thumbnail share the pane beside the video.
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
            if model.proposedCount > 0 {
                HStack(spacing: Theme.Space.sm) {
                    Text("\(model.proposedCount) suggested \(model.proposedCount == 1 ? "cut" : "cuts"), dashed until you accept")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("Accept all") { model.acceptAllProposed() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.clear).frame(height: 1)
                        .overlay(Line().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
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
                                 message: "Nothing was said in this take, or the mic was off. You can still trim it on the timeline once trimming lands.",
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

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A tab in the side pane: ink outline when selected, muted text when not.
private struct TabPillStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isOn ? .medium : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
            .overlay(Capsule().strokeBorder(isOn ? Theme.text : .clear, lineWidth: 1))
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

/// Owns the editor window. A menu bar app has no window of its own, so
/// this makes one on demand and brings the app forward.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()
    private var window: NSWindow?
    private var model: EditorModel?
    private var clips: ClipsModel?

    /// Opens the newest take, or says there is nothing to edit yet.
    func openLatest() {
        if let take = TakeLibrary.standard.takes().first {
            open(take)
        } else {
            let alert = NSAlert()
            alert.messageText = "No recordings yet"
            alert.informativeText = "Record something with ⌘⇧R, then open the editor to cut it."
            alert.runModal()
        }
    }

    func open(_ take: Take) {
        model?.close()
        clips?.close()
        let model = EditorModel(take: take)
        let clips = ClipsModel(take: take, editor: model)
        let thumbnail = ThumbnailModel(take: take, editor: model, clips: clips)
        self.model = model
        self.clips = clips
        let view = EditorView(model: model, clips: clips, thumbnail: thumbnail,
                              takes: TakeLibrary.standard.takes()) { [weak self] next in
            self?.open(next)
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.setFrameAutosaveName("VisionOneEditor")
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = take.name
        window?.contentViewController = NSHostingController(rootView: view)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        clips?.close()
        model = nil
        clips = nil
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
