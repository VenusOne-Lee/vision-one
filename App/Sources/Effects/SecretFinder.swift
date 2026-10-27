import AVFoundation
import CoreGraphics
import Vision
import VisionOneKit

/// Reads the text on screen a few times a second with Vision, on the Mac,
/// and hands anything `SecretScanner` flags to `BlurPlanner`. Nothing
/// leaves the Mac and the secrets themselves are never saved.
enum SecretFinder {
    /// Seconds between frames read. Every blur reaches past the frames on
    /// either side, so a key that shows for less than this can still slip
    /// through; the editor says so and lets you draw a blur by hand.
    static let interval = 0.5

    /// Scans the take and returns proposed blurs. `progress` gets 0...1 on
    /// the main actor.
    static func scan(_ take: Take, progress: @escaping @MainActor (Double) -> Void) async throws -> [Blur] {
        let asset = AVURLAsset(url: take.screenURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: interval / 4, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var samples: [SecretSample] = []
        var last: (thumbnail: [UInt8], hits: [SecretSample.Hit])?
        var t = 0.0
        while t < duration {
            try Task.checkCancellation()
            let (image, actual) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let thumbnail = Self.thumbnail(of: image)
            let hits: [SecretSample.Hit]
            // Screen recordings sit still most of the time; a frame where
            // no pixel of the small copy changed has the same text. Any
            // change at all (a key being typed, a scroll) reads it again.
            if let last, let thumbnail, Self.largestChange(thumbnail, last.thumbnail) <= 3 {
                hits = last.hits
            } else {
                hits = try Self.read(image)
            }
            if let thumbnail { last = (thumbnail, hits) } else { last = nil }
            samples.append(SecretSample(t: actual.seconds, hits: hits))
            let done = min(1, t / duration)
            await progress(done)
            t += interval
        }
        await progress(1)
        return BlurPlanner.propose(from: samples, interval: interval, sourceDuration: duration)
    }

    /// Recognises the text in one frame and keeps only what looks secret.
    static func read(_ image: CGImage) throws -> [SecretSample.Hit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" keys into words; read them as is.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        var hits: [SecretSample.Hit] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for match in SecretScanner.find(in: candidate.string) {
                // Vision's boxes are 0...1 with the origin bottom left.
                let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                let rect = FrameRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                hits.append(SecretSample.Hit(kind: match.kind, rect: rect,
                                             fingerprint: String(candidate.string[match.range]).hashValue))
            }
        }
        return hits
    }

    /// A 320 x 180 grey copy of the frame, to tell whether it changed.
    static func thumbnail(of image: CGImage) -> [UInt8]? {
        let width = 320, height = 180
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The biggest change of any one pixel, 0...255.
    static func largestChange(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return .max }
        var largest = 0
        for i in a.indices { largest = max(largest, abs(Int(a[i]) - Int(b[i]))) }
        return largest
    }
}
