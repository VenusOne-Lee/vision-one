import Foundation

/// The three lanes of the sound full mode.
public enum MixLane: String, CaseIterable, Identifiable, Codable, Sendable {
    case voice, music, effects

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voice: return "Voice"
        case .music: return "Music"
        case .effects: return "Effects"
        }
    }
}

/// Mute and solo for listening in the editor. Only the preview changes;
/// the export always has every lane.
public struct LaneMix: Equatable, Sendable {
    public var muted: Set<MixLane>
    public var soloed: Set<MixLane>

    public init(muted: Set<MixLane> = [], soloed: Set<MixLane> = []) {
        self.muted = muted
        self.soloed = soloed
    }

    /// Soloing any lane silences the lanes that aren't soloed; otherwise
    /// every lane that isn't muted plays.
    public func isAudible(_ lane: MixLane) -> Bool {
        soloed.isEmpty ? !muted.contains(lane) : soloed.contains(lane)
    }

    public var isDefault: Bool { muted.isEmpty && soloed.isEmpty }

    public mutating func toggleMute(_ lane: MixLane) {
        if muted.contains(lane) { muted.remove(lane) } else { muted.insert(lane) }
    }

    public mutating func toggleSolo(_ lane: MixLane) {
        if soloed.contains(lane) { soloed.remove(lane) } else { soloed.insert(lane) }
    }
}

/// Integrated loudness, for the meter in the sound full mode.
public enum LoudnessTarget {
    /// YouTube, Spotify and most platforms play back at about −14 LUFS.
    public static let platform: Float = -14

    public static func verdict(lufs: Float) -> String {
        switch lufs {
        case ..<(-20): return "quiet, platforms will turn it up"
        case ..<(-16): return "a little quiet"
        case ..<(-12): return "good for YouTube"
        case ..<(-9): return "loud"
        default: return "very loud, may distort"
        }
    }
}

extension LoudnessEnvelope {
    /// Integrated loudness in the style of ITU BS.1770: 400 ms blocks
    /// with 75% overlap, an absolute gate at −70 and a relative gate 10
    /// below the gated mean. The levels aren't K-weighted, so for speech
    /// this reads within a dB or two of true LUFS. Nil when nothing is
    /// louder than the gate.
    public func integratedLoudness() -> Float? {
        guard !levels.isEmpty, hop > 0 else { return nil }
        let block = max(1, min(levels.count, Int((0.4 / hop).rounded())))
        let step = max(1, block / 4)
        var energies: [Double] = []
        var i = 0
        while i + block <= levels.count {
            var sum = 0.0
            for j in i..<(i + block) { sum += pow(10, Double(levels[j]) / 10) }
            energies.append(sum / Double(block))
            i += step
        }
        func loudness(_ energy: Double) -> Double { 10 * log10(max(energy, 1e-12)) }
        let audible = energies.filter { loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let gate = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let kept = audible.filter { loudness($0) > gate }
        guard !kept.isEmpty else { return nil }
        return Float(loudness(kept.reduce(0, +) / Double(kept.count)))
    }
}
