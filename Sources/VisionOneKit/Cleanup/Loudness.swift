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

    /// Seconds of sound the levels cover.
    public var duration: Double { Double(levels.count) * hop }

    /// The quiet run that starts the take and the one that ends it, if
    /// the sound starts or ends quiet.
    public func edgeSilence(minDuration: Double) -> (lead: TimeSpan?, tail: TimeSpan?) {
        let runs = silentSpans(minDuration: minDuration)
        let lead = runs.first.flatMap { $0.start <= hop + 1e-9 ? $0 : nil }
        let tail = runs.last.flatMap { $0.end >= duration - hop - 1e-9 ? $0 : nil }
        return (lead, tail)
    }

    /// The loudest level between two moments, for drawing a waveform one
    /// pixel at a time. `floorDB` outside the sound.
    public func peak(from start: Double, to end: Double) -> Float {
        guard hop > 0, !levels.isEmpty else { return Self.floorDB }
        let first = max(0, Int((min(start, end) / hop).rounded(.down)))
        let last = min(levels.count - 1, Int((max(start, end) / hop).rounded(.down)))
        guard first <= last else { return Self.floorDB }
        return levels[first...last].max() ?? Self.floorDB
    }

    /// 0...1 for a level, with -60 dBFS and below drawn flat.
    public static func amplitude(db: Float) -> Double {
        Double(min(1, max(0, (db + 60) / 60)))
    }
}

// MARK: levels.json

/// Saved beside the take as levels.json, so the editor can draw the
/// waveform and find silence without decoding the audio again. Levels
/// are whole dB below full scale, one byte each, base64 in the file.
extension LoudnessEnvelope: Codable {
    private enum CodingKeys: String, CodingKey { case version, hop, db }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hop = try container.decode(Double.self, forKey: .hop)
        let encoded = try container.decode(String.self, forKey: .db)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(forKey: .db, in: container, debugDescription: "Levels aren't base64")
        }
        levels = bytes.map { -Float($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(hop, forKey: .hop)
        let bytes = levels.map { UInt8(min(100, max(0, -$0.rounded()))) }
        try container.encode(Data(bytes).base64EncodedString(), forKey: .db)
    }

    public static func read(from url: URL) throws -> LoudnessEnvelope {
        try JSONDecoder().decode(LoudnessEnvelope.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
