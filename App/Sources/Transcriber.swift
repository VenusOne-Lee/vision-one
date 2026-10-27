import AVFoundation
import FluidAudio
import VisionOneKit

/// Writes transcript.json for each take, on the Mac, after recording
/// stops. Takes are done one at a time in the order they were recorded,
/// and any take left without a transcript (the app quit mid-way) is
/// picked up on the next launch. See docs/TRANSCRIPT.md.
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    @Published private(set) var phase: TranscriptionPhase = .idle

    private let engine = ParakeetEngine()
    private var queue: [Take] = []
    private var running = false

    func transcribe(_ take: Take) {
        guard !queue.contains(take) else { return }
        queue.append(take)
        runQueue()
    }

    /// Queues every take that has a recording but no transcript yet.
    func catchUp(in library: TakeLibrary) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: library.folder, includingPropertiesForKeys: [.creationDateKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        let missing = folders.map(Take.init(folder:)).filter {
            fm.fileExists(atPath: $0.screenURL.path) && !fm.fileExists(atPath: $0.transcriptURL.path)
        }
        for take in missing.sorted(by: { $0.name < $1.name }) { transcribe(take) }
    }

    func retry() {
        guard case let .failed(name, _) = phase else { return }
        phase = .idle
        transcribe(Take(folder: TakeLibrary.standard.folder.appendingPathComponent(name, isDirectory: true)))
    }

    private func runQueue() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let take = queue.removeFirst()
        Task {
            await run(take)
            running = false
            runQueue()
        }
    }

    private func run(_ take: Take) async {
        do {
            if !(await engine.isLoaded) {
                phase = .downloadingModel(progress: nil)
                try await engine.load { fraction in
                    Task { @MainActor in
                        if case .downloadingModel = Transcriber.shared.phase {
                            Transcriber.shared.phase = .downloadingModel(progress: fraction)
                        }
                    }
                }
            }
            phase = .transcribing(takeName: take.name)
            let audio = try await TakeAudio.read(from: take.screenURL)
            let pieces = try await engine.transcribe(audio.samples)
            let transcript = TranscriptBuilder.build(
                pieces: pieces, language: "en", engine: ParakeetEngine.name,
                audioTrack: audio.track, duration: audio.duration)
            try transcript.write(to: take.transcriptURL)
            // Propose cuts for fillers and long pauses. A failure here
            // leaves the transcript usable, so it isn't shown as an error.
            let loudness = LoudnessEnvelope.measure(samples: audio.samples, sampleRate: TakeAudio.sampleRate)
            try? AutoClean.run(on: take, transcript: transcript, loudness: loudness)
            phase = .idle
        } catch {
            phase = .failed(takeName: take.name, message: Self.describe(error))
        }
    }

    /// Errors say how to fix, per the design system.
    private static func describe(_ error: Error) -> String {
        if let error = error as? TakeAudio.ReadError { return error.localizedDescription }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "The speech model needs the internet once to download. Connect and try again."
        }
        return "Something went wrong (\(error.localizedDescription)). Try again."
    }
}

/// Parakeet TDT 0.6B v2 through FluidAudio: English, on the Neural
/// Engine, with timings for every sub-word token. The model (~0.5 GB)
/// downloads from Hugging Face on first use and is cached after that.
actor ParakeetEngine {
    static let name = "parakeet-tdt-0.6b-v2"

    private var manager: AsrManager?

    var isLoaded: Bool { manager != nil }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2) { update in
            progress(update.fractionCompleted)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> [RecognizedPiece] {
        guard let manager else { throw ASRError.notInitialized }
        // Parakeet needs at least a second of audio.
        guard samples.count >= 16_000 else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return (result.tokenTimings ?? []).map { token in
            RecognizedPiece(
                text: token.token,
                start: token.startTime,
                end: token.endTime,
                confidence: Double(token.confidence),
                // SentencePiece marks the start of a word with "▁".
                startsWord: token.token.hasPrefix("▁") || token.token.hasPrefix(" "))
        }
    }
}

/// Reads a take's voice as 16 kHz mono floats, the format speech models
/// want. Uses the mic track; a take recorded without the mic falls back
/// to system sound.
enum TakeAudio {
    static let sampleRate = 16_000.0

    struct Audio {
        let samples: [Float]
        let track: String
        var duration: Double { Double(samples.count) / TakeAudio.sampleRate }
    }

    enum ReadError: LocalizedError {
        case noAudio
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This take has no sound. Turn on the mic and record again."
            case .unreadable: return "The recording couldn't be read. It may still be saving; try again."
            }
        }
    }

    static func read(from url: URL) async throws -> Audio {
        let asset = AVURLAsset(url: url)
        // TakeWriter adds system sound first, then the mic.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.count >= 2 ? tracks[1] : tracks.first else { throw ReadError.noAudio }
        let trackName = tracks.count >= 2 ? "mic" : "system"

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReadError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadError.unreadable }

        var timeline = SampleTimeline(sampleRate: sampleRate)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            // Times are on the movie's clock, which starts at the first
            // video frame, so gaps before or inside the mic track become
            // silence and word times match the video.
            timeline.append(floats, at: buffer.presentationTimeStamp.seconds)
        }
        guard reader.status == .completed else { throw reader.error ?? ReadError.unreadable }
        return Audio(samples: timeline.samples, track: trackName)
    }
}
