import SwiftUI
import VisionOneKit

/// Zoom and blur over the editor's player: a "Zoom & blur" pill with the
/// controls and the list of changes, and, while adjusting, the boxes
/// themselves on the whole frame to drag and resize. Dashed boxes are
/// proposals, solid ones accepted.
struct EffectsLayer: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var effects: EffectsModel
    @State private var showPanel = false

    var body: some View {
        GeometryReader { geometry in
            let video = Self.videoFrame(for: model.videoSize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                if effects.isAdjusting {
                    boxes(in: video)
                }
                HStack(spacing: Theme.Space.sm) {
                    Button(effects.proposedCount > 0 ? "Zoom & blur · \(effects.proposedCount)" : "Zoom & blur") {
                        showPanel.toggle()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .popover(isPresented: $showPanel, arrowEdge: .bottom) {
                        EffectsPanel(model: model, effects: effects)
                            .padding(Theme.Space.md)
                            .frame(width: 340)
                            .background(Theme.paper)
                            .environment(\.colorScheme, .light)
                    }
                    .help("Auto zoom on clicks and blur secrets on screen")
                    if effects.isAdjusting {
                        Button("Done adjusting") { effects.isAdjusting = false }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    if case let .scanning(progress) = effects.scan {
                        ScanBadge(progress: progress)
                    }
                }
                .padding(Theme.Space.sm)
            }
        }
    }

    /// Where the video sits inside the player (aspect fit).
    static func videoFrame(for videoSize: CGSize, in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / videoSize.width, size.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    @ViewBuilder
    private func boxes(in video: CGRect) -> some View {
        let t = model.sourceTime
        ForEach(effects.blurs.blurs(at: t)) { blur in
            AdjustableBox(rect: blur.rect, video: video, state: blur.state,
                          label: blur.kind ?? "Blur", keepsFrameShape: false) { rect in
                var next = blur
                next.rect = rect
                effects.setBlur(next)
            }
        }
        if let zoom = effects.zooms.zoom(at: t) {
            AdjustableBox(rect: zoom.target, video: video, state: zoom.state,
                          label: String(format: "Zoom %.1f×", zoom.scale), keepsFrameShape: true) { rect in
                var next = zoom
                next.setViewport(rect)
                // Placed by hand, so it holds still there.
                next.followsCursor = false
                effects.setZoom(next)
            }
        }
    }
}

/// A box on the video: drag inside to move it, drag a corner to resize.
/// Changes are saved (and undoable) when the drag ends.
struct AdjustableBox: View {
    let rect: FrameRect
    let video: CGRect
    let state: ProposalState
    let label: String
    /// Zoom boxes keep the frame's shape, so the zoom never stretches.
    let keepsFrameShape: Bool
    let onCommit: (FrameRect) -> Void

    @State private var live: FrameRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let current = live ?? rect
        let box = viewRect(current)
        ZStack(alignment: .topLeading) {
            outline
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .position(x: box.midX, y: box.midY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { live = moved(rect, by: $0.translation) }
                    .onEnded { _ in commit() })
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.text, style: strokeStyle(width: 1)))
                .foregroundStyle(Theme.text)
                .fixedSize()
                .position(x: box.minX + 40, y: max(10, box.minY - 12))
                .allowsHitTesting(false)
            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Theme.paper)
                    .overlay(Circle().strokeBorder(Theme.text, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .position(point(of: corner, in: box))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { live = resized(rect, corner: corner, by: $0.translation) }
                        .onEnded { _ in commit() })
            }
        }
        .opacity(state == .rejected ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(state == .proposed ? "suggested" : state == .accepted ? "on" : "off")")
    }

    /// Dashed until accepted. A white line under the ink keeps it visible
    /// on dark screens.
    private var outline: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.paper, style: strokeStyle(width: 3))
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.text, style: strokeStyle(width: 1.5))
        }
    }

    private func strokeStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, dash: state == .accepted ? [] : [5, 3])
    }

    private func commit() {
        if let live, live != rect { onCommit(live) }
        live = nil
    }

    private func viewRect(_ r: FrameRect) -> CGRect {
        CGRect(x: video.minX + r.x * video.width, y: video.minY + r.y * video.height,
               width: r.width * video.width, height: r.height * video.height)
    }

    private func point(of corner: Corner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    private func moved(_ r: FrameRect, by translation: CGSize) -> FrameRect {
        let dx = translation.width / max(video.width, 1)
        let dy = translation.height / max(video.height, 1)
        return FrameRect(x: min(max(r.x + dx, 0), 1 - r.width),
                         y: min(max(r.y + dy, 0), 1 - r.height),
                         width: r.width, height: r.height)
    }

    /// The opposite corner stays put.
    private func resized(_ r: FrameRect, corner: Corner, by translation: CGSize) -> FrameRect {
        let dx = translation.width / max(video.width, 1)
        let dy = translation.height / max(video.height, 1)
        let minimum = 0.02
        let fixedX = (corner == .topLeft || corner == .bottomLeft) ? r.maxX : r.minX
        let fixedY = (corner == .topLeft || corner == .topRight) ? r.maxY : r.minY
        let movingX = min(max(((corner == .topLeft || corner == .bottomLeft) ? r.minX : r.maxX) + dx, 0), 1)
        let movingY = min(max(((corner == .topLeft || corner == .topRight) ? r.minY : r.maxY) + dy, 0), 1)
        var width = max(abs(movingX - fixedX), minimum)
        var height = max(abs(movingY - fixedY), minimum)
        if keepsFrameShape {
            // Zoom boxes are as wide as they are tall in frame units.
            let side = min(max(width, height, 1 / Zoom.scaleRange.upperBound), 1)
            width = side
            height = side
        }
        let x = movingX < fixedX ? fixedX - width : fixedX
        let y = movingY < fixedY ? fixedY - height : fixedY
        return FrameRect(x: min(max(x, 0), 1 - width), y: min(max(y, 0), 1 - height), width: width, height: height)
    }
}

