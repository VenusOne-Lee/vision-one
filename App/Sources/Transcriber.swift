import AVFoundation
import FluidAudio
import VisionOneKit

/// Writes transcript.json for each take, on the Mac, after recording
/// stops. Takes are done one at a time in the order they were recorded,
/// and any take left without a transcript (the app quit mid-way) is
/// picked up on the next launch. A take that can never be transcribed
/// (it has no sound) gets transcript-failed.json so launches skip it.
/// See docs/TRANSCRIPT.md.
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    /// What's happening right now: idle, getting the model or transcribing.
    @Published private var activity: TranscriptionPhase = .idle
    /// Each failed take and why, so one take's failure isn't lost when
    /// the next take starts.
    @Published private(set) var failures = TranscriptionFailures()
    /// Where each failed take lives, for Retry.
    private var failedTakes: [String: Take] = [:]

    /// The menu line: the work in progress, otherwise the newest failure
    /// still waiting for a retry.
    var phase: TranscriptionPhase {
        if activity.isWorking { return activity }
        if let latest = failures.latest {
            return .failed(takeName: latest.takeName, message: latest.message)
        }
        return .idle
    }

    private let engine = ParakeetEngine()
    private var queue: [Take] = []
    private var running = false

    func transcribe(_ take: Take) {
        guard !queue.contains(take) else { return }
        queue.append(take)
        runQueue()
    }

    /// Queues every take that has a recording but no transcript yet,
    /// skipping takes marked as never transcribable.
    func catchUp(in library: TakeLibrary) {
        for take in library.untranscribedTakes() { transcribe(take) }
    }

    /// Tries the most recent failure again, even one marked as never
    /// transcribable: the marker is removed first.
    func retry() {
        guard let latest = failures.latest else { return }
        let take = failedTakes[latest.takeName]
            ?? Take(folder: TakeLibrary.standard.folder.appendingPathComponent(latest.takeName, isDirectory: true))
        try? FileManager.default.removeItem(at: take.transcriptFailedURL)
        failures.clear(take.name)
        failedTakes[take.name] = nil
        transcribe(take)
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
        failures.clear(take.name)
        failedTakes[take.name] = nil
        activity = .transcribing(takeName: take.name)
        do {
            // Read the sound first, so a take without any fails straight
            // away instead of waiting on a 0.5 GB model download.
            let audio = try await TakeAudio.read(take)
            if !(await engine.isLoaded) {
                activity = .downloadingModel(progress: nil)
                try await engine.load { fraction in
                    Task { @MainActor in Transcriber.shared.showDownload(fraction) }
                }
                activity = .transcribing(takeName: take.name)
            }
            let pieces = try await engine.transcribe(audio.samples)
            let transcript = TranscriptBuilder.build(
                pieces: pieces, language: "en", engine: ParakeetEngine.name,
                audioTrack: audio.source.rawValue, duration: audio.duration)
            try transcript.write(to: take.transcriptURL)
            // Propose cuts for fillers and long pauses, measured against
            // the video's length. A failure here leaves the transcript
            // usable, so it isn't shown as an error.
            let loudness = LoudnessEnvelope.measure(samples: audio.samples, sampleRate: TakeAudio.sampleRate)
            // The editor draws the waveform and finds silence from these.
            try? loudness.write(to: take.levelsURL)
            try? AutoClean.run(on: take, transcript: transcript, sourceDuration: audio.videoDuration,
                               loudness: loudness)
            activity = .idle
            AIServices.shared.transcriptReady(for: take)
        } catch {
            let message = Self.describe(error)
            if (error as? TakeAudio.ReadError) == .noAudio {
                // Recording again is the only fix, so don't try it again on
                // every launch. Retry in the menu still works.
                try? TranscriptFailure(reason: .noAudio, message: message).write(to: take.transcriptFailedURL)
            }
            failedTakes[take.name] = take
            failures.record(message, for: take.name)
            activity = .idle
        }
    }

    private func showDownload(_ fraction: Double) {
        if case .downloadingModel = activity { activity = .downloadingModel(progress: fraction) }
    }

    /// Errors say how to fix, per the design system.
    private static func describe(_ error: Error) -> String {
        if let error = error as? TakeAudio.ReadError { return error.localizedDescription }
        if let error = error as? TranscriptError { return error.localizedDescription }
        // FluidAudio's model download errors. Plain network errors
        // (URLError) come through unwrapped and are caught below.
        if let error = error as? DownloadError {
            switch error {
            case .rateLimited:
                return TranscriptionErrorText.busy
            case let .downloadFailed(_, underlying):
                return TranscriptionErrorText.message(forUnderlying: underlying) ?? TranscriptionErrorText.downloadFailed
            default:
                return TranscriptionErrorText.downloadFailed
            }
        }
        if let error = error as? AsrModelsError, case .downloadFailed = error {
            return TranscriptionErrorText.downloadFailed
        }
        if let message = TranscriptionErrorText.message(forUnderlying: error) { return message }
        return TranscriptionErrorText.generic(error)
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
/// want. Uses the mic track; when the take has no mic track, or the mic
/// gave under a second of sound, system sound is used instead.
enum TakeAudio {
    static let sampleRate = 16_000.0

    struct Audio {
        let samples: [Float]
        let source: TakeAudioSource
        /// Seconds of sound the track actually gave, not counting gaps.
        let decodedSeconds: Double
        /// Length of screen.mov, or nil when it couldn't be read.
        var videoDuration: Double?
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

    static func read(_ take: Take) async throws -> Audio {
        let asset = AVURLAsset(url: take.screenURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ReadError.unreadable
        }
        guard !tracks.isEmpty else { throw ReadError.noAudio }

        // audio-tracks.json says which track is which; takes from before
        // it existed are told apart by channel count.
        var channelCounts: [Int] = []
        for track in tracks { channelCounts.append(await channelCount(of: track)) }
        let recorded = try? TakeAudioTracks.read(from: take.audioTracksURL)
        let sources = TakeAudioTracks.sources(recorded: recorded, channelCounts: channelCounts)
        let micIndex = sources.firstIndex(of: .mic)
        let systemIndex = sources.firstIndex(of: .system)

        var audio: Audio
        if let micIndex {
            audio = try await readTrack(tracks[micIndex], of: asset, source: .mic)
            // The mic barely recorded; system sound may hold the voice.
            if let systemIndex, audio.decodedSeconds < TakeAudioTracks.minimumMicSeconds,
               let system = try? await readTrack(tracks[systemIndex], of: asset, source: .system),
               TakeAudioTracks.prefersSystem(micSeconds: audio.decodedSeconds, systemSeconds: system.decodedSeconds) {
                audio = system
            }
        } else {
            audio = try await readTrack(tracks[systemIndex ?? 0], of: asset, source: .system)
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            audio.videoDuration = duration.seconds
        }
        return audio
    }

    /// TakeWriter encodes the mic as mono and system sound as stereo.
    private static func channelCount(of track: AVAssetTrack) async -> Int {
        guard let formats = try? await track.load(.formatDescriptions),
              let format = formats.first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return 0 }
        return Int(description.pointee.mChannelsPerFrame)
    }

    private static func readTrack(_ track: AVAssetTrack, of asset: AVAsset, source: TakeAudioSource) async throws -> Audio {
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
        return Audio(samples: timeline.samples, source: source, decodedSeconds: timeline.decodedDuration)
    }
}
