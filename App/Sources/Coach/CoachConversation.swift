import AVFoundation
import Foundation
import VisionOneKit

/// "Talk it through": a spoken back-and-forth with the coach agent on
/// the user's ElevenLabs account. The mic streams only while this is
/// open, after the user approves it, with echo cancellation on so the
/// coach doesn't hear itself.
@MainActor
final class CoachConversation: ObservableObject {
    enum State: Equatable {
        case idle, connecting, listening, coachSpeaking, ended
        case failed(String)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let fromCoach: Bool
        let text: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [Line] = []

    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pendingAudio = 0

    var isOpen: Bool {
        switch state {
        case .connecting, .listening, .coachSpeaking: return true
        default: return false
        }
    }

    func start(script: Script, review: RehearsalReview) {
        guard !isOpen else { return }
        let coach = CoachServices.shared
        guard coach.elevenLabsReady else {
            state = .failed(coach.elevenLabsNote)
            return
        }
        state = .connecting
        lines = []
        let context = CoachContext(script: script, review: review)
        Task {
            do {
                let agent = try await coach.coachAgentID()
                let url = try await coach.client().conversationURL(agentID: agent, context: context)
                let socket = URLSession.shared.webSocketTask(with: url)
                self.socket = socket
                socket.resume()
                send(CoachWire.start(context))
                receive()
                try startAudio()
                state = .listening
            } catch {
                close()
                state = .failed(CoachServices.message(for: error))
            }
        }
    }

    /// Tells the coach which line the user wants to work on, without interrupting.
    func focus(on line: String) {
        send(CoachWire.context("The user wants to work on this line: \(line)"))
    }

    func stop() {
        close()
        state = .ended
    }

    private func close() {
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
    }

    // MARK: Socket

    private func send(_ text: String) {
        socket?.send(.string(text)) { _ in }
    }

    private func receive() {
        receiver = Task { [weak self] in
            while let socket = self?.socket, !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    let text: String
                    switch message {
                    case let .string(string): text = string
                    case let .data(data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                    if let event = CoachWire.parse(text) { self?.handle(event) }
                } catch {
                    if let self, self.isOpen {
                        self.close()
                        self.state = .ended
                    }
                    return
                }
            }
        }
    }

    private func handle(_ event: CoachWire.Event) {
        switch event {
        case let .started(_, format):
            let rate = CoachWire.sampleRate(of: format)
            if rate != playFormat.sampleRate, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                                          channels: 1, interleaved: false) {
                playFormat = format
                if engine.isRunning {
                    engine.disconnectNodeOutput(player)
                    engine.connect(player, to: engine.mainMixerNode, format: playFormat)
                    player.play()
                }
            }
        case let .audio(data, _):
            play(data)
        case let .agentSaid(text):
            if !text.isEmpty { lines.append(Line(fromCoach: true, text: text)) }
        case let .userSaid(text):
            if !text.isEmpty { lines.append(Line(fromCoach: false, text: text)) }
        case .interrupted:
            player.stop()
            player.play()
            pendingAudio = 0
            state = .listening
        case let .ping(eventID, delay):
            Task {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                send(CoachWire.pong(eventID))
            }
        case .other:
            break
        }
    }

    // MARK: Audio

    private func startAudio() throws {
        let input = engine.inputNode
        // Echo cancellation, so the coach's voice from the speakers isn't sent back.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "VisionOne", code: 1,
                                                         userInfo: [NSLocalizedDescriptionKey: "No microphone found."]) }
        guard let pcm = MicToPCM16(from: format) else {
            throw NSError(domain: "VisionOne", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the microphone."])
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let data = pcm.convert(buffer) else { return }
            let message = CoachWire.audio(data)
            Task { @MainActor in self?.send(message) }
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// Plays one chunk of the coach's voice (16-bit PCM, mono).
    private func play(_ pcm16: Data) {
        let count = pcm16.count / MemoryLayout<Int16>.size
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        state = .coachSpeaking
        pendingAudio += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingAudio = max(0, self.pendingAudio - 1)
                if self.pendingAudio == 0, self.state == .coachSpeaking { self.state = .listening }
            }
        }
    }
}

/// Mic audio as 16 kHz mono 16-bit PCM, little-endian, for the agent.
/// One converter for the whole talk, used on the audio thread.
final class MicToPCM16: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: CoachWire.inputSampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: format) else { return nil }
        self.format = format
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
