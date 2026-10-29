import AppKit
import AVKit
import SwiftUI
import VisionOneKit

/// The Clips tab beside the video: suggested clips dashed, kept ones
/// solid. The selected clip opens up with its format, framing, trim
/// grips and export.
struct ClipsPane: View {
    @ObservedObject var model: ClipsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.saveError {
                EditorNotice(title: "Clips not saved", message: error, isError: true)
                    .padding(Theme.Space.sm)
            }
            if model.list.visible.isEmpty {
                EditorNotice(
                    title: model.canFind ? "No clips yet" : "Clips need the transcript",
                    message: model.canFind
                        ? "Find clips looks for 15 to 60 second moments that start with a hook and end on a full stop. You can also make one from the playhead."
                        : "Vision One cuts clips on sentence edges, so it waits for the transcript. You can still make one by hand from the playhead.",
                    isError: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(model.list.visible) { clip in
                            ClipCard(model: model, clip: clip, isSelected: clip.id == model.selectedID)
                        }
                    }
                    .padding(Theme.Space.sm + 4)
                }
            }
        }
        .background(Theme.paper)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
            Spacer(minLength: 4)
            if model.proposedCount > 1 {
                Button("Keep all") { model.acceptAll() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            Menu("Add") {
                Button("Find clips") { model.findClips() }.disabled(!model.canFind)
                Button("New clip from the playhead") { model.addAtPlayhead() }
                Divider()
                Button("Export all kept clips") { model.exportAccepted() }
                    .disabled(model.list.accepted.isEmpty || model.isExporting)
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let proposed = model.proposedCount
        let kept = model.list.accepted.count
        switch (proposed, kept) {
        case (0, 0): return "Short clips for Shorts, Reels and LinkedIn"
        case (_, 0): return "\(proposed) suggested, dashed until you keep them"
        case (0, _): return "\(kept) kept"
        default: return "\(kept) kept · \(proposed) suggested"
        }
    }
}

struct ClipCard: View {
    @ObservedObject var model: ClipsModel
    let clip: Clip
    let isSelected: Bool

    @State private var title = ""
    @State private var previewing = false
    @FocusState private var editingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: 10) {
                FormatThumb(format: clip.format, accepted: clip.state == .accepted)
                VStack(alignment: .leading, spacing: 3) {
                    if isSelected {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($editingTitle)
                            .onSubmit { model.rename(clip.id, to: title) }
                            .onChange(of: editingTitle) { _, editing in
                                if !editing { model.rename(clip.id, to: title) }
                            }
                    } else {
                        Text(clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    }
                    if let hook = clip.hook, !hook.isEmpty {
                        Text(hook)
                            .font(Font(Theme.transcriptFont(size: 13) as CTFont))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(isSelected ? 4 : 2)
                    }
                    meta
                }
            }
            if isSelected { controls }
        }
        .padding(10)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            // Dashed until kept, the app's one grammar.
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(clip.state == .accepted ? Theme.text : Theme.textMuted,
                              style: StrokeStyle(lineWidth: 1, dash: clip.state == .accepted ? [] : [4, 3]))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md + 2)
                .stroke(isSelected ? Theme.selectionSoft : .clear, lineWidth: 3)
                .padding(-2)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = clip.id }
        .onAppear { title = clip.title }
        .onChange(of: clip.title) { _, new in title = new }
        .accessibilityElement(children: .contain)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            ScoreBars(score: clip.score)
            Text(String(format: "%.1f s", model.duration(of: clip)))
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
            if let reason = clip.reason, !reason.isEmpty {
                Text(reason).font(.system(size: 11)).lineLimit(1)
            }
            if clip.origin == Clip.Origin.agent {
                Text("Clipper").font(.system(size: 11))
            }
        }
        .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder
    private var controls: some View {
        ClipRangeBar(model: model, clip: clip)
        HStack(spacing: Theme.Space.sm) {
            ForEach(ClipFormat.allCases) { format in
                FormatButton(format: format, isOn: clip.format == format) {
                    model.setFormat(format, for: clip.id)
                }
            }
            Spacer(minLength: 4)
            if clip.format != .landscape {
                Picker("Framing", selection: Binding(
                    get: { clip.framing.mode },
                    set: { model.setFramingMode($0, for: clip.id) })) {
                    Text("Follow cursor").tag(ClipFraming.Mode.follow)
                    Text("Fixed").tag(ClipFraming.Mode.fixed)
                    Text("Fit").tag(ClipFraming.Mode.fit)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Follow cursor centres on where you worked. Drag the window on the video to fix it. Fit shows the whole screen.")
            }
        }
        HStack(spacing: Theme.Space.sm) {
            Button("Play") { model.play(clip) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Spacer(minLength: 4)
            exportStatus
            if clip.state == .accepted {
                Button("Export") { model.export(clip) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(model.isExporting)
            } else {
                Button("Not this one") { model.reject(clip.id) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Keep clip") { model.accept(clip.id) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        if let warning = model.warnings[clip.id] {
            Text(warning).textStyle(.caption).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
        }
        if model.queuedIDs.contains(clip.id), model.exports[clip.id] == nil {
            Text("Queued").textStyle(.caption).foregroundStyle(Theme.textMuted)
        }
        if model.cancelledIDs.contains(clip.id) {
            Button("Cancelled · Retry") { model.export(clip) }.buttonStyle(.secondary).disabled(model.isExporting)
        }
        switch model.exports[clip.id] {
        case let .exporting(progress):
            HStack(spacing: 6) {
                ExportRing(progress: progress)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Button("Cancel") { model.cancelExport() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        case let .done(url, bytes):
            HStack(spacing: 6) {
                ExportRing(progress: 1)
                Button("Preview MP4") { previewing = true }
                    .buttonStyle(.secondary)
                    .sheet(isPresented: $previewing) { RenderedClipPreview(url: url) }
                Button("Show · \(ExportPhase.size(bytes))") { model.reveal(clip.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
            }
        case let .failed(message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.error)
                .lineLimit(1)
                .help(message)
        case nil:
            EmptyView()
        }
    }
}

/// The whole take as a bar with the clip's span on it. Drag the grips
/// to trim, or the middle to slide the clip.
struct ClipRangeBar: View {
    @ObservedObject var model: ClipsModel
    let clip: Clip

    @State private var dragStart: (start: Double, end: Double)?
    private static let space = "clipRangeBar"

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let total = max(model.sourceDuration, 0.001)
                let x0 = CGFloat(clip.start / total) * width
                let x1 = CGFloat(clip.end / total) * width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.canvas)
                    Rectangle()
                        .fill(Theme.text)
                        .frame(width: 1.5)
                        .offset(x: CGFloat(model.playhead / total) * width)
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.selectionSoft)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: clip.state == .accepted ? [] : [4, 3])))
                        .frame(width: max(x1 - x0, 4))
                        .offset(x: x0)
                        .gesture(slide(width: width, total: total))
                    grip.offset(x: x0 - 5).gesture(edge(start: true, width: width, total: total))
                    grip.offset(x: x1 - 5).gesture(edge(start: false, width: width, total: total))
                }
                .coordinateSpace(name: Self.space)
            }
            .frame(height: 22)
            HStack {
                Text(Timecode.string(from: clip.start))
                Spacer()
                Button("Start at playhead") { model.trim(clip.id, start: model.playhead) }
                    .buttonStyle(.plain)
                Text("·")
                Button("End at playhead") { model.trim(clip.id, end: model.playhead) }
                    .buttonStyle(.plain)
                Spacer()
                Text(Timecode.string(from: clip.end))
            }
            .font(.system(size: 11, design: .monospaced).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        }
    }

    private var grip: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.text)
            .frame(width: 10, height: 26)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func edge(start: Bool, width: CGFloat, total: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let t = Double(value.location.x / width) * total
                if start { model.trim(clip.id, start: t, final: false) } else { model.trim(clip.id, end: t, final: false) }
            }
            .onEnded { value in
                let t = Double(value.location.x / width) * total
                if start { model.trim(clip.id, start: t) } else { model.trim(clip.id, end: t) }
            }
    }

    private func slide(width: CGFloat, total: Double) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = dragStart ?? (start: clip.start, end: clip.end)
                dragStart = origin
                let length = origin.end - origin.start
                let shift = Double(value.translation.width / width) * total
                let start = min(max(0, origin.start + shift), total - length)
                model.trim(clip.id, start: start, end: start + length, final: false)
            }
            .onEnded { _ in
                dragStart = nil
                model.trim(clip.id, start: clip.start, end: clip.end)
            }
    }
}

