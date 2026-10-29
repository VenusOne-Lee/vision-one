import AppKit
import SwiftUI
import VisionOneKit

/// The sound full mode, for the frame's Sound switch: the Energy dial
/// and a loudness meter on top, the video, then Voice, Music and Effects
/// as lanes you can mute, solo and resize, with the dashed line where
/// the music ducks under your voice. Mix, Music and Effects settings sit
/// on the right, and the frame's task rail on the edge.
struct SoundFullMode<Rail: View>: View {
    @ObservedObject var model: EditorModel
    let onBack: () -> Void
    @ViewBuilder let rail: () -> Rail

    @AppStorage("sound.asideWidth") private var asideWidth = 320.0
    @AppStorage("sound.aside") private var asideRaw = SoundAside.mix.rawValue
    @AppStorage("sound.videoHeight") private var videoHeight = 240.0

    init(model: EditorModel, onBack: @escaping () -> Void, @ViewBuilder rail: @escaping () -> Rail) {
        self.model = model
        self.onBack = onBack
        self.rail = rail
    }

    private var aside: SoundAside { SoundAside(rawValue: asideRaw) ?? .mix }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 760 {
                VSplitView {
                    main.frame(minHeight: 280)
                    asidePanel.frame(minHeight: 160)
                }
            } else {
            HStack(spacing: 0) {
                main
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                if geometry.size.width >= 760 {
                    SideResizeHandle(width: $asideWidth, range: 260...min(560, geometry.size.width * 0.45))
                    asidePanel.frame(width: min(asideWidth, max(260, geometry.size.width - 500)))
                }
                rail()
            }
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .task(id: model.take.folder) {
            await model.loadIfNeeded()
            await model.loadLevels()
        }
        // Mute and solo are for listening here; leaving puts every lane back.
        .onDisappear { model.laneMix = LaneMix() }
    }

    // MARK: Main column

    @ViewBuilder
    private var main: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            EditorNotice(title: "Can't open this take", message: message, isError: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.md) {
                    sectionLabel("ENERGY")
                    EnergyDial(energy: model.sound.energy) { model.setEnergy($0) }
                    Spacer(minLength: Theme.Space.sm)
                    LoudnessMeter(lufs: model.voiceLoudness)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                PlayerSurface(player: model.player)
                    .overlay { CaptionLayer(model: model) }
                    .background(Theme.text)
                    .onTapGesture { model.togglePlay() }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .frame(maxWidth: .infinity)
                    .frame(height: videoHeight)
                    .padding(.horizontal, 12)
                TransportBar(model: model, zoom: .constant(1), showsZoom: false) {
                    if !model.laneMix.isDefault {
                        Button("Hear everything") { model.laneMix = LaneMix() }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .fixedSize()
                            .help("Turn off every mute and solo")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                TimelineResizeBar(height: Binding(get: { 520 - videoHeight }, set: { videoHeight = 520 - $0 }),
                                  range: 160...420)
                ScrollView {
                    MixLanes(model: model)
                        .padding([.horizontal, .bottom], 12)
                }
            }
        }
    }

    // MARK: Aside

    private var asidePanel: some View {
        VStack(spacing: 0) {
            HStack {
                SegmentedTabs(selection: Binding(get: { aside }, set: { asideRaw = $0.rawValue }),
                              options: SoundAside.allCases) { $0.title }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line)
            ScrollView {
                Group {
                    switch aside {
                    case .mix: MixSettings(model: model)
                    case .music: MusicPicker(model: model)
                    case .effects: EffectsSettings(model: model)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }
}

extension SoundFullMode where Rail == EmptyView {
    init(model: EditorModel, onBack: @escaping () -> Void) {
        self.init(model: model, onBack: onBack) { EmptyView() }
    }
}

enum SoundAside: String, CaseIterable, Identifiable {
    case mix, music, effects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mix: return "Mix"
        case .music: return "Music"
        case .effects: return "Effects"
        }
    }
}

private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .medium))
        .tracking(0.6)
        .foregroundStyle(Theme.textMuted)
}

// MARK: Lanes

/// Voice, Music and Effects on the take's clock, each with mute and
/// solo, each as tall as you drag it. Click anywhere to move the
/// playhead.
struct MixLanes: View {
    @ObservedObject var model: EditorModel
    @AppStorage("sound.lane.voice") private var voiceHeight = 64.0
    @AppStorage("sound.lane.music") private var musicHeight = 64.0
    @AppStorage("sound.lane.effects") private var effectsHeight = 40.0

    static let headerWidth: CGFloat = 132

    var body: some View {
        VStack(spacing: 0) {
            lane(.voice, height: $voiceHeight, detail: voiceDetail) {
                VoiceWave(model: model)
            }
            lane(.music, height: $musicHeight, detail: musicDetail) {
                SoundLane(model: model, parts: .music, height: musicHeight, showsDuckLine: true)
            }
            lane(.effects, height: $effectsHeight, detail: effectsDetail) {
                SoundLane(model: model, parts: .effects, height: effectsHeight)
            }
        }
        .overlay(alignment: .topLeading) { playhead }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
    }

