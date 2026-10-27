import AVKit
import SwiftUI
import VisionOneKit

/// The whole take as one strip: speech in ink, fillers in ring gold,
/// cuts hatched and faded, proposals dashed, an ink playhead. Click or
/// drag to scrub.
struct EditorTimeline: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.edits.sourceDuration, 0.001)
            let x = { (t: Double) in CGFloat(t / duration) * width }
            // Read the model here, on the main actor, not in the renderer.
            let spans = model.wordSpans
            let marks = model.edits.marks(for: spans)
            let removedSpans = model.edits.removedSpans
            let proposed = model.edits.cuts.filter { $0.state == .proposed }
            let playhead = model.sourceTime
            Canvas { context, size in
                let lane = CGRect(x: 0, y: size.height / 2 - 8, width: size.width, height: 16)
                for (i, span) in spans.enumerated() {
                    let rect = CGRect(x: x(span.start), y: lane.minY, width: max(1, x(span.end) - x(span.start)), height: lane.height)
                    switch marks[i] {
                    case .kept:
                        context.fill(Path(rect), with: .color(Theme.text))
                    case .cut:
                        break // drawn with the cut below
                    case let .proposed(reason):
                        context.fill(Path(rect), with: .color(reason == Cut.Reason.filler ? Theme.ringGold : Theme.text))
                    }
                }
                for removed in removedSpans {
                    let rect = CGRect(x: x(removed.start), y: lane.minY, width: max(1, x(removed.end) - x(removed.start)), height: lane.height)
                    context.fill(Path(rect), with: .color(Theme.canvas))
                    var hatch = Path()
                    var hx = rect.minX - rect.height
                    while hx < rect.maxX {
                        hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                        hatch.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY))
                        hx += 5
                    }
                    context.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        layer.stroke(hatch, with: .color(Theme.cutText.opacity(0.6)), lineWidth: 1)
                    }
                }
                for cut in proposed {
                    let rect = CGRect(x: x(cut.start), y: lane.minY - 3, width: max(2, x(cut.end) - x(cut.start)), height: lane.height + 6)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3),
                                   with: .color(Theme.ringGold),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                let head = CGRect(x: x(playhead) - 1, y: 4, width: 2, height: size.height - 8)
                context.fill(Path(head), with: .color(Theme.text))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.seek(toSource: Double(value.location.x / max(width, 1)) * duration)
            })
        }
        .frame(height: 40)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(Timecode.string(from: model.sourceTime))
        .accessibilityAdjustableAction { direction in
            model.skip(by: direction == .increment ? 5 : -5)
        }
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
