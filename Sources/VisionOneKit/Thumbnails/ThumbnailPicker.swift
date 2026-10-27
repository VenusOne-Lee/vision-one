import Foundation

/// Picks the frames worth offering as a thumbnail. The app grabs each
/// candidate frame and measures it with Apple Vision and Core Image;
/// this decides where to look and how to rank what it measured.
public struct ThumbnailPicker: Sendable {
    /// What the app measured on one frame.
    public struct Metrics: Equatable, Sendable {
        /// Seconds of the take.
        public var time: Double
        /// 0...1, edge contrast. Blurry or mid-scroll frames score low.
        public var sharpness: Double
        /// 0...1 from Vision's face capture quality, or nil without a face.
        public var faceQuality: Double?
        /// 0...1 mean brightness.
        public var brightness: Double
        /// How far the cursor moved around this moment, in screen widths
        /// per second. A rushing cursor means a frame in transition.
        public var cursorSpeed: Double
        /// Seconds to the nearest cut in the edited video.
        public var distanceFromCut: Double

        public init(time: Double, sharpness: Double, faceQuality: Double? = nil, brightness: Double = 0.5,
                    cursorSpeed: Double = 0, distanceFromCut: Double = .infinity) {
            self.time = time
            self.sharpness = sharpness
            self.faceQuality = faceQuality
            self.brightness = brightness
            self.cursorSpeed = cursorSpeed
            self.distanceFromCut = distanceFromCut
        }

        /// 0...1, higher is a better thumbnail.
        public var score: Double {
            let face = faceQuality ?? 0.3
            let exposure = max(0, 1 - abs(brightness - 0.55) * 2)
            let still = max(0, 1 - cursorSpeed * 2)
            let awayFromCut = min(1, distanceFromCut / 1.0)
            return 0.4 * sharpness + 0.25 * face + 0.15 * exposure + 0.1 * still + 0.1 * awayFromCut
        }
    }

    /// How many frames to measure.
    public var sampleCount = 16
    /// How many to offer.
    public var offerCount = 5
    /// Offered frames are at least this far apart, so the five look
    /// different.
    public var minSeparation = 3.0
    /// Frames this close to a cut are moved away from it.
    public var cutMargin = 0.5

    public init() {}

    /// Moments to measure, in seconds of the take: spread evenly across
    /// the edited video, nudged away from cuts and the very start and
    /// end. Skips the first and last 5% where people say hello and reach
    /// for the stop button.
    public func sampleTimes(edits: EditList) -> [Double] {
        let duration = edits.outputDuration
        guard duration > 0, sampleCount > 0 else { return [] }
        let lead = duration * 0.05
        let usable = duration - 2 * lead
        var times: [Double] = []
        for k in 0..<sampleCount {
            let output = lead + usable * (Double(k) + 0.5) / Double(sampleCount)
            let source = edits.sourceTime(forOutput: output)
            times.append(awayFromCuts(source, edits: edits))
        }
        var seen = Set<Int>()
        return times.filter { seen.insert(Int(($0 * 10).rounded())).inserted }
    }

    /// The best `offerCount` frames, best first, at least
    /// `minSeparation` apart.
    public func rank(_ metrics: [Metrics]) -> [Metrics] {
        var picks: [Metrics] = []
        for m in metrics.sorted(by: { $0.score > $1.score }) {
            guard picks.count < offerCount else { break }
            guard !picks.contains(where: { abs($0.time - m.time) < minSeparation }) else { continue }
            picks.append(m)
        }
        return picks
    }

    /// Seconds from `t` to the nearest edge of the kept span it sits in.
    public func distanceFromCut(_ t: Double, edits: EditList) -> Double {
        let joins = edits.keptSpans.flatMap { [$0.start, $0.end] }
            .filter { $0 > 0 && $0 < edits.sourceDuration }
        return joins.map { abs($0 - t) }.min() ?? .infinity
    }

    /// Cursor speed around `t` in screen widths per second, over a
    /// window of `window` seconds.
    public static func cursorSpeed(at t: Double, events: EventLog, window: Double = 0.5) -> Double {
        guard events.displayWidth > 0 else { return 0 }
        let near = events.events.filter { abs($0.t - t) <= window / 2 }
        guard near.count > 1 else { return 0 }
        var distance = 0.0
        for (a, b) in zip(near, near.dropFirst()) {
            let dx = (b.x - a.x) / events.displayWidth
            let dy = (b.y - a.y) / events.displayWidth
            distance += (dx * dx + dy * dy).squareRoot()
        }
        return distance / window
    }

    private func awayFromCuts(_ t: Double, edits: EditList) -> Double {
        guard let span = edits.keptSpans.first(where: { $0.start <= t && t <= $0.end }) else { return t }
        guard span.duration > 2 * cutMargin else { return (span.start + span.end) / 2 }
        return min(max(t, span.start + cutMargin), span.end - cutMargin)
    }
}
