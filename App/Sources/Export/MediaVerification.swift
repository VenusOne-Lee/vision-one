import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VisionOneKit

/// Deterministic AVFoundation checks run by macOS CI. No capture, model
/// downloads, external providers or user library files are involved.
@MainActor
enum MediaVerification {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func run(in root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let take = Take(folder: root.appendingPathComponent("fixture"))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        let silent = root.appendingPathComponent("source.mov")
        try await movie(at: silent, green: false)
        try await movie(at: take.cameraURL, green: true)
        let tone = root.appendingPathComponent("tone.wav")
        try audio(at: tone)
        print("Media check: fixture tracks generated; preparing source composition")
        let composition = AVMutableComposition()
        let sourceAsset = AVURLAsset(url: silent)
        let video = try await sourceAsset.loadTracks(withMediaType: .video)[0]
        let voiceAsset = AVURLAsset(url: tone)
        let voice = try await voiceAsset.loadTracks(withMediaType: .audio)[0]
        let duration = CMTime(seconds: 3, preferredTimescale: 600)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: voice, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure(message: "Couldn't create the fixture export session")
        }
        print("Media check: exporting source fixture with audio")
        try await session.export(to: take.screenURL, as: .mov)
        print("Media check: source fixture ready; preparing caption/camera export")
        try CameraTrack(cameraName: "Synthetic green camera", startOffset: 0,
                        placements: [.init(t: 0, x: 0.75, y: 0.1, size: 0.2)]).write(to: take.cameraInfoURL)
        try Transcript(language: "en", engine: "fixture", duration: 3,
                       segments: [.init(words: [
                        .init(id: 0, text: "Producer.", start: 0.2, end: 0.8),
                        .init(id: 1, text: "Workspace", start: 1.6, end: 2.2)
                       ])]).write(to: take.transcriptURL)
        try take.saveCaptionSettings(CaptionSettings(style: .subtitle))
        try EditList(sourceDuration: 3, cuts: [.init(span: TimeSpan(start: 1, end: 1.5))]).write(to: take.editsURL)
        let log = EventLog(displayWidth: 320, displayHeight: 180, events: [
            .init(kind: .leftDown, t: 0, x: 50, y: 90), .init(kind: .leftDown, t: 2, x: 280, y: 90)
        ])
        try log.write(to: take.eventsURL)

        try RecordedMix(voiceDB: -6, systemDB: -12).write(for: take)
        var exporter = VideoExporter(take: take, preset: .hd1080)
        exporter.clip = (.vertical, .follow)
        exporter.captionRingHex = 0x0000FF
        exporter.overlays = [VerificationOverlay()]
        print("Media check: rendering portrait MP4")
        let output = try await exporter.run(to: root.appendingPathComponent("portrait-with-captions.mp4")) { _ in }
        let warning = CaptionExport.writeFiles(for: take, video: output.url, timeline: output.timeline, offset: output.videoStart)
        try require(warning == nil, warning ?? "Subtitle writing failed")
        print("Media check: decoding rendered MP4 and sidecars")
        let asset = AVURLAsset(url: output.url)
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        let length = try await asset.load(.duration).seconds
        try require(Int(size.width) == 1080 && Int(size.height) == 1920, "Incorrect portrait dimensions")
        try require(abs(length - 2.5) < 0.1, "Accepted cut did not shorten the actual MP4")
        try require(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty, "Rendered audio track missing")
        let decodedAudio = try await TakeAudio.read(Take(folder: take.folder))
        try require(decodedAudio.samples.contains { abs($0) > 0.05 }, "Fixture audio is silent")
        let exportedAudio = try await audioPeak(asset)
        try require(exportedAudio > 0.08 && exportedAudio < 0.18, "Saved microphone level did not reach the rendered audio")
        let editor = EditorModel(take: take)
        await editor.loadIfNeeded()
        defer { editor.close() }
        guard let preview = editor.player.currentItem else { throw Failure(message: "Editor preview missing") }
        let previewPeak = try await audioPeak(preview.asset, mix: preview.audioMix)
        try require(abs(previewPeak - exportedAudio) < 0.03, "Saved source mix differs between preview and export")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let pixels = try analyse(image)
        let laterImage = try await generator.image(at: CMTime(seconds: 1.8, preferredTimescale: 600)).image
        let laterPixels = try analyse(laterImage)
        try require(pixels.red > pixels.blue && laterPixels.blue > laterPixels.red,
                    "Follow framing did not move from the red to blue source region")
        try save(laterImage, to: root.appendingPathComponent("portrait-later-frame.png"))
        try require(pixels.green > 1000, "Separate camera track missing from the rendered clip")
        try require(pixels.yellow > 500, "Brand-overlay hook missing from the rendered clip")
        try require(pixels.white > 100, "Caption glyphs missing from the rendered clip")
        try save(image, to: root.appendingPathComponent("portrait-frame.png"))
        let srt = output.url.deletingPathExtension().appendingPathExtension("srt")
        let subtitles = try String(contentsOf: srt, encoding: .utf8)
        try require(subtitles.contains("Producer") && subtitles.contains("Workspace"), "Subtitle words missing")
        try require(subtitles.contains("00:00:01,100"), "Subtitle times did not follow the accepted cut")

