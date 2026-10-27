import AVFoundation
import VisionOneKit

/// Something drawn on top of every exported frame: burned-in captions,
/// later the camera bubble and click highlights. Draws in output pixels,
/// origin bottom left, at a time on the edited timeline.
protocol ExportOverlay: Sendable {
    func draw(in context: CGContext, size: CGSize, at outputTime: Double)
}

/// Renders a take into an MP4. The kept parts of every track (screen,
/// system sound, mic) are spliced into one AVMutableComposition, frames
/// go through `FrameCompositor` to be scaled and overlaid, and
/// AVAssetWriter encodes H.264 + AAC at the bitrate `ExportPlanner` chose.
/// Music and sound effects from sound.json are mixed in by `SoundComposer`.
/// AVAssetExportSession can't set a bitrate, so it can't promise the
/// WhatsApp size; this pipeline can.
struct VideoExporter {
    enum Failure: LocalizedError {
        case noVideo
        case plan(ExportPlanError)
        case reader(Error?)
        case writer(Error?)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "This take has no video."
            case let .plan(error): return ExportPhase.message(for: error)
            case let .reader(error): return "Couldn't read the recording. \(error?.localizedDescription ?? "")"
            case let .writer(error): return "Couldn't write the video. \(error?.localizedDescription ?? "")"
            }
        }
    }

    /// Sound fades out and back in over this long at every cut.
    static let joinFade = 0.012

    let take: Take
    /// Kept spans in seconds from the take's first frame; nil uses the
    /// take's edits.json.
    var keep: [Range<Double>]?
    let preset: ExportPreset
    var overlays: [ExportOverlay] = []
    /// Brand intro and outro around the edited video; nil for none.
    var cards: CardMaker?

    /// Exports and returns the file's URL and size. `progress` is called
    /// from a background queue with 0...1.
    func run(to outputURL: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, Int64) {
        let asset = AVURLAsset(url: take.screenURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let frameRate = try await sourceVideo.load(.nominalFrameRate)

        // Without explicit spans, export what the editor kept (edits.json;
        // no file means no cuts).
        let timeline: ExportTimeline
        if let keep {
            timeline = ExportTimeline(keep: keep, sourceDuration: assetDuration.seconds, frameRate: Double(frameRate))
        } else {
            var edits = try EditList.load(from: take.editsURL, sourceDuration: assetDuration.seconds)
            edits.sourceDuration = min(edits.sourceDuration, assetDuration.seconds)
            timeline = ExportTimeline(edits: edits, frameRate: Double(frameRate))
        }
        let plan = cards?.plan(bodyDuration: timeline.duration)
            ?? TemplatePlan(introDuration: nil, bodyDuration: timeline.duration, outroDuration: nil)
        let source = ExportSource(width: Int(naturalSize.width), height: Int(naturalSize.height), frameRate: Double(frameRate))
        var settings: ExportSettings
        do {
            settings = try ExportPlanner.settings(for: preset, source: source, duration: plan.duration)
        } catch let error as ExportPlanError {
            throw Failure.plan(error)
        }

        // Cards are drawn once at the export's size, then reused if the
        // export has to go again.
        var cardSet = BrandCardSet.empty
        if plan.hasCards, let cards {
            cardSet = await cards.make(plan: plan,
                                       size: CGSize(width: settings.width, height: settings.height),
                                       frameRate: settings.frameRate)
            try Task.checkCancellation()
        }

        let url = outputURL ?? take.exportURL(for: preset)
        var bytes = try await render(timeline: timeline, plan: plan, cards: cardSet,
                                     sourceVideo: sourceVideo, sourceAudio: sourceAudio,
                                     settings: settings, to: url, progress: progress)

        // A single-pass encoder only roughly meets its average bitrate.
        // If a size-limited export overshoots, go again a little lower.
        if let limit = preset.sizeLimitBytes, bytes > limit {
            let scale = Double(limit) * 0.85 / Double(bytes)
            settings.videoBitRate = Int(Double(settings.videoBitRate) * scale)
            bytes = try await render(timeline: timeline, plan: plan, cards: cardSet,
                                     sourceVideo: sourceVideo, sourceAudio: sourceAudio,
                                     settings: settings, to: url, progress: progress)
        }
        return (url, bytes)
    }

    // MARK: - Composition

    private func render(timeline: ExportTimeline, plan: TemplatePlan, cards: BrandCardSet,
                        sourceVideo: AVAssetTrack, sourceAudio: [AVAssetTrack],
                        settings: ExportSettings, to url: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideo
        }
        var audio: [AVMutableCompositionTrack] = []
        var audioSources: [(track: AVAssetTrack, range: CMTimeRange)] = []
        for track in sourceAudio {
            guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            audio.append(added)
            audioSources.append((track, try await track.load(.timeRange)))
        }

        for segment in timeline.segments {
            let range = CMTimeRange(start: Self.time(segment.source.lowerBound),
                                    end: Self.time(segment.source.upperBound))
            let at = Self.time(segment.outputStart)
            try video.insertTimeRange(range, of: sourceVideo, at: at)
            for (index, track) in audio.enumerated() {
                // A track can be shorter than the video (the mic starts a
                // moment late); insert only the part it has.
                let source = audioSources[index]
                let available = range.intersection(source.range)
                guard available.duration > .zero else { continue }
                try track.insertTimeRange(available, of: source.track, at: at + (available.start - range.start))
            }
        }

        // Room for the cards: a gap after the video for the outro, then a
        // gap at the start of every track for the intro, which pushes the
        // video and sound along. The compositor draws the cards in them.
        let bodyStart = Self.time(plan.body.lowerBound)
        let bodyEnd = Self.time(plan.body.upperBound)
        if let outro = plan.outro, cards.outro != nil {
            video.insertEmptyTimeRange(CMTimeRange(start: video.timeRange.end,
                                                   duration: Self.time(outro.upperBound - outro.lowerBound)))
        }
        if plan.intro != nil, cards.intro != nil {
            composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: bodyStart))
        }

        var instructions: [FrameInstruction] = []
        if let intro = cards.intro, plan.intro != nil {
            instructions.append(FrameInstruction(timeRange: CMTimeRange(start: .zero, end: bodyStart), card: intro))
        }
        let videoStart = cards.intro != nil ? bodyStart : .zero
        let videoEnd = cards.intro != nil ? bodyEnd : Self.time(timeline.duration)
        instructions.append(FrameInstruction(timeRange: CMTimeRange(start: videoStart, end: videoEnd),
                                             trackID: video.trackID, overlays: overlays,
                                             overlayTimeOffset: videoStart.seconds))
        if let outro = cards.outro, let range = plan.outro {
            // Cover the composition to its very end, whatever rounding did.
            let end = CMTimeMaximum(videoEnd + Self.time(range.upperBound - range.lowerBound), composition.duration)
            instructions.append(FrameInstruction(timeRange: CMTimeRange(start: videoEnd, end: end), card: outro))
        }
        let duration = instructions.last.map { $0.timeRange.end } ?? Self.time(timeline.duration)
        // Joins move along with the intro.
        let joinOffset = videoStart.seconds

        // Music and sound effects from sound.json go on their own tracks,
        // after the intro so they start with the video.
        let sound = (try? SoundPlan.load(from: take.soundURL)) ?? SoundPlan()
        let words: [TimeSpan] = sound.isEmpty ? [] : ((try? Transcript.read(from: take.transcriptURL))?.words.map(\.span) ?? [])
        let soundTracks = await SoundComposer.add(sound, timeline: timeline, words: words, to: composition,
                                                  offset: joinOffset)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FrameCompositor.self
        videoComposition.renderSize = CGSize(width: settings.width, height: settings.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        let recorded: [AVMutableAudioMixInputParameters] = audio.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            for join in timeline.joins.map({ $0 + joinOffset }) {
                let fade = Self.time(Self.joinFade)
                let t = Self.time(join)
                parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: t - fade, duration: fade))
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: t, duration: fade))
            }
            return parameters
        }
        audioMix.inputParameters = recorded + soundTracks.parameters

        return try await encode(composition: composition, video: video, audio: audio + soundTracks.tracks,
                                videoComposition: videoComposition, audioMix: audioMix,
                                duration: duration.seconds, settings: settings, to: url, progress: progress)
    }

    // MARK: - Encoding

    private func encode(composition: AVComposition, video: AVCompositionTrack, audio: [AVCompositionTrack],
                        videoComposition: AVVideoComposition, audioMix: AVAudioMix,
                        duration: Double, settings: ExportSettings, to url: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audio.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: settings.audioChannels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        }

        // Write next to the destination, then swap in, so a failed export
        // never leaves half a file under the real name.
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).partial.mp4")
        try? FileManager.default.removeItem(at: partial)

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: settings.audioChannels,
                AVEncoderBitRateKey: settings.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw Failure.reader(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.writer(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let pumps = [
            Pump(output: videoOutput, input: videoInput, label: "video") { time in
                progress(min(1, max(0, time.seconds / max(duration, 0.001))))
            },
            audioOutput.flatMap { output in audioInput.map { Pump(output: output, input: $0, label: "audio", onSample: nil) } },
        ].compactMap { $0 }

        let completed = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                for pump in pumps {
                    group.addTask { await pump.run(reader: reader) }
                }
                return await group.reduce(true) { $0 && $1 }
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled || !completed || reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            if Task.isCancelled { throw CancellationError() }
            throw Failure.reader(reader.error)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.writer(writer.error)
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        progress(1)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    /// Seconds to CMTime on a timescale every common frame rate divides.
    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}

/// Moves samples from one reader output to one writer input as fast as
/// the encoder takes them.
private final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let queue: DispatchQueue
    let onSample: (@Sendable (CMTime) -> Void)?

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String,
         onSample: (@Sendable (CMTime) -> Void)?) {
        self.output = output
        self.input = input
        self.queue = DispatchQueue(label: "za.co.versionone.visionone.export.\(label)", qos: .userInitiated)
        self.onSample = onSample
    }

    /// True when the output ran dry normally.
    func run(reader: AVAssetReader) async -> Bool {
        await withCheckedContinuation { continuation in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(returning: reader.status == .completed || reader.status == .reading)
                        return
                    }
                    guard input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(returning: false)
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
        }
    }
}
