import AVFoundation
import Speech
import VisionOneKit

/// Listens to the mic buffers already going into the recording and moves
/// the teleprompter along with the voice. Apple's on-device recogniser
/// only: nothing leaves the Mac. Without speech permission, or where the
/// Mac can't recognise on device, the prompter scrolls steadily instead.
final class ScriptVoice: @unchecked Sendable {
    static let shared = ScriptVoice()

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Words of the current recognition already passed on.
    private var passed = 0
    private var onWord: (@Sendable (String) -> Void)?

    private init() {}

    /// Asks for speech permission the first time. True when following
    /// the voice on this Mac is possible.
    static func prepare() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard status == .authorized else { return false }
        guard let recognizer = makeRecognizer() else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Starts listening; each newly recognised word goes to `onWord`.
    func start(onWord: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.onWord = onWord
        recognizer = Self.makeRecognizer()
        lock.unlock()
        begin()
    }

    func stop() {
        lock.lock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onWord = nil
        recognizer = nil
        lock.unlock()
    }

    /// From the capture queue: a mic buffer that's also being recorded.
    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.appendAudioSampleBuffer(buffer)
    }

    private func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard let recognizer, onWord != nil else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        passed = 0
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result, error: error)
        }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        var newWords: [String] = []
        if let result {
            let segments = result.bestTranscription.segments
            if segments.count > passed {
                newWords = segments[passed...].map(\.substring)
                passed = segments.count
            }
        }
        let onWord = self.onWord
        let ended = error != nil || result?.isFinal == true
        lock.unlock()
        newWords.forEach { onWord?($0) }
        // Recognition ends after a long pause or a time limit; carry on
        // with a fresh request while the take is still going. After an
        // error, wait a moment so a recogniser that keeps failing can't spin.
        guard ended else { return }
        if error != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.begin() }
        } else {
            begin()
        }
    }
}
