import Foundation

/// A demo Autopilot can record again and again: which app, which apps it
/// may touch, and the steps in order. Saved as one small JSON file, either
/// in Vision One's Demos folder or in the product's own repo
/// (`.visionone/demos/checkout.json`), so it changes with the code.
///
///     {
///       "version": 1,
///       "name": "Checkout demo",
///       "app": { "bundleID": "com.apple.Safari", "open": "https://rankride.co.za/ranks" },
///       "allowedApps": ["com.apple.Safari"],
///       "steps": [
///         { "do": "click", "target": { "role": "AXLink", "name": "Bree St rank" }, "say": "Pick your rank." },
///         { "do": "wait", "seconds": 1.5 }
///       ]
///     }
public struct DemoScript: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var app: DemoApp
    /// Bundle ids Autopilot may act in. The demo's own app is always
    /// allowed; `AutopilotPolicy.alwaysBlocked` never is.
    public var allowedApps: [String]
    /// The window size to record at, in points. Nil keeps the window as it is.
    public var window: WindowSize?
    public var pace: Pace
    public var steps: [DemoStep]
    /// Where releases come from, "owner/repo". Nil means don't watch.
    public var repo: String?
    /// Re-record when `repo` ships a new release.
    public var rerecordOnRelease: Bool

    public static let currentVersion = 1

    public init(name: String, app: DemoApp, allowedApps: [String] = [], window: WindowSize? = nil,
                pace: Pace = .normal, steps: [DemoStep] = [], repo: String? = nil,
                rerecordOnRelease: Bool = true) {
        self.version = Self.currentVersion
        self.name = name
        self.app = app
        self.allowedApps = allowedApps
        self.window = window
        self.pace = pace
        self.steps = steps
        self.repo = repo
        self.rerecordOnRelease = rerecordOnRelease
    }

    enum CodingKeys: String, CodingKey {
        case version, name, app, allowedApps, window, pace, steps, repo, rerecordOnRelease
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        name = try c.decode(String.self, forKey: .name)
        app = try c.decode(DemoApp.self, forKey: .app)
        allowedApps = try c.decodeIfPresent([String].self, forKey: .allowedApps) ?? []
        window = try c.decodeIfPresent(WindowSize.self, forKey: .window)
        pace = try c.decodeIfPresent(Pace.self, forKey: .pace) ?? .normal
        steps = try c.decodeIfPresent([DemoStep].self, forKey: .steps) ?? []
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        rerecordOnRelease = try c.decodeIfPresent(Bool.self, forKey: .rerecordOnRelease) ?? true
    }

    /// Every app this demo may act in: its own app plus the extra ones.
    public var appsInPlay: [String] {
        var apps = [app.bundleID]
        for id in allowedApps where !apps.contains(id) { apps.append(id) }
        return apps
    }

    /// The words to read over the video, one step's line after another.
    public var script: String {
        steps.compactMap { $0.say?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A rough length: each step's own time plus the pace's pause after it.
    public var estimatedSeconds: Double {
        steps.reduce(0) { $0 + $1.estimatedSeconds(pace: pace) }
    }

    /// "checkout-demo", for file names.
    public var slug: String { Self.slug(name) }

    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = name.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        return words.isEmpty ? "demo" : words.joined(separator: "-")
    }

    // MARK: Files

    public static func load(from url: URL) throws -> DemoScript {
        try JSONDecoder().decode(DemoScript.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Checking

    /// What's wrong with a demo before it runs, in plain words. Empty
    /// means it can run.
    public func problems(policy: AutopilotPolicy = AutopilotPolicy()) -> [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("Give the demo a name.") }
        if steps.isEmpty { found.append("Add at least one step.") }
        if app.bundleID.isEmpty { found.append("Pick the app the demo runs in.") }
        for id in appsInPlay where policy.isAlwaysBlocked(id) {
            found.append("Autopilot never acts in \(AutopilotPolicy.appName(id)).")
        }
        for (i, step) in steps.enumerated() {
            if let problem = step.problem { found.append("Step \(i + 1): \(problem)") }
        }
        return found
    }
}

/// The app a demo runs in, and what to open first.
public struct DemoApp: Codable, Equatable, Sendable {
    public var bundleID: String
    /// Shown in the pill: "Autopilot is driving Safari".
    public var name: String?
    /// A web address or file to open in the app before the first step.
    public var open: String?

    public init(bundleID: String, name: String? = nil, open: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.open = open
    }

    public var displayName: String { name ?? AutopilotPolicy.appName(bundleID) }
}

public struct WindowSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// How quickly Autopilot moves. Calm reads best for tutorials, quick for
/// short clips.
public enum Pace: String, Codable, CaseIterable, Sendable {
    case calm, normal, quick

    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .normal: return "Normal"
        case .quick: return "Quick"
        }
    }

    /// Points per second the cursor glides at.
    public var cursorSpeed: Double {
        switch self {
        case .calm: return 900
        case .normal: return 1400
        case .quick: return 2200
        }
    }

    /// The pause after each step, so viewers see what happened.
    public var pauseAfterStep: Double {
        switch self {
        case .calm: return 1.2
        case .normal: return 0.7
        case .quick: return 0.35
        }
    }

    /// Seconds between typed characters.
    public var typingInterval: Double {
        switch self {
        case .calm: return 0.09
        case .normal: return 0.06
        case .quick: return 0.03
        }
    }
}

