import AVFoundation
import CoreGraphics
import SoundAnalysis
import Vision
import VisionOneKit

/// Reads a video file (or a direct video link) for Copy a style: small
/// frames for cuts and colour, Vision for faces and on-screen words, and
/// macOS's own sound classifier for speech and music. Everything stays in
/// memory and only the numbers come out; the video is never copied.
enum StyleSampler {
    enum Failure: LocalizedError {
        case unreadable
        case noVideo

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Vision One couldn't open that video. Try an MP4 or MOV file."
            case .noVideo: return "That file has no picture to read."
            }
        }
    }

    /// Reads `url` and calls `progress` on the main actor with 0...1 and the
    /// frames read so far, so the window can show what it has found.
    static func read(_ url: URL, progress: @escaping @MainActor (Double, StyleInput) -> Void) async throws -> StyleInput {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.unreadable }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = natural.applying(transform)
        let width = Double(abs(shown.width)), height = Double(abs(shown.height))
        let readSeconds = min(duration, StyleMeasure.maxSeconds)

        // Sound first: it's quick, and the live numbers can show it.
        let sound = await readSound(asset, seconds: readSeconds)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Big enough for Vision to read caption words.
        generator.maximumSize = CGSize(width: 720, height: 720)
        let tolerance = CMTime(seconds: 0.5 / StyleMeasure.framesPerSecond, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = StyleMeasure.sampleTimes(duration: duration)
        var frames: [StyleFrame] = []
        frames.reserveCapacity(times.count)
        for (index, t) in times.enumerated() {
            try Task.checkCancellation()
            guard let grabbed = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let image = grabbed.image
            let (signature, colours) = measure(image)
            guard !signature.isEmpty else { continue }
            var frame = StyleFrame(time: grabbed.actualTime.seconds.isFinite ? grabbed.actualTime.seconds : t,
                                   signature: signature, colours: colours)
            if StyleMeasure.readsVision(at: index) {
                let seen = vision(image)
                frame.faces = seen.faces
                frame.text = seen.text
            }
            frames.append(frame)
            if index % 24 == 0 || index == times.count - 1 {
                let partial = StyleInput(duration: max(t, 0.1), width: width, height: height, frames: frames,
                                         sound: sound.windows.filter { $0.start < t },
                                         envelope: [], envelopeRate: StyleMeasure.envelopeRate)
                await progress(Double(index + 1) / Double(times.count), partial)
            }
        }
        guard frames.count >= 4 else { throw Failure.unreadable }
        return StyleInput(duration: readSeconds, width: width, height: height, frames: frames,
                          sound: sound.windows, envelope: sound.envelope, envelopeRate: StyleMeasure.envelopeRate)
    }

    // MARK: - Pictures

    /// Shrinks the frame to `StyleMeasure.sampleWidth` and measures it.
    static func measure(_ image: CGImage) -> (signature: [Double], colours: [StyleRGB]) {
        let width = StyleMeasure.sampleWidth
        let height = max(1, Int((Double(width) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ([], []) }
        return StyleMeasure.frame(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// Faces and words on one frame. Vision's boxes are 0...1 from the
    /// bottom left; these are flipped to top left like every other rect.
    static func vision(_ image: CGImage) -> (faces: [NormalisedRect], text: [StyleTextBox]) {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([faceRequest, textRequest])
        } catch {
            return ([], [])
        }
        func rect(_ box: CGRect) -> NormalisedRect {
            NormalisedRect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height))
        }
        let faces = (faceRequest.results ?? []).map { rect($0.boundingBox) }
        let text = (textRequest.results ?? []).compactMap { observation -> StyleTextBox? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            return StyleTextBox(rect: rect(observation.boundingBox), text: candidate.string)
        }
        return (faces, text)
    }

    // MARK: - Sound

    static let soundRate = 16_000.0

    /// Speech and music per second, and the loudness envelope. Empty when
    /// there is no sound or it can't be read (a remote link, for one).
    static func readSound(_ asset: AVAsset, seconds: Double) async -> (windows: [StyleSoundWindow], envelope: [Double]) {
        guard let samples = try? await readSamples(asset, seconds: seconds), samples.count > Int(soundRate) else {
            return ([], [])
        }
        let hop = Int(soundRate / StyleMeasure.envelopeRate)
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            envelope.append(rms(samples, i, min(i + hop, samples.count)))
            i += hop
        }
        let labels = classify(samples)
        let windows = labels.map { label -> StyleSoundWindow in
            let lo = max(0, Int(label.start * soundRate)), hi = min(samples.count, Int((label.start + label.duration) * soundRate))
            let level = hi > lo ? rms(samples, lo, hi) : 0
            return StyleSoundWindow(start: label.start, duration: label.duration, speech: label.speech,
                                    music: label.music, loudness: 20 * log10(max(level, 0.000_001)))
        }
        return (windows, envelope)
    }

    private static func rms(_ samples: [Float], _ lo: Int, _ hi: Int) -> Double {
        guard hi > lo else { return 0 }
        var sum = 0.0
        for j in lo..<hi { sum += Double(samples[j]) * Double(samples[j]) }
        return (sum / Double(hi - lo)).squareRoot()
    }

    private static func readSamples(_ asset: AVAsset, seconds: Double) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: soundRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples += floats }
        }
        return samples
    }

    struct Label {
        var start: Double
        var duration: Double
        var speech: Double
        var music: Double
    }

    /// Runs Apple's built-in sound classifier over the samples.
    private static func classify(_ samples: [Float]) -> [Label] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: soundRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        request.overlapFactor = 0
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = LabelCollector()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }

        let chunk = 8192
        var position = 0
        while position < samples.count {
            let count = min(chunk, samples.count - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + position, count: count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += count
        }
        analyzer.completeAnalysis()
        return observer.labels.sorted { $0.start < $1.start }
    }
}

/// Collects the classifier's speech and music confidences per window.
private final class LabelCollector: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var collected: [StyleSampler.Label] = []

    var labels: [StyleSampler.Label] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let label = StyleSampler.Label(
            start: result.timeRange.start.seconds, duration: result.timeRange.duration.seconds,
            speech: result.classification(forIdentifier: "speech")?.confidence ?? 0,
            music: result.classification(forIdentifier: "music")?.confidence ?? 0)
        lock.lock()
        collected.append(label)
        lock.unlock()
    }
}
