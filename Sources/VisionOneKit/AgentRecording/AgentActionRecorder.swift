import Foundation

/// An input event from an agent, as the app reads it from AppKit. The
/// app passes only events whose `InputOrigin` is `.agent`.
public struct AgentInputEvent: Equatable, Sendable {
    public enum Button: Equatable, Sendable { case left, right, other }

    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public enum Kind: Equatable, Sendable {
        case mouseDown(Button, clickCount: Int)
        case mouseUp(Button)
        /// Scroll wheel deltas: positive `dy` scrolls up, positive `dx` left.
        case scroll(dx: Double, dy: Double)
        /// `characters` as typed; `bare` is the key without modifiers, for
        /// shortcuts ("c" in ⌘C).
        case key(characters: String, bare: String, keyCode: UInt16, modifiers: Modifiers)
    }

    public var kind: Kind
    /// Seconds from the take's first frame.
    public var t: Double
    /// Points from the top left of what was recorded.
    public var x: Double
    public var y: Double
    /// The app in front ("Safari").
    public var app: String?
    /// macOS secure input was on: a password field had the keyboard.
    public var secure: Bool

    public init(_ kind: Kind, t: Double, x: Double = 0, y: Double = 0, app: String? = nil, secure: Bool = false) {
        self.kind = kind
        self.t = t
        self.x = x
        self.y = y
        self.app = app
        self.secure = secure
    }
}

/// Turns an agent's raw input into the step list: down and up become a
/// click (or a drag), runs of keys become one "Typed …", shortcuts become
/// "Pressed ⌘C", scroll bursts become one scroll. Typing into a password
/// field is kept as "a password (hidden)" and anything that looks like a
/// key or token is masked.
public struct AgentActionRecorder: Sendable {
    /// Further than this between down and up is a drag, in points.
    public var dragDistance = 8.0
    /// Keys closer together than this are one piece of typing.
    public var typingGap = 2.0
    /// Scroll events closer together than this are one scroll.
    public var scrollGap = 0.6

    public private(set) var actions: [AgentAction] = []
    private var down: AgentInputEvent?
    private var downClicks = 1
    private var typing: (start: Double, end: Double, text: String, hidden: Bool, app: String?, x: Double, y: Double)?

    public init() {}

    public mutating func add(_ event: AgentInputEvent) {
        guard event.t >= 0 else { return }
        switch event.kind {
        case let .mouseDown(_, clickCount):
            flushTyping()
            down = event
            downClicks = max(1, clickCount)
        case let .mouseUp(button):
            mouseUp(event, button: button)
        case let .scroll(dx, dy):
            flushTyping()
            scroll(event, dx: dx, dy: dy)
        case let .key(characters, bare, keyCode, modifiers):
            key(event, characters: characters, bare: bare, keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// A note from the agent: "Open the pricing page".
    public mutating func step(_ text: String, at t: Double, x: Double? = nil, y: Double? = nil) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, t >= 0 else { return }
        flushTyping()
        actions.append(AgentAction(kind: .step, source: .told, t: t, x: x, y: y,
                                   text: String(Self.masked(words).prefix(200))))
    }

    /// Everything so far, with typing in progress finished off.
    public mutating func finish() -> [AgentAction] {
        flushTyping()
        down = nil
        return actions
    }

    // MARK: Mouse

    private mutating func mouseUp(_ event: AgentInputEvent, button: AgentInputEvent.Button) {
        guard let pressed = down else { return }
        down = nil
        let distance = hypot(event.x - pressed.x, event.y - pressed.y)
        if distance > dragDistance {
            actions.append(AgentAction(kind: .drag, t: pressed.t, end: event.t, x: pressed.x, y: pressed.y,
                                       text: nil, app: pressed.app))
            return
        }
        if button == .right {
            actions.append(AgentAction(kind: .rightClick, t: pressed.t, x: pressed.x, y: pressed.y, app: pressed.app))
            return
        }
        if downClicks >= 2, let last = actions.last, last.kind == .click,
           let lx = last.x, let ly = last.y, hypot(lx - pressed.x, ly - pressed.y) <= dragDistance,
           pressed.t - last.t < 1 {
            // The second click of a double click: one action, not two.
            actions[actions.count - 1].kind = .doubleClick
            return
        }
        actions.append(AgentAction(kind: downClicks >= 2 ? .doubleClick : .click, t: pressed.t,
                                   x: pressed.x, y: pressed.y, app: pressed.app))
    }

    private mutating func scroll(_ event: AgentInputEvent, dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let direction: String
        if abs(dy) >= abs(dx) { direction = dy < 0 ? "down" : "up" } else { direction = dx < 0 ? "right" : "left" }
        if let last = actions.last, last.kind == .scroll, last.text == direction,
           event.t - last.finish <= scrollGap {
            actions[actions.count - 1].end = event.t
            return
        }
        actions.append(AgentAction(kind: .scroll, t: event.t, end: event.t, x: event.x, y: event.y,
                                   text: direction, app: event.app))
    }

    // MARK: Keys

    static let keyNames: [UInt16: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 53: "Esc", 51: "Delete", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        49: "Space",
    ]

    /// Characters that type text, not control keys or function keys.
    static func isPrintable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    static func combo(_ modifiers: AgentInputEvent.Modifiers, key: String) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + key
    }

    private mutating func key(_ event: AgentInputEvent, characters: String, bare: String, keyCode: UInt16,
                              modifiers: AgentInputEvent.Modifiers) {
        let shortcut = modifiers.contains(.command) || modifiers.contains(.control)
        if !shortcut, Self.isPrintable(characters) {
            type(characters, event: event)
            return
        }
        if !shortcut, keyCode == 51, var current = typing, !current.text.isEmpty, event.t - current.end <= typingGap {
            // Backspace while typing fixes the typing; it isn't a step.
            current.text.removeLast()
            current.end = event.t
            typing = current
            return
        }
        flushTyping()
        let name = Self.keyNames[keyCode]
            ?? (Self.isPrintable(bare) ? bare.uppercased() : nil)
            ?? "key \(keyCode)"
        actions.append(AgentAction(kind: .key, t: event.t, text: Self.combo(modifiers, key: name), app: event.app))
    }

    private mutating func type(_ characters: String, event: AgentInputEvent) {
        if var current = typing, event.t - current.end <= typingGap, current.app == event.app,
           current.hidden == event.secure {
            current.text += characters
            current.end = event.t
            typing = current
            return
        }
        flushTyping()
        typing = (event.t, event.t, characters, event.secure, event.app, event.x, event.y)
    }

    private mutating func flushTyping() {
        guard let current = typing else { return }
        typing = nil
        guard !current.text.isEmpty else { return }
        let text: String? = current.hidden ? nil : String(Self.masked(current.text).prefix(500))
        actions.append(AgentAction(kind: .type, t: current.start, end: current.end, text: text,
                                   hidden: current.hidden, app: current.app))
    }

    /// Text with anything that looks like a key, token or card number
    /// replaced by dots, using the scanner that blurs secrets on screen.
    public static func masked(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in SecretScanner.find(in: text) where match.range.lowerBound >= cursor {
            result += text[cursor..<match.range.lowerBound]
            result += "•••"
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
