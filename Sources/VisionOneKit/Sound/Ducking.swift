import Foundation

/// How music gets out of the way of the voice. Vision One already knows
/// when you speak from the transcript, so it draws the volume curve
/// ahead of time instead of listening with a compressor: the preview
/// and the export sound the same, and the dips can be drawn.
public struct DuckingSettings: Equatable, Sendable {
    /// Seconds the music starts dipping before a word.
    public var lead: Double
    /// Seconds it takes to come back after the last word.
    public var release: Double
    /// Gaps shorter than this between words stay ducked, so the music
    /// doesn't pump on every breath. Never shorter than lead + release.
    public var bridge: Double
    /// Extra dB taken off a sound effect that lands on speech.
    public var effectDuckDB: Double

    public init(lead: Double = 0.25, release: Double = 0.6, bridge: Double = 0.8, effectDuckDB: Double = 6) {
        self.lead = lead
        self.release = release
        self.bridge = bridge
        self.effectDuckDB = effectDuckDB
    }
}

public enum Speech {
    /// Where someone is talking in the edited video, in output seconds.
    /// Each word's kept part is mapped through the cuts, and words closer
    /// than `bridge` are joined.
    public static func outputRegions(words: [TimeSpan], timeline: ExportTimeline, bridge: Double) -> [TimeSpan] {
        var pieces: [TimeSpan] = []
        for word in words where word.end > word.start {
            for segment in timeline.segments {
                let lower = max(word.start, segment.source.lowerBound)
                let upper = min(word.end, segment.source.upperBound)
                guard upper > lower else { continue }
                let offset = segment.outputStart - segment.source.lowerBound
                pieces.append(TimeSpan(start: lower + offset, end: upper + offset))
            }
        }
        pieces.sort { $0.start < $1.start }
        var merged: [TimeSpan] = []
        for piece in pieces {
            if let last = merged.last, piece.start - last.end <= bridge {
                merged[merged.count - 1].end = max(last.end, piece.end)
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    /// True when `span` touches any of the (sorted) regions.
    static func overlaps(_ span: TimeSpan, _ regions: [TimeSpan]) -> Bool {
        regions.contains { $0.overlaps(span) }
    }
}

/// The music bed's volume over the edited video: its level, dipped
/// under speech, faded in at the start and out at the end. Points are
/// joined by straight lines in gain, which is how AVAudioMix ramps.
public struct MusicEnvelope: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var time: Double
        /// Linear gain, 1 = as the file was made.
        public var gain: Float
    }

    public let points: [Point]

    public init(points: [Point]) {
        self.points = points
    }

    /// - Parameters:
    ///   - duration: length of the edited video.
    ///   - speech: speech regions in output seconds, from `Speech.outputRegions`.
    public init(duration: Double, bed: MusicBed, speech: [TimeSpan], settings: DuckingSettings = DuckingSettings()) {
        guard duration > 0 else {
            points = []
            return
        }
        let lead = max(0, settings.lead)
        let release = max(0, settings.release)

        // Regions closer than a dip and a recovery stay ducked between,
        // so no two ramps overlap.
        var regions: [TimeSpan] = []
        for region in speech.sorted(by: { $0.start < $1.start }) {
            let clamped = TimeSpan(start: max(0, region.start), end: min(duration, region.end))
            guard clamped.end > clamped.start else { continue }
            if let last = regions.last, clamped.start - last.end <= lead + release {
                regions[regions.count - 1].end = max(last.end, clamped.end)
            } else {
                regions.append(clamped)
            }
        }

        // Fades share the length when the video is shorter than both.
        var fadeIn = max(0, bed.fadeIn), fadeOut = max(0, bed.fadeOut)
        if fadeIn + fadeOut > duration {
            let scale = duration / (fadeIn + fadeOut)
            fadeIn *= scale
            fadeOut *= scale
        }

        func duck(at t: Double) -> Double {
            var amount = 0.0
            for r in regions {
                if t >= r.start && t <= r.end { return 1 }
                if t < r.start && t > r.start - lead, lead > 0 { amount = max(amount, 1 - (r.start - t) / lead) }
                if t > r.end && t < r.end + release, release > 0 { amount = max(amount, 1 - (t - r.end) / release) }
            }
            return amount
        }

        func fade(at t: Double) -> Double {
            var amount = 1.0
            if fadeIn > 0 && t < fadeIn { amount = min(amount, t / fadeIn) }
            if fadeOut > 0 && t > duration - fadeOut { amount = min(amount, (duration - t) / fadeOut) }
            return max(0, amount)
        }

        func gain(at t: Double) -> Float {
            let db = bed.levelDB - max(0, bed.duckDB) * duck(at: t)
            return Float(pow(10, db / 20) * fade(at: t))
        }

        // Every corner of every curve, plus the middle of each dip so the
        // straight-line ramps follow the dB curve closely.
        var times: [Double] = [0, duration, fadeIn, duration - fadeOut]
        for r in regions {
            times += [r.start - lead, r.start - lead / 2, r.start, r.end, r.end + release / 2, r.end + release]
        }
        let sorted = times.map { min(max(0, $0), duration) }.sorted()
        var unique: [Double] = []
        for t in sorted where unique.last.map({ t - $0 > 1e-6 }) ?? true {
            unique.append(t)
        }
        points = unique.map { Point(time: $0, gain: gain(at: $0)) }
    }

    /// Gain at `t`, read off the straight lines between points.
    public func gain(at t: Double) -> Float {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.time { return first.gain }
        if t >= last.time { return last.gain }
        // Points are few (a handful per sentence), so a scan is fine.
        for i in 1..<points.count where points[i].time >= t {
            let a = points[i - 1], b = points[i]
            let span = b.time - a.time
            guard span > 0 else { return b.gain }
            let f = Float((t - a.time) / span)
            return a.gain + (b.gain - a.gain) * f
        }
        return last.gain
    }

    public static func gain(db: Double) -> Float {
        Float(pow(10, db / 20))
    }
}
