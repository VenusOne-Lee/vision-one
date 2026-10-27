import SwiftUI
import VisionOneKit

/// The music and effects lane under the timeline, on the same clock
/// (the whole take). The music's volume is drawn as a filled curve that
/// dips wherever you talk; cut parts stay empty. Effects are circles:
/// dashed when suggested, solid when accepted. Drag one to move it, click
/// a dashed one to accept it, right-click for more.
struct SoundLane: View {
    @ObservedObject var model: EditorModel
    @State private var dragStart: SoundPlan?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.edits.sourceDuration, 0.001)
            let x = { (t: Double) in CGFloat(t / duration) * width }
            let envelope = model.musicEnvelope
            let edits = model.edits
            let playhead = model.sourceTime
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard let envelope else { return }
                    // Full height is -6 dB, the loudest the level slider goes.
                    let top: CGFloat = 4, bottom = size.height - 4
                    let loudest = MusicEnvelope.gain(db: -6)
                    var path = Path()
                    var open = false
                    var px: CGFloat = 0
                    while px <= size.width {
                        let source = Double(px / max(size.width, 1)) * duration
                        if let output = edits.outputTime(forSource: source) {
                            let level = CGFloat(min(1, envelope.gain(at: output) / loudest))
                            let y = bottom - level * (bottom - top)
                            if !open {
                                path.move(to: CGPoint(x: px, y: bottom))
                                open = true
                            }
                            path.addLine(to: CGPoint(x: px, y: y))
                        } else if open {
                            path.addLine(to: CGPoint(x: px, y: bottom))
                            path.closeSubpath()
                            open = false
                        }
                        px += 2
                    }
                    if open {
                        path.addLine(to: CGPoint(x: size.width, y: bottom))
                        path.closeSubpath()
                    }
                    context.fill(path, with: .color(Theme.text.opacity(0.1)))
                    context.stroke(path, with: .color(Theme.text.opacity(0.7)), lineWidth: 1)
                }
                if envelope == nil {
                    Text("No music · pick one below, or add effects at the playhead")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, 8)
                        .frame(maxHeight: .infinity)
                } else if let title = model.sound.music?.title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, 8)
                        .padding(.top, 3)
                }
                Rectangle()
                    .fill(Theme.text)
                    .frame(width: 2)
                    .offset(x: x(playhead) - 1)
                    .allowsHitTesting(false)
                ForEach(model.sound.effects.filter { $0.state != .rejected }) { effect in
                    marker(effect)
                        .gesture(drag(effect, width: width, duration: duration))
                        .position(x: x(effect.at), y: geometry.size.height / 2)
                }
            }
            .coordinateSpace(name: "soundLane")
        }
        .frame(height: 36)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music and sound effects")
    }

    private func marker(_ effect: PlacedEffect) -> some View {
        let accepted = effect.state == .accepted
        let title = SoundLibrary.sound(id: effect.soundID)?.title ?? effect.soundID
        return Circle()
            .fill(accepted ? Theme.text : Theme.paper)
            .overlay(Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: accepted ? [] : [3, 2])))
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture {
                if accepted { EffectAudition.play(effect.soundID) } else { model.setEffectState(.accepted, for: effect.id) }
            }
            .help(accepted ? "\(title). Drag to move, right-click for more." : "Suggested \(title.lowercased()). Click to use it.")
            .contextMenu {
                if !accepted {
                    Button("Use \(title)") { model.setEffectState(.accepted, for: effect.id) }
                    Button("Don't use") { model.setEffectState(.rejected, for: effect.id) }
                }
                Button("Play") { EffectAudition.play(effect.soundID) }
                Menu("Change to") {
                    ForEach(SoundLibrary.effects) { sound in
                        Button(sound.title) { model.changeEffectSound(effect.id, to: sound.id) }
                    }
                }
                Divider()
                Button("Remove") { model.removeEffect(effect.id) }
            }
            .accessibilityLabel(accepted ? title : "Suggested \(title)")
    }

    private func drag(_ effect: PlacedEffect, width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("soundLane"))
            .onChanged { value in
                if dragStart == nil { dragStart = model.sound }
                let at = Double(value.location.x / max(width, 1)) * duration
                model.previewSound { $0.move(id: effect.id, to: at, sourceDuration: model.edits.sourceDuration) }
            }
            .onEnded { _ in
                model.commitSound(from: dragStart, actionName: "Move Sound Effect")
                dragStart = nil
            }
    }
}
