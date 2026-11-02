import Foundation

/// The macOS permissions Vision One asks for.
public enum AccessKind: String, CaseIterable, Sendable {
    case screen
    case microphone
    case camera
    /// Autopilot's clicks and the keys shown in agent recordings.
    case accessibility

    public var title: String {
        switch self {
        case .screen: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .accessibility: return "Accessibility"
        }
    }

    /// Setup is done without these: the camera is for the bubble and
    /// Camera only, Accessibility for Autopilot and agent recordings.
    public var isOptional: Bool { self == .camera || self == .accessibility }

    /// Once turned off, these come back only by a switch in System
    /// Settings. Microphone and Camera get macOS's own prompt again once
    /// Vision One clears its old entry.
    public var needsSettingsSwitch: Bool { self == .screen || self == .accessibility }

    /// First-run setup asks for these. Accessibility is asked where it's
    /// used (Autopilot, Record an Agent) and lives in Settings › Access.
    public var isInSetup: Bool { self != .accessibility }

    public var why: String {
        switch self {
        case .screen: return "To record your screen and the sound your Mac plays."
        case .microphone: return "To record your voice for the transcript."
        case .camera: return "Optional. To show you in the camera bubble, or record just you."
        case .accessibility: return "Optional. For Autopilot, and to show keys pressed in agent recordings."
        }
    }
}

public enum AccessState: Equatable, Sendable {
    /// macOS hasn't asked yet; pressing Allow shows the system prompt.
    case notAsked
    case granted
    /// Turned off. Vision One clears its old entry and asks again.
    case denied
}

/// What the "Get set up" window shows. Screen Recording only takes effect
/// after a full relaunch, so the checklist also tracks whether access was
/// granted since this launch.
public struct AccessChecklist: Equatable, Sendable {
    public var states: [AccessKind: AccessState]
    /// Screen Recording state when the app launched.
    public let screenAtLaunch: AccessState

    public init(states: [AccessKind: AccessState], screenAtLaunch: AccessState) {
        self.states = states
        self.screenAtLaunch = screenAtLaunch
    }

    public func state(of kind: AccessKind) -> AccessState {
        states[kind] ?? .notAsked
    }

    public var allGranted: Bool {
        AccessKind.allCases.filter { !$0.isOptional }.allSatisfy { state(of: $0) == .granted }
    }

    /// Screen Recording was turned on after launch: macOS won't hand
    /// this process any frames until it restarts.
    public var needsRestart: Bool {
        state(of: .screen) == .granted && screenAtLaunch != .granted
    }

    /// Ready to record without a restart.
    public var canRecord: Bool {
        screenAtLaunch == .granted && state(of: .screen) == .granted
    }

    /// Ready to record in `mode`. Camera only needs the camera, not
    /// Screen Recording; asking for it the first time is still to come
    /// when it's `notAsked`, so only a refusal stops it.
    public func canRecord(_ mode: CaptureMode) -> Bool {
        mode.recordsScreen ? canRecord : state(of: .camera) != .denied
    }
}
