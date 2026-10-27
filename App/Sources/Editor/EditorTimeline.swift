import AVKit
import SwiftUI
import VisionOneKit

/// The whole take on one clock: a ruler, a filmstrip of the screen, the
/// mic's waveform (words underneath, fillers in gold), then the zoom and
/// sound lanes. Accepted cuts are hatched, suggestions dashed ink, the
/// playhead is ink with a handle on the ruler.
///
/// Click to jump, drag on the ruler or the playhead to scrub, drag in
/// the picture to pick a stretch and press Delete to cut it. The ink
/// handles at either end trim the start and end. Pinch, ⌘+ and ⌘− zoom;
/// zooming keeps the playhead where it is.
struct EditorTimeline: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var effects: EffectsModel
    @ObservedObject var filmstrip: FilmstripModel
    @Binding var zoom: Double
    var showWaveform = true
    var showEffects = true
    var showSound = true

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var viewWidth: CGFloat = 1
    @State private var hoveredCut: Cut?
    @State private var pinchStart: Double?
    /// Where a drag in the picture started, in seconds of the take.
    @State private var anchor: Double?
    @State private var scrubbing = false
    @State private var trimDrag: (isStart: Bool, t: Double)?
    @FocusState private var focused: Bool

    static let rulerHeight: CGFloat = 20
    static let pictureHeight: CGFloat = 42
    static let wordsHeight: CGFloat = 8
    static let waveHeight: CGFloat = 36

    private var duration: Double { max(model.edits.sourceDuration, 0.001) }

    var body: some View {
        GeometryReader { geometry in
            let available = max(geometry.size.width, 1)
            let z = TimelineScale.clampZoom(zoom, duration: duration, width: available)
            let width = available * z
            ScrollView([.horizontal, .vertical]) {
                content(width: width)
            }
            .scrollIndicators(z > 1 ? .visible : .hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, new in
                offset = new
            }
            .onAppear { viewWidth = available }
            .onChange(of: available) { _, new in viewWidth = new }
            .onChange(of: z) { old, new in keepPlayhead(fromZoom: old, toZoom: new, width: available) }
            .onChange(of: model.sourceTime) { _, t in follow(t, width: width) }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = z }
                        zoom = TimelineScale.clampZoom((pinchStart ?? z) * value.magnification,
                                                       duration: duration, width: available)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { model.cutSelection() }
        .onExitCommand { model.selection = nil }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let back = press.key == .leftArrow
            if press.modifiers.contains(.shift) {
                model.skip(by: back ? -1 : 1)
            } else {
                model.stepFrames(back ? -1 : 1)
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            mark(isStart: press.characters.lowercased() == "i")
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Timecode.string(from: model.sourceTime))
        .accessibilityAdjustableAction { direction in
            model.skip(by: direction == .increment ? 5 : -5)
        }
    }

    // MARK: Content

    private func content(width: CGFloat) -> some View {
        let x = { (t: Double) in CGFloat(t / duration) * width }
        let trackHeight = Self.rulerHeight + Self.pictureHeight + Self.wordsHeight + (showWaveform ? Self.waveHeight : 0)
        let kept = model.keptRange
        return VStack(spacing: 0) {
            TimelineTrack(
                width: width,
                duration: duration,
                height: trackHeight,
                spans: model.wordSpans,
                marks: model.wordMarks,
                removed: model.edits.removedSpans,
                proposed: model.edits.cuts.filter { $0.state == .proposed }.map(\.span),
                hovered: hoveredCut?.span,
                levels: showWaveform ? model.levels : nil,
                showWaveform: showWaveform,
                filmstrip: filmstrip,
                filmstripVersion: filmstrip.version
            )
            .equatable()
            .frame(width: width, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(trackGesture(width: width))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    let cut = model.proposedCut(at: time(at: location.x, width: width))
                    if cut?.id != hoveredCut?.id { hoveredCut = cut }
                case .ended:
                    if hoveredCut != nil { hoveredCut = nil }
                }
            }
            .contextMenu { menu }
            .task(id: FilmstripRequest(width: width, duration: duration)) {
                requestFrames(width: width)
            }
            if showEffects { EffectsLane(model: model, effects: effects) }
            if showSound { SoundLane(model: model).padding(.top, 2) }
        }
        .frame(width: width, alignment: .topLeading)
        .overlay(alignment: .topLeading) { selectionBox(x: x, height: trackHeight) }
        .overlay(alignment: .topLeading) {
            trimHandle(isStart: true, at: trimDrag?.isStart == true ? trimDrag!.t : kept.start,
                       x: x, width: width, height: trackHeight)
        }
        .overlay(alignment: .topLeading) {
            trimHandle(isStart: false, at: trimDrag?.isStart == false ? trimDrag!.t : kept.end,
                       x: x, width: width, height: trackHeight)
        }
        .overlay(alignment: .topLeading) {
            TimelinePlayhead(x: x(model.sourceTime))
                .gesture(scrub(width: width))
        }
        .coordinateSpace(.named("timeline"))
    }

    @ViewBuilder
    private var menu: some View {
        if let cut = hoveredCut {
            Button("Cut this part") { model.decide(cut.id, accept: true) }
            Button("Keep this part") { model.decide(cut.id, accept: false) }
        }
        if let span = model.selection {
            if hoveredCut != nil { Divider() }
            Button("Cut \(Self.seconds(span.duration))") { model.cutSelection() }
            Button("Clear selection") { model.selection = nil }
        }
    }

    /// I and O: the stretch to cut starts or ends at the playhead.
    private func mark(isStart: Bool) {
        let t = model.sourceTime
        let current = model.selection
        if isStart {
            let end = current.map { $0.end > t ? $0.end : t } ?? t
            model.selection = TimeSpan(start: t, end: end)
        } else {
            let start = current.map { $0.start < t ? $0.start : t } ?? t
            model.selection = TimeSpan(start: start, end: t)
        }
    }

    // MARK: Gestures

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        min(max(0, Double(x / max(width, 1)) * duration), duration)
    }

    /// On the ruler: scrub. In the picture: a click jumps there, a drag
    /// picks a stretch to cut.
    private func trackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                focused = true
                let t = time(at: value.location.x, width: width)
                if anchor == nil && !scrubbing {
                    if value.startLocation.y < Self.rulerHeight {
                        scrubbing = true
                    } else {
                        anchor = time(at: value.startLocation.x, width: width)
                    }
                }
                if scrubbing {
                    model.selection = nil
                    model.seek(toSource: t)
                } else if let anchor, abs(value.translation.width) >= 3 {
                    model.selection = TimeSpan(start: anchor, end: t)
                }
            }
            .onEnded { value in
                if !scrubbing, abs(value.translation.width) < 3 {
                    model.selection = nil
                    model.seek(toSource: time(at: value.location.x, width: width))
                }
                anchor = nil
                scrubbing = false
            }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                model.selection = nil
                model.seek(toSource: time(at: value.location.x, width: width))
            }
    }

    // MARK: Overlays

    @ViewBuilder
    private func selectionBox(x: (Double) -> CGFloat, height: CGFloat) -> some View {
        if let span = model.selection {
            Rectangle()
                .fill(Theme.selectionSoft.opacity(0.7))
                .overlay(Rectangle().strokeBorder(Theme.selection, lineWidth: 1.5))
                .frame(width: max(2, x(span.end) - x(span.start)), height: height - Self.rulerHeight)
                .offset(x: x(span.start), y: Self.rulerHeight)
                .allowsHitTesting(false)
        }
    }

    /// An ink bracket at the first or last kept moment. Drag it to trim.
    private func trimHandle(isStart: Bool, at t: Double, x: (Double) -> CGFloat, width: CGFloat,
                            height: CGFloat) -> some View {
        let barHeight = height - Self.rulerHeight
        return UnevenRoundedRectangle(topLeadingRadius: isStart ? 0 : 3, bottomLeadingRadius: isStart ? 0 : 3,
                                      bottomTrailingRadius: isStart ? 3 : 0, topTrailingRadius: isStart ? 3 : 0)
            .fill(Theme.text)
            .frame(width: 6, height: barHeight)
            .overlay(Capsule().fill(Theme.paper).frame(width: 2, height: 12))
            .frame(width: 14, height: barHeight)
            .contentShape(Rectangle())
            .offset(x: isStart ? x(t) - 1 : x(t) - 13, y: Self.rulerHeight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        trimDrag = (isStart, time(at: value.location.x, width: width))
                    }
                    .onEnded { _ in
                        if let drag = trimDrag {
                            if drag.isStart { model.trimStart(to: drag.t) } else { model.trimEnd(to: drag.t) }
                        }
                        trimDrag = nil
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help(isStart ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(isStart ? "Start trim handle" : "End trim handle")
    }

    // MARK: Scrolling

    /// After a zoom, keeps the playhead at the same place on screen, or
    /// in the middle if it was out of view.
    private func keepPlayhead(fromZoom old: Double, toZoom new: Double, width: CGFloat) {
        let t = model.sourceTime
        let wasAt = CGFloat(t / duration) * width * old - offset
        let viewX = (0...width).contains(wasAt) ? wasAt : width / 2
        let x = TimelineScale.offset(keeping: t, atViewX: Double(viewX), zoom: new,
                                     duration: duration, width: Double(width))
        position.scrollTo(x: x)
    }

    /// While playing, pages along so the playhead stays in view.
    private func follow(_ t: Double, width: CGFloat) {
        guard model.isPlaying, width > viewWidth + 1, !scrubbing else { return }
        let px = CGFloat(t / duration) * width
        if px > offset + viewWidth - 24 || px < offset {
            position.scrollTo(x: min(max(0, px - 24), width - viewWidth))
        }
    }

    private func requestFrames(width: CGFloat) {
        let slot = TimelineTrack.slotWidth
        let count = Int((width / slot).rounded(.up))
        let times = (0..<count).map { i in (Double(i) + 0.5) * Double(slot / width) * duration }
        filmstrip.request(times, near: model.sourceTime)
    }

    static func seconds(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded())) s" : String(format: "%.1f s", value)
    }
}