/// One thing Autopilot does.
public struct DemoStep: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        /// Open `text` (a web address or file) in the demo's app.
        case open
        /// Press the target.
        case click
        /// Glide to the target and rest there, so viewers look at it.
        case point
        /// Type `text`, into the target when there is one.
        case type
        /// Press a key combination in `keys`, like "cmd+k".
        case press
        /// Scroll `direction` by `amount` lines, over the target if any.
        case scroll
        /// Wait `seconds`, or until the target appears when there is one.
        case wait
    }

    public enum Direction: String, Codable, CaseIterable, Sendable {
        case up, down, left, right
    }

    public var id: UUID
    public var action: Action
    public var target: UITarget?
    public var text: String?
    public var keys: String?
    public var direction: Direction?
    public var amount: Int?
    public var seconds: Double?
    /// The line to read over this step.
    public var say: String?

    public init(id: UUID = UUID(), _ action: Action, target: UITarget? = nil, text: String? = nil,
                keys: String? = nil, direction: Direction? = nil, amount: Int? = nil,
                seconds: Double? = nil, say: String? = nil) {
        self.id = id
        self.action = action
        self.target = target
        self.text = text
        self.keys = keys
        self.direction = direction
        self.amount = amount
        self.seconds = seconds
        self.say = say
    }

    enum CodingKeys: String, CodingKey {
        case id, action = "do", target, text, keys, direction, amount, seconds, say
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try c.decode(Action.self, forKey: .action)
        target = try c.decodeIfPresent(UITarget.self, forKey: .target)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        keys = try c.decodeIfPresent(String.self, forKey: .keys)
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        say = try c.decodeIfPresent(String.self, forKey: .say)
    }

    /// What's missing for this step to run, if anything.
    public var problem: String? {
        switch action {
        case .open:
            return (text ?? "").isEmpty ? "say what to open." : nil
        case .click, .point:
            return target == nil ? "say what to \(action == .click ? "click" : "point at")." : nil
        case .type:
            return (text ?? "").isEmpty ? "say what to type." : nil
        case .press:
            guard let keys, !keys.isEmpty else { return "say which keys to press." }
            return KeyCombo(keys) == nil ? "“\(keys)” isn't a key Vision One knows." : nil
        case .scroll, .wait:
            return nil
        }
    }

    /// About how long the step takes, with the pause after it.
    public func estimatedSeconds(pace: Pace) -> Double {
        let own: Double
        switch action {
        case .open: own = 2
        case .click, .point: own = 0.8
        case .type: own = Double((text ?? "").count) * pace.typingInterval + 0.6
        case .press, .scroll: own = 0.4
        case .wait: own = seconds ?? 1
        }
        return own + pace.pauseAfterStep
    }
}

/// How Autopilot finds a thing on screen: the way a person names it
/// (role and visible name), like Playwright's getByRole. The position is
/// only a fallback, so a re-record survives a button moving.
public struct UITarget: Codable, Equatable, Hashable, Sendable {
    /// Accessibility role, like "AXButton", "AXLink", "AXTextField".
    public var role: String?
    /// Visible name: the button's title, the link's text, the field's label.
    public var name: String?
    /// The developer's accessibility identifier, when the app sets one.
    public var identifier: String?
    /// Which match to take when several fit, counted from 0.
    public var index: Int?
    /// Where it was last seen, as a fraction of the window (0...1), so a
    /// renamed button in the same spot can be suggested as a fix.
    public var lastSeen: UnitPoint?

    public init(role: String? = nil, name: String? = nil, identifier: String? = nil,
                index: Int? = nil, lastSeen: UnitPoint? = nil) {
        self.role = role
        self.name = name
        self.identifier = identifier
        self.index = index
        self.lastSeen = lastSeen
    }

    /// "“Pay now” button", for receipts and the pill.
    public var label: String {
        let kind = role.map(AXRoleName.plain) ?? ""
        if let name, !name.isEmpty { return kind.isEmpty ? "“\(name)”" : "“\(name)” \(kind)" }
        if let identifier { return kind.isEmpty ? identifier : "\(kind) \(identifier)" }
        return kind.isEmpty ? "the spot" : "the \(kind)"
    }
}

/// A point as fractions of a rectangle, 0 to 1, top left origin.
public struct UnitPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Plain names for accessibility roles.
public enum AXRoleName {
    public static func plain(_ role: String) -> String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "field"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "option"
        case "AXMenuItem", "AXMenuBarItem": return "menu item"
        case "AXTab", "AXTabButton": return "tab"
        case "AXRow", "AXCell": return "row"
        case "AXImage": return "image"
        case "AXStaticText": return "text"
        case "AXSlider": return "slider"
        default:
            let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return trimmed.lowercased()
        }
    }

    /// The role for a plain word, for steps typed by hand.
    public static func role(for word: String) -> String? {
        switch word.lowercased() {
        case "button": return "AXButton"
        case "link": return "AXLink"
        case "field", "text field", "box": return "AXTextField"
        case "checkbox": return "AXCheckBox"
        case "tab": return "AXTab"
        case "menu item": return "AXMenuItem"
        case "row": return "AXRow"
        default: return nil
        }
    }
}