        // Invalid and silent media validation use the same AVFoundation path
        // the import UI uses, without creating an actual user task.
        let invalid = root.appendingPathComponent("invalid.mp4")
        try Data("not a video".utf8).write(to: invalid)
        do { try await VideoImporter.validate(invalid); throw Failure(message: "Invalid video accepted") }
        catch is Failure { throw Failure(message: "Invalid video accepted") }
        catch { /* expected AVFoundation rejection */ }
        try await VideoImporter.validate(silent)
        try await verifyStoppedMic()

        let report: [String: Any] = [
            "dimensions": [Int(size.width), Int(size.height)], "duration": length,
            "cameraGreenPixels": pixels.green, "brandYellowPixels": pixels.yellow,
            "captionWhitePixels": pixels.white, "earlyRedPixels": pixels.red, "laterBluePixels": laterPixels.blue, "decodedAudioPeak": exportedAudio, "previewAudioPeak": previewPeak,
            "checks": ["actual MP4 decode", "accepted-cut duration", "separate camera", "caption pixels", "brand overlay", "timed sidecars", "invalid import", "silent import", "stale mic start/callback"],
            "remaining": ["real capture and permissions", "native UI light/dark walkthrough", "human inspection of framing, caption placement and audible mix"]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("verification.json"), options: .atomic)
        print("Media verification passed; inspect verification.json, the MP4 and portrait-frame.png.")
    }

    private static func movie(at url: URL, green: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input)
        try require(writer.startWriting(), "Fixture writer failed")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw Failure(message: "No fixture pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<180 {
                for x in 0..<320 {
                    let p = y * stride + x * 4
                    pixels[p] = 255
                    pixels[p + 1] = green ? 0 : (x < 160 ? 150 : 30)
                    pixels[p + 2] = green ? 230 : 20
                    pixels[p + 3] = green ? 0 : (x < 160 ? 60 : 150)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Fixture frame failed")
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Fixture video failed")
    }
    private static func audio(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.25) }
        try file.write(from: buffer)
    }
    private static func audioPeak(_ asset: AVAsset, mix: AVAudioMix? = nil) async throws -> Double {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32
        ])
        output.audioMix = mix
        reader.add(output)
        try require(reader.startReading(), "Couldn't decode exported audio")
        var peak = 0.0
        while let buffer = output.copyNextSampleBuffer() { peak = max(peak, AudioSamples.peak(of: buffer) ?? 0) }
        try require(reader.status == .completed, "Exported audio decode failed")
        return peak
    }
    private static func analyse(_ image: CGImage) throws -> (green: Int, yellow: Int, white: Int, red: Int, blue: Int) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try data.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(message: "Couldn't decode frame pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var green = 0, yellow = 0, white = 0, red = 0, blue = 0
        let bytes = raw.bindMemory(to: UInt8.self)
        for p in stride(from: 0, to: raw.count, by: 4) {
            let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
            if g > 140 && g > r + 50 && g > b + 50 { green += 1 }
            if r > 180 && g > 180 && b < 80 { yellow += 1 }
            if r > 220 && g > 220 && b > 220 { white += 1 }
            if r > b + 30 && r > g + 30 { red += 1 }
            if b > r + 30 && b > g + 30 { blue += 1 }
        }
        return (green, yellow, white, red, blue)
        }
    }
    private static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "Couldn't save decoded frame")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Couldn't save decoded frame")
    }

    private static func verifyStoppedMic() async throws {
        let fake = VerificationMicProbe()
        let check = RecordingInputCheck(microphoneID: { _ in "fixture" }, hasAccess: { true }, makeProbe: { callback in
            fake.callback = callback
            return fake
        })
        var choice = CaptureChoice()
        choice.includeMicrophone = true
        let pending = Task { await check.testMicrophone(choice) }
        while !fake.started { await Task.yield() }
        check.cancel()
        fake.finish()
        await pending.value
        fake.callback?(1)
        await Task.yield()
        try require(!check.testing && check.level == 0, "Stopped microphone test revived or accepted a stale callback")
        try require(fake.stops > 0, "Stale microphone session was not stopped")
    }
}

private struct VerificationOverlay: ExportOverlay {
    func draw(in context: CGContext, size: CGSize, at outputTime: Double) {
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 60, height: 60))
    }
}

@MainActor
private final class VerificationMicProbe: PreparationMicSession {
    var callback: (@Sendable (Double) -> Void)?
    var started = false
    var stops = 0
    private var continuation: CheckedContinuation<Void, Error>?
    func start(_ id: String) async throws {
        try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; started = true }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func stop() async { stops += 1 }
}
