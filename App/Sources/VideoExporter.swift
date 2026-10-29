import AVFoundation
import CoreImage
import VisionOneKit

/// Something drawn on top of every exported frame: burned-in captions,
/// later click highlights. Draws in output pixels,
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
        case blurs(Error)
        /// Still over the preset's size limit after every retry.
        case tooBig(limit: Int64)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "This take has no video."
            case let .plan(error): return ExportPhase.message(for: error)
            case let .reader(error): return "Couldn't read the recording. \(error?.localizedDescription ?? "")"
            case let .writer(error): return "Couldn't write the video. \(error?.localizedDescription ?? "")"
            case let .blurs(error): return "Couldn't read this take's blurs, so it wasn't exported. Open it in the editor to check them. \(error.localizedDescription)"
            case let .tooBig(limit): return ExportPhase.stillTooBig(limitBytes: limit)
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
    /// Burn in the take's captions (captions.json, when on and set to burn
    /// in) with keywords in this 0xRRGGBB colour; nil leaves them out.
    /// They're built here, from the frame-snapped timeline this export
    /// renders, so they stay on the frames where the words are said.
    var captionRingHex: UInt32?
    /// Captions in this translation instead of the take's choice.
    var captionLanguage: SALanguage?
    /// Brand intro and outro around the edited video; nil for none.
    var cards: CardMaker?
    /// Draw the take's zooms (zooms.json) and blurs (blurs.json).
    var appliesEffects = true
    /// Set for a short clip: renders at the clip format's size, cut out
    /// of the screen with `framing`, instead of following the preset.
    var clip: (format: ClipFormat, framing: ClipFraming)?
    /// Colour of the ring around the camera bubble (the builder's ring).
    var ring: RingColour = .black

    /// The part of the screen an export shows.
    enum Crop {
        /// One window for the whole export (a clip).
        case fixed(NormalisedRect)
        /// A window that moves, planned on the recording's clock.
        case follow(ReframePlan)
    }

    /// What a finished export made, and what's needed to line other files
    /// (subtitles) up with it.
    struct Output {
        let url: URL
        let bytes: Int64
        /// The kept spans as rendered, edges snapped to frames.
        let timeline: ExportTimeline
        /// Seconds into the file where the edited video starts: the brand
        /// intro's length, or 0 without one.
        let videoStart: Double
    }

    /// Exports and returns the file and how it was laid out. `progress` is
    /// called from a background queue with 0...1, and only goes forward,
    /// even when a size-limited export has to go again.
    func run(to outputURL: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let asset = AVURLAsset(url: take.screenURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)
        let encodedSize = try await sourceVideo.load(.naturalSize)
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: encodedSize).applying(sourceTransform)
        let naturalSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        let frameRate = try await sourceVideo.load(.nominalFrameRate)

        // Without explicit spans, export what the editor kept (edits.json;
        // no file means no cuts). The recording's own length always wins:
        // an older edits.json can store a shorter one (the mic's length),
        // which would trim the end of the video.
        let timeline: ExportTimeline
        if let keep {
            timeline = ExportTimeline(keep: keep, sourceDuration: assetDuration.seconds, frameRate: Double(frameRate))
        } else {
            var edits = try EditList.load(from: take.editsURL, sourceDuration: assetDuration.seconds)
            edits.sourceDuration = assetDuration.seconds
            timeline = ExportTimeline(edits: edits, frameRate: Double(frameRate))
        }
        let appliedLook = AppliedTemplate.look(for: take)
        let cardMaker: CardMaker? = cards.map { maker in
            guard let look = appliedLook else { return maker }
            return CardMaker(brand: AppliedTemplate.cardBrand(for: take, base: maker.brand),
                             brandFolder: maker.brandFolder, look: look,
                             templateFolder: AppliedTemplate.folder(for: take), personal: maker.personal)
        }
        let plan = cardMaker?.plan(bodyDuration: timeline.duration)
            ?? TemplatePlan(introDuration: nil, bodyDuration: timeline.duration, outroDuration: nil)
        let source = ExportSource(width: Int(naturalSize.width), height: Int(naturalSize.height), frameRate: Double(frameRate))
        var settings: ExportSettings
        do {
            if let clip {
                settings = try ExportPlanner.settings(for: clip.format, sourceFrameRate: Double(frameRate), duration: plan.duration)
            } else {
                settings = try ExportPlanner.settings(for: preset, source: source, duration: plan.duration)
            }
        } catch let error as ExportPlanError {
            throw Failure.plan(error)
        }
        // A clip shows one fixed window; vertical and square exports of
        // the whole video follow the cursor (events.json) through it.
        let crop: Crop?
        if let clip {
            if let plan = ClipFrame.reframe(format: clip.format, framing: clip.framing,
                                             sourceWidth: Int(naturalSize.width), sourceHeight: Int(naturalSize.height),
                                             duration: assetDuration.seconds,
                                             events: try? EventLog.read(from: take.eventsURL)) {
                crop = .follow(plan)
            } else {
                crop = .fixed(ClipFrame.rect(format: clip.format,
                                             sourceAspect: naturalSize.height > 0 ? Double(naturalSize.width / naturalSize.height) : 0,
                                             framing: clip.framing))
            }
        } else if let format = preset.format {
            let focus = (try? EventLog.read(from: take.eventsURL)).map { ReframePlanner.focus(from: $0) } ?? []
            crop = .follow(ReframePlanner.plan(format: format, mode: AppliedTemplate.look(for: take)?.reframe(for: format) ?? .follow,
                                               sourceWidth: Int(naturalSize.width), sourceHeight: Int(naturalSize.height),
                                               duration: assetDuration.seconds, focus: focus))
        } else {
            crop = nil
        }

        // Cards are drawn once at the export's size, then reused if the
        // export has to go again.
        var cardSet = BrandCardSet.empty
        if plan.hasCards, let cards = cardMaker {
            cardSet = await cards.make(plan: plan,
                                       size: CGSize(width: settings.width, height: settings.height),
                                       frameRate: settings.frameRate)
            try Task.checkCancellation()
        }

        let effects = try appliesEffects ? Self.effects(for: take, timeline: timeline) : nil
        let captions = captionRingHex.map {
            CaptionExport.overlays(for: take, timeline: timeline, ringHex: $0, language: captionLanguage)
        } ?? []
        let allowedOverlays = appliedLook?.watermark == false ? overlays.filter { !($0 is WatermarkOverlay) } : overlays
        let allOverlays = captions + allowedOverlays
        let url = outputURL ?? take.exportURL(for: preset)

        // A single-pass encoder only roughly meets its average bitrate. If
        // a size-limited export overshoots, go again lower, up to
        // `sizeLimitAttempts` tries, each filling its own slice of the ring.
        let attempts = preset.sizeLimitBytes == nil ? 1 : ExportPlanner.sizeLimitAttempts
        var attempt = 0
        var bytes: Int64 = 0
        while true {
            let slice = attempt
            bytes = try await render(timeline: timeline, plan: plan, cards: cardSet,
                                     sourceVideo: sourceVideo, sourceAudio: sourceAudio, sourceTransform: sourceTransform,
                                     overlays: allOverlays, effects: effects, settings: settings, crop: crop, to: url) { fraction in
                progress(ExportPlanner.overallProgress(fraction, attempt: slice, of: attempts))
            }
            guard let limit = preset.sizeLimitBytes, bytes > limit else { break }
            attempt += 1
            guard attempt < attempts else {
                // Too big to send isn't a WhatsApp export; don't leave it.
                try? FileManager.default.removeItem(at: url)
                throw Failure.tooBig(limit: limit)
            }
            try Task.checkCancellation()
            settings.videoBitRate = ExportPlanner.retryVideoBitRate(after: settings, bytes: bytes, limit: limit,
                                                                    duration: plan.duration, attempt: attempt)
        }
        let videoStart = cardSet.intro != nil ? plan.body.lowerBound : 0
        return Output(url: url, bytes: bytes, timeline: timeline, videoStart: videoStart)
    }

    // MARK: - Composition

    /// Zooms and blurs for this export, or nil when the take has none.
    static func effects(for take: Take, timeline: ExportTimeline) throws -> FrameEffects? {
        // A blur list that can't be read stops the export rather than
        // letting through what it was hiding.
        let blurs: BlurList
        do {
            blurs = try BlurList.load(from: take.blursURL)
        } catch {
            throw Failure.blurs(error)
        }
        let zooms = (try? ZoomList.load(from: take.zoomsURL)) ?? ZoomList()
        let cursor = (try? EventLog.read(from: take.eventsURL))?.cursorPath ?? []
        let effects = FrameEffects.export(zooms: zooms, blurs: blurs, cursor: cursor, timeline: timeline)
        return effects.isEmpty ? nil : effects
    }

    /// The take's camera.mov and camera.json, or nil when it has none or
    /// either can't be read (the export then shows the screen alone).
    static func camera(for take: Take) async -> (track: AVAssetTrack, range: CMTimeRange, info: CameraTrack)? {
        guard let info = try? CameraTrack.read(from: take.cameraInfoURL), !info.placements.isEmpty else { return nil }
        let asset = AVURLAsset(url: take.cameraURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange), range.duration > .zero else { return nil }
        return (track, range, info)
    }

    static func cgColor(_ ring: RingColour) -> CGColor {
        CGColor(srgbRed: CGFloat((ring.hex >> 16) & 0xFF) / 255, green: CGFloat((ring.hex >> 8) & 0xFF) / 255,
                blue: CGFloat(ring.hex & 0xFF) / 255, alpha: 1)
    }

    private func render(timeline: ExportTimeline, plan: TemplatePlan, cards: BrandCardSet,
                        sourceVideo: AVAssetTrack, sourceAudio: [AVAssetTrack], sourceTransform: CGAffineTransform,
                        overlays: [ExportOverlay], effects: FrameEffects?, settings: ExportSettings,
                        crop: Crop?, to url: URL,
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
        // Kept voice tools (voice.json): the cleaned voice in place of the mic.
        let micIndex = await MicTrack.micIndex(of: sourceAudio, take: take)
        audioSources = await VoiceComposer.sources(audioSources, take: take)

        // The camera, on its own track, cut the same way as the screen.
        // The compositor places the bubble after cropping, in output coordinates.
        let camera = await Self.camera(for: take)
        var cameraTrack: AVMutableCompositionTrack?
        if camera != nil {
            cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        for segment in timeline.segments {
            let range = CMTimeRange(start: Self.time(segment.source.lowerBound),
                                    end: Self.time(segment.source.upperBound))
            let at = Self.time(segment.outputStart)
            try video.insertTimeRange(range, of: sourceVideo, at: at)
            if let camera, let cameraTrack {
                let wanted = CMTimeRange(start: Self.time(camera.info.cameraTime(forScreen: segment.source.lowerBound)),
                                         end: Self.time(camera.info.cameraTime(forScreen: segment.source.upperBound)))
                let available = wanted.intersection(camera.range)
                if available.duration > .zero {
                    try cameraTrack.insertTimeRange(available, of: camera.track, at: at + (available.start - wanted.start))
                }
            }
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
        let cropAt: (@Sendable (Double) -> NormalisedRect?)?
        switch crop {
        case let .fixed(rect)?:
            cropAt = { @Sendable _ in rect }
        case let .follow(reframe)?:
            // The compositor asks on the edited clock; the plan is on the
            // recording's.
            cropAt = { @Sendable t in reframe.crop(at: timeline.sourceTime(forOutput: t) ?? t) }
        case nil:
            cropAt = nil
        }
        var split = false
        if case let .follow(plan)? = crop { split = plan.mode == .split }
        var isFit = false
        if case let .fixed(rect)? = crop, rect == .full { isFit = true }
        instructions.append(FrameInstruction(timeRange: CMTimeRange(start: videoStart, end: videoEnd),
                                             trackID: video.trackID, overlays: overlays, sourceTransform: sourceTransform,
                                             overlayTimeOffset: videoStart.seconds, effects: effects,
                                             crop: cropAt,
                                             // "Fit" clips sit on the canvas, ink on paper.
                                             background: isFit
                                                ? CIColor(red: 0xF4 / 255.0, green: 0xF4 / 255.0, blue: 0xF1 / 255.0)
                                                : .black,
                                             camera: cameraTrack.flatMap { track in
                                                 camera.map { CameraLayer(trackID: track.trackID, track: $0.info,
                                                                          timeline: timeline, ringColour: Self.cgColor(ring),
                                                                          background: BackgroundRenderer(
                                                                              background: CameraBackground.read(from: take.backgroundURL))) }
                                             }, split: split))
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
        // Sentences said again replace the original voice in their slot.
        let redos = ((try? RedoList.load(from: take.redosURL)) ?? RedoList()).accepted
        let redone = await RedoComposer.add(redos, take: take, timeline: timeline, to: composition, offset: joinOffset)
        // Words re-said in the user's cloned voice, with the original muted under them.
        let voiceFixes = await VoiceComposer.addFixes(for: take, timeline: timeline, to: composition, offset: joinOffset)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FrameCompositor.self
        videoComposition.renderSize = CGSize(width: settings.width, height: settings.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        let savedMix = RecordedMix.load(for: take)
        let recorded: [AVMutableAudioMixInputParameters] = audio.enumerated().map { index, track in
            let gain = savedMix.gain(isMicrophone: index == micIndex)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(gain, at: .zero)
            RedoComposer.mute(parameters, during: redone.mutes, gain: gain)
            // Ramps can't overlap: a word fix inside a redone line is
            // already silent, and a join right beside a redone line or a
            // fixed word keeps their fades.
            let fixMutes = voiceFixes.mutes.filter { fix in
                !redone.mutes.contains { $0.lowerBound - 0.2 < fix.end && fix.start < $0.upperBound + 0.2 }
            }
            if index == micIndex { VoiceComposer.mute(fixMutes, on: parameters, gain: gain) }
            let quiet = redone.mutes + fixMutes.map { $0.start..<max($0.start, $0.end) }
            let joins = timeline.joins.map { $0 + joinOffset }.filter { join in
                !quiet.contains { ($0.lowerBound - 0.2)...($0.upperBound + 0.2) ~= join }
            }
            for join in joins {
                let fade = Self.time(Self.joinFade)
                let t = Self.time(join)
                parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: CMTimeRange(start: t - fade, duration: fade))
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: t, duration: fade))
            }
            return parameters
        }
        audioMix.inputParameters = recorded + soundTracks.parameters + redone.parameters + voiceFixes.parameters

        return try await encode(composition: composition, videoTracks: [video] + (cameraTrack.map { [$0] } ?? []),
                                audio: audio + soundTracks.tracks + redone.tracks + voiceFixes.tracks,
                                videoComposition: videoComposition, audioMix: audioMix,
                                duration: duration.seconds, settings: settings, to: url, progress: progress)
    }

    // MARK: - Encoding

    private func encode(composition: AVComposition, videoTracks: [AVCompositionTrack], audio: [AVCompositionTrack],
                        videoComposition: AVVideoComposition, audioMix: AVAudioMix,
                        duration: Double, settings: ExportSettings, to url: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
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
            // Redone lines are fitted to their slot; keep the voice's pitch.
            output.audioTimePitchAlgorithm = .spectral
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

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
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
