import Foundation

/// What Autopilot may and may not do. Checked before a run starts and
/// again before every step, against what is really on screen.
public struct AutopilotPolicy: Equatable, Sendable {
    /// Apps Autopilot never acts in, whatever a demo says: settings,
    /// shells, passwords, and Vision One itself.
    public static let alwaysBlocked: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.Settings",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.ScriptEditor2",
        "com.apple.Automator",
        "com.apple.installer",
        "za.co.versionone.visionone",
    ]

    /// Longest a run may take before it stops by itself.
    public var maxRunSeconds: Double
    /// Seconds to wait for a step's target to appear before giving up.
    public var findTimeout: Double
    /// Pause when the person moves the mouse or types.
    public var pauseOnTouch: Bool

    public init(maxRunSeconds: Double = 600, findTimeout: Double = 8, pauseOnTouch: Bool = true) {
        self.maxRunSeconds = maxRunSeconds
        self.findTimeout = findTimeout
        self.pauseOnTouch = pauseOnTouch
    }

    public func isAlwaysBlocked(_ bundleID: String) -> Bool {
        Self.alwaysBlocked.contains(bundleID)
    }

    /// Whether `step` may act on `element`, which sits in the app
    /// `bundleID`, for `demo`.
    public func check(_ step: DemoStep, in demo: DemoScript, bundleID: String?,
                      element: UICandidate? = nil) -> Verdict {
        guard let bundleID else { return .stop(.unknownApp) }
        if isAlwaysBlocked(bundleID) { return .stop(.blockedApp(Self.appName(bundleID))) }
        guard demo.appsInPlay.contains(bundleID) else { return .stop(.notAllowed(Self.appName(bundleID))) }
        if let element {
            if element.isSecure, step.action == .type || step.action == .click {
                return .stop(.passwordField)
            }
            if !element.isEnabled, step.action == .click { return .wait }
        }
        return .go
    }

    public enum Verdict: Equatable, Sendable {
        case go
        /// Not ready yet (a disabled button): wait and look again.
        case wait
        case stop(StopReason)
    }

    /// A readable name for a bundle id.
    public static func appName(_ bundleID: String) -> String {
        let known = [
            "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "company.thebrowser.dia": "Dia",
            "company.thebrowser.Browser": "Arc", "org.mozilla.firefox": "Firefox",
            "com.apple.systempreferences": "System Settings", "com.apple.Settings": "System Settings",
            "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
            "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords",
            "com.1password.1password": "1Password", "com.apple.finder": "Finder",
            "za.co.versionone.visionone": "Vision One",
        ]
        if let name = known[bundleID] { return name }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

/// Why a run stopped before the end, in words for the receipt.
public enum StopReason: Codable, Equatable, Sendable {
    /// The person pressed Esc.
    case escape
    /// The person pressed Stop.
    case stopped
    /// The run went past `maxRunSeconds`.
    case tooLong
    /// A step would have acted in an app the demo doesn't allow.
    case notAllowed(String)
    /// A step would have acted in an app Autopilot never touches.
    case blockedApp(String)
    case unknownApp
    case passwordField
    /// The target never appeared.
    case notFound(String)
    /// Accessibility access is off.
    case noAccess
    /// Recording couldn't start.
    case recordingFailed(String)

    public var message: String {
        switch self {
        case .escape: return "You pressed Esc."
        case .stopped: return "You stopped it."
        case .tooLong: return "It ran past the time limit."
        case .notAllowed(let app): return "It would have clicked in \(app), which this demo doesn't allow."
        case .blockedApp(let app): return "Autopilot never acts in \(app)."
        case .unknownApp: return "It couldn't tell which app was in front."
        case .passwordField: return "That's a password field. Autopilot never types or clicks in one."
        case .notFound(let what): return "It couldn't find \(what)."
        case .noAccess: return "Autopilot needs Accessibility access. Turn it on in Access."
        case .recordingFailed(let why): return "Recording didn't start: \(why)"
        }
    }

    /// Stops the person caused, which aren't failures.
    public var byPerson: Bool { self == .escape || self == .stopped }
}

/// One thing on screen Autopilot could act on, as read from the app's
/// accessibility tree. The app fills these in; matching is plain logic.
public struct UICandidate: Equatable, Sendable {
    public var role: String
    /// Title, then description, then value: what a person would call it.
    public var name: String
    public var identifier: String?
    /// Frame in screen points, top left origin.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var isEnabled: Bool
    /// A password field.
    public var isSecure: Bool

    public init(role: String, name: String, identifier: String? = nil, x: Double, y: Double,
                width: Double, height: Double, isEnabled: Bool = true, isSecure: Bool = false) {
        self.role = role
        self.name = name
        self.identifier = identifier
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isEnabled = isEnabled
        self.isSecure = isSecure || role == "AXSecureTextField"
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    /// Where its centre sits in `window`, as fractions.
    public func unitPoint(in window: CaptureRect) -> UnitPoint {
        guard window.width > 0, window.height > 0 else { return UnitPoint(x: 0.5, y: 0.5) }
        return UnitPoint(x: min(max((centerX - window.x) / window.width, 0), 1),
                         y: min(max((centerY - window.y) / window.height, 0), 1))
    }
}
