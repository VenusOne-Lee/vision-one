import Foundation

/// Where a waiting approval is asked, so the user answers it once.
///
/// The one source of truth is the job's pending approval on the
/// `AgentJobBoard`. The task's numbered card and the floating panel are
/// two views of it: whichever answers resolves the board, and the other
/// goes away.
public enum ApprovalSurface: Equatable, Sendable {
    /// Only the numbered card in the task's thread: the main window is in
    /// front, and the sidebar and the menu bar's Tasks list show "needs you".
    case thread
    /// The card in the thread, plus the floating panel because the main
    /// window is closed, hidden or behind another app. Answering the panel
    /// answers the card.
    case threadAndPanel
    /// Nothing to put a card on (no job, or a job filed under no task):
    /// only the floating panel.
    case panel

    /// `onTask`: the request belongs to a job filed under a Desk task.
    /// `windowInFront`: the main window is on screen and Vision One is the
    /// app in front, so the user will see the card.
    public static func route(onTask: Bool, windowInFront: Bool) -> ApprovalSurface {
        guard onTask else { return .panel }
        return windowInFront ? .thread : .threadAndPanel
    }

    /// Whether the floating panel asks.
    public var showsPanel: Bool { self != .thread }
}
