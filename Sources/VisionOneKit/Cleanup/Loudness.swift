import Foundation

/// How loud the mic was, in dBFS, every `hop` seconds. Pause edges are
/// checked against this because word timestamps drift into silence.
public struct LoudnessEnvelope: Equatable, Sendable {
    /// Seconds per level. 0.01 by default.
    public var hop: Double
    public var levels: [Float]

    /// Quietest level reported, for digital silence.
    public static let floorDB: Float = -100

    public init(hop: Double, levels: [Float]) {
        self.hop = hop
        self.levels = levels
    }

    /// RMS level of each `hop` of mono samples (-1...1).
    public static func measure(samples: [Float], sampleRate: Double, hop: Double = 0.01) -> LoudnessEnvelope {
        let size = max(1, Int((sampleRate * hop).rounded()))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / size + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + size, samples.count)
            var sum: Float = 0
            for s in samples[i..<end] { sum += s * s }
            let rms = (sum / Float(end - i)).squareRoot()
            levels.append(rms > 0 ? max(floorDB, 20 * log10(rms)) : floorDB)
            i = end
        }
        return LoudnessEnvelope(hop: hop, levels: levels)
    }

    /// The level below which the take counts as quiet: 12 dB above the
    /// room's noise floor (its 10th percentile), kept between -60 and
    /// -35 dBFS so a noisy room or a very quiet one still works.
    public var adaptiveThreshold: Float {
        guard !levels.isEmpty else { return -45 }
        let sorted = levels.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return min(-35, max(-60, noiseFloor + 12))
    }

    /// Runs of quiet at least `minDuration` long. Loud blips shorter than
    /// `bridge` (a click, a breath) don't split a run.
    public func silentSpans(threshold: Float? = nil, minDuration: Double, bridge: Double = 0.06) -> [TimeSpan] {
        let limit = threshold ?? adaptiveThreshold
        var runs: [TimeSpan] = []
        var runStart: Int?
        for (i, level) in levels.enumerated() {
            if level < limit {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                runs.append(TimeSpan(start: Double(s) * hop, end: Double(i) * hop))
                runStart = nil
            }
        }
        if let s = runStart {
            runs.append(TimeSpan(start: Double(s) * hop, end: Double(levels.count) * hop))
        }

        var merged: [TimeSpan] = []
        for run in runs {
            if let last = merged.last, run.start - last.end <= bridge + 1e-9 {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        return merged.filter { $0.duration >= minDuration - 1e-9 }
    }
}
