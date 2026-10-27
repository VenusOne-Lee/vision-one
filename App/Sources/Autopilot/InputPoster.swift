import AppKit
import CoreGraphics
import VisionOneKit

/// Autopilot's hands: posts mouse and key events like a person would make
/// them. Every event carries `tag`, and the last place it moved the
/// cursor is remembered, so `AutopilotGuard` can tell Autopilot's input
/// from the person's own.
@MainActor
final class InputPoster {
    static let shared = InputPoster()

    /// "VION", in each event's user data field.
    nonisolated static let tag: Int64 = 0x5649_4F4E

    private let source = CGEventSource(stateID: .hidSystemState)
    /// Where Autopilot last put the cursor, and when.
    private(set) var lastPoint: CGPoint?
    private(set) var lastPostedAt = Date.distantPast
    /// Set while the run is paused or stopping: glides, typing and
    /// scrolling stop part way instead of fighting the person.
    var halted = false

    /// The cursor now, in Core Graphics global points (top left origin).
    var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Whether an event at `point` is most likely one Autopilot just made.
    func isOurs(at point: CGPoint) -> Bool {
        guard Date().timeIntervalSince(lastPostedAt) < 0.25, let lastPoint else { return false }
        return abs(lastPoint.x - point.x) < 3 && abs(lastPoint.y - point.y) < 3
    }

    // MARK: Mouse

    /// Glides the cursor to `point` along an eased arc.
    func glide(to point: CGPoint, pace: Pace) async {
        let path = CursorPath(from: .init(x: cursor.x, y: cursor.y), to: .init(x: point.x, y: point.y),
                              speed: pace.cursorSpeed)
        for frame in path.frames(fps: 60) {
            if halted { return }
            move(to: CGPoint(x: frame.x, y: frame.y))
            try? await Task.sleep(nanoseconds: 16_666_667)
        }
    }

    func move(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                     mouseButton: .left), at: point)
    }

    func click(at point: CGPoint) async {
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point,
                           mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point,
                         mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(down, at: point)
        // Long enough for the press to show in the video.
        try? await Task.sleep(nanoseconds: 70_000_000)
        post(up, at: point)
    }

    /// Scrolls by whole lines; positive `lines` scrolls toward `direction`.
    func scroll(_ direction: DemoStep.Direction, lines: Int) async {
        let delta: (y: Int32, x: Int32)
        switch direction {
        case .down: delta = (-1, 0)
        case .up: delta = (1, 0)
        case .left: delta = (0, 1)
        case .right: delta = (0, -1)
        }
        // One line at a time reads as a smooth scroll in the video.
        for _ in 0..<max(lines, 1) {
            if halted { return }
            let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                wheel1: delta.y, wheel2: delta.x, wheel3: 0)
            post(event, at: cursor)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: Keys

    func type(_ text: String, pace: Pace) async {
        for character in text {
            if halted { return }
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                units.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                post(event, at: nil)
            }
            try? await Task.sleep(nanoseconds: UInt64(pace.typingInterval * 1_000_000_000))
        }
    }

    func press(_ combo: KeyCombo) async {
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: keyDown)
            event?.flags = flags
            post(event, at: nil)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: Posting

    private func post(_ event: CGEvent?, at point: CGPoint?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        if let point { lastPoint = point }
        lastPostedAt = Date()
        event.post(tap: .cghidEventTap)
    }
}
