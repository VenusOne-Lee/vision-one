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
        try TakeAudioTracks(tracks: [.mic]).write(to: take.audioTracksURL)
        try CameraTrack(cameraName: "Synthetic green camera", startOffset: 0.2,
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
        exporter.trace = { print("Media export stage: \($0)") }
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
        let earlyImage = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        try require(try analyse(earlyImage).green == 0, "Camera appeared before its recorded start offset")
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
        try await verifyOtherOutputs(take: take, silent: silent, in: root)
        try await TranscriptViewVerification.verifySilentSource(silent, in: root)
        try await verifyRotatedImport(silent, in: root)
        try await verifyStoppedMic()
        let sourcePeaks = try await verifySeparateSourceLevels(video: silent, in: root)
        try await CardVerification.run(in: root)
        try await verifyOwnedTemplateCard(source: take, in: root)

        let report: [String: Any] = [
            "dimensions": [Int(size.width), Int(size.height)], "duration": length,
            "separateSourcePeaks": sourcePeaks,
            "cameraGreenPixels": pixels.green, "brandYellowPixels": pixels.yellow,
            "captionWhitePixels": pixels.white, "earlyRedPixels": pixels.red, "laterBluePixels": laterPixels.blue, "decodedAudioPeak": exportedAudio, "previewAudioPeak": previewPeak,
            "checks": ["actual MP4 decode", "accepted-cut duration", "separate camera", "caption pixels", "brand overlay", "timed sidecars", "invalid import", "silent import", "stale mic start/callback", "square and 4:5 MP4 dimensions", "manual fixed framing", "fit framing", "silent import edit/undo/redo/export", "camera late-start gap", "rotated import matches native orientation", "independent microphone/system levels and preview/export agreement", "applied template owned HTML asset renders with timed captions and camera after intro", "compiled WebKit offline rules with reachable loopback control and blocked subresource", "painted animated card retained with flat final frame"],
            "remaining": ["real capture and permissions", "native UI light/dark walkthrough", "human inspection of framing, caption placement and audible mix"]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("verification.json"), options: .atomic)
        print("Media verification passed; inspect verification.json, the MP4 and portrait-frame.png.")
    }

    /// Applying a reusable style must affect the real deliverable, even after
    /// its original library folder is removed. Exercise a relative HTML asset.
    private static func verifyOwnedTemplateCard(source: Take, in root: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let library = root.appendingPathComponent("template-library")
        let template = library.appendingPathComponent("fixture-card")
        let assets = template.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let look = TemplateLook(id: "fixture-card", title: "Owned card", summary: "Native render fixture", purposeID: "short",
                                intro: .file("intro.html"), outro: .off,
                                formats: [.init(.vertical, reframe: .follow)], captionStyle: .subtitle, watermark: false)
        try look.save(to: template)
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100' preserveAspectRatio='none'><rect width='100' height='100' fill='#ffff00'/><rect y='90' width='100' height='10' fill='#0000ff'/></svg>".utf8)
            .write(to: assets.appendingPathComponent("paper.svg"))
        try Data("<html><head><style>html,body{margin:0;width:100%;height:100%;background:#000}img{width:100%;height:100%;object-fit:fill}</style></head><body><img src='assets/paper.svg'></body></html>".utf8)
            .write(to: template.appendingPathComponent("intro.html"))
        let take = Take(folder: root.appendingPathComponent("template-take"))
        try FileManager.default.copyItem(at: source.folder, to: take.folder)
        try AppliedTemplate.apply(id: look.id, to: take, overwrite: true, root: library)
        try FileManager.default.removeItem(at: template)
        let brand = BrandKit(name: "Fixture", intro: BrandCard(enabled: true, duration: 1))
        let maker = CardMaker(brand: brand, brandFolder: root, look: nil, templateFolder: nil)
        var exporter = VideoExporter(take: take, preset: .hd720)
        exporter.clip = (.vertical, .follow)
        exporter.cards = maker
        exporter.captionRingHex = 0x0000FF
        let output = try await exporter.run(to: root.appendingPathComponent("owned-template-card.mp4")) { _ in }
        try require(abs(output.videoStart - 1) < 0.05, "Applied template intro was not included in the clip render")
        let asset = AVURLAsset(url: output.url)
        try require(abs(try await asset.load(.duration).seconds - 3.5) < 0.1, "Template card/cut duration is incorrect")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let intro = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let colours = try analyse(intro)
        try require(colours.yellow > intro.width * intro.height * 8 / 10,
                    "Owned HTML card asset did not reach the rendered MP4 (native fallback is not equivalent)")
        let body = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        let bodyColours = try analyse(body)
        try require(bodyColours.green > 1000 && bodyColours.white > 1000,
                    "Camera/captions were lost or mistimed after template intro")
        try require(CaptionExport.writeFiles(for: take, video: output.url, timeline: output.timeline, offset: output.videoStart) == nil,
                    "Template clip subtitle write failed")
        let srt = try String(contentsOf: output.url.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
        try require(srt.contains("00:00:01,200"), "Subtitle clock did not include the applied intro")
        try save(intro, to: root.appendingPathComponent("owned-template-intro.png"))
        try save(body, to: root.appendingPathComponent("owned-template-body.png"))
    }

    private static func verifySeparateSourceLevels(video: URL, in root: URL) async throws -> [String: Double] {
        let take = Take(folder: root.appendingPathComponent("separate-source-levels"))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        let micURL = take.folder.appendingPathComponent("mic.wav")
        let systemURL = take.folder.appendingPathComponent("system.wav")
        try audio(at: micURL)
        try audio(at: systemURL, frequency: 660, amplitude: 0.1)
        let screen = AVURLAsset(url: video)
        let mic = AVURLAsset(url: micURL)
        let system = AVURLAsset(url: systemURL)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        let videoTrack = try await screen.loadTracks(withMediaType: .video)[0]
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        // Deliberately put system first: microphone identity must use metadata.
        for asset in [system, mic] {
            let track = try await asset.loadTracks(withMediaType: .audio)[0]
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: track, at: .zero)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(message: "Couldn't create separate source-level fixture")
        }
        try await session.export(to: take.screenURL, as: .mov)
        try require(try await AVURLAsset(url: take.screenURL).loadTracks(withMediaType: .audio).count == 2,
                    "Source-level fixture did not retain two separate audio tracks")
        try TakeAudioTracks(tracks: [.system, .mic]).write(to: take.audioTracksURL)
        var peaks: [String: Double] = [:]
        for systemOnly in [true, false] {
            let name = systemOnly ? "system" : "microphone"
            try RecordedMix(voiceDB: systemOnly ? -60 : 0, systemDB: systemOnly ? 0 : -60).write(for: take)
            let output = try await VideoExporter(take: take, preset: .hd720)
                .run(to: root.appendingPathComponent("source-level-\(name).mp4")) { _ in }
            let peak = try await audioPeak(AVURLAsset(url: output.url))
            let expected = systemOnly ? 0.07...0.14 : 0.2...0.32
            try require(expected.contains(peak), "Wrong source level/identity in \(name) export: \(peak)")
            let editor = EditorModel(take: take)
            await editor.loadIfNeeded()
            defer { editor.close() }
            guard let item = editor.player.currentItem else { throw Failure(message: "Separate-source preview missing") }
            let preview = try await audioPeak(item.asset, mix: item.audioMix)
            try require(abs(preview - peak) < 0.03, "Separate \(name) level differs between preview/export")
            peaks[name + "Export"] = peak
            peaks[name + "Preview"] = preview
        }
        return peaks
    }

    private static func verifyOtherOutputs(take: Take, silent: URL, in root: URL) async throws {
        for preset in [ExportPreset.square, .portrait] {
            var exporter = VideoExporter(take: take, preset: preset)
            exporter.captionRingHex = 0x0000FF
            let output = try await exporter.run(to: root.appendingPathComponent("\(preset.rawValue).mp4")) { _ in }
            let track = try await AVURLAsset(url: output.url).loadTracks(withMediaType: .video)[0]
            let size = try await track.load(.naturalSize)
            let expectedHeight = preset == .square ? 1080 : 1350
            try require(Int(size.width) == 1080 && Int(size.height) == expectedHeight, "Incorrect \(preset.rawValue) dimensions")
        }
        for mode in [ClipFraming.Mode.fixed, .fit] {
            var exporter = VideoExporter(take: take, preset: .hd1080)
            exporter.clip = (.vertical, ClipFraming(mode: mode, centerX: 0.8, centerY: 0.5))
            let output = try await exporter.run(to: root.appendingPathComponent("\(mode.rawValue)-portrait.mp4")) { _ in }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output.url))
            let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            let pixels = try analyse(image)
            if mode == .fixed { try require(pixels.blue > pixels.red, "Manual fixed framing was not preserved") }
            else { try require(pixels.blue > 1000 && pixels.red > 1000, "Fit framing cropped part of the original screen") }
            try save(image, to: root.appendingPathComponent("\(mode.rawValue)-portrait-frame.png"))
        }

        let imported = try VideoImport.copy(silent, into: TakeLibrary(folder: root.appendingPathComponent("imported")))
        Transcriber.shared.transcribe(imported)
        while Transcriber.shared.isWorking(on: imported) { try await Task.sleep(for: .milliseconds(10)) }
        let editor = EditorModel(take: imported)
        await editor.loadIfNeeded()
        defer { editor.close() }
        try require(editor.phase == .ready, "Silent imported video could not open in the editor")
        guard case .failed = editor.transcriptState else { throw Failure(message: "Silent import did not explain its missing transcript") }
        editor.selection = TimeSpan(start: 0.5, end: 1)
        editor.cutSelection()
        try require(abs(editor.edits.outputDuration - 2.5) < 0.1 && editor.undoManager.canUndo, "Silent import timeline editing failed")
        editor.undoManager.undo()
        try require(abs(editor.edits.outputDuration - 3) < 0.1, "Silent import cut undo failed")
        editor.undoManager.redo()
        try require(abs(editor.edits.outputDuration - 2.5) < 0.1, "Silent import cut redo failed")
        let output = try await VideoExporter(take: imported, preset: .hd720)
            .run(to: root.appendingPathComponent("silent-import-edited.mp4")) { _ in }
        let asset = AVURLAsset(url: output.url)
        try require(try await asset.loadTracks(withMediaType: .audio).isEmpty, "Silent import unexpectedly gained an audio track")
        try require(abs(try await asset.load(.duration).seconds - 2.5) < 0.1, "Silent imported-video export ignored the edit")
    }

    private static func verifyRotatedImport(_ source: URL, in root: URL) async throws {
        let folder = root.appendingPathComponent("rotated")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let take = Take(folder: folder)
        let asset = AVURLAsset(url: source)
        let sourceTrack = try await asset.loadTracks(withMediaType: .video)[0]
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(message: "Couldn't create rotated fixture")
        }
        try track.insertTimeRange(try await sourceTrack.load(.timeRange), of: sourceTrack, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(message: "Couldn't create rotated fixture export")
        }
        try await session.export(to: take.screenURL, as: .mov)
        try await VideoImporter.validate(take.screenURL)
        let expectedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: take.screenURL))
        expectedGenerator.appliesPreferredTrackTransform = true
        let expected = try await expectedGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let output = try await VideoExporter(take: take, preset: .hd720)
            .run(to: root.appendingPathComponent("rotated-import.mp4")) { _ in }
        let actualGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: output.url))
        actualGenerator.appliesPreferredTrackTransform = true
        let actual = try await actualGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        try save(expected, to: root.appendingPathComponent("rotated-source-frame.png"))
        try save(actual, to: root.appendingPathComponent("rotated-export-frame.png"))
        try require(actual.width == expected.width && actual.height == expected.height,
                    "Rotated import export has incorrect dimensions")
        let nativeColours = try signature(expected)
        let renderedColours = try signature(actual)
        try require(zip(nativeColours, renderedColours).allSatisfy { abs($0.0 - $0.1) < 35 },
                    "Rotated import orientation differs from native AVFoundation preview")
    }

    private static func signature(_ image: CGImage) throws -> [Int] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "Couldn't inspect orientation") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = raw.bindMemory(to: UInt8.self)
            var colours: [Int] = []
            for y in [image.height / 4, image.height * 3 / 4] {
                for x in [image.width / 4, image.width * 3 / 4] {
                    let p = (y * image.width + x) * 4
                    colours += [Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2])]
                }
            }
            return colours
        }
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
    private static func audio(at url: URL, frequency: Double = 440, amplitude: Double = 0.25) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * frequency / 48_000) * amplitude) }
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