/// Five bars for the clip's score.
struct ScoreBars: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(i) < (score * 5).rounded() ? Theme.text : Theme.line)
                    .frame(width: 5, height: 10)
            }
        }
        .accessibilityLabel("Score \(Int((score * 100).rounded())) out of 100")
    }
}

/// A clip's shape at its true ratio, dashed until kept.
struct FormatThumb: View {
    let format: ClipFormat
    let accepted: Bool

    var body: some View {
        let height: CGFloat = 64
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
            .fill(Theme.canvas)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1, dash: accepted ? [] : [3, 3])))
            .frame(width: min(height * CGFloat(format.aspect), 72), height: format == .landscape ? 72 / CGFloat(format.aspect) : height)
            .frame(width: 72, height: height)
    }
}

/// Format choice drawn at its true ratio (the design's format shapes).
struct FormatButton: View {
    let format: ClipFormat
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isOn ? Theme.text : Theme.textMuted,
                                  style: StrokeStyle(lineWidth: 1.5, dash: isOn ? [] : [3, 2]))
                    .frame(width: format == .landscape ? 30 : (format == .square ? 22 : 15),
                           height: format == .landscape ? 17 : (format == .square ? 22 : 27))
                    .frame(height: 28, alignment: .bottom)
                Text(format.title)
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
        .help(format.detail)
        .accessibilityLabel("\(format.title), \(format.detail)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Drawn over the preview while a clip is selected: the screen outside
/// the clip's window is dimmed, and the window drags to reframe.
struct ClipWindowOverlay: View {
    @ObservedObject var model: ClipsModel
    let clip: Clip

    /// The window's centre when the drag began.
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoRect(in: geometry.size, aspect: model.sourceAspect)
            let window = model.window(for: clip)
            let rect = CGRect(x: video.minX + CGFloat(window.x) * video.width,
                              y: video.minY + CGFloat(window.y) * video.height,
                              width: CGFloat(window.width) * video.width,
                              height: CGFloat(window.height) * video.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(video)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .bottom) {
                        Text("\(clip.format.title) · drag to reframe")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .padding(.bottom, 8)
                    }
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? CGPoint(x: window.centerX, y: window.centerY)
                            dragStart = start
                            move(from: start, by: value.translation, in: video, final: false)
                        }
                        .onEnded { value in
                            let start = dragStart ?? CGPoint(x: window.centerX, y: window.centerY)
                            dragStart = nil
                            move(from: start, by: value.translation, in: video, final: true)
                        })
                    .onHover { inside in
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
            }
        }
    }

    /// `start` is the window centre, normalized; `translation` is in points.
    private func move(from start: CGPoint, by translation: CGSize, in video: CGRect, final: Bool) {
        guard video.width > 0, video.height > 0 else { return }
        model.moveWindow(clip.id,
                         centerX: Double(start.x + translation.width / video.width),
                         centerY: Double(start.y + translation.height / video.height),
                         final: final)
    }

    /// Where an aspect-fit video sits inside `size`.
    static func videoRect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let a = CGFloat(aspect)
        if size.width / size.height > a {
            let w = size.height * a
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
        let h = size.width / a
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }
}

private struct RenderedClipPreview: View {
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Text("Rendered clip").textStyle(.title)
            VideoPlayer(player: player).frame(minWidth: 400, minHeight: 360)
            Button("Done") { dismiss() }.buttonStyle(.primary)
        }
        .padding(Theme.Space.md).frame(maxHeight: 700).background(Theme.canvas).themed()
        .onAppear { player.play() }.onDisappear { player.pause() }
    }
}
