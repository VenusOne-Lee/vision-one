import AVFoundation
import Foundation
import VisionOneKit

/// Plays "Hear it first" and moves a highlight word by word: ElevenLabs
/// audio with its own word timings, or a free Apple voice on the Mac.
@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Source: Equatable { case elevenLabs, apple }

    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    /// Index into `words` of the word being said now.
    @Published private(set) var currentWord: Int?
    @Published private(set) var words: [String] = []
    @Published private(set) var source: Source = .apple
    @Published private(set) var duration: Double = 0
    @Published var problem: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var timings: [HeardWord] = []
    private let synthesizer = AVSpeechSynthesizer()
    /// What ElevenLabs read last, so playing the same script again costs nothing.
    private var cache: (text: String, voice: String, audio: SpokenAudio)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads the script: ElevenLabs when it's set up, otherwise an Apple voice.
    func play(_ script: Script, tone: DeliveryTone, flags: [ScriptFlag], coach: CoachServices) {
        stop()
        problem = nil
        if coach.elevenLabsReady {
            playElevenLabs(script, tone: tone, flags: flags, coach: coach)
        } else {
            playApple(script, tone: tone)
        }
    }

    private func playElevenLabs(_ script: Script, tone: DeliveryTone, flags: [ScriptFlag], coach: CoachServices) {
        source = .elevenLabs
        let text = DeliveryMarkup.reading(script, tone: tone, flags: flags)
        let voice = coach.voiceID
        if let cache, cache.text == text, cache.voice == voice {
            start(cache.audio)
            return
        }
        guard !voice.isEmpty else {
            problem = "Pick an ElevenLabs voice first."
            return
        }
        isLoading = true
        let client = coach.client()
        Task {
            defer { isLoading = false }
            do {
                let spoken = try await client.speak(text, voiceID: voice, summary: "Read your script aloud (Hear it first)")
                cache = (text, voice, spoken)
                start(spoken)
            } catch {
                problem = CoachServices.message(for: error)
            }
        }
    }

    private func start(_ spoken: SpokenAudio) {
        do {
            let player = try AVAudioPlayer(data: spoken.audio)
            self.player = player
            timings = spoken.words
            words = spoken.words.map(\.text)
            duration = player.duration
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            problem = "Couldn't play the reading: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard let player else { return }
        if !player.isPlaying {
            stop()
            return
        }
        let t = player.currentTime
        currentWord = timings.lastIndex { $0.start <= t }
    }

    private func playApple(_ script: Script, tone: DeliveryTone) {
        source = .apple
        let text = DeliveryMarkup.plain(script)
        words = text.split(separator: " ").map(String.init)
        wordStarts = Self.wordStarts(in: text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = tone.appleRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-ZA") ?? AVSpeechSynthesisVoice(language: "en-GB")
        isPlaying = true
        synthesizer.speak(utterance)
    }

    /// UTF-16 offsets where each word starts, to match the synthesiser's ranges.
    private var wordStarts: [Int] = []

    private static func wordStarts(in text: String) -> [Int] {
        var starts: [Int] = []
        var previousSpace = true
        for (offset, unit) in text.utf16.enumerated() {
            let space = unit == 32 || unit == 10
            if !space && previousSpace { starts.append(offset) }
            previousSpace = space
        }
        return starts
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isPlaying = false
        currentWord = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let location = characterRange.location
        Task { @MainActor in
            self.currentWord = self.wordStarts.lastIndex { $0 <= location }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentWord = nil
        }
    }
}
