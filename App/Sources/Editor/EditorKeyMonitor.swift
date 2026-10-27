import AppKit

/// Single-letter keys for the editor (V, C, Z, B, D for the tools) and
/// Space (tap to play, hold to talk) without stealing them from typing:
/// a key is offered only when no text is being edited and no ⌘, ⌃ or ⌥
/// is held. Returning true from the handler swallows the key.
final class EditorKeyMonitor {
    enum SpaceEvent {
        case down, up
    }

    private var monitor: Any?
    /// Space went down while free, so its key-up is ours too.
    private var spaceIsOurs = false

    func start(onKey: @escaping @MainActor (Character) -> Bool,
               onSpace: @escaping @MainActor (SpaceEvent) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // NSEvent isn't Sendable; local monitors run on the main
            // thread, so only a yes or no crosses back.
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated { self?.handle(event, onKey: onKey, onSpace: onSpace) ?? false }
            return swallow ? nil : event
        }
    }

    @MainActor
    private func handle(_ event: NSEvent, onKey: @MainActor (Character) -> Bool,
                        onSpace: @MainActor (SpaceEvent) -> Void) -> Bool {
        if event.keyCode == 49 { // Space
            if event.type == .keyDown {
                if event.isARepeat { return spaceIsOurs }
                guard Self.isFree(event) else { return false }
                spaceIsOurs = true
                onSpace(.down)
                return true
            }
            guard spaceIsOurs else { return false }
            spaceIsOurs = false
            onSpace(.up)
            return true
        }
        guard event.type == .keyDown, !event.isARepeat, Self.isFree(event),
              let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let key = characters.first
        else { return false }
        return onKey(key)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        spaceIsOurs = false
    }

    /// No modifier, and the key isn't going into a text field or an
    /// editable text view.
    @MainActor static func isFree(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .control, .option])
        guard held.isEmpty else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable || text.isFieldEditor {
            return false
        }
        return true
    }
}
