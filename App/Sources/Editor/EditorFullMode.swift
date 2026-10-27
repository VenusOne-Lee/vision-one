import AppKit
import SwiftUI
import VisionOneKit

/// The editor full mode, for the frame's Editor switch: tools down the
/// left, the video in the middle with transport, timeline and Ask under
/// it, Changes and Transcript on the right, and the frame's task rail on
/// the edge so agents keep working. The frame owns the top bar, the
/// mode switch and Esc; this owns everything under it.
///
/// Everything adjusts: drag the aside's edge, drag the bar above the
/// timeline, fold the aside away, and Show tracks adds a lane per agent.
struct EditorFullMode<Rail: View>: View {
    @ObservedObject var model: EditorModel
    /// The Clips and Thumbnail tabs show only when these are given.
    var clips: ClipsModel?
    var thumbnail: ThumbnailModel?
    let onBack: () -> Void
    @ViewBuilder let rail: () -> Rail

    @StateObject private var filmstrip: FilmstripModel
    @AppStorage("editor.tool") private var toolRaw = EditorTool.select.rawValue
    @AppStorage("editor.showTranscript") private var showAside = true
    @AppStorage("editor.asideWidth") private var asideWidth = 340.0
    @AppStorage("editor.aside") private var asideRaw = EditorAside.transcript.rawValue
    @AppStorage("editor.timelineHeight") private var timelineHeight = 172.0
    @AppStorage("editor.showTracks") private var showTracks = true
    @AppStorage("editor.lane.waveform") private var showWaveform = true
    @State private var zoom = 1.0
    @State private var resizeStart: Double?
    @State private var keys = EditorKeyMonitor()
    @StateObject private var talk = TalkController()
    /// Space is down; a hold past `holdToTalk` starts listening.
    @State private var spaceDown = false

    static var holdToTalk: Duration { .milliseconds(350) }

    init(model: EditorModel, clips: ClipsModel? = nil, thumbnail: ThumbnailModel? = nil,
         onBack: @escaping () -> Void, @ViewBuilder rail: @escaping () -> Rail) {
        self.model = model
        self.clips = clips
        self.thumbnail = thumbnail
        self.onBack = onBack
        self.rail = rail
        _filmstrip = StateObject(wrappedValue: FilmstripModel(url: model.take.screenURL))
    }

    private var tool: EditorTool { EditorTool(rawValue: toolRaw) ?? .select }

    private var asides: [EditorAside] {
        var all: [EditorAside] = [.transcript, .changes]
        if clips != nil { all.append(.clips) }
        if thumbnail != nil { all.append(.thumbnail) }
        return all
    }

