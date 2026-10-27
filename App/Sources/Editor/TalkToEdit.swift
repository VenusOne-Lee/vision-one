import AVFoundation
import SwiftUI
import VisionOneKit

/// One thing you said or drew while watching, and what it did.
struct SteerEntry: Identifiable, Equatable {
    let id = UUID()
    /// Seconds of the edited video when you spoke or drew.
    let at: Double
    let said: String
    let result: String
    /// A drawn zoom or blur, dashed until kept.
    var proposal: Proposal?

    enum Proposal: Equatable {
        case zoom(UUID)
        case blur(UUID)
    }
}

/// Hold Space while watching and say what you want. The video keeps
/// playing, quietly so the mic doesn't hear it; what you said is read
/// on this Mac by the transcript model and done at the moment you
/// started speaking.
@MainActor
final class TalkController: ObservableObject {
    enum State: Equatable {
        case idle
        case listening(at: Double)
        case hearing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var startedAt = 0.0
    private var volumeBefore: Float = 1

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    func start(on model: EditorModel) {
        guard !isListening, state != .hearing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            state = .failed("Allow the microphone, then hold Space again.")
            return
        default:
            state = .failed("Vision One can't use the microphone. Turn it on in System Settings → Privacy & Security → Microphone.")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .failed("No microphone found.")
            return
        }
        buffer.reset(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(into: buffer))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        startedAt = model.sourceTime
        volumeBefore = model.player.volume
        model.player.volume = min(volumeBefore, 0.2)
        state = .listening(at: model.edits.outputTime(forSource: startedAt) ?? 0)
    }

    /// Space let go: stop listening and do what was said.
    func finish(on model: EditorModel) {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        model.player.volume = volumeBefore
        let (samples, rate) = buffer.take()
        let at = startedAt
        guard Double(samples.count) / rate > 0.3 else {
            state = .idle
            return
        }
        state = .hearing
        Task { [weak self, weak model] in
            do {
                let said = try await Transcriber.shared.transcribeCommand(Self.resample(samples, from: rate, to: 16_000))
                guard let self, let model else { return }
                guard !said.isEmpty else {
                    self.state = .failed("Didn't catch that. Hold Space and speak a little closer.")
                    return
                }
                model.steer(SpokenEdit.parse(said), said: said, at: at)
                self.state = .idle
            } catch {
                self?.state = .failed("Couldn't hear that: \(error.localizedDescription)")
            }
        }
    }

    /// Built outside the main actor: the block runs on the audio thread.
    nonisolated static func tap(into sink: SampleBuffer) -> AVAudioNodeTapBlock {
        { pcm, _ in
            guard let channel = pcm.floatChannelData?[0] else { return }
            sink.append(Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength))))
        }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    /// Linear resampling, plenty for speech going to a 16 kHz model.
    nonisolated static func resample(_ samples: [Float], from rate: Double, to target: Double) -> [Float] {
        guard rate > 0, abs(rate - target) > 1, !samples.isEmpty else { return samples }
        let count = Int(Double(samples.count) * target / rate)
        let step = rate / target
        return (0..<count).map { i in
            let position = Double(i) * step
            let index = Int(position)
            let next = min(index + 1, samples.count - 1)
            let fraction = Float(position - Double(index))
            return samples[index] * (1 - fraction) + samples[next] * fraction
        }
    }
}

/// Mic samples from the audio thread, read once listening stops.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 48_000.0

    func reset(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        samples = []
        rate = sampleRate
    }

    func append(_ more: [Float]) {
        lock.lock(); defer { lock.unlock() }
        // Thirty seconds is plenty for one ask.
        guard Double(samples.count) < rate * 30 else { return }
        samples += more
    }

    func take() -> ([Float], Double) {
        lock.lock(); defer { lock.unlock() }
        let result = (samples, rate)
        samples = []
        return result
    }
}

// MARK: Doing what was said or drawn

