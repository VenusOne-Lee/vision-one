import AVFoundation
import SwiftUI
import VisionOneKit

/// Records one sentence again for "Redo this sentence". The new line is
/// trimmed, matched to the original's level and fitted to its slot, then
/// plays in place, dashed until you keep it.
@MainActor
final class LineRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case saving
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed = 0.0

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var timer: Task<Void, Never>?

    func start(for sentence: SpokenSentence, on model: EditorModel) {
        guard state != .recording, state != .saving else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            state = .failed("Allow the microphone, then press Record again.")
            return
        }
        model.pause()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            state = .failed("No microphone found.")
            return
        }
        buffer.reset(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: TalkController.tap(into: buffer))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        state = .recording
        elapsed = 0
        // Stops by itself well after the line should be done.
        let limit = max(6, sentence.duration * 1.6 + 2)
        timer = Task { [weak self, weak model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.state == .recording else { return }
                self.elapsed += 0.1
                if self.elapsed >= limit, let model { self.stop(for: sentence, on: model) }
            }
        }
    }

    func stop(for sentence: SpokenSentence, on model: EditorModel) {
        guard state == .recording else { return }
        timer?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .saving
        let (samples, rate) = buffer.take()
        let recording = LoudnessEnvelope.measure(samples: samples, sampleRate: rate)
        let id = UUID()
        let file = "redos/\(id.uuidString).caf"
        switch LineRedo.plan(slot: sentence.span, text: sentence.text, file: file,
                             recording: recording, original: model.levels) {
        case let .failure(problem):
            state = .failed(problem.message)
        case var .success(redo):
            do {
                // Gain goes into the file: a mix can't turn a track up.
                let gain = Float(pow(10, redo.gainDB / 20))
                try Self.write(samples.map { max(-1, min(1, $0 * gain)) }, rate: rate,
                               to: model.take.folder.appendingPathComponent(file))
                redo.file = file
                var next = model.redos
                next.add(redo)
                model.applyRedos(next, actionName: "Redo Sentence")
                state = .idle
                // Hear it in place straight away.
                model.seek(toSource: max(0, sentence.start - 1))
                model.play()
            } catch {
                state = .failed("Couldn't save the new line: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        timer?.cancel()
        if state == .recording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        state = .idle
    }

    private static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            pcm.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
    }
}

/// The card under the aside's tabs while a sentence is picked to redo:
/// record it, hear it in place, keep it or go back to the original.
struct RedoCard: View {
    @ObservedObject var model: EditorModel
    let sentence: SpokenSentence
    @StateObject private var recorder = LineRecorder()

    private var redo: LineRedo? {
        model.redos.redos.last { $0.slot.overlaps(sentence.span) && $0.state != .rejected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Redo this sentence").font(.system(size: 13, weight: .semibold))
                Spacer()
                IconButton("Close", systemImage: "xmark") {
                    recorder.cancel()
                    model.redoTarget = nil
                }
            }
            Text("“\(sentence.text)”")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            switch recorder.state {
            case .recording:
                HStack(spacing: Theme.Space.sm) {
                    // Tally orange: the mic is recording, live.
                    Circle().fill(Theme.tally).frame(width: 8, height: 8)
                    Text("Recording \(String(format: "%.1f", recorder.elapsed)) s · say the line, then Stop")
                        .font(.system(size: 12).monospacedDigit())
                    Spacer()
                    Button("Stop") { recorder.stop(for: sentence, on: model) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .keyboardShortcut(.return, modifiers: [])
                }
            case .saving:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Matching your level and fitting it in…").font(.system(size: 12))
                }
            case .idle, .failed:
                if case let .failed(message) = recorder.state {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let redo {
                    decided(redo)
                } else {
                    Text("Record just this line. Vision One matches your voice level and fits it in place. The original stays under Undo.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.sm) {
                        Button("Record the line") { recorder.start(for: sentence, on: model) }
                            .buttonStyle(PillButtonStyle(kind: .primary))
                        Text("≈ \(Timecode.short(from: sentence.duration))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1, dash: redo?.state == .accepted ? [] : Theme.Stroke.dash)))
        .padding(10)
        .onDisappear { recorder.cancel() }
    }

    @ViewBuilder
    private func decided(_ redo: LineRedo) -> some View {
        Text(redo.state == .accepted
             ? "Using the new line."
             : "New line in place, \(Self.describe(redo)). Dashed until you keep it.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Theme.Space.sm) {
            Button("Hear it") {
                model.seek(toSource: max(0, sentence.start - 1))
                model.play()
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            if redo.state != .accepted {
                Button("Keep") { set(.accepted, redo) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            Button(redo.state == .accepted ? "Use the original" : "Don't use") { set(.rejected, redo) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button("Record again") { recorder.start(for: sentence, on: model) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func set(_ state: ProposalState, _ redo: LineRedo) {
        var next = model.redos
        next.setState(state, for: redo.id)
        model.applyRedos(next, actionName: state == .accepted ? "Keep Redone Sentence" : "Use Original Sentence")
    }

    static func describe(_ redo: LineRedo) -> String {
        var parts: [String] = []
        if abs(redo.gainDB) >= 1 {
            parts.append(redo.gainDB > 0 ? "turned up \(Int(redo.gainDB.rounded())) dB" : "turned down \(Int(-redo.gainDB.rounded())) dB")
        } else {
            parts.append("level matched")
        }
        let percent = Int(((redo.rate - 1) * 100).rounded())
        if abs(percent) >= 3 {
            parts.append(percent > 0 ? "\(percent)% quicker to fit" : "\(-percent)% slower to fit")
        }
        return parts.joined(separator: ", ")
    }
}