/// What the filmstrip needs fetching for; a new one asks for new frames.
private struct FilmstripRequest: Equatable {
    var width: CGFloat
    var duration: Double
}

/// The ruler, filmstrip, words and waveform, drawn in one pass. Only
/// redrawn when what it shows changes, not on every playhead tick.
struct TimelineTrack: View, Equatable {
    static let slotWidth: CGFloat = 68

    let width: CGFloat
    let duration: Double
    let height: CGFloat
    let spans: [TimeSpan]
    let marks: [WordMark]
    let removed: [TimeSpan]
    let proposed: [TimeSpan]
    let hovered: TimeSpan?
    let levels: LoudnessEnvelope?
    let showWaveform: Bool
    let filmstrip: FilmstripModel
    let filmstripVersion: Int

    static func == (a: Self, b: Self) -> Bool {
        a.width == b.width && a.duration == b.duration && a.height == b.height && a.spans == b.spans
            && a.marks == b.marks && a.removed == b.removed && a.proposed == b.proposed && a.hovered == b.hovered
            && a.levels == b.levels && a.showWaveform == b.showWaveform && a.filmstripVersion == b.filmstripVersion
    }

    var body: some View {
        // Frames picked here, on the main actor, not in the renderer.
        let slots = Int((width / Self.slotWidth).rounded(.up))
        let frames: [CGImage?] = (0..<slots).map { i in
            filmstrip.frame(near: (Double(i) + 0.5) * Double(Self.slotWidth / width) * duration)
        }
        Canvas { context, size in
            let x = { (t: Double) in CGFloat(t / duration) * size.width }
            let ruler = EditorTimeline.rulerHeight
            let pictureTop = ruler
            let picture = CGRect(x: 0, y: pictureTop + 3, width: size.width, height: EditorTimeline.pictureHeight - 6)
            let wordsTop = pictureTop + EditorTimeline.pictureHeight
            let waveTop = wordsTop + EditorTimeline.wordsHeight

            drawRuler(&context, width: size.width)

            // Filmstrip: a frame every slot, cropped to fill it.
            context.fill(Path(picture), with: .color(Theme.text))
            for (i, frame) in frames.enumerated() {
                guard let frame else { continue }
                let slot = CGRect(x: CGFloat(i) * Self.slotWidth, y: picture.minY,
                                  width: Self.slotWidth - 1, height: picture.height)
                let aspect = CGFloat(frame.width) / max(CGFloat(frame.height), 1)
                let drawn = CGSize(width: max(slot.width, slot.height * aspect),
                                   height: max(slot.height, slot.width / aspect))
                context.drawLayer { layer in
                    layer.clip(to: Path(slot))
                    layer.draw(Image(decorative: frame, scale: 1),
                               in: CGRect(x: slot.midX - drawn.width / 2, y: slot.midY - drawn.height / 2,
                                          width: drawn.width, height: drawn.height))
                }
            }

            // Words: a thin strip of ink, fillers and retakes in gold.
            for (i, span) in spans.enumerated() where i < marks.count {
                let rect = CGRect(x: x(span.start), y: wordsTop + 2, width: max(1, x(span.end) - x(span.start)),
                                  height: EditorTimeline.wordsHeight - 3)
                switch marks[i] {
                case .kept: context.fill(Path(rect), with: .color(Theme.text))
                case .cut: context.fill(Path(rect), with: .color(Theme.cutText))
                case let .proposed(reason):
                    context.fill(Path(rect), with: .color(reason == Cut.Reason.filler || reason == Cut.Reason.`repeat`
                        ? Theme.ringGold : Theme.text))
                }
            }

            // Waveform: the loudest level in each point, mirrored.
            if showWaveform {
                let mid = waveTop + EditorTimeline.waveHeight / 2
                let half = EditorTimeline.waveHeight / 2 - 3
                if let levels {
                    var path = Path()
                    var px: CGFloat = 0
                    let perPoint = duration / Double(max(size.width, 1))
                    while px < size.width {
                        let t = Double(px) * perPoint
                        let a = CGFloat(LoudnessEnvelope.amplitude(db: levels.peak(from: t, to: t + perPoint * 2)))
                        let h = max(0.5, a * half)
                        path.addRect(CGRect(x: px, y: mid - h, width: 1.4, height: h * 2))
                        px += 2
                    }
                    context.fill(path, with: .color(Theme.text.opacity(0.75)))
                } else {
                    // No levels yet: the words, larger, so there's still sound to see.
                    var path = Path()
                    for span in spans {
                        path.addRect(CGRect(x: x(span.start), y: mid - half * 0.6,
                                            width: max(1, x(span.end) - x(span.start)), height: half * 1.2))
                    }
                    context.fill(path, with: .color(Theme.text.opacity(0.25)))
                }
            }

            let below = CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler)

            // Accepted cuts: faded and hatched across every row.
            for span in removed {
                let rect = CGRect(x: x(span.start), y: below.minY, width: max(1, x(span.end) - x(span.start)),
                                  height: below.height)
                context.fill(Path(rect), with: .color(Theme.paper.opacity(0.78)))
                var hatch = Path()
                var hx = rect.minX - rect.height
                while hx < rect.maxX {
                    hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY))
                    hx += 6
                }
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(hatch, with: .color(Theme.cutText), lineWidth: 1)
                }
            }

            // Suggestions: dashed ink, a little bolder under the pointer.
            for span in proposed {
                let rect = CGRect(x: x(span.start) + 0.75, y: below.minY + 0.75,
                                  width: max(2, x(span.end) - x(span.start) - 1.5), height: below.height - 1.5)
                let isHovered = hovered == span
                context.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(Theme.text.opacity(isHovered ? 0.12 : 0.05)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Theme.text),
                               style: StrokeStyle(lineWidth: isHovered ? 2 : 1.2, dash: [4, 3]))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    /// Timecodes along the top, spaced so labels never crowd.
    private func drawRuler(_ context: inout GraphicsContext, width: CGFloat) {
        let ruler = EditorTimeline.rulerHeight
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: ruler)), with: .color(Theme.paper))
        let pointsPerSecond = Double(width) / duration
        let step = TimelineScale.step(pointsPerSecond: pointsPerSecond)
        let minor = step / Double(TimelineScale.minorDivisions(for: step))
        var ticks = Path()
        var small = Path()
        var t = 0.0
        while t <= duration + 1e-9 {
            let px = (CGFloat(t / duration) * width).rounded() + 0.5
            let isMajor = abs((t / step).rounded() * step - t) < minor / 10
            if isMajor {
                ticks.move(to: CGPoint(x: px, y: ruler - 8))
                ticks.addLine(to: CGPoint(x: px, y: ruler))
                let label = Text(TimelineScale.label(t, step: step))
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundColor(Theme.textMuted)
                context.draw(label, at: CGPoint(x: px + 3, y: 1), anchor: .topLeading)
            } else {
                small.move(to: CGPoint(x: px, y: ruler - 4))
                small.addLine(to: CGPoint(x: px, y: ruler))
            }
            t += minor
        }
        context.stroke(ticks, with: .color(Theme.textMuted), lineWidth: 1)
        context.stroke(small, with: .color(Theme.line), lineWidth: 1)
        var base = Path()
        base.move(to: CGPoint(x: 0, y: ruler - 0.5))
        base.addLine(to: CGPoint(x: width, y: ruler - 0.5))
        context.stroke(base, with: .color(Theme.line), lineWidth: 1)
    }
}

/// The ink playhead: a line through every lane and a handle on the ruler
/// to grab.
struct TimelinePlayhead: View {
    let x: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.text)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            PlayheadHandle()
                .fill(Theme.text)
                .frame(width: 13, height: 15)
        }
        .frame(width: 18)
        .contentShape(Rectangle())
        .offset(x: x - 9)
        .help("Drag to scrub")
    }
}

/// A pentagon pointing down, like every editor's playhead.
private struct PlayheadHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.6))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.6))
        path.closeSubpath()
        return path
    }
}

/// AVPlayerView without its own controls; the editor has its transport.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
