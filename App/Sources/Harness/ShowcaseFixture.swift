import AppKit
import AVFoundation
import VisionOneKit

/// A calm, realistic take for the workspace renders: a 2:14 walkthrough of
/// a light project-management app on a soft background, six timestamped
/// paragraphs, suggested pause and filler cuts, a click zoom, captions and
/// two clips, so renders can be compared with the approved pictures.
/// Verification only; nothing here touches the user's library.
@MainActor
enum ShowcaseFixture {
    static let duration = 134.0
    static let paragraphs: [(start: Double, text: String)] = [
        (0, "Hey everyone. In this video, I'll give you a quick walkthrough of Acme and show you how to create a new project from start to finish."),
        (7, "We'll cover the main pieces, including projects, tasks, and how to invite your team. Um, let's start."),
        (24, "Here on the Projects page, you can see all of your active work. I'll click New project to get started."),
        (38, "You can give it a name, add a description, and choose a template if you want to move faster."),
        (52, "Once the project is created, you can add tasks, set due dates, and uh, invite teammates to collaborate."),
        (70, "Each task has an owner and a due date, so everyone knows what's next. That's the whole flow. Thanks for watching."),
    ]

    static func make(in root: URL) async throws -> Take {
        let folder = root.appendingPathComponent("Vision One \(stamp()) - Product walkthrough")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let take = Take(folder: folder)
        let words = transcriptWords()
        do {
            try await writeMovie(to: take.screenURL, words: words)
        } catch {
            throw MediaVerification.Failure(message: "Showcase movie failed: \(error)")
        }
        try TakeAudioTracks(tracks: [.mic]).write(to: take.audioTracksURL)
        try take.setTitle("Product walkthrough")
        try Transcript(language: "en", engine: "workspace fixture", duration: duration,
                       segments: segments(words)).write(to: take.transcriptURL)
        try LoudnessEnvelope(hop: 0.01, levels: levels(words)).write(to: take.levelsURL)
        try take.saveCaptionSettings(CaptionSettings(style: .subtitle))
        try RecordedMix(voiceDB: -6, systemDB: -12).write(for: take)
        // Four long pauses and two fillers, still dashed.
        var cuts = [(19.0, 21.4), (33.6, 35.8), (47.9, 50.6), (64.0, 67.2)].map {
            Cut(span: TimeSpan(start: $0.0, end: $0.1), reason: Cut.Reason.pause, state: .proposed)
        }
        for filler in words where ["Um,", "uh,"].contains(filler.text) {
            cuts.append(Cut(span: TimeSpan(start: filler.start, end: filler.end), reason: Cut.Reason.filler, state: .proposed))
        }
        try EditList(sourceDuration: duration, cuts: cuts).write(to: take.editsURL)
        try ZoomList(zooms: [Zoom(span: TimeSpan(start: 26, end: 31), scale: 1.6, centerX: 0.62, centerY: 0.3,
                                  reason: Zoom.Reason.click, state: .proposed)]).write(to: take.zoomsURL)
        try ClipList(clips: [
            Clip(title: "Create a new project", hook: "Shows the Projects page and how to get started.",
                 span: TimeSpan(start: 24, end: 54), state: .accepted),
            Clip(title: "Add tasks and invite", hook: "Covers tasks, due dates, and inviting your team.",
                 span: TimeSpan(start: 70, end: 98)),
        ]).write(to: take.clipsURL)
        return take
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let today = Calendar.current.date(bySettingHour: 16, minute: 48, second: 0, of: Date()) ?? Date()
        return formatter.string(from: today)
    }

    // MARK: Words

