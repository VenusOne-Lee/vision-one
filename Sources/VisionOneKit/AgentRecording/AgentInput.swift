import Foundation

/// Who made an input event. Every Core Graphics event carries the id of
/// the process that posted it: 0 for the keyboard, mouse and trackpad,
/// the poster's own id for synthetic events. Apps that refuse fake clicks
/// check the same field.
public enum InputOrigin: Equatable, Sendable {
    /// The person, at the keyboard or trackpad.
    case person
    /// Vision One itself: Autopilot's events carry its tag.
    case visionOne
    /// Another process posted it: most likely an agent.
    case agent(pid: Int32)

    /// "VION", which Autopilot puts in each event's user data field.
    public static let autopilotTag: Int64 = 0x5649_4F4E

    public static func of(sourcePID: Int64, userData: Int64, ownPID: Int32) -> InputOrigin {
        if userData == autopilotTag { return .visionOne }
        if sourcePID <= 0 { return .person }
        let pid = Int32(truncatingIfNeeded: sourcePID)
        if pid == ownPID { return .visionOne }
        return .agent(pid: pid)
    }

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

/// Apps known to drive a Mac for an AI agent. Vision One offers to record
/// when one of these takes the mouse; any other app never sets that off.
public enum AgentApps {
    public struct Known: Equatable, Sendable {
        public var name: String
        public var bundlePrefixes: [String]
        public var processNames: [String]
    }

    public static let known: [Known] = [
        Known(name: "Claude", bundlePrefixes: ["com.anthropic."], processNames: ["claude"]),
        Known(name: "ChatGPT", bundlePrefixes: ["com.openai.chat"], processNames: ["chatgpt"]),
        Known(name: "Codex", bundlePrefixes: ["com.openai.codex"], processNames: ["codex"]),
        Known(name: "Cursor", bundlePrefixes: ["com.todesktop.230313mzl4w4u92"], processNames: ["cursor"]),
        Known(name: "Perplexity", bundlePrefixes: ["ai.perplexity."], processNames: ["comet", "perplexity"]),
        Known(name: "Computer use", bundlePrefixes: [], processNames: ["cliclick", "computer-use", "computer_use"]),
    ]

    /// The agent's name when the posting app (or its helper process) is a
    /// known agent, else nil.
    public static func match(bundleID: String?, processName: String?) -> String? {
        let bundle = bundleID?.lowercased() ?? ""
        let process = processName?.lowercased() ?? ""
        for app in known {
            if !bundle.isEmpty, app.bundlePrefixes.contains(where: { bundle.hasPrefix($0.lowercased()) }) {
                return app.name
            }
            if !process.isEmpty, app.processNames.contains(where: { process == $0 || process.hasPrefix($0 + " ") }) {
                return app.name
            }
        }
        return nil
    }
}

/// Decides when to offer "Claude is using your Mac. Record it?": a few
/// clicks or keys from one known agent close together, not a single stray
/// event, and not again for a while after the offer.
public struct AgentTakeoverDetector: Sendable {
    public var eventsNeeded: Int
    public var within: Double
    /// After an offer (answered or not), stay quiet this long.
    public var quietAfterOffer: Double

    private var recent: [Int32: [Double]] = [:]
    private var lastOffer: Double?

    public init(eventsNeeded: Int = 3, within: Double = 5, quietAfterOffer: Double = 600) {
        self.eventsNeeded = eventsNeeded
        self.within = within
        self.quietAfterOffer = quietAfterOffer
    }

    /// Feed one event from an agent at host time `t`. Returns true when
    /// it's time to offer.
    public mutating func see(pid: Int32, at t: Double) -> Bool {
        if let lastOffer, t - lastOffer < quietAfterOffer { return false }
        var times = (recent[pid] ?? []).filter { t - $0 <= within }
        times.append(t)
        recent[pid] = times
        guard times.count >= eventsNeeded else { return false }
        recent.removeAll()
        lastOffer = t
        return true
    }
}
