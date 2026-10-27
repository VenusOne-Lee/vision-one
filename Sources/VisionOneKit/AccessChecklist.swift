import Foundation

/// The macOS permissions Vision One asks for.
public enum AccessKind: String, CaseIterable, Sendable {
    case screen
    case microphone
    case camera

    public var title: String {
        switch self {
        case .screen: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        }
    }

    /// Only needed for the camera bubble, so setup is done without it.
    public var isOptional: Bool { self == .camera }

    public var why: String {
        switch self {
        case .screen: return "To record your screen and the sound your Mac plays."
        case .microphone: return "To record your voice for the transcript."
        case .camera: return "Optional. To show you in the camera bubble."
        }
    }
}

public enum AccessState: Equatable, Sendable {
    /// macOS hasn't asked yet; pressing Allow shows the system prompt.
    case notAsked
    case granted
    /// Turned off. Only System Settings can turn it back on.
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
}
