import AVFoundation
import Combine

/// Small frames of screen.mov for the timeline, made in the background.
/// Frames are kept by time (to a tenth of a second), so zooming in only
/// fetches the ones that are new.
@MainActor
final class FilmstripModel: ObservableObject {
    /// Goes up each time frames arrive, so the timeline knows to redraw.
    @Published private(set) var version = 0

    private var frames: [Int: CGImage] = [:]
    private var sortedKeys: [Int] = []
    private var requested = Set<Int>()
    private var queue: [Int] = []
    private var task: Task<Void, Never>?
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 120)
        // Close is good enough at this size, and much faster than exact.
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }

    static func key(_ t: Double) -> Int { max(0, Int((t * 10).rounded())) }

    /// Asks for frames at `times`, nearest the playhead first. Ones
    /// already made or on the way are skipped.
    func request(_ times: [Double], near playhead: Double) {
        let keys = times.map(Self.key).filter { !requested.contains($0) }
        guard !keys.isEmpty else { return }
        requested.formUnion(keys)
        let centre = Self.key(playhead)
        queue = (queue + keys).sorted { abs($0 - centre) < abs($1 - centre) }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        var arrived = 0
        while !Task.isCancelled, !queue.isEmpty {
            let key = queue.removeFirst()
            let time = CMTime(value: CMTimeValue(key), timescale: 10)
            if let image = try? await generator.image(at: time).image {
                insert(image, at: key)
                arrived += 1
                // Redraw in batches rather than once a frame.
                if arrived % 6 == 0 { version += 1 }
            }
        }
        version += 1
        task = nil
    }

    private func insert(_ image: CGImage, at key: Int) {
        if frames[key] == nil {
            let i = sortedKeys.firstIndex { $0 > key } ?? sortedKeys.count
            sortedKeys.insert(key, at: i)
        }
        frames[key] = image
    }

    /// The frame made so far that's closest to `t`.
    func frame(near t: Double) -> CGImage? {
        guard !sortedKeys.isEmpty else { return nil }
        let key = Self.key(t)
        if let exact = frames[key] { return exact }
        var low = 0, high = sortedKeys.count
        while low < high {
            let mid = (low + high) / 2
            if sortedKeys[mid] < key { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { sortedKeys.indices.contains($0) }.map { sortedKeys[$0] }
        guard let best = candidates.min(by: { abs($0 - key) < abs($1 - key) }) else { return nil }
        return frames[best]
    }

    func cancel() {
        task?.cancel()
        task = nil
        queue = []
    }
}
