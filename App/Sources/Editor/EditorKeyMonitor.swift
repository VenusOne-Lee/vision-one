import AppKit

/// Single-letter keys for the editor (V, C, Z, B for the tools) without
/// stealing them from typing: a key is offered only when no text is
/// being edited and no ⌘, ⌃ or ⌥ is held. Returning true from the
/// handler swallows the key.
final class EditorKeyMonitor {
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor (Character) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard Self.isFree(event),
                      let characters = event.charactersIgnoringModifiers, characters.count == 1,
                      let key = characters.first
                else { return event }
                return handler(key) ? nil : event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
