import Foundation

/// The menu bar icon: the builder's ring, saying at a glance what Vision
/// One is up to. Recording wins and keeps its own look; then a task
/// waiting on you; then an agent at work; otherwise the dashed ring.
/// Every mark is an SF Symbol the menu bar draws as a template, so it's
/// ink only: orange stays for live recording.
public enum MenuBarMark: String, Sendable, Equatable, CaseIterable {
    case idle, working, needsYou, recording

    /// The mark for the recorder's state and the open tasks' statuses.
    public static func current(isLive: Bool, statuses: [TaskStatus]) -> MenuBarMark {
        if isLive { return .recording }
        if statuses.contains(.needsYou) { return .needsYou }
        if statuses.contains(.working) { return .working }
        return .idle
    }

    public var systemImage: String {
        switch self {
        case .idle: return "circle.dashed"
        case .working: return "ellipsis.circle"
        case .needsYou: return "exclamationmark.circle.fill"
        case .recording: return "record.circle.fill"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Vision One"
        case .working: return "Vision One, an agent is working"
        case .needsYou: return "Vision One, a task needs you"
        case .recording: return "Vision One, recording"
        }
    }
}

extension DeskSnapshot {
    /// The status of every task that isn't archived.
    public var openStatuses: [TaskStatus] {
        tasks.filter { !$0.archived }.map { status(of: $0) }
    }
}
