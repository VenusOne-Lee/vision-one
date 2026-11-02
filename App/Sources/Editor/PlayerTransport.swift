import AVFoundation
import SwiftUI
import VisionOneKit

/// The video with its own transport bar attached underneath: play,
/// "0:24 / 2:14", scrubber, volume, speed, fit and full screen. Used by
/// the review column, the editor and Sound.
struct VideoStage: View {
    @ObservedObject var model: EditorModel
    var onExpand: (() -> Void)?
    var showsOverlays = true

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: model.player)
                .overlay { if showsOverlays { CaptionLayer(model: model) } }
                .overlay { if showsOverlays { EffectsLayer(model: model, effects: model.effects) } }
                .background(Color.black)
                .onTapGesture { model.togglePlay() }
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            PlayerTransport(model: model, onExpand: onExpand)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var aspect: CGFloat {
        let size = model.videoSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
}

/// Video chrome: light on a near-black bar in every look, like the video.
struct PlayerTransport: View {
    @ObservedObject var model: EditorModel
    var onExpand: (() -> Void)?
    @State private var muted = false
    @State private var speed: Float = 1
    @State private var scrubbing: Double?

    private let ink = Color.white

    var body: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Text("\(Timecode.short(from: current))  /  \(Timecode.short(from: total))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            Scrubber(value: scrubbing ?? current, total: total, tint: ink) { value, done in
                scrubbing = done ? nil : value
                model.seek(toSource: model.edits.sourceTime(forOutput: value))
            }
            .frame(minWidth: 60)
            Button {
                muted.toggle()
                model.player.isMuted = muted
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute" : "Mute")
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                    Button { setSpeed(rate) } label: { MenuCheck(label(rate), isOn: rate == speed) }
                }
            } label: {
                Text(label(speed)).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
            .accessibilityLabel("Speed \(label(speed))")
            if FileManager.default.fileExists(atPath: model.take.cameraURL.path) {
                TakeBackgroundMenu(take: model.take, iconOnly: true)
            }
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in the editor")
                .accessibilityLabel("Open in the editor")
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
        .background(Color.black.opacity(0.92))
    }

    private var current: Double { model.edits.outputTime(forSource: model.sourceTime) ?? 0 }
    private var total: Double { model.edits.outputDuration }

    private func label(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }

    private func setSpeed(_ rate: Float) {
        speed = rate
        model.player.defaultRate = rate
        if model.isPlaying { model.player.rate = rate }
    }
}

/// A thin track, filled to the playhead, with a round knob. Drag or click.
struct Scrubber: View {
    let value: Double
    let total: Double
    var tint: Color = Theme.text
    let seek: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fraction = total > 0 ? min(1, max(0, value / total)) : 0
            let x = proxy.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.28)).frame(height: 4)
                Capsule().fill(tint).frame(width: x, height: 4)
                Circle().fill(tint).frame(width: 14, height: 14).offset(x: x - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in seek(position(drag.location.x, width: proxy.size.width), false) }
                .onEnded { drag in seek(position(drag.location.x, width: proxy.size.width), true) })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Timecode.short(from: value))
        .accessibilityAdjustableAction { direction in
            let step = max(1, total / 20)
            seek(min(total, max(0, value + (direction == .increment ? step : -step))), true)
        }
    }

    private func position(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * total
    }
}

/// The magnifier beside Transcript | Changes: opens a field that marks
/// every match in the transcript.
struct TranscriptSearchButton: View {
    @Binding var query: String
    @Binding var isOpen: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isOpen {
                TextField("Search transcript", text: $query)
                    .textFieldStyle(.plain)
                    .font(.custom(BundledFont.sansRegular, size: 13))
                    .focused($focused)
                    .frame(minWidth: 80, maxWidth: 180)
                    .onExitCommand { query = ""; isOpen = false }
                    .onAppear { focused = true }
            }
            IconButton(isOpen ? "Close search" : "Search transcript",
                       systemImage: isOpen ? "xmark" : "magnifyingglass", shortcut: "⌘F") {
                if isOpen { query = "" }
                isOpen.toggle()
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .padding(.leading, isOpen ? 10 : 0)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(isOpen ? Theme.canvas : .clear))
    }
}

/// The same black bar for a plain movie (a rendered clip): play, time,
/// scrubber, mute and speed.
struct MoviePlayerBar: View {
    let player: AVPlayer
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var playing = false
    @State private var muted = false
    @State private var speed: Float = 1
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 14) {
            Button { playing ? player.pause() : player.play() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play")
            Text("\(PlayheadBadge.stamp(time))  /  \(PlayheadBadge.stamp(duration))")
                .font(.system(size: 13, weight: .medium).monospacedDigit()).fixedSize()
            Scrubber(value: time, total: duration, tint: .white) { value, _ in
                time = value
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            .frame(minWidth: 60)
            Button { muted.toggle(); player.isMuted = muted } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                    Button { speed = rate; player.defaultRate = rate; if playing { player.rate = rate } } label: {
                        MenuCheck(rate == 1 ? "1×" : String(format: "%g×", rate), isOn: rate == speed)
                    }
                }
            } label: {
                Text(speed == 1 ? "1×" : String(format: "%g×", speed)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Speed")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 46)
        .background(Color.black.opacity(0.92))
        .task {
            if let item = player.currentItem, let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { now in
                MainActor.assumeIsolated {
                    time = now.seconds.isFinite ? now.seconds : 0
                    playing = player.rate != 0
                }
            }
        }
        .onDisappear { if let observer { player.removeTimeObserver(observer) }; observer = nil }
    }
}
