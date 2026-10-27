import Foundation

/// Turns mic sample peaks into what the REC bar shows: a level that jumps
/// up fast and falls back slowly (like a hardware meter), and whether the
/// mic has been silent long enough to say "Can't hear you".
public struct MicLevelMeter: Equatable, Sendable {
    /// Quieter than this counts as silence, in dBFS. Room noise on a
    /// working laptop mic sits around -60 to -50; speech well above -40.
    public static let silenceFloor: Double = -50
    /// The bottom of the meter, in dBFS.
    public static let meterFloor: Double = -60
    /// Seconds of silence before the bar asks you to check the mic.
    public static let silenceWarningAfter: Double = 6
    /// How fast the shown level falls, in dB per second.
    public static let releasePerSecond: Double = 24

    /// What the meter shows, 0 (floor) to 1 (full scale).
    public private(set) var level: Double = 0
    private var shownDB: Double = MicLevelMeter.meterFloor
    private var lastUpdate: Double?
    private var lastHeard: Double?
    private var startedAt: Double?

    public init() {}

    /// Feeds one buffer's peak (linear, 0...1) at time `t` in seconds.
    public mutating func update(peak: Double, at t: Double) {
        if startedAt == nil { startedAt = t }
        let db = Self.decibels(peak)
        if db >= Self.silenceFloor { lastHeard = t }
        let elapsed = lastUpdate.map { max(0, t - $0) } ?? 0
        lastUpdate = t
        let fallen = shownDB - Self.releasePerSecond * elapsed
        shownDB = max(db, fallen, Self.meterFloor)
        level = (shownDB - Self.meterFloor) / -Self.meterFloor
    }

    /// Restarts the silence timer, for example after a pause, so the
    /// warning doesn't fire the moment recording resumes.
    public mutating func restartSilenceTimer(at t: Double) {
        startedAt = t
        lastHeard = nil
    }

    /// True once nothing above the silence floor has arrived for
    /// `silenceWarningAfter` seconds.
    public func isSilent(at t: Double) -> Bool {
        guard let since = lastHeard ?? startedAt else { return false }
        return t - since >= Self.silenceWarningAfter
    }

    /// How many of `count` bars are lit.
    public func litBars(of count: Int) -> Int {
        guard level > 0.02 else { return 0 }
        return min(count, max(1, Int((level * Double(count)).rounded(.up))))
    }

    public static func decibels(_ peak: Double) -> Double {
        guard peak > 0 else { return meterFloor }
        return max(meterFloor, min(0, 20 * log10(peak)))
    }

    /// The loudest sample, as a linear 0...1 value.
    public static func peak(ofFloats samples: UnsafeBufferPointer<Float>) -> Double {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        return Double(min(peak, 1))
    }

    public static func peak(ofInt16 samples: UnsafeBufferPointer<Int16>) -> Double {
        var peak: Int32 = 0
        for sample in samples { peak = max(peak, abs(Int32(sample))) }
        return min(1, Double(peak) / Double(Int16.max))
    }
}