    private var aside: EditorAside {
        let picked = EditorAside(rawValue: asideRaw) ?? .transcript
        return asides.contains(picked) ? picked : .transcript
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 760 {
                // Narrow: the aside goes under the stage.
                VSplitView {
                    HStack(spacing: 0) {
                        ToolStrip(model: model, tool: $toolRaw)
                        stage
                    }
                    .frame(minHeight: 320)
                    if showAside { asidePanel.frame(minHeight: 180) }
                }
            } else {
                HStack(spacing: 0) {
                    ToolStrip(model: model, tool: $toolRaw)
                    stage
                        .frame(minWidth: 380, maxWidth: .infinity)
                        .layoutPriority(1)
                    if showAside {
                        SideResizeHandle(width: $asideWidth, range: 260...min(640, geometry.size.width * 0.5))
                        asidePanel.frame(width: asideWidth)
                    }
                    rail()
                }
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .task(id: model.take.folder) {
            await model.loadIfNeeded()
            await clips?.load()
        }
        .onAppear {
            keys.start(onKey: { key in
                guard let picked = EditorTool.forKey(key) else { return false }
                toolRaw = picked.rawValue
                return true
            }, onSpace: space)
        }
        .onChange(of: model.requestedTool) { _, requested in
            guard let requested else { return }
            toolRaw = requested.rawValue
            model.requestedTool = nil
        }
        .onDisappear {
            keys.stop()
            filmstrip.cancel()
        }
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
                TransportBar(model: model, zoom: $zoom) {
                    Text("Hold Space to talk · D to draw")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Hold Space while it plays and say what you want, like “cut this bit” or “zoom in here”. With the pen (D), circle to zoom and scribble to blur.")
                    Button("Show tracks") { showTracks.toggle() }
                        .buttonStyle(TabPillStyle(isOn: showTracks))
                        .accessibilityAddTraits(showTracks ? .isSelected : [])
                        .help("One lane each for zooms and blurs, and music and sound effects")
                    IconButton(showAside ? "Hide the side pane" : "Show the side pane",
                               systemImage: "sidebar.right", shortcut: "⌘2", isOn: false) {
                        showAside.toggle()
                    }
                    .keyboardShortcut("2", modifiers: .command)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                TimelineResizeBar(height: $timelineHeight)
                EditorTimeline(model: model, effects: model.effects, filmstrip: filmstrip, zoom: $zoom,
                               showWaveform: showWaveform, showEffects: showTracks, showSound: showTracks,
                               cutsOnRelease: tool == .cut)
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
                if tool == .zoom || tool == .blur {
                    ToolBoxLayer(model: model, tool: tool)
                } else if tool == .draw {
                    DrawLayer(model: model)
                }
            }
            .overlay { SteerOverlay(model: model, talk: talk).allowsHitTesting(true) }
            .overlay {
                if showAside, aside == .clips, let clips {
                    ClipWindowHost(clips: clips)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 160)
            .layoutPriority(1)
    }

    /// Space: a tap plays or pauses, a hold listens until it's let go.
    private func space(_ event: EditorKeyMonitor.SpaceEvent) {
        switch event {
        case .down:
            spaceDown = true
            Task {
                try? await Task.sleep(for: Self.holdToTalk)
                if spaceDown, model.phase == .ready { talk.start(on: model) }
            }
        case .up:
            spaceDown = false
            if talk.isListening {
                talk.finish(on: model)
            } else if case .failed = talk.state {
                talk.dismissError()
                model.togglePlay()
            } else {
                model.togglePlay()
            }
        }
    }

    // MARK: Aside

    private var asidePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                SegmentedTabs(selection: Binding(get: { aside }, set: { asideRaw = $0.rawValue }),
                              options: asides) { pane in
                    pane == .changes && model.proposedChangeCount > 0
                        ? "\(pane.title) \(model.proposedChangeCount)" : pane.title
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line)
            if !model.steerLog.isEmpty { SteerLogStrip(model: model) }
            switch aside {
            case .transcript: TranscriptPane(model: model)
            case .changes: ChangesPanel(model: model, effects: model.effects)
            case .clips:
                if let clips { ClipsPane(model: clips) }
            case .thumbnail:
                if let thumbnail {
                    ThumbnailPane(model: thumbnail)
                        .task { await thumbnail.loadIfNeeded() }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }
}

extension EditorFullMode where Rail == EmptyView {
    init(model: EditorModel, clips: ClipsModel? = nil, thumbnail: ThumbnailModel? = nil,
         onBack: @escaping () -> Void) {
        self.init(model: model, clips: clips, thumbnail: thumbnail, onBack: onBack) { EmptyView() }
    }
}

/// What the pane beside the video shows.
enum EditorAside: String, CaseIterable, Identifiable {
    case transcript, changes, clips, thumbnail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .changes: return "Changes"
        case .clips: return "Clips"
        case .thumbnail: return "Thumbnail"
        }
    }
}

// MARK: Tools strip

/// The tools, top to bottom, with undo and redo at the foot. One key
/// each (V, C, Z, B) when you're not typing.
struct ToolStrip: View {
    @ObservedObject var model: EditorModel
    @Binding var tool: String

    var body: some View {
        VStack(spacing: 4) {
            ForEach(EditorTool.allCases) { option in
                IconButton(option.title, systemImage: option.systemImage,
                           shortcut: option.key.uppercased(), isOn: option.rawValue == tool) {
                    tool = option.rawValue
                }
                .help("\(option.title) (\(option.key.uppercased())): \(option.help)")
            }
            Spacer(minLength: Theme.Space.sm)
            IconButton(undoTitle, systemImage: "arrow.uturn.backward", shortcut: "⌘Z") {
                model.undoManager.undo()
            }
            .disabled(!model.undoManager.canUndo)
            IconButton("Redo", systemImage: "arrow.uturn.forward", shortcut: "⇧⌘Z") {
                model.undoManager.redo()
            }
            .disabled(!model.undoManager.canRedo)
        }
        .padding(.vertical, 10)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private var undoTitle: String {
        let name = model.undoManager.undoActionName
        return name.isEmpty ? "Undo" : "Undo \(name)"
    }
}

extension EditorTool {
    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .cut: return "scissors"
        case .zoom: return "plus.magnifyingglass"
        case .blur: return "square.grid.3x3.fill"
        case .draw: return "pencil.tip"
        }
    }
}

