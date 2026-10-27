import SwiftUI
import VisionOneKit

/// Music and effects controls under the transport: the music picker and
/// its licence, level and duck sliders, the Energy dial and the effects
/// buttons. Lays out in one row when there's room and wraps to two when
/// the stage is narrow.
struct SoundPanel: View {
    @ObservedObject var model: EditorModel
    @State private var sliderStart: SoundPlan?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.lg) {
                music
                levels
                effects
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                music
                HStack(spacing: Theme.Space.lg) {
                    levels
                }
                effects
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
    }

    // MARK: Music

    private var music: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.sm) {
                label("MUSIC")
                Menu {
                    Button("None") { model.setMusic(nil) }
                    Divider()
                    ForEach(SoundLibrary.music) { sound in
                        Button("\(sound.title) · \(sound.summary)") { model.setMusic(.library(sound)) }
                    }
                    Divider()
                    Button("Choose a file…") { model.chooseMusicFile() }
                } label: {
                    Text(model.sound.music?.title ?? "None")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
            }
            Text(model.soundProblem ?? model.sound.music?.licence ?? "Vision One's own beds are free to use anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(model.soundProblem == nil ? Theme.textMuted : Theme.error)
                .lineLimit(2)
                .frame(maxWidth: 260, alignment: .leading)
        }
    }

    // MARK: Level and duck

    @ViewBuilder
    private var levels: some View {
        let bed = model.sound.music
        slider("LEVEL", value: bed?.levelDB ?? MusicBed.defaultLevelDB, range: -30...(-6),
               text: { "\(Int($0)) dB" }, action: "Music Level") { plan, value in plan.music?.levelDB = value }
            .disabled(bed == nil)
            .help("How loud the music is while nobody is talking")
        slider("DUCK", value: bed?.duckDB ?? MusicBed.defaultDuckDB, range: 0...24,
               text: { "\(Int($0)) dB" }, action: "Duck Amount") { plan, value in plan.music?.duckDB = value }
            .disabled(bed == nil)
            .help("How far the music drops while you talk")
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, text: @escaping (Double) -> String,
                        action: String, set: @escaping (inout SoundPlan, Double) -> Void) -> some View {
        HStack(spacing: Theme.Space.sm) {
            label(title)
            Slider(value: Binding(get: { value }, set: { new in model.previewSound { set(&$0, new) } }),
                   in: range, step: 1, onEditingChanged: { editing in
                if editing {
                    sliderStart = model.sound
                } else {
                    model.commitSound(from: sliderStart, actionName: action)
                    sliderStart = nil
                }
            })
            .frame(minWidth: 80, idealWidth: 120, maxWidth: 160)
            .tint(Theme.text)
            Text(text(value))
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: Effects

    private var effects: some View {
        HStack(spacing: Theme.Space.sm) {
            label("ENERGY")
            EnergyDial(energy: model.sound.energy) { model.setEnergy($0) }
            Menu {
                ForEach(SoundLibrary.effects) { sound in
                    Button("\(sound.title) · \(sound.summary)") { model.addEffect(sound.id) }
                }
            } label: {
                Text("Add effect").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .fixedSize()
            .help("Adds a sound effect at the playhead")
            if model.proposedEffectCount > 0 {
                Button("Accept \(model.proposedEffectCount)") { model.acceptAllEffects() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Use every suggested sound effect")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
    }
}

/// Calm, Lively, Viral as one pill split in three; the chosen part is ink.
struct EnergyDial: View {
    let energy: Energy
    let choose: (Energy) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Energy.allCases, id: \.self) { option in
                Button { choose(option) } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(option == energy ? Theme.paper : Theme.text)
                        .background(option == energy ? Theme.text : Theme.paper)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == energy ? .isSelected : [])
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1))
        .help("Calm suggests no effects, Lively a few on new topics, Viral more")
    }
}