    private static func transcriptWords() -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let end = index + 1 < paragraphs.count ? paragraphs[index + 1].start - 1.5 : duration - 4
            let parts = paragraph.text.split(separator: " ").map(String.init)
            let step = min(0.42, (end - paragraph.start) / Double(parts.count))
            for (i, part) in parts.enumerated() {
                let start = paragraph.start + 0.3 + Double(i) * step
                words.append(TranscriptWord(id: words.count, text: part, start: start, end: start + step * 0.85))
            }
        }
        return words
    }

    private static func segments(_ words: [TranscriptWord]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var index = 0
        for paragraph in paragraphs {
            let count = paragraph.text.split(separator: " ").count
            result.append(TranscriptSegment(words: Array(words[index..<(index + count)])))
            index += count
        }
        return result
    }

    private static func levels(_ words: [TranscriptWord]) -> [Float] {
        let count = Int(duration / 0.01)
        var levels = [Float](repeating: -60, count: count)
        for word in words {
            let a = Int(word.start / 0.01), b = min(count, Int(word.end / 0.01))
            guard a < b else { continue }
            for i in a..<b {
                let phase = Double(i - a) / Double(b - a)
                levels[i] = Float(-30 + 22 * sin(phase * .pi) + Double((i * 7919) % 6))
            }
        }
        return levels
    }

    // MARK: Media

    /// One pass, one writer: a frame a second of the app window and 16 kHz
    /// speech-shaped tones, so it stays cheap on a CI VM with no hardware
    /// encoder (no export session, no re-encode). Every wait is bounded.
    private static func writeMovie(to url: URL, words: [TranscriptWord]) async throws {
        let width = 1280, height = 800, rate = 16_000
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ])
        writer.add(video)
        writer.add(audio)
        try MediaVerification.require(writer.startWriting(), "Showcase writer failed: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw MediaVerification.Failure(message: "No showcase audio format") }
        let samples = voiceSamples(words: words, rate: rate)

        func ready(_ input: AVAssetWriterInput) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    throw MediaVerification.Failure(message: "Showcase writer stalled: \(String(describing: writer.error))")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        let seconds = Int(duration)
        for second in 0..<seconds {
            try await ready(video)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw MediaVerification.Failure(message: "No showcase pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.scaleBy(x: CGFloat(width) / 1440, y: CGFloat(height) / 900)
                draw(in: context, size: CGSize(width: 1440, height: 900), second: Double(second))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try MediaVerification.require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(second) * 600, timescale: 600)),
                                          "Showcase frame failed")
            // The second of sound that goes with this frame.
            let start = second * rate
            let end = min(samples.count, start + rate)
            guard start < end else { continue }
            try await ready(audio)
            let data = samples[start..<end].withUnsafeBytes { Data($0) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                               flags: 0, blockBufferOut: &block)
            guard let block else { throw MediaVerification.Failure(message: "No showcase audio block") }
            _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                       offsetIntoDestination: 0, dataLength: data.count) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: end - start,
                                                                 presentationTimeStamp: CMTime(value: Int64(start), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample else { throw MediaVerification.Failure(message: "No showcase audio sample") }
            try MediaVerification.require(audio.append(sample), "Showcase audio failed: \(String(describing: writer.error))")
        }
        video.markAsFinished()
        audio.markAsFinished()
        await writer.finishWriting()
        try MediaVerification.require(writer.status == .completed, "Showcase movie failed: \(String(describing: writer.error))")
    }

    private static func voiceSamples(words: [TranscriptWord], rate: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: Int(duration) * rate)
        for word in words {
            let a = Int(word.start * Double(rate)), b = min(samples.count, Int(word.end * Double(rate)))
            guard a < b else { continue }
            for i in a..<b {
                let t = Double(i) / Double(rate)
                let envelope = sin(Double(i - a) / Double(b - a) * .pi)
                let value = envelope * 0.3 * (sin(2 * .pi * 180 * t) + 0.4 * sin(2 * .pi * 360 * t))
                samples[i] = Int16(max(-1, min(1, value)) * 32_000)
            }
        }
        return samples
    }

    /// A light app window on a soft blue-grey backdrop: sidebar, Projects
    /// heading, New project and three project rows. The hovered row and
    /// the cursor move along with what's being said.
    private static func draw(in context: CGContext, size: CGSize, second: Double) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let backdrop = NSGradient(colors: [NSColor(red: 0.80, green: 0.85, blue: 0.93, alpha: 1),
                                           NSColor(red: 0.93, green: 0.90, blue: 0.88, alpha: 1)])
        backdrop?.draw(in: CGRect(origin: .zero, size: size), angle: 300)

        let window = CGRect(x: 160, y: 90, width: 1120, height: 720)
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: window.offsetBy(dx: 0, dy: 10), xRadius: 18, yRadius: 18).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: window, xRadius: 16, yRadius: 16).fill()
        let sidebar = CGRect(x: window.minX, y: window.minY, width: 240, height: window.height)
        NSColor(white: 0.965, alpha: 1).setFill()
        NSBezierPath(roundedRect: sidebar, xRadius: 16, yRadius: 16).fill()
        NSBezierPath(rect: CGRect(x: sidebar.maxX - 20, y: sidebar.minY, width: 20, height: sidebar.height)).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + 22 + CGFloat(i) * 22, y: window.minY + 22, width: 13, height: 13)).fill()
        }
        let items = ["Home", "Projects", "Tasks", "Calendar", "People", "Settings"]
        for (i, item) in items.enumerated() {
            let row = CGRect(x: sidebar.minX + 16, y: sidebar.minY + 70 + CGFloat(i) * 46, width: 208, height: 36)
            if item == "Projects" {
                NSColor(white: 0.88, alpha: 1).setFill()
                NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
            }
            text(item, at: CGPoint(x: row.minX + 16, y: row.minY + 9), size: 16, weight: item == "Projects" ? .semibold : .regular)
        }
        let content = CGPoint(x: sidebar.maxX + 48, y: window.minY + 54)
        text("Projects", at: content, size: 30, weight: .bold)
        let button = CGRect(x: window.maxX - 200, y: content.y, width: 150, height: 42)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: button, xRadius: 10, yRadius: 10).fill()
        text("New project", at: CGPoint(x: button.minX + 26, y: button.minY + 11), size: 16, weight: .semibold, color: .white)
        let search = CGRect(x: content.x, y: content.y + 64, width: 320, height: 40)
        NSColor(white: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: search, xRadius: 8, yRadius: 8).fill()
        text("Search projects…", at: CGPoint(x: search.minX + 16, y: search.minY + 11), size: 15, color: NSColor(white: 0.55, alpha: 1))
        let projects = [("Website redesign", "12 tasks · Due Nov 12"), ("Mobile app", "8 tasks · Due Nov 3"),
                        ("Marketing campaign", "6 tasks · Due Nov 20")]
        let hovered = second < 24 ? -1 : Int(second / 20) % 3
        for (i, project) in projects.enumerated() {
            let row = CGRect(x: content.x, y: content.y + 136 + CGFloat(i) * 112, width: window.maxX - 48 - content.x, height: 96)
            (i == hovered ? NSColor(white: 0.955, alpha: 1) : .white).setFill()
            let path = NSBezierPath(roundedRect: row, xRadius: 12, yRadius: 12)
            path.fill()
            NSColor(white: 0.88, alpha: 1).setStroke()
            path.stroke()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: row.minX + 22, y: row.minY + 24, width: 48, height: 48), xRadius: 10, yRadius: 10).fill()
            text(project.0, at: CGPoint(x: row.minX + 92, y: row.minY + 24), size: 18, weight: .semibold)
            text(project.1, at: CGPoint(x: row.minX + 92, y: row.minY + 52), size: 14, color: NSColor(white: 0.5, alpha: 1))
        }
        // The cursor drifts between the rows and the New project button.
        let target = second < 24 ? CGPoint(x: button.midX, y: button.maxY + 8)
            : CGPoint(x: content.x + 640, y: content.y + 180 + CGFloat(max(hovered, 0)) * 112)
        let cursor = NSBezierPath()
        cursor.move(to: target)
        cursor.line(to: CGPoint(x: target.x, y: target.y + 26))
        cursor.line(to: CGPoint(x: target.x + 7, y: target.y + 20))
        cursor.line(to: CGPoint(x: target.x + 18, y: target.y + 19))
        cursor.close()
        NSColor.black.setFill()
        cursor.fill()
        NSColor.white.setStroke()
        cursor.lineWidth = 1.5
        cursor.stroke()
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor = NSColor(white: 0.12, alpha: 1)) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]).draw(at: point)
    }
}
