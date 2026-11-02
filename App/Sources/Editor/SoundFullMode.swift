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

    @AppStorage("sound.asideWidth") private var asideWidth = 420.0
    @AppStorage("sound.aside") private var asideRaw = SoundAside.mix.rawValue
    @State private var compactPane = "Mix"
    @State private var tracksOverride: Bool?

    init(model: EditorModel, onBack: @escaping () -> Void, @ViewBuilder rail: @escaping () -> Rail) {
        self.model = model
        self.onBack = onBack
        self.rail = rail
    }

    private var aside: SoundAside { SoundAside(rawValue: asideRaw) ?? .mix }

    var body: some View {
        GeometryReader { outer in
        let tracksVisible = tracksOverride ?? (outer.size.height >= 540)
        HStack(spacing: 0) {
            rail()
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    if geometry.size.width < 760 {
                        VStack(spacing: 0) {
                            HStack {
                                SegmentedTabs(selection: $compactPane, options: ["Preview", "Mix"]) { $0 }
                                Spacer()
                                Button(tracksVisible ? "Hide tracks" : "Show tracks") { tracksOverride = !tracksVisible }
                                    .buttonStyle(.secondary)
                            }.padding(8).background(Theme.paper)
                            if compactPane == "Preview" { main }
                            else { asidePanel }
                        }
                    } else {
                        HStack(spacing: 0) {
                            main.frame(minWidth: 380, maxWidth: .infinity).layoutPriority(1)
                            SideResizeHandle(width: $asideWidth, range: 260...min(560, geometry.size.width * 0.45))
                            asidePanel.frame(width: min(asideWidth, max(260, geometry.size.width - 430)))
                        }
                    }
                }
                if model.phase == .ready {
                    Divider().overlay(Theme.line)
                    if tracksVisible {
                        ScrollView { MixLanes(model: model).padding(12) }
                            .frame(height: min(300, outer.size.height * 0.32))
                    }
                    HStack(spacing: Theme.Space.md) {
                        AskBar(model: model, placeholder: "Make the music softer when I'm talking…")
                        Button { model.acceptAllEffects() } label: {
                            Text("Apply mix").padding(.horizontal, 28)
                        }
                        .buttonStyle(WideButtonStyle(kind: model.proposedEffectCount > 0 ? .primary : .secondary, height: 52))
                        .fixedSize()
                        .disabled(model.proposedEffectCount == 0)
                        .help(model.proposedEffectCount > 0 ? "Keep the \(model.proposedEffectCount) suggested sound effects"
                              : "Your mix changes are already saved")
                    }
                    .padding(12)
                }
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
                VStack(spacing: 0) {
                    PlayerSurface(player: model.player)
                        .overlay { CaptionLayer(model: model) }
                        .background(Color.black)
                        .onTapGesture { model.togglePlay() }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 100, maxHeight: .infinity)
                    PlayerTransport(model: model, onExpand: { NSApp.keyWindow?.toggleFullScreen(nil) })
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .padding(12)
                if !model.laneMix.isDefault {
                    Button("Hear everything") { model.laneMix = LaneMix() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .fixedSize()
                        .help("Turn off every mute and solo")
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: Aside

    private var asidePanel: some View {
        ScrollView {
            VoiceClearCard(model: model)
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }
}

/// "Keep your voice clear": energy, music, its volume, ducking and sound
/// effects in one card. Levels, loudness and the full music list are one
/// click away under More.
private struct VoiceClearCard: View {
    @ObservedObject var model: EditorModel
    @State private var sliderStart: SoundPlan?
    @State private var showEffects = false
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep your voice clear").font(.custom(BundledFont.sansSemiBold, size: 17))
                Text("Balance your audio so your voice is easy to hear.")
                    .textStyle(.body).foregroundStyle(Theme.textMuted)
                LoudnessMeter(lufs: model.voiceLoudness, status: model.audioLevelsState.message)
                    .padding(.top, 4)
            }
            row("Voice energy", icon: "dial.medium") { EmptyView() }
            SegmentBar(selection: Binding(get: { model.sound.energy }, set: { model.setEnergy($0) }),
                       options: Energy.allCases) { $0.title }
                .padding(.leading, 36)
            row("Music", icon: "music.note") { EmptyView() }
            musicMenu.padding(.leading, 36)
            row("Music volume", icon: "speaker.wave.2") {
                Slider(value: Binding(get: { percent(model.sound.music?.levelDB ?? MusicBed.defaultLevelDB) },
                                      set: { value in model.previewSound { $0.music?.levelDB = -30 + value / 100 * 24 } }),
                       in: 0...100, onEditingChanged: editing("Music Level"))
                    .tint(Theme.text)
                    .frame(minWidth: 80, maxWidth: 150)
                    .accessibilityLabel("Music volume")
                Text("\(Int(percent(model.sound.music?.levelDB ?? MusicBed.defaultLevelDB)))%")
                    .font(.system(size: 13).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .disabled(model.sound.music == nil)
            row("Lower music while speaking", icon: "waveform.badge.minus") {
                Toggle("", isOn: Binding(get: { (model.sound.music?.duckDB ?? 0) > 0 }, set: { on in
                    let start = model.sound
                    model.previewSound { $0.music?.duckDB = on ? MusicBed.defaultDuckDB : 0 }
                    model.commitSound(from: start, actionName: "Duck Music")
                }))
                .labelsHidden().toggleStyle(.ink)
                .accessibilityLabel("Lower music while speaking")
            }
            .disabled(model.sound.music == nil)
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            Button { showEffects.toggle() } label: {
                row("Sound effects", icon: "sparkle") {
                    if model.proposedEffectCount > 0 {
                        Text("\(model.proposedEffectCount) suggested").textStyle(.caption).foregroundStyle(Theme.textMuted)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showEffects ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showEffects { EffectsSettings(model: model) }
            Button { showMore.toggle() } label: {
                row("Levels and music library", icon: "slider.horizontal.3") {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showMore {
                MixSettings(model: model)
                MusicPicker(model: model)
            }
            if let problem = model.soundProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md + 4)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
    }

    private func percent(_ db: Double) -> Double { min(100, max(0, (db + 30) / 24 * 100)) }

    private func editing(_ action: String) -> (Bool) -> Void {
        { editing in
            if editing { sliderStart = model.sound } else {
                model.commitSound(from: sliderStart, actionName: action)
                sliderStart = nil
            }
        }
    }

    private func row<Trailing: View>(_ title: String, icon: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 24)
            Text(title).font(.custom(BundledFont.sansMedium, size: 14)).lineLimit(1).fixedSize()
            Spacer(minLength: Theme.Space.sm)
            trailing()
        }
        .foregroundStyle(Theme.text)
    }

    private var musicMenu: some View {
        Menu {
            Button { model.setMusic(nil) } label: { MenuCheck("No music", isOn: model.sound.music == nil) }
            Divider()
            ForEach(SoundLibrary.music) { sound in
                Button { model.setMusic(.library(sound)) } label: {
                    MenuCheck("\(sound.title) · \(sound.summary)", isOn: model.sound.music?.libraryID == sound.id)
                }
            }
            Divider()
            Button("Choose a file…") { model.chooseMusicFile() }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.canvas)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: model.sound.music == nil ? "music.note.slash" : "music.note")
                        .font(.system(size: 14)))
                Text(model.sound.music?.title ?? "No music").font(.custom(BundledFont.sansRegular, size: 14))
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 46)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Music: \(model.sound.music?.title ?? "none")")
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

    static let headerWidth: CGFloat = 190

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
                HStack(spacing: 10) {
                    Image(systemName: icon(lane)).font(.system(size: 15)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lane.title).font(.custom(BundledFont.sansMedium, size: 13))
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    let muted = model.laneMix.muted.contains(lane)
                    Button { model.laneMix.toggleMute(lane) } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(muted ? Theme.textMuted : Theme.text)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute \(lane.title.lowercased()) while you listen" : "Mute \(lane.title.lowercased()) while you listen")
                    .accessibilityLabel(muted ? "Unmute \(lane.title)" : "Mute \(lane.title)")
                }
                .padding(.horizontal, 10)
                .frame(width: Self.headerWidth, alignment: .leading)
                .contextMenu {
                    Button(model.laneMix.soloed.contains(lane) ? "Stop hearing only \(lane.title)" : "Hear only \(lane.title)") {
                        model.laneMix.toggleSolo(lane)
                    }
                }
                content()
                    .frame(maxWidth: .infinity)
                    .frame(height: height.wrappedValue)
                    .opacity(model.laneMix.isAudible(lane) ? 1 : 0.35)
                    .padding(.trailing, 8)
            }
            .frame(height: max(height.wrappedValue, 48))
            LaneResizeEdge(height: height)
        }
    }

    private func icon(_ lane: MixLane) -> String {
        switch lane {
        case .voice: return "mic"
        case .music: return "music.note"
        case .effects: return "sparkle"
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
                    Text(model.audioLevelsState.message)
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
    let status: String

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
                Text(status)
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
    @State private var sourceStart: RecordedMix?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionLabel("ENERGY")
            EnergyDial(energy: model.sound.energy) { model.setEnergy($0) }
            Text("Calm suggests no effects; Lively suggests a few; Viral suggests more. Your accepted effects stay in place.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
            Divider().overlay(Theme.line)
            HStack {
                Text("Voice clarity").textStyle(.bodyStrong)
                Spacer()
                Button("Open…") { VoiceToolsWindowController.shared.show(for: model.take) }
                    .buttonStyle(.secondary)
            }
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
                model.previewRecordedMix(mix)
            }), in: -60...6, step: 1, onEditingChanged: { editing in
                if editing { sourceStart = model.recordedMix }
                else { model.applyRecordedMix(model.recordedMix, from: sourceStart); sourceStart = nil }
            })
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
            Button(action: pick) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        Text(summary).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "Selected" : "Not selected")
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isOn ? Theme.canvas : Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(isOn ? Theme.text : Theme.line))
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