extension EditorModel {
    /// Does a spoken edit at `t` (seconds of the take, where the playhead
    /// was when you started speaking) and logs it.
    func steer(_ edit: SpokenEdit, said: String, at t: Double) {
        let output = edits.outputTime(forSource: t) ?? 0
        func log(_ result: String) {
            steerLog.append(SteerEntry(at: output, said: said, result: result))
        }
        switch edit {
        case .cutSentence:
            guard let sentence = SpokenEdit.sentence(at: t, in: transcript?.sentences(keeping: edits) ?? []) else {
                return log("No sentence there to cut")
            }
            var next = edits
            next.add(Cut(span: sentence.span, reason: Cut.Reason.word, state: .accepted))
            apply(next, actionName: "Cut Sentence")
            log("cut \(Timecode.short(from: sentence.duration))")
        case .cutWord:
            guard let span = wordSpans.last(where: { $0.start <= t + 0.2 && t - $0.end < 1.5 }) else {
                return log("No word there to cut")
            }
            var next = edits
            next.add(Cut(span: span, reason: Cut.Reason.word, state: .accepted))
            apply(next, actionName: "Cut Word")
            log("cut a word")
        case .zoomIn:
            guard let span = EditorTool.drawnSpan(at: t, sourceDuration: edits.sourceDuration) else { return }
            let (x, y) = effects.cursorPosition(at: t) ?? (0.5, 0.5)
            effects.addZoom(span: span, viewport: FrameRect.centered(x: x, y: y, width: 0.5, height: 0.5),
                            actionName: "Zoom In")
            log(effects.cursorPosition(at: t) == nil ? "zoom 2× on the middle" : "zoom 2× on the cursor")
        case .zoomOut:
            guard let zoom = effects.zooms.zoom(at: t) else { return log("No zoom there") }
            effects.setZoomState(.rejected, for: zoom.id)
            log("zoom turned off")
        case .blur:
            requestedTool = .draw
            log("draw over what to hide")
        case let .music(louder):
            guard let bed = sound.music else { return log("No music to change") }
            var next = sound
            next.music?.levelDB = min(-6, max(-30, bed.levelDB + (louder ? 4 : -4)))
            applySound(next, actionName: louder ? "Music Louder" : "Music Quieter")
            log("music \(Int(next.music?.levelDB ?? 0)) dB")
        case .undo:
            let name = undoManager.undoActionName
            undoManager.undo()
            log(name.isEmpty ? "undone" : "undid \(name.lowercased())")
        case let .ask(text):
            pendingAsk = "At \(Timecode.short(from: output)): \(text)"
            log("sent to Ask")
        }
    }

    /// Does a pen stroke drawn at `t`: a circle proposes a zoom on it, a
    /// scribble a blur over it, a line a zoom where it points. `video`
    /// is the video's box in the stroke's coordinates.
    func steer(_ shape: StrokeShape, video: CGRect, at t: Double) {
        let output = edits.outputTime(forSource: t) ?? 0
        guard video.width > 0, video.height > 0,
              let span = EditorTool.drawnSpan(at: t, sourceDuration: edits.sourceDuration) else { return }
        func frame(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, pad: Double) -> FrameRect {
            let w = (maxX - minX) / video.width, h = (maxY - minY) / video.height
            return FrameRect(x: (minX - video.minX) / video.width - w * pad,
                             y: (minY - video.minY) / video.height - h * pad,
                             width: w * (1 + 2 * pad), height: h * (1 + 2 * pad)).clamped
        }
        switch shape {
        case let .circle(minX, minY, maxX, maxY):
            let rect = frame(minX, minY, maxX, maxY, pad: 0.15)
            let id = effects.addZoom(span: span, viewport: rect, state: .proposed, actionName: "Zoom from a Circle")
            let scale = effects.zooms.zooms.first { $0.id == id }?.scale ?? 2
            steerLog.append(SteerEntry(at: output, said: "✎ circle",
                                       result: "zoom \(String(format: "%.1f", scale))×", proposal: .zoom(id)))
        case let .scribble(minX, minY, maxX, maxY):
            let id = effects.addBlur(span: span, rect: frame(minX, minY, maxX, maxY, pad: 0.05),
                                     state: .proposed, actionName: "Blur from a Scribble")
            steerLog.append(SteerEntry(at: output, said: "✎ scribble", result: "blur", proposal: .blur(id)))
        case let .line(_, to):
            let x = (to.x - video.minX) / video.width, y = (to.y - video.minY) / video.height
            let id = effects.addZoom(span: span, viewport: FrameRect.centered(x: x, y: y, width: 0.62, height: 0.62),
                                     state: .proposed, actionName: "Zoom from a Line")
            steerLog.append(SteerEntry(at: output, said: "✎ line", result: "zoom toward where it points",
                                       proposal: .zoom(id)))
        }
    }

