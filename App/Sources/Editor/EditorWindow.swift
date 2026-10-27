import AppKit
import SwiftUI
import VisionOneKit

/// The editor: takes sidebar, stage (video, transport, timeline, Ask) and
/// the side pane, with the transcript first. The video takes centre
/// stage. Every divider drags, the timeline grows or shrinks from the bar
/// above it, the takes and side pane fold away, "Focus video" hides them
/// both, and the side pane can sit on either side.
/// Narrow windows drop the sidebar; very narrow ones stack the panes.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clips: ClipsModel
    @ObservedObject var thumbnail: ThumbnailModel
    @ObservedObject private var exports = ExportController.shared
    @StateObject private var filmstrip: FilmstripModel
    let open: (Take) -> Void
    /// Read again whenever the window comes forward or a take finishes,
    /// so a new recording shows up in the sidebar.
    @State private var takes: [Take] = TakeLibrary.standard.takes()

    @AppStorage("editor.showTakes") private var showTakes = true
    @AppStorage("editor.showTranscript") private var showSide = true
    @AppStorage("editor.transcriptOnLeft") private var sideOnLeft = false
    /// A new key, so everyone starts on the transcript once.
    @AppStorage("editor.sidePane") private var sidePaneRaw = SidePane.transcript.rawValue
    @AppStorage("editor.timelineHeight") private var timelineHeight = 172.0
    @AppStorage("editor.lane.waveform") private var showWaveform = true
    @AppStorage("editor.lane.effects") private var showEffectsLane = true
    @AppStorage("editor.lane.sound") private var showSoundLane = true
    /// How far the timeline is zoomed in; 1 shows the whole take.
    @State private var zoom = 1.0
    @State private var resizeStart: Double?
    /// An export of this take exists: the ring before its name goes solid.
    @State private var isExported = false
    @State private var showExport = false

    init(model: EditorModel, clips: ClipsModel, thumbnail: ThumbnailModel, open: @escaping (Take) -> Void) {
        self.model = model
        self.clips = clips
        self.thumbnail = thumbnail
        self.open = open
        _filmstrip = StateObject(wrappedValue: FilmstripModel(url: model.take.screenURL))
    }

    /// What the pane beside the video shows.
    enum SidePane: String, CaseIterable, Identifiable {
        case transcript, changes, sound, clips, thumbnail
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: return "Transcript"
            case .changes: return "Changes"
            case .sound: return "Sound"
            case .clips: return "Clips"
            case .thumbnail: return "Thumbnail"
            }
        }

        var systemImage: String {
            switch self {
            case .transcript: return "text.alignleft"
            case .changes: return "checklist"
            case .sound: return "music.note"
            case .clips: return "film.stack"
            case .thumbnail: return "photo"
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
                        stage.frame(minHeight: 320)
                        if showSide { sidePanel.frame(minHeight: 160) }
                    }
                } else {
                    HSplitView {
                        if showTakes && width >= 1000 {
                            TakesSidebar(takes: takes, current: model.take, open: open)
                                .frame(minWidth: 160, idealWidth: 200, maxWidth: 320)
                        }
                        if sideOnLeft && showSide {
                            sidePanel.frame(minWidth: 280, idealWidth: 360, maxWidth: 640)
                        }
                        stage
                            .frame(minWidth: 420, maxWidth: .infinity)
                            .layoutPriority(1)
                        if !sideOnLeft && showSide {
                            sidePanel.frame(minWidth: 280, idealWidth: 360, maxWidth: 640)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .task(id: model.take.folder) {
            await model.load()
            await clips.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshTakes()
        }
        .onReceive(ScreenRecorder.shared.$lastTake) { _ in refreshTakes() }
        .onReceive(exports.$phase) { _ in refreshExported() }
        .onDisappear { filmstrip.cancel() }
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

    /// One black pill (Export); everything else is quieter: undo and the
    /// panels as icon groups, rare things in the ⋯ menu.
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
            ToolbarIcon(systemImage: "sidebar.left", help: showTakes ? "Hide takes (⌘1)" : "Show takes (⌘1)",
                        isOn: showTakes) { showTakes.toggle() }
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
            .layoutPriority(-1)
            Spacer(minLength: Theme.Space.sm)
            if model.phase == .ready {
                EditorExportStatus(exports: exports)
                if model.proposedChangeCount > 0 && !(showSide && sidePane == .changes) { suggestions }
            }
            IconGroup {
                ToolbarIcon(systemImage: "arrow.uturn.backward", help: undoHelp) { model.undoManager.undo() }
                    .disabled(!model.undoManager.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                ToolbarIcon(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.undoManager.redo() }
                    .disabled(!model.undoManager.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            if model.phase == .ready {
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
            IconGroup {
                ToolbarIcon(systemImage: focusVideo ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            help: focusVideo ? "Show the panels again (⌘0)" : "Focus video: hide the takes and side pane (⌘0)",
                            isOn: focusVideo) {
                    let show = focusVideo
                    showTakes = show
                    showSide = show
                }
                .keyboardShortcut("0", modifiers: .command)
                ToolbarIcon(systemImage: "arrow.left.arrow.right", help: "Move the side pane to the other side of the video") {
                    sideOnLeft.toggle()
                }
                ToolbarIcon(systemImage: sideOnLeft ? "sidebar.left" : "sidebar.right",
                            help: showSide ? "Hide the side pane (⌘2)" : "Show the side pane (⌘2)", isOn: showSide) {
                    showSide.toggle()
                }
                .keyboardShortcut("2", modifiers: .command)
            }
            moreMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.paper)
    }

    private var undoHelp: String {
        let name = model.undoManager.undoActionName
        return name.isEmpty ? "Undo (⌘Z)" : "Undo \(name) (⌘Z)"
    }

    private var focusVideo: Bool { !showTakes && !showSide }

    /// Rare and destructive things live here, out of the way.
    private var moreMenu: some View {
        Menu {
            Button("Undo all changes") { model.undoAll() }
                .disabled(!model.canUndoAll)
                .help("Back to the take as you recorded it: your cuts go and every suggestion is turned off. Blurs stay. ⌘Z brings it all back.")
            Divider()
            Section("Timeline") {
                Toggle("Waveform", isOn: $showWaveform)
                Toggle("Zooms and blurs", isOn: $showEffectsLane)
                Toggle("Music and sound effects", isOn: $showSoundLane)
                Button("Show the whole take") { zoom = 1 }
            }
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

    @State private var showShortcuts = false

    /// The suggestions, compact, in the toolbar while Changes isn't open.
    /// Dashed, like the suggestions themselves, until you decide.
    private var suggestions: some View {
        HStack(spacing: 6) {
            Button("\(model.proposedChangeCount) suggested") {
                sidePaneRaw = SidePane.changes.rawValue
                showSide = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .fixedSize()
            .help("See each suggestion in Changes")
            Button("Accept all") { model.acceptAllChanges() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help("Dashed until you decide. ⌘Z undoes Accept all.")
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                EditorNotice(title: "Can't open this take", message: message, isError: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                video
                    .padding([.horizontal, .top], 12)
                TransportBar(model: model, zoom: $zoom)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                timelineResizeBar
                EditorTimeline(model: model, effects: model.effects, filmstrip: filmstrip, zoom: $zoom,
                               showWaveform: showWaveform, showEffects: showEffectsLane, showSound: showSoundLane)
                    .frame(height: timelineHeight)
                    .padding(.horizontal, 12)
                AskBar(model: model)
                    .padding(12)
            }
            if let saveError = model.saveError {
                EditorNotice(title: "Edits not saved", message: saveError, isError: true)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .background(Theme.canvas)
    }

    private var video: some View {
        PlayerSurface(player: model.player)
            .overlay { CaptionLayer(model: model) }
            .background(Theme.text)
            .onTapGesture { model.togglePlay() }
            .overlay { EffectsLayer(model: model, effects: model.effects) }
            .overlay {
                // The selected clip's window, draggable to reframe.
                if showSide, sidePane == .clips, let clip = clips.selected, clip.format != .landscape {
                    ClipWindowOverlay(model: clips, clip: clip)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 160)
            .layoutPriority(1)
    }

    /// Drag up for a taller timeline, down for a bigger video.
    private var timelineResizeBar: some View {
        Capsule()
            .fill(Theme.line)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = timelineHeight }
                        timelineHeight = min(420, max(96, (resizeStart ?? timelineHeight) - value.translation.height))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize the timeline")
            .accessibilityLabel("Timeline height")
    }

    // MARK: Side pane

    /// Transcript, Changes, Sound, Clips and Thumbnail share the pane
    /// beside the video. Tabs never wrap: when the pane is narrow they
    /// become icons.
    private var sidePanel: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                tabs(icons: false)
                tabs(icons: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line)
            switch sidePane {
            case .transcript: transcriptPane
            case .changes: ChangesPanel(model: model, effects: model.effects)
            case .sound:
                ScrollView {
                    SoundPanel(model: model)
                        .padding(14)
                }
            case .clips: ClipsPane(model: clips)
            case .thumbnail:
                ThumbnailPane(model: thumbnail)
                    .task { await thumbnail.loadIfNeeded() }
            }
        }
        .background(Theme.paper)
    }

    private func tabs(icons: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(SidePane.allCases) { pane in
                Button { sidePaneRaw = pane.rawValue } label: {
                    HStack(spacing: 4) {
                        if icons {
                            Image(systemName: pane.systemImage)
                        } else {
                            Text(pane.title)
                        }
                        if pane == .changes, model.proposedChangeCount > 0 {
                            Text("\(model.proposedChangeCount)")
                                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                                .opacity(0.75)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(TabPillStyle(isOn: pane == sidePane))
                .help(pane.title)
                .accessibilityLabel(pane.title)
                .accessibilityAddTraits(pane == sidePane ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
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
struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @Binding var zoom: Double

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
            ViewThatFits(in: .horizontal) {
                zoomControls(slider: true)
                zoomControls(slider: false)
            }
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

/// The keys, for the ⋯ menu.
private struct ShortcutsCard: View {
    private let rows: [(String, String)] = [
        ("Space", "Play or pause"),
        ("J  K  L", "Back 5 s, stop, play (in the transcript)"),
        ("←  →", "One frame (timeline selected)"),
        ("⇧←  ⇧→", "One second (timeline selected)"),
        ("I  O", "Start and end of a stretch at the playhead"),
        ("⌫", "Cut the selected words or stretch"),
        ("⌘+  ⌘−", "Zoom the timeline"),
        ("⌘Z  ⇧⌘Z", "Undo and redo"),
        ("⌘0", "Focus video"),
        ("⌘1  ⌘2", "Takes and side pane"),
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
