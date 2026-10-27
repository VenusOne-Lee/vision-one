import Foundation

/// Where a recording is in its life. The menu bar ring and the record
/// button read this to decide how they look.
public enum RecordingPhase: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case finishing
    case failed(message: String)

    /// True only while frames are being written. This is the one state
    /// that is allowed to show tally orange.
    public var isLive: Bool {
        if case .recording = self { return true }
        return false
    }

    /// True while a start or stop is in flight, so the button can't be
    /// pressed twice.
    public var isBusy: Bool {
        switch self {
        case .preparing, .finishing: return true
        default: return false
        }
    }

    /// Seconds since recording started, or nil when not live.
    public func elapsed(at now: Date = Date()) -> TimeInterval? {
        guard case let .recording(startedAt) = self else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }
}