    /// Keep a drawn proposal: its dashed zoom or blur goes solid.
    func keep(_ entry: SteerEntry) {
        switch entry.proposal {
        case let .zoom(id): effects.setZoomState(.accepted, for: id)
        case let .blur(id): effects.setBlurState(.accepted, for: id)
        case nil: return
        }
        if let i = steerLog.firstIndex(of: entry) { steerLog[i].proposal = nil }
    }
}

// MARK: On the video

/// Over the video: "Listening at 0:31…" while Space is held, then what
/// it did, with Keep for a drawn proposal and Undo for anything.
struct SteerOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var talk: TalkController
    @State private var shown: SteerEntry.ID?

    var body: some View {
        VStack {
            switch talk.state {
            case let .listening(at):
                pill {
                    Circle().fill(Theme.text).frame(width: 8, height: 8)
                        .phaseAnimator([1.0, 0.3]) { dot, phase in dot.opacity(phase) }
                    Text("Listening at \(Timecode.short(from: at))… let go of Space when you're done")
                }
            case .hearing:
                pill {
                    ProgressView().controlSize(.mini)
                    Text("Working out what you said…")
                }
            case let .failed(message):
                pill {
                    Text(message)
                    Button("OK") { talk.dismissError() }.buttonStyle(.plain).fontWeight(.semibold)
                }
            case .idle:
                EmptyView()
            }
            Spacer()
            if let entry = model.steerLog.last, entry.id == shown {
                result(entry)
            }
        }
        .padding(Theme.Space.md)
        .onChange(of: model.steerLog.last?.id) { _, id in
            shown = id
            guard let id else { return }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if shown == id { shown = nil }
            }
        }
    }

    private func result(_ entry: SteerEntry) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("\(entry.said) → \(entry.result)")
                .lineLimit(1)
            if entry.proposal != nil {
                Button("Keep") { model.keep(entry); shown = nil }
                    .buttonStyle(.plain).fontWeight(.semibold)
            }
            Button("Undo") { model.undoManager.undo(); shown = nil }
                .buttonStyle(.plain).fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.text,
                                        style: StrokeStyle(lineWidth: 1, dash: entry.proposal == nil ? [] : Theme.Stroke.dash)))
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.sm) { content() }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Draw tool: draw on the video with the pen. The stroke shows as
/// you draw and becomes a dashed zoom or blur when you lift.
struct DrawLayer: View {
    @ObservedObject var model: EditorModel
    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            let video = EffectsLayer.videoFrame(for: model.videoSize, in: geometry.size)
            ZStack {
                Color.clear.contentShape(Rectangle())
                Path { path in path.addLines(points) }
                    .stroke(Theme.text.opacity(0.45), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                Path { path in path.addLines(points) }
                    .stroke(Theme.paper, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in points.append(value.location) }
                    .onEnded { _ in
                        let stroke = points.map { StrokePoint(x: $0.x, y: $0.y) }
                        points = []
                        if let shape = StrokeShape.classify(stroke) {
                            model.steer(shape, video: video, at: model.sourceTime)
                        }
                    }
            )
            .help("Circle something to zoom on it, scribble over it to blur it, or draw a line to point at it")
        }
    }
}
