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
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 49 { // Space
                    if event.type == .keyDown {
                        if event.isARepeat { return self.spaceIsOurs ? nil : event }
                        guard Self.isFree(event) else { return event }
                        self.spaceIsOurs = true
                        onSpace(.down)
                        return nil
                    }
                    guard self.spaceIsOurs else { return event }
                    self.spaceIsOurs = false
                    onSpace(.up)
                    return nil
                }
                guard event.type == .keyDown, !event.isARepeat, Self.isFree(event),
                      let characters = event.charactersIgnoringModifiers, characters.count == 1,
                      let key = characters.first
                else { return event }
                return onKey(key) ? nil : event
            }
        }
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
