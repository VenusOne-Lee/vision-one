import Foundation

/// A word heard during a practice run, from live on-device speech
/// recognition. Times are seconds from the start of the run.
public struct HeardWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var isHesitation: Bool { FillerLexicon.isHesitation(FillerLexicon.normalize(text)) }
}

/// One slice of the mic during a practice run: how loud, and the pitch
/// when the voice was voiced.
public struct VoiceFrame: Codable, Equatable, Sendable {
    public var time: Double
    public var levelDB: Float
    public var pitchHz: Double?

    public init(time: Double, levelDB: Float, pitchHz: Double?) {
        self.time = time
        self.levelDB = levelDB
        self.pitchHz = pitchHz
    }
}

/// What Rehearse aims for. Defaults follow common speaking advice:
/// 130 to 165 words a minute, under two ums a minute, pauses of about
/// half a second between thoughts.
public struct RehearsalTargets: Codable, Equatable, Sendable {
    public var pace: ClosedRange<Double>
    public var umsPerMinute: Double
    public var energy: ClosedRange<Double>
    public var pause: ClosedRange<Double>
    /// Which meters show, in order. The user can hide the ones they don't care about.
    public var meters: [RehearsalMeter]

    public init(pace: ClosedRange<Double> = SpeakingPace.comfortable, umsPerMinute: Double = 2,
                energy: ClosedRange<Double> = 0.5...0.85, pause: ClosedRange<Double> = 0.3...0.9,
                meters: [RehearsalMeter] = RehearsalMeter.allCases) {
        self.pace = pace
        self.umsPerMinute = umsPerMinute
        self.energy = energy
        self.pause = pause
        self.meters = meters
    }

    /// The pace band shifted to sit around the person's own pace, so a
    /// naturally quick talker isn't told off on every line.
    public static func around(_ pace: SpeakingPace) -> RehearsalTargets {
        guard pace.isLearned else { return RehearsalTargets() }
        let mid = min(175, max(120, pace.wordsPerMinute))
        return RehearsalTargets(pace: (mid - 20)...(mid + 15))
    }
}

public enum RehearsalMeter: String, Codable, CaseIterable, Sendable, Identifiable {
    case pace, ums, energy, pauses
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pace: return "Pace"
        case .ums: return "Ums"
        case .energy: return "Energy"
        case .pauses: return "Pauses"
        }
    }
}

/// Where a reading sits against its band.
public enum MeterZone: Equatable, Sendable {
    case low, inBand, high, unknown

    public static func of(_ value: Double?, in band: ClosedRange<Double>) -> MeterZone {
        guard let value else { return .unknown }
        if value < band.lowerBound { return .low }
        if value > band.upperBound { return .high }
        return .inBand
    }
}

/// The live meters at one moment.
public struct MeterReading: Equatable, Sendable {
    /// Words a minute over the last few seconds of talking.
    public var pace: Double?
    public var ums: Int
    /// 0 (flat) to 1 (big), from how much loudness and pitch move.
    public var energy: Double?
    /// Average pause between words, in seconds.
    public var pause: Double?

    public init(pace: Double?, ums: Int, energy: Double?, pause: Double?) {
        self.pace = pace
        self.ums = ums
        self.energy = energy
        self.pause = pause
    }

    public var energyLabel: String {
        guard let energy else { return "–" }
        switch energy {
        case ..<0.35: return "Flat"
        case ..<0.55: return "Steady"
        case ..<0.85: return "Lively"
        default: return "Big"
        }
    }
}

/// Keeps a practice run's words and voice frames and works out the live
/// meters from them. Everything stays on the Mac; nothing is saved as a
/// take. Feed it from the recogniser (`setWords`, which takes the whole
/// list each time because partial results change) and the mic (`add`).
public struct RehearsalMonitor: Sendable {
    public private(set) var words: [HeardWord] = []
    public private(set) var frames: [VoiceFrame] = []
    /// Seconds of talk the pace meter looks back over.
    public var paceWindow: Double = 12
    /// Seconds the energy meter looks back over.
    public var energyWindow: Double = 6

    public init() {}

    public mutating func setWords(_ words: [HeardWord]) {
        self.words = words.sorted { $0.start < $1.start }
    }

    public mutating func add(_ frame: VoiceFrame) {
        frames.append(frame)
    }

    public mutating func reset() {
        words = []
        frames = []
    }

    public func reading(at time: Double) -> MeterReading {
        MeterReading(pace: Self.pace(words, at: time, window: paceWindow),
                     ums: words.filter(\.isHesitation).count,
                     energy: Self.energy(frames.filter { $0.time > time - energyWindow && $0.time <= time }),
                     pause: Self.averagePause(words))
    }

    /// Words a minute over the last `window` seconds, counted from the
    /// first word in the window so a slow start doesn't drag it down.
    /// Hesitations don't count as words. Nil until there are four words.
    public static func pace(_ words: [HeardWord], at time: Double, window: Double) -> Double? {
        let recent = words.filter { !$0.isHesitation && $0.end > time - window && $0.start <= time }
        guard recent.count >= 4, let first = recent.first, let last = recent.last else { return nil }
        let span = max(last.end, min(time, last.end + 1)) - first.start
        guard span > 1 else { return nil }
        return Double(recent.count) / span * 60
    }

    /// Mean gap between words, counting gaps of 0.25 s to 4 s (shorter is
    /// running speech, longer is a break, not a pause).
    public static func averagePause(_ words: [HeardWord]) -> Double? {
        let gaps = zip(words, words.dropFirst()).map { $1.start - $0.end }.filter { $0 >= 0.25 && $0 <= 4 }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    /// Energy from voiced frames: half from how much loudness moves (2 to
    /// 9 dB of spread), half from how much pitch moves (1 to 5 semitones).
    /// A flat, even voice scores low even when it's loud.
    public static func energy(_ frames: [VoiceFrame]) -> Double? {
        let voiced = frames.filter { $0.pitchHz != nil && $0.levelDB > -60 }
        guard voiced.count >= 8 else { return nil }
        let levels = voiced.map { Double($0.levelDB) }
        let pitches = voiced.compactMap(\.pitchHz)
        let reference = median(pitches)
        let semitones = pitches.map { PitchTracker.semitones($0, from: reference) }
        let loud = clamp((spread(levels) - 2) / 7)
        let pitch = clamp((spread(semitones) - 1) / 4)
        return (loud + pitch) / 2
    }

    /// Pitch spread in semitones, for the "flat" note on a line.
    public static func pitchSpread(_ frames: [VoiceFrame]) -> Double? {
        let pitches = frames.compactMap(\.pitchHz)
        guard pitches.count >= 8 else { return nil }
        let reference = median(pitches)
        return spread(pitches.map { PitchTracker.semitones($0, from: reference) })
    }

    static func spread(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
