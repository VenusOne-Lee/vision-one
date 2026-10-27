import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AITask {
    /// A take spoken in a language Parakeet doesn't know, sent to Scribe.
    public static let transcribeCloud = AITask("transcribe.cloud")
    /// The edited voice sent to ElevenLabs Dubbing.
    public static let dub = AITask("languages.dub")
}

/// Scribe and Dubbing, on the coach's ElevenLabs client. Both upload the
/// voice only (never the screen) and pass the gate as `.audio`.
extension ElevenLabsClient {
    /// Scribe v2, the speech to text model with word timings.
    public static let scribeModel = "scribe_v2"

    // MARK: Scribe

    /// Words from Scribe, in seconds from the start of the audio.
    public static func pieces(fromScribe data: Data) throws -> (language: String?, pieces: [RecognizedPiece]) {
        struct Word: Decodable {
            var text: String
            var start: Double?
            var end: Double?
            var type: String?
            var logprob: Double?
        }
        struct Reply: Decodable {
            var language_code: String?
            var words: [Word]?
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) } catch {
            throw AIError.badResponse(.elevenLabs, "Scribe sent something unexpected.")
        }
        let pieces = (reply.words ?? []).compactMap { word -> RecognizedPiece? in
            // Spacing and (laughs)-style events aren't words.
            guard (word.type ?? "word") == "word", let start = word.start, let end = word.end else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedPiece(text: text, start: start, end: max(end, start),
                                   confidence: word.logprob.map { min(1, max(0, exp($0))) }, startsWord: true)
        }
        return (reply.language_code, pieces)
    }

    /// Transcribes a take's voice (a WAV or M4A of the mic track) in
    /// `language` and returns a transcript in Vision One's format.
    public func transcribe(audio: Data, fileName: String, mimeType: String, seconds: Double,
                           language: SALanguage, audioTrack: String = "mic") async throws -> Transcript {
        try await check(.audio, task: .transcribeCloud,
                        summary: "Transcribe this take in \(language.name) with Scribe (\(Self.clock(seconds)) of audio)",
                        payload: "The voice of this take: \(Self.clock(seconds)) of audio, \(ByteCountFormatter.string(fromByteCount: Int64(audio.count), countStyle: .file)). Your screen and camera aren't sent. Scribe writes back the words with their timings.")
        var form = MultipartForm()
        form.addField(name: "model_id", value: Self.scribeModel)
        form.addField(name: "language_code", value: language.iso3)
        form.addField(name: "timestamps_granularity", value: "word")
        form.addField(name: "tag_audio_events", value: "false")
        form.addFile(name: "file", fileName: fileName, mimeType: mimeType, data: audio)
        var request = form.request(Self.base.appendingPathComponent("v1/speech-to-text"), headers: headers)
        request.timeoutInterval = 600
        let data = try await send(request)
        let result = try Self.pieces(fromScribe: data)
        return TranscriptBuilder.build(pieces: result.pieces, language: language.code,
                                       engine: "elevenlabs-\(Self.scribeModel)", audioTrack: audioTrack, duration: seconds)
    }

    // MARK: Dubbing

    public enum DubStatus: Equatable, Sendable {
        case working
        case done
        case failed(String)
    }

    /// Starts a dub of the edited voice into `target` and returns its id.
    /// The voice is cloned for the dub on ElevenLabs' side, so it sounds
    /// like the person; ElevenLabs keeps it with the dubbing project.
    public func startDub(audio: Data, fileName: String, mimeType: String, seconds: Double,
                         from source: SALanguage, to target: SALanguage, name: String) async throws -> String {
        guard target.support.dub.quality.isAvailable else {
            throw AIError.unavailable(.elevenLabs, "ElevenLabs doesn't dub \(target.name) yet. Captions still work.")
        }
        try await check(.audio, task: .dub,
                        summary: "Dub this take into \(target.name) (\(Self.clock(seconds)) of audio)",
                        payload: "The edited sound of this take: \(Self.clock(seconds)), \(ByteCountFormatter.string(fromByteCount: Int64(audio.count), countStyle: .file)). Your screen isn't sent. ElevenLabs makes a copy of your voice for the dub and uses your ElevenLabs minutes. Free plans add a watermark.")
        var form = MultipartForm()
        form.addField(name: "name", value: name)
        form.addField(name: "source_lang", value: source.code)
        form.addField(name: "target_lang", value: target.code)
        form.addField(name: "num_speakers", value: "1")
        form.addField(name: "watermark", value: "false")
        form.addFile(name: "file", fileName: fileName, mimeType: mimeType, data: audio)
        let data = try await send(form.request(Self.base.appendingPathComponent("v1/dubbing"), headers: headers))
        struct Reply: Decodable { var dubbing_id: String }
        return try decode(Reply.self, data).dubbing_id
    }

    public static func dubStatus(from data: Data) throws -> DubStatus {
        struct Reply: Decodable {
            var status: String
            var error: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AIError.badResponse(.elevenLabs, "ElevenLabs sent something unexpected.")
        }
        switch reply.status.lowercased() {
        case "dubbed", "completed", "done": return .done
        case "failed", "error": return .failed(reply.error ?? "ElevenLabs couldn't dub this take.")
        default: return .working
        }
    }

    public func dubStatus(id: String) async throws -> DubStatus {
        try Self.dubStatus(from: await send(get(Self.base.appendingPathComponent("v1/dubbing/\(id)"))))
    }

    /// The dubbed sound, as ElevenLabs sends it (MP3 or MP4 audio).
    public func dubbedAudio(id: String, language: SALanguage) async throws -> Data {
        var request = get(Self.base.appendingPathComponent("v1/dubbing/\(id)/audio/\(language.code)"))
        request.timeoutInterval = 300
        return try await send(request)
    }

    /// Starts a dub and waits for it, checking every `interval` seconds.
    public func dub(audio: Data, fileName: String, mimeType: String, seconds: Double,
                    from source: SALanguage, to target: SALanguage, name: String,
                    interval: Double = 5, timeout: Double = 30 * 60) async throws -> Data {
        let id = try await startDub(audio: audio, fileName: fileName, mimeType: mimeType, seconds: seconds,
                                    from: source, to: target, name: name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            switch try await dubStatus(id: id) {
            case .done: return try await dubbedAudio(id: id, language: target)
            case let .failed(message): throw AIError.http(.elevenLabs, status: 500, message: message)
            case .working: try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        throw AIError.unavailable(.elevenLabs, "The dub is taking longer than 30 minutes. It will be in your ElevenLabs account when it's done.")
    }
}
