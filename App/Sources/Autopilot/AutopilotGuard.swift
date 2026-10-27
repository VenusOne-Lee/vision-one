import AppKit
import VisionOneKit

/// Watches for the person while Autopilot drives: Esc stops the run at
/// once; moving the mouse, clicking, scrolling or typing pauses it ("You
/// took over"). Autopilot's own events carry `InputPoster.tag` and are
/// ignored. Global key monitoring needs Accessibility access, which
/// Autopilot already has.
@MainActor
final class AutopilotGuard {
    var onEscape: (() -> Void)?
    var onTouch: (() -> Void)?
    private var monitors: [Any] = []

    func arm() {
        disarm()
        let mask: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                           .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let input = Input(event)
            MainActor.assumeIsolated { self?.handle(input) }
        }) {
            monitors.append(global)
        }
        // Esc while a Vision One window is in front.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.onEscape?() }
            return nil
        }) {
            monitors.append(local)
        }
    }

    func disarm() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// What the guard needs from an event, read before hopping actors.
    private struct Input {
        let isKey: Bool
        let isEscape: Bool
        let tagged: Bool
        let location: CGPoint?

        init(_ event: NSEvent) {
            isKey = event.type == .keyDown
            isEscape = isKey && event.keyCode == 53
            tagged = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputPoster.tag
            location = event.cgEvent?.location
        }
    }

    private func handle(_ input: Input) {
        if input.tagged { return }
        if input.isEscape {
            onEscape?()
            return
        }
        if !input.isKey, let location = input.location, InputPoster.shared.isOurs(at: location) { return }
        onTouch?()
    }
}