    private var voiceDetail: String {
        model.levels == nil ? "Mic" : "Mic · \(model.edits.cuts.filter { $0.state == .accepted }.count) cuts"
    }

    private var musicDetail: String {
        guard let bed = model.sound.music else { return "None" }
        return "\(bed.title) · \(Int(bed.levelDB)) dB"
    }

    private var effectsDetail: String {
        let proposed = model.proposedEffectCount
        let used = model.sound.effects.filter { $0.state == .accepted }.count
        return proposed > 0 ? "\(used) in · \(proposed) suggested" : "\(used) in"
    }

    private func lane<Content: View>(_ lane: MixLane, height: Binding<Double>, detail: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.title).font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        mixButton("M", on: model.laneMix.muted.contains(lane),
                                  help: "Mute \(lane.title.lowercased()) while you listen") {
                            model.laneMix.toggleMute(lane)
                        }
                        mixButton("S", on: model.laneMix.soloed.contains(lane),
                                  help: "Hear only \(lane.title.lowercased())") {
                            model.laneMix.toggleSolo(lane)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: Self.headerWidth, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity)
                    .frame(height: height.wrappedValue)
                    .opacity(model.laneMix.isAudible(lane) ? 1 : 0.35)
                    .padding(.trailing, 8)
            }
            .frame(height: max(height.wrappedValue, 58))
            LaneResizeEdge(height: height)
        }
    }

    private func mixButton(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 20, height: 18)
                .foregroundStyle(on ? Theme.paper : Theme.text)
                .background(on ? Theme.text : Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(on ? Theme.text : Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One line through every lane at the playhead; click a lane to seek.
    private var playhead: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.headerWidth - 8, 1)
            let duration = max(model.edits.sourceDuration, 0.001)
            let x = Self.headerWidth + CGFloat(model.sourceTime / duration) * width
            Rectangle()
                .fill(Theme.text)
                .frame(width: 1.5, height: geometry.size.height)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }
}

