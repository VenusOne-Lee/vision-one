import Foundation

/// Steps as plain lines, so a demo can be typed or read without JSON:
///
///     Open https://rankride.co.za/ranks
///     Click "Bree St rank"
///     Click the "Pay now" button
///     Point at "Queue count"
///     Type "Thabo" into "Name"
///     Press cmd+return
///     Scroll down 5
///     Wait 1.5s
///     Wait for "Receipt"
///     Say "Pick your rank, and you're in."
///
/// A `Say` line is the script for the step before it.
public enum StepWords {
    public struct ParseError: Error, Equatable, LocalizedError {
        public let line: Int
        public let text: String

        public var errorDescription: String? {
            "Line \(line): Vision One doesn't know “\(text)”. Start with Open, Click, Point at, Type, Press, Scroll, Wait or Say."
        }
    }

    /// Every step in `text`, one per line. Blank lines and lines starting
    /// with # are skipped.
    public static func parse(_ text: String) throws -> [DemoStep] {
        var steps: [DemoStep] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let said = sayLine(line) {
                guard !steps.isEmpty else { throw ParseError(line: i + 1, text: line) }
                steps[steps.count - 1].say = said
                continue
            }
            guard let step = parseLine(line) else { throw ParseError(line: i + 1, text: line) }
            steps.append(step)
        }
        return steps
    }

    /// One step from one line, or nil when it isn't one.
    public static func parseLine(_ line: String) -> DemoStep? {
        let (verb, rest) = splitVerb(line)
        switch verb {
        case "open", "go to", "visit":
            guard !rest.isEmpty else { return nil }
            return DemoStep(.open, text: unquoted(rest))
        case "click", "press on", "tap", "choose", "select":
            guard let target = target(rest) else { return nil }
            return DemoStep(.click, target: target)
        case "point at", "point to", "hover", "hover over", "show":
            guard let target = target(rest) else { return nil }
            return DemoStep(.point, target: target)
        case "type", "enter":
            let quoted = quotes(rest)
            guard let text = quoted.first else { return nil }
            var into: UITarget?
            if let range = rest.range(of: " into ", options: [.caseInsensitive, .backwards]) {
                let after = String(rest[range.upperBound...])
                let named = !quotes(after).isEmpty || after.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                if named { into = target(after) }
            }
            return DemoStep(.type, target: into, text: text)
        case "press", "hit":
            let keys = unquoted(rest)
            guard KeyCombo(keys) != nil else { return nil }
            return DemoStep(.press, keys: keys)
        case "scroll":
            let words = rest.lowercased().split(separator: " ").map(String.init)
            let direction = words.compactMap(DemoStep.Direction.init(rawValue:)).first ?? .down
            let amount = words.compactMap { Int($0) }.first
            let over = rest.range(of: "over", options: .caseInsensitive).flatMap { target(String(rest[$0.upperBound...])) }
            return DemoStep(.scroll, target: over, direction: direction, amount: amount)
        case "wait":
            if let forRange = rest.range(of: "for", options: [.caseInsensitive, .anchored]) {
                guard let target = target(String(rest[forRange.upperBound...])) else { return nil }
                return DemoStep(.wait, target: target)
            }
            return DemoStep(.wait, seconds: seconds(rest) ?? 1)
        default:
            return nil
        }
    }

    /// The step as one plain line, the inverse of `parseLine`.
    public static func line(for step: DemoStep) -> String {
        switch step.action {
        case .open: return "Open \(step.text ?? "")"
        case .click: return "Click \(phrase(step.target))"
        case .point: return "Point at \(phrase(step.target))"
        case .type:
            let typed = "Type \(quote(step.text ?? ""))"
            return step.target.map { "\(typed) into \(phrase($0))" } ?? typed
        case .press: return "Press \(step.keys ?? "")"
        case .scroll:
            var words = "Scroll \((step.direction ?? .down).rawValue)"
            if let amount = step.amount { words += " \(amount)" }
            if let target = step.target { words += " over \(phrase(target))" }
            return words
        case .wait:
            if let target = step.target { return "Wait for \(phrase(target))" }
            return "Wait \(format(step.seconds ?? 1))s"
        }
    }

    /// All steps as lines, with each step's script under it.
    public static func text(for steps: [DemoStep]) -> String {
        steps.flatMap { step -> [String] in
            var lines = [line(for: step)]
            if let say = step.say, !say.isEmpty { lines.append("Say \(quote(say))") }
            return lines
        }.joined(separator: "\n")
    }

    // MARK: Pieces

    private static let verbs = ["go to", "press on", "point at", "point to", "hover over",
                                "open", "visit", "click", "tap", "choose", "select", "hover", "show",
                                "type", "enter", "press", "hit", "scroll", "wait"]

    private static func splitVerb(_ line: String) -> (String, String) {
        let lower = line.lowercased()
        for verb in verbs where lower == verb || lower.hasPrefix(verb + " ") {
            let rest = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
            return (verb, rest)
        }
        return ("", line)
    }

    private static func sayLine(_ line: String) -> String? {
        let lower = line.lowercased()
        guard lower.hasPrefix("say ") || lower.hasPrefix("say:") else { return nil }
        let rest = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return unquoted(rest)
    }

    /// `"Pay now"`, `the "Pay now" button`, `button "Pay now"`, `#pay-button`
    /// (an identifier), or a bare name.
    static func target(_ text: String) -> UITarget? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("the ") { rest = String(rest.dropFirst(4)) }
        guard !rest.isEmpty else { return nil }
        if rest.hasPrefix("#") {
            let id = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : UITarget(identifier: id)
        }
        let quoted = quotes(rest)
        guard let name = quoted.first else {
            return UITarget(name: rest)
        }
        // Whatever is outside the quotes may name the kind: "button", "link".
        let outside = rest.replacingOccurrences(of: "\"\(name)\"", with: " ")
            .replacingOccurrences(of: "“\(name)”", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return UITarget(role: AXRoleName.role(for: outside), name: name)
    }

    /// Text inside straight or curly double quotes, in order.
    static func quotes(_ text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for ch in text {
            if ch == "\"" || ch == "“" || ch == "”" {
                if let open = current {
                    found.append(open)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return found
    }

    private static func unquoted(_ text: String) -> String {
        quotes(text).first ?? text.trimmingCharacters(in: .whitespaces)
    }

    private static func quote(_ text: String) -> String { "\"\(text)\"" }

    private static func phrase(_ target: UITarget?) -> String {
        guard let target else { return "\"\"" }
        if let name = target.name, !name.isEmpty {
            let kind = target.role.map(AXRoleName.plain) ?? ""
            let known = target.role.flatMap { AXRoleName.role(for: kind) == $0 ? kind : nil }
            return known.map { "the \(quote(name)) \($0)" } ?? quote(name)
        }
        if let id = target.identifier { return "#\(id)" }
        return "\"\""
    }

    /// "1.5s", "2 s", "500ms", "2 seconds".
    static func seconds(_ text: String) -> Double? {
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        if lower.hasSuffix("ms"), let n = Double(lower.dropLast(2)) { return n / 1000 }
        for suffix in ["seconds", "second", "secs", "sec", "s"] where lower.hasSuffix(suffix) {
            return Double(lower.dropLast(suffix.count))
        }
        return Double(lower)
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// A key combination like "cmd+shift+k" or "return".
public struct KeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public var modifiers: Modifiers
    /// macOS virtual key code (kVK_*).
    public var keyCode: UInt16
    public var key: String

    public init?(_ text: String) {
        let parts = text.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+").replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "opt+").replacingOccurrences(of: "⌃", with: "ctrl+")
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" })
            .map(String.init)
        guard let last = parts.last else { return nil }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        guard let code = Self.codes[last] else { return nil }
        modifiers = mods
        keyCode = code
        key = last
    }

    /// The keys Autopilot can press, by their US layout key codes.
    static let codes: [String: UInt16] = {
        var map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "0": 29, "8": 28,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "[": 33, "]": 30,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()

    /// The name `init` reads for a key code, preferring the plain word
    /// ("return", not "enter"), for steps recorded from real key presses.
    public static func name(forKeyCode code: UInt16) -> String? {
        let preferred = ["return", "tab", "space", "delete", "escape", "left", "right", "up", "down"]
        if let word = preferred.first(where: { codes[$0] == code }) { return word }
        return codes.filter { $0.value == code }.map { $0.key }.sorted().first
    }

    /// Text for a recorded key press, like "cmd+shift+k".
    public static func text(keyCode: UInt16, modifiers: Modifiers) -> String? {
        guard let key = name(forKeyCode: keyCode) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// "⌘K", for the pill and receipts.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names = ["return": "Return", "enter": "Return", "tab": "Tab", "space": "Space", "delete": "Delete",
                     "backspace": "Delete", "escape": "Esc", "esc": "Esc", "left": "←", "right": "→",
                     "up": "↑", "down": "↓"]
        return s + (names[key] ?? key.uppercased())
    }
}
