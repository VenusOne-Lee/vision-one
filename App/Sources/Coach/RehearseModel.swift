import AVFoundation
import Foundation
import Speech
import VisionOneKit

/// A practice run: the mic goes to on-device speech recognition for the
/// words and to a pitch and level analyser for energy. Nothing is saved
/// as a take and nothing leaves the Mac. The run's sound is kept in a
/// temporary file only so the coach's notes can play a moment back.
@MainActor
final class RehearseModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case running
        case notes
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var reading = MeterReading(pace: nil, ums: 0, energy: nil, pause: nil)
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var currentLine: Int?
    @Published private(set) var review: RehearsalReview?
    /// When set, the run only covers this line ("Run just that line").
    @Published private(set) var onlyLine: Int?

    let coach = CoachServices.shared
    private(set) var script = Script(text: "")
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var monitor = RehearsalMonitor()
    private var analyzer: VoiceAnalyzer?
    private var startedAt = Date()
    /// When each recognised word first showed up, for engines that give
    /// partial results without times.
    private var arrivals: [Double] = []
    private var timer: Timer?
    private var playback: AVAudioPlayer?
    private var playbackStop: Timer?
    private let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vision-one-rehearsal-\(UUID().uuidString).caf")

    var targets: RehearsalTargets { coach.targets }

    // MARK: Run

    func start(line: Int? = nil) {
        stopPlayback()
        let full = coach.script
        if let line, let scriptLine = full.lines.first(where: { $0.id == line }) {
            script = Script(text: scriptLine.text)
            onlyLine = line
        } else {
            script = full
            onlyLine = nil
        }
        guard !script.isEmpty else {
            phase = .failed("Write a script in the Script coach first.")
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.phase = .failed("Rehearse needs Speech Recognition. Turn it on for Vision One in System Settings → Privacy & Security → Speech Recognition.")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer = Self.onDeviceRecognizer() else {
            phase = .failed("This Mac can't recognise English speech on the device. Rehearse only listens on the Mac, so it can't run here.")
            return
        }
        monitor.reset()
        arrivals = []
        review = nil
        reading = MeterReading(pace: nil, ums: 0, energy: nil, pause: nil)
        elapsed = 0
        currentLine = script.lines.first?.id

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            phase = .failed("No microphone found. Plug one in or pick one in System Settings → Sound.")
            return
        }
        let file = try? AVAudioFile(forWriting: recordingURL, settings: format.settings)
        let analyzer = VoiceAnalyzer(sampleRate: format.sampleRate) { [weak self] frame in
            Task { @MainActor in self?.monitor.add(frame) }
        }
        self.analyzer = analyzer
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
            try? file?.write(from: buffer)
            analyzer.process(buffer)
        }
        startedAt = Date()
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let segments = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) }
            Task { @MainActor in self?.heard(segments) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            phase = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        phase = .running
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// The recogniser's words so far. Times come from the engine when it
    /// gives them, otherwise from when each word appeared.
    private func heard(_ segments: [(String, TimeInterval, TimeInterval)]) {
        guard phase == .running else { return }
        let now = Date().timeIntervalSince(startedAt)
        while arrivals.count < segments.count { arrivals.append(now) }
        let timed = segments.contains { $0.1 > 0 }
        var words: [HeardWord] = []
        for (i, segment) in segments.enumerated() {
            if timed {
                words.append(HeardWord(text: segment.0, start: segment.1, end: segment.1 + max(0.05, segment.2)))
            } else {
                let at = arrivals[i]
                words.append(HeardWord(text: segment.0, start: max(0, at - 0.35), end: at))
            }
        }
        monitor.setWords(words)
        var follower = ScriptFollower(script: script)
        for word in words { follower.hear(word.text) }
        currentLine = follower.currentLine
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(startedAt)
        reading = monitor.reading(at: elapsed)
    }

    /// Stops listening and writes the coach's three notes.
    func finish() {
        guard phase == .running else { return }
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        // Give the recogniser a moment to settle its last words.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            recognition?.cancel()
            recognition = nil
            request = nil
            review = CoachNotes.review(script: script, words: monitor.words, frames: monitor.frames, targets: targets)
            phase = .notes
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recognition?.cancel()
        recognition = nil
        request = nil
        stopPlayback()
        phase = .ready
    }

    // MARK: Play a moment back

    /// Plays about six seconds of the practice run from `time`.
    func play(from time: Double) {
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: recordingURL) else { return }
        player.currentTime = max(0, time)
        player.play()
        playback = player
        playbackStop = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopPlayback() }
        }
    }

    func stopPlayback() {
        playbackStop?.invalidate()
        playbackStop = nil
        playback?.stop()
        playback = nil
    }

    deinit {
        try? FileManager.default.removeItem(at: recordingURL)
    }

    // MARK: Recogniser

    /// South African English first, then any English the Mac can do on
    /// the device. Nil when none can: Rehearse never sends the mic out.
    static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        for id in ["en-ZA", "en-GB", "en-US"] {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
               recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }
}

/// Turns mic buffers into level and pitch frames, on the audio thread.
/// About 20 frames a second.
final class VoiceAnalyzer: @unchecked Sendable {
    private let tracker: PitchTracker
    private let hop: Int
    private var window: [Float] = []
    private var sinceLast = 0
    private var samples = 0
    private let sampleRate: Double
    private let emit: @Sendable (VoiceFrame) -> Void

    init(sampleRate: Double, emit: @escaping @Sendable (VoiceFrame) -> Void) {
        self.sampleRate = sampleRate
        tracker = PitchTracker(sampleRate: sampleRate)
        hop = Int(sampleRate / 20)
        self.emit = emit
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let length = tracker.frameLength
        for i in 0..<count {
            window.append(channel[i])
        }
        if window.count > length { window.removeFirst(window.count - length) }
        samples += count
        sinceLast += count
        guard sinceLast >= hop, window.count >= length else { return }
        sinceLast = 0
        var energy: Float = 0
        for s in window { energy += s * s }
        let rms = (energy / Float(window.count)).squareRoot()
        let level = rms > 0 ? max(LoudnessEnvelope.floorDB, 20 * log10(rms)) : LoudnessEnvelope.floorDB
        emit(VoiceFrame(time: Double(samples) / sampleRate, levelDB: level, pitchHz: tracker.pitch(of: window)))
    }
}
