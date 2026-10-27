import AVFoundation
import Foundation
import VisionOneKit

/// Reads what the Library lists for each take off disk: title, length,
/// where it's up to, what it's for and its words for search. Off the main
/// thread; lengths and transcripts are kept once read, since neither
/// changes after they land.
actor LibraryIndex {
    static let shared = LibraryIndex()

    private var durations: [URL: Double] = [:]
    private var transcripts: [URL: String] = [:]

    func items(for takes: [Take]) async -> [TakeListing] {
        var items: [TakeListing] = []
        items.reserveCapacity(takes.count)
        for take in takes {
            items.append(await item(for: take))
        }
        return items
    }

    private func item(for take: Take) async -> TakeListing {
        let fileManager = FileManager.default
        let edits = try? EditList.read(from: take.editsURL)
        let isExported = ExportPreset.allCases.contains {
            fileManager.fileExists(atPath: take.exportURL(for: $0).path)
        }
        let purpose = TakePlan.load(for: take).flatMap { Purpose.named($0.purposeID) }
        return TakeListing(
            take: take,
            title: take.displayTitle(fileManager: fileManager),
            recordedAt: take.recordedAt(),
            duration: await duration(of: take),
            isExported: isExported,
            suggestedCuts: edits?.cuts.filter { $0.state == .proposed }.count ?? 0,
            transcriptText: transcript(of: take),
            purposeTitle: purpose?.title
        )
    }

    private func duration(of take: Take) async -> Double? {
        if let known = durations[take.folder] { return known }
        let seconds = (try? await AVURLAsset(url: take.screenURL).load(.duration))?.seconds ?? 0
        guard seconds.isFinite, seconds > 0 else { return nil }
        // A take still being written grows; only keep finished lengths.
        if FileManager.default.fileExists(atPath: take.transcriptURL.path)
            || FileManager.default.fileExists(atPath: take.transcriptFailedURL.path) {
            durations[take.folder] = seconds
        }
        return seconds
    }

    private func transcript(of take: Take) -> String? {
        if let known = transcripts[take.folder] { return known }
        guard let text = (try? Transcript.read(from: take.transcriptURL))?.text else { return nil }
        transcripts[take.folder] = text
        return text
    }
}

/// First frames, made once per launch and kept in memory so scrolling and
/// coming back to the Library stay instant.
@MainActor
final class LibraryPreviews {
    static let shared = LibraryPreviews()

    private var firstFrames: [URL: CGImage] = [:]

    func firstFrame(for take: Take) async -> CGImage? {
        if let cached = firstFrames[take.folder] { return cached }
        let image = await Self.frame(of: take, at: .zero)
        // A take still being written has no frame yet: try again next time.
        if let image { firstFrames[take.folder] = image }
        return image
    }

    private static func frame(of take: Take, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.screenURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 300)
        // Near enough is fine while scrubbing, and much faster.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return try? await generator.image(at: time).image
    }
}