/// The mic's loudness on the take's clock, with cut parts faint.
private struct VoiceWave: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let duration = max(model.edits.sourceDuration, 0.001)
            Canvas { context, size in
                guard let levels = model.levels, !levels.levels.isEmpty else { return }
                let mid = size.height / 2
                var px: CGFloat = 0
                while px < size.width {
                    let t0 = Double(px / size.width) * duration
                    let t1 = Double((px + 2) / size.width) * duration
                    let amp = CGFloat(LoudnessEnvelope.amplitude(db: levels.peak(from: t0, to: t1)))
                    let h = max(1, amp * (size.height - 6))
                    let kept = model.edits.outputTime(forSource: t0) != nil
                    context.fill(Path(CGRect(x: px, y: mid - h / 2, width: 1.4, height: h)),
                                 with: .color(kept ? Theme.text.opacity(0.75) : Theme.cutText.opacity(0.5)))
                    px += 2
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                model.seek(toSource: Double(location.x / max(geometry.size.width, 1)) * duration)
            }
            .overlay {
                if model.levels == nil {
                    Text("Reading the mic…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .accessibilityLabel("Voice")
    }
}

/// Drag the line under a lane to make it taller or shorter.
private struct LaneResizeEdge: View {
    @Binding var height: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .frame(height: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if start == nil { start = height }
                        height = min(200, max(28, (start ?? height) + value.translation.height))
                    }
                    .onEnded { _ in start = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize this lane")
    }
}

/// The voice's loudness against what platforms aim for.
struct LoudnessMeter: View {
    let lufs: Float?

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let lufs {
                Text("\(Int(lufs.rounded())) LUFS · \(LoudnessTarget.verdict(lufs: lufs))")
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                // −30 to −6 across; the tick is the −14 platforms aim for.
                GeometryReader { geometry in
                    let fraction = { (v: Float) in CGFloat(min(1, max(0, (v + 30) / 24))) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.text).frame(width: geometry.size.width * fraction(lufs))
                        Rectangle()
                            .fill(Theme.textMuted)
                            .frame(width: 1.5, height: geometry.size.height + 6)
                            .offset(x: geometry.size.width * fraction(LoudnessTarget.platform))
                    }
                }
                .frame(width: 120, height: 8)
            } else {
                Text("Loudness after the mic is read")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .help("How loud your voice is, measured like YouTube does. Platforms play everything back near −14 LUFS.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: Aside sections

private struct MixSettings: View {
    @ObservedObject var model: EditorModel
    @State private var sliderStart: SoundPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sourceLevel("VOICE LEVEL", value: model.recordedMix.voiceDB, isVoice: true)
            sourceLevel("SYSTEM AUDIO LEVEL", value: model.recordedMix.systemDB, isVoice: false)
            Text("Source levels are saved for preview and export. Voice clarity tools are available from Task tools → Voice tools.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
            Divider().overlay(Theme.line)
            let bed = model.sound.music
            slider("MUSIC LEVEL", value: bed?.levelDB ?? MusicBed.defaultLevelDB, range: -30...(-6),
                   action: "Music Level", help: "How loud the music is while nobody is talking") { plan, value in
                plan.music?.levelDB = value
            }
            .disabled(bed == nil)
            slider("MUSIC UNDER SPEECH", value: -(bed?.duckDB ?? MusicBed.defaultDuckDB), range: -24...0,
                   action: "Duck Amount", help: "How far the music drops while you talk: the dashed line") { plan, value in
                plan.music?.duckDB = -value
            }
            .disabled(bed == nil)
            if bed == nil {
                Text("Pick music in the Music tab to set its level.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("LISTEN")
                Text("M mutes a lane and S hears it alone, here only. Exports always have every lane.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.soundProblem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceLevel(_ title: String, value: Double, isVoice: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { sectionLabel(title); Spacer(); Text("\(Int(value)) dB").textStyle(.caption) }
            Slider(value: Binding(get: { value }, set: { level in
                var mix = model.recordedMix
                if isVoice { mix.voiceDB = level } else { mix.systemDB = level }
                model.applyRecordedMix(mix)
            }), in: -60...6, step: 1)
            .accessibilityLabel(title.capitalized)
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, action: String, help: String,
                        set: @escaping (inout SoundPlan, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel(title)
                Spacer()
                Text("\(Int(value)) dB")
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
            }
            Slider(value: Binding(get: { value }, set: { new in model.previewSound { set(&$0, new) } }),
                   in: range, step: 1, onEditingChanged: { editing in
                if editing {
                    sliderStart = model.sound
                } else {
                    model.commitSound(from: sliderStart, actionName: action)
                    sliderStart = nil
                }
            })
            .tint(Theme.text)
            .accessibilityLabel(title.capitalized)
        }
        .help(help)
    }
}

/// The licence-safe beds by mood, each playable before you pick it.
private struct MusicPicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(title: "None", summary: "No music", isOn: model.sound.music == nil, preview: nil) {
                model.setMusic(nil)
            }
            ForEach(SoundLibrary.music) { sound in
                row(title: sound.title, summary: sound.summary,
                    isOn: model.sound.music?.libraryID == sound.id, preview: sound.id) {
                    model.setMusic(.library(sound))
                }
            }
            Button("Choose a file…") { model.chooseMusicFile() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .padding(.top, 4)
            Text(model.sound.music?.licence ?? "Vision One's own beds are free to use anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { EffectAudition.stop() }
    }

    private func row(title: String, summary: String, isOn: Bool, preview: String?,
                     pick: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let preview {
                IconButton("Play \(title)", systemImage: "play.fill") { EffectAudition.play(preview) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(summary).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isOn {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isOn ? Theme.canvas : Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(isOn ? Theme.text : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Every placed effect, dashed until kept, plus adding your own.
private struct EffectsSettings: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Energy decides how many effects are suggested: none for Calm, a few for Lively, more for Viral.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.sm) {
                Menu {
                    ForEach(SoundLibrary.effects) { sound in
                        Button("\(sound.title) · \(sound.summary)") { model.addEffect(sound.id) }
                    }
                } label: {
                    Text("Add at the playhead").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
                if model.proposedEffectCount > 0 {
                    Button("Keep all \(model.proposedEffectCount)") { model.acceptAllEffects() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .fixedSize()
                }
            }
            ForEach(model.sound.effects.filter { $0.state != .rejected }.sorted { $0.at < $1.at }) { effect in
                row(effect)
            }
        }
    }

    private func row(_ effect: PlacedEffect) -> some View {
        let kept = effect.state == .accepted
        let title = SoundLibrary.sound(id: effect.soundID)?.title ?? effect.soundID
        let at = model.edits.outputTime(forSource: effect.at).map { Timecode.short(from: $0) } ?? "cut"
        return HStack(spacing: Theme.Space.sm) {
            IconButton("Play \(title)", systemImage: "play.fill") { EffectAudition.play(effect.soundID) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(kept ? "at \(at)" : "suggested at \(at)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
            if kept {
                IconButton("Remove \(title)", systemImage: "xmark") { model.removeEffect(effect.id) }
            } else {
                Button("Keep") { model.setEffectState(.accepted, for: effect.id) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                IconButton("Don't use \(title)", systemImage: "xmark") {
                    model.setEffectState(.rejected, for: effect.id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1, dash: kept ? [] : Theme.Stroke.dash)))
        .contentShape(Rectangle())
        .onTapGesture { model.seek(toSource: effect.at) }
    }
}
