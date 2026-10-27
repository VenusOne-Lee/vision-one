import AppKit
import VisionOneKit

/// Logs cursor moves and clicks while recording, into events.json.
/// Global mouse monitors need no Accessibility permission.
@MainActor
final class CursorLogger {
    private var log: EventLog
    private var monitor: Any?
    /// What's being recorded (display, window or area) in Core Graphics
    /// global points: origin top left of the main display, y down.
    private let captureFrame: CGRect
    /// Host time of the first video frame, in seconds. NSEvent timestamps
    /// use the same clock (seconds since boot).
    private var origin: TimeInterval?

    init(captureFrame: CGRect) {
        self.captureFrame = captureFrame
        log = EventLog(displayWidth: captureFrame.width, displayHeight: captureFrame.height)
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
        guard let kind, let origin else { return }
        // AppKit's global origin is the bottom left of the main display;
        // Core Graphics' is its top left.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let x = location.x - captureFrame.minX
        let y = (mainHeight - location.y) - captureFrame.minY
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
