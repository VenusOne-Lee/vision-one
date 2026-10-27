import Foundation

/// The Energy dial: one control for how busy the edit feels (it replaces
/// the sound feature's first version, same cases). It sets zooms,
/// punch-ins, sound effects, caption style and how tightly the Editor cuts,
/// so they always agree. Templates pick the starting value.
public enum Energy: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm, lively, viral

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .lively: return "Lively"
        case .viral: return "Viral"
        }
    }

    public var blurb: String {
        switch self {
        case .calm: return "Few zooms, no sound effects, clean captions. Good for bug reports and walkthroughs."
        case .lively: return "Zooms on clicks, a few soft sound effects, bold captions."
        case .viral: return "Punch-ins, fast cuts, keyword captions and sound effects on beats."
        }
    }

    public var profile: EnergyProfile {
        switch self {
        case .calm:
            return EnergyProfile(zoomsPerMinute: 1, punchIns: false, soundEffectsPerMinute: 0,
                                 captionStyle: "clean", maxPause: 1.0, keptPause: 0.5, keepThreshold: 0.2)
        case .lively:
            return EnergyProfile(zoomsPerMinute: 3, punchIns: false, soundEffectsPerMinute: 1.5,
                                 captionStyle: "bold", maxPause: 0.7, keptPause: 0.35, keepThreshold: 0.3)
        case .viral:
            return EnergyProfile(zoomsPerMinute: 6, punchIns: true, soundEffectsPerMinute: 4,
                                 captionStyle: "keywords", maxPause: 0.45, keptPause: 0.2, keepThreshold: 0.45)
        }
    }
}

/// What one Energy setting means for each feature. Zoom, captions, music
/// and sound effects read these numbers rather than the dial itself.
public struct EnergyProfile: Equatable, Sendable {
    /// Upper bound on auto zooms; zooms still only land on clicks and typing.
    public var zoomsPerMinute: Double
    /// Quick zoom-ins on the speaker's face or a key word.
    public var punchIns: Bool
    /// Sound effects, always ducked under the voice.
    public var soundEffectsPerMinute: Double
    /// Caption style id: "clean", "bold", "keywords" (keywords in ring colour).
    public var captionStyle: String
    /// Pauses at least this long get shortened.
    public var maxPause: Double
    /// What a long pause is shortened to.
    public var keptPause: Double
    /// The Editor proposes cutting sentences it is less sure than this
    /// are worth keeping (0...1).
    public var keepThreshold: Double
}

extension CleanupSettings {
    /// Cleanup tuned to the dial: Viral trims pauses harder than Calm.
    public init(energy: Energy) {
        self.init()
        minPause = energy.profile.maxPause
        keptPause = energy.profile.keptPause
    }
}