/// With the Zoom or Blur tool: drag a box on the video and it becomes a
/// zoom or a blur from the playhead for three seconds. A click with the
/// Zoom tool zooms 2× on that point.
struct ToolBoxLayer: View {
    @ObservedObject var model: EditorModel
    let tool: EditorTool
    @State private var box: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let video = EffectsLayer.videoFrame(for: model.videoSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let box {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.paper, style: StrokeStyle(lineWidth: 2, dash: Theme.Stroke.dash))
                        .background(Theme.paper.opacity(0.12))
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        box = CGRect(x: min(value.startLocation.x, value.location.x),
                                     y: min(value.startLocation.y, value.location.y),
                                     width: abs(value.location.x - value.startLocation.x),
                                     height: abs(value.location.y - value.startLocation.y))
                    }
                    .onEnded { value in
                        defer { box = nil }
                        guard video.width > 0, video.height > 0,
                              let span = EditorTool.drawnSpan(at: model.sourceTime,
                                                              sourceDuration: model.edits.sourceDuration)
                        else { return }
                        let drawn = box ?? .zero
                        var rect = FrameRect(x: (drawn.minX - video.minX) / video.width,
                                             y: (drawn.minY - video.minY) / video.height,
                                             width: drawn.width / video.width,
                                             height: drawn.height / video.height).clamped
                        let isClick = rect.width < 0.02 && rect.height < 0.02
                        if isClick {
                            guard tool == .zoom else { return }
                            let x = (value.location.x - video.minX) / video.width
                            let y = (value.location.y - video.minY) / video.height
                            rect = FrameRect.centered(x: x, y: y, width: 0.5, height: 0.5)
                        }
                        switch tool {
                        case .zoom: model.effects.addZoom(span: span, viewport: rect)
                        case .blur: model.effects.addBlur(span: span, rect: rect)
                        case .select, .cut, .draw: break
                        }
                    }
            )
            .help(tool == .zoom ? "Drag a box to zoom there, or click to zoom on a point"
                                : "Drag a box over what to hide")
        }
    }
}

// MARK: Shared pieces

/// The selected clip's window over the video, draggable to reframe.
private struct ClipWindowHost: View {
    @ObservedObject var clips: ClipsModel

    var body: some View {
        if let clip = clips.selected, clip.format != .landscape {
            ClipWindowOverlay(model: clips, clip: clip)
        }
    }
}

/// Drag to make the side pane wider or narrower. Saved across launches.
struct SideResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .background(Theme.canvas)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if start == nil { start = width }
                        let upper = max(range.lowerBound, range.upperBound)
                        width = min(upper, max(range.lowerBound, (start ?? width) - value.translation.width))
                    }
                    .onEnded { _ in start = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize the side pane")
            .accessibilityLabel("Side pane width")
    }
}

/// Drag up for a taller timeline, down for a bigger video.
struct TimelineResizeBar: View {
    @Binding var height: Double
    var range: ClosedRange<Double> = 96...420
    @State private var start: Double?

    var body: some View {
        Capsule()
            .fill(Theme.line)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if start == nil { start = height }
                        height = min(range.upperBound, max(range.lowerBound, (start ?? height) - value.translation.height))
                    }
                    .onEnded { _ in start = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize the timeline")
            .accessibilityLabel("Timeline height")
    }
}

/// The transcript, or why it isn't there yet.
struct TranscriptPane: View {
    @ObservedObject var model: EditorModel

    var body: some View {
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

/// The last few things said or drawn, newest first, above the aside.
private struct SteerLogStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.steerLog.suffix(3).reversed()) { entry in
                HStack(spacing: Theme.Space.sm) {
                    Text(Timecode.short(from: entry.at))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                    Text("\(entry.said) → \(entry.result)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if entry.proposal != nil {
                        Button("Keep") { model.keep(entry) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1,
                                                                 dash: entry.proposal == nil ? [] : Theme.Stroke.dash)))
                .contentShape(Rectangle())
                .onTapGesture {
                    model.seek(toSource: model.edits.sourceTime(forOutput: entry.at))
                }
            }
        }
        .padding(10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
