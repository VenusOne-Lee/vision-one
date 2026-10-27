import AppKit
import VisionOneKit

/// Logs cursor moves and clicks while recording, into events.json.
/// Global mouse monitors need no Accessibility permission.
@MainActor
final class CursorLogger {
    private var log: EventLog
    private var monitor: Any?
    /// The recorded display in global coordinates. For the main display
    /// AppKit's and Core Graphics' frames share the origin, so a plain
    /// flip of y maps AppKit points onto the video.
    private let displayFrame: CGRect
    /// Host time of the first video frame, in seconds. NSEvent timestamps
    /// use the same clock (seconds since boot).
    private var origin: TimeInterval?

    init(displayFrame: CGRect) {
        self.displayFrame = displayFrame
        log = EventLog(displayWidth: displayFrame.width, displayHeight: displayFrame.height)
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let kind = Self.kind(of: event)
            let timestamp = event.timestamp
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.record(kind, at: timestamp, location: location) }
        }
    }

    /// Called once the first frame is written.
    func setOrigin(_ seconds: TimeInterval) {
        origin = seconds
    }

    func stop(writingTo url: URL) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        try? log.write(to: url)
    }

    private func record(_ kind: InputEvent.Kind?, at timestamp: TimeInterval, location: CGPoint) {
        guard let kind, let origin, displayFrame.contains(location) else { return }
        // AppKit's origin is bottom left; the video's is top left.
        let x = location.x - displayFrame.minX
        let y = displayFrame.maxY - location.y
        log.append(InputEvent(kind: kind, t: timestamp - origin, x: x, y: y))
    }

    private nonisolated static func kind(of event: NSEvent) -> InputEvent.Kind? {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged: return .move
        case .leftMouseDown: return .leftDown
        case .leftMouseUp: return .leftUp
        case .rightMouseDown: return .rightDown
        case .rightMouseUp: return .rightUp
        default: return nil
        }
    }
}