/// "Reading the screen" with a dashed ring filling, beside the pill.
private struct ScanBadge: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 1.5))
                    .rotationEffect(.degrees(-90))
                    .padding(0.75)
            }
            .frame(width: 14, height: 14)
            Text("Looking for secrets \(Int(progress * 100))%")
                .font(.system(size: 11).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.paper, in: Capsule())
        .foregroundStyle(Theme.text)
    }
}

/// The popover: auto zoom, secret blur, and every zoom and blur as a row.
struct EffectsPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var effects: EffectsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            zoomSection
            Divider().overlay(Theme.line)
            blurSection
            Divider().overlay(Theme.line)
            Toggle("Adjust boxes on the video", isOn: $effects.isAdjusting)
                .toggleStyle(.switch)
                .tint(Theme.text)
                .font(.system(size: 12))
                .help("Shows the whole frame with every box at the playhead. Drag to move, corners to resize.")
            changes
            if let error = effects.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.error)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionLabel("AUTO ZOOM")
            if effects.hasClickLog {
                Picker("Energy", selection: Binding(
                    get: { effects.zooms.energy },
                    set: { effects.findZooms(energy: $0, edits: model.edits) }
                )) {
                    ForEach(ZoomEnergy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Zooms in on your \(effects.clickCount) \(effects.clickCount == 1 ? "click" : "clicks"). Calm zooms a little, Viral zooms close and often.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This take has no click log, so there's nothing to zoom on. You can still add zooms by hand.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                if effects.hasClickLog {
                    Button("Find zooms again") { effects.findZooms(energy: effects.zooms.energy, edits: model.edits) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button("Zoom here") { effects.addZoom(at: model.sourceTime, sourceDuration: model.edits.sourceDuration) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Add a three second zoom at the playhead")
            }
        }
    }

    private var blurSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionLabel("SECRET BLUR")
            switch effects.scan {
            case let .scanning(progress):
                ProgressView(value: progress).tint(Theme.text)
                Text("Reading the text on screen, on this Mac. \(Int(progress * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            case let .done(found):
                Text(found == 0 ? "No new secrets found." : "Found \(found) new \(found == 1 ? "secret" : "secrets"). Each one is blurred already; turn it off if it isn't secret.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case let .failed(message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                Text("Blurs API keys, tokens, passwords, card and ID numbers it reads on screen. Blurs hide from the moment they're found, even before you accept them.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                Button("Look for secrets again") { effects.findSecrets() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(effects.scan.isScanning)
                Button("Blur here") { effects.addBlur(at: model.sourceTime, sourceDuration: model.edits.sourceDuration) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Add a three second blur at the playhead, then drag it over what to hide")
            }
        }
    }

    private struct Row: Identifiable {
        let id: UUID
        let start: Double
        let title: String
        let state: ProposalState
        let isZoom: Bool
    }

    private var rows: [Row] {
        let zooms = effects.zooms.zooms.map {
            Row(id: $0.id, start: $0.start, title: String(format: "Zoom %.1f×", $0.scale), state: $0.state, isZoom: true)
        }
        let blurs = effects.blurs.blurs.map {
            Row(id: $0.id, start: $0.start, title: "Blur · \($0.kind ?? "drawn")", state: $0.state, isZoom: false)
        }
        return (zooms + blurs).sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private var changes: some View {
        let list = rows
        if list.isEmpty {
            Text("No zooms or blurs yet.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if effects.proposedCount > 0 {
                    HStack {
                        Text("\(effects.proposedCount) suggested, dashed until you accept")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Accept all") { effects.acceptAllProposed() }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(list) { row in
                            ChangeRow(title: row.title, start: row.start, state: row.state,
                                      seek: { model.seek(toSource: row.start) },
                                      setState: { state in
                                          if row.isZoom { effects.setZoomState(state, for: row.id) } else { effects.setBlurState(state, for: row.id) }
                                      },
                                      remove: {
                                          if row.isZoom { effects.removeZoom(row.id) } else { effects.removeBlur(row.id) }
                                      })
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

/// One zoom or blur: dashed while suggested, solid once on, faded when
/// turned off. The switch turns it on or off; the time jumps there.
private struct ChangeRow: View {
    let title: String
    let start: Double
    let state: ProposalState
    let seek: () -> Void
    let setState: (ProposalState) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: seek) {
                HStack(spacing: Theme.Space.sm) {
                    Text(Timecode.string(from: start))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                    Text(title)
                        .font(.system(size: 12))
                        .strikethrough(state == .rejected)
                        .foregroundStyle(state == .rejected ? Theme.cutText : Theme.text)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Jump to it")
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { state == .accepted },
                set: { setState($0 ? .accepted : .rejected) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.text)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(state == .rejected ? Theme.line : Theme.text,
                          style: StrokeStyle(lineWidth: 1, dash: state == .accepted ? [] : [4, 3])))
        .contextMenu { Button("Delete", role: .destructive, action: remove) }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
    }
}

extension EffectsModel.ScanState {
    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

/// Zooms and blurs under the timeline, on the same scale: one row each,
/// dashed while suggested, solid once on. Click to jump there.
struct EffectsLane: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var effects: EffectsModel

    var body: some View {
        // Takes no room until there's something to show.
        if !effects.zooms.zooms.isEmpty || !effects.blurs.blurs.isEmpty {
            lane
        }
    }

    private var lane: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.edits.sourceDuration, 0.001)
            let zooms = effects.zooms.zooms
            let blurs = effects.blurs.blurs
            Canvas { context, size in
                func draw(_ span: TimeSpan, _ state: ProposalState, row: Int) {
                    let rect = CGRect(x: CGFloat(span.start / duration) * size.width, y: 3 + CGFloat(row) * 11,
                                      width: max(3, CGFloat(span.duration / duration) * size.width), height: 7)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    switch state {
                    case .accepted:
                        context.fill(path, with: .color(Theme.text))
                    case .proposed:
                        context.stroke(path, with: .color(Theme.text), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    case .rejected:
                        context.stroke(path, with: .color(Theme.cutText), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                for zoom in zooms { draw(zoom.span, zoom.state, row: 0) }
                for blur in blurs { draw(blur.span, blur.state, row: 1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                model.seek(toSource: Double(location.x / max(width, 1)) * duration)
            }
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Zooms and blurs: \(effects.zooms.zooms.count) zooms, \(effects.blurs.blurs.count) blurs")
    }
}
