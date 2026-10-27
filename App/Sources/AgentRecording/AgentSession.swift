import AppKit
import Carbon.HIToolbox
import VisionOneKit

/// Marks an AI agent's clicks and typing while Vision One records it.
/// Every input event names the process that posted it (0 for the
/// keyboard and trackpad), so only events posted by another app are
/// kept: the person's own input is never logged. Notes the agent sends
/// over MCP (`log_step`) go in the same list. At stop it all goes into
/// actions.json in the take.
///
/// Mouse events need no permission. The agent's typing is only seen with
/// Accessibility access (which Autopilot asks for); without it, clicks
/// are still marked.
@MainActor
final class AgentSession: ObservableObject {
    static let shared = AgentSession()

    /// Who is driving, while an agent recording is live: "Claude Code".
    @Published private(set) var agentName: String?
    @Published private(set) var isLive = false

    private var armed: (agent: String?, task: String?)?
    private var log = AgentActionLog(agent: "An agent")
    private var recorder = AgentActionRecorder()
    private var monitor: Any?
    /// What's being recorded, in Core Graphics global points.
    private var captureFrame: CGRect = .zero
    /// Host time of the first video frame, in seconds; NSEvent timestamps
    /// use the same clock.
    private var origin: TimeInterval?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The next recording is an agent recording. `agent` is nil when the
    /// person picked Record an Agent: the name then comes from the app
    /// that posts the first click.
    func arm(agent: String?, task: String?) {
        armed = (agent, task)
    }

    func disarm() {
        armed = nil
    }

    var isArmed: Bool { armed != nil }

    /// Called by the recorder once capture is running.
    func begin(captureFrame: CGRect) {
        guard let armed else { return }
        self.armed = nil
        self.captureFrame = captureFrame
        origin = nil
        recorder = AgentActionRecorder()
        log = AgentActionLog(agent: armed.agent ?? "An agent", task: armed.task)
        agentName = armed.agent
        isLive = true
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let input = Self.read(event) else { return }
            MainActor.assumeIsolated { self?.handle(input) }
        }
    }

    /// Called once the first frame is written.
    func setOrigin(_ seconds: TimeInterval) {
        guard isLive else { return }
        origin = seconds
    }

    /// A note from the agent. `point` is in global points from the top left
    /// of the main display. False when no agent recording is live.
    func logStep(_ text: String, point: CGPoint?) -> Bool {
        guard isLive else { return false }
        let t = HostClock.now - (origin ?? HostClock.now)
        let local = point.map { CGPoint(x: $0.x - captureFrame.minX, y: $0.y - captureFrame.minY) }
        recorder.step(text, at: max(0, t), x: local.map { Double($0.x) }, y: local.map { Double($0.y) })
        return true
    }

    /// Writes actions.json and stops watching.
    func end(writingTo take: Take) {
        guard isLive else { return }
        stopWatching()
        log.actions = recorder.finish()
        try? log.write(for: take)
        reset()
    }

    /// The recording failed or was thrown away.
    func cancel() {
        stopWatching()
        armed = nil
        reset()
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func reset() {
        isLive = false
        agentName = nil
        origin = nil
    }

    // MARK: Events

    /// What's needed from an event, read before hopping actors. Nil for the
    /// person's own input and Vision One's (Autopilot's) input.
    private struct Input {
        let event: AgentInputEvent.Kind
        let timestamp: TimeInterval
        let location: CGPoint
        let pid: Int32
    }

    private nonisolated static func read(_ event: NSEvent) -> Input? {
        guard let cg = event.cgEvent else { return nil }
        let origin = InputOrigin.of(sourcePID: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                    userData: cg.getIntegerValueField(.eventSourceUserData),
                                    ownPID: ProcessInfo.processInfo.processIdentifier)
        guard case let .agent(pid) = origin else { return nil }
        let kind: AgentInputEvent.Kind
        switch event.type {
        case .leftMouseDown: kind = .mouseDown(.left, clickCount: event.clickCount)
        case .rightMouseDown: kind = .mouseDown(.right, clickCount: event.clickCount)
        case .otherMouseDown: kind = .mouseDown(.other, clickCount: event.clickCount)
        case .leftMouseUp: kind = .mouseUp(.left)
        case .rightMouseUp: kind = .mouseUp(.right)
        case .otherMouseUp: kind = .mouseUp(.other)
        case .scrollWheel: kind = .scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        case .keyDown:
            var modifiers: AgentInputEvent.Modifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            kind = .key(characters: event.characters ?? "", bare: event.charactersIgnoringModifiers ?? "",
                        keyCode: event.keyCode, modifiers: modifiers)
        default:
            return nil
        }
        return Input(event: kind, timestamp: event.timestamp, location: cg.location, pid: pid)
    }

    private func handle(_ input: Input) {
        guard isLive, let origin else { return }
        if agentName == nil {
            let name = AgentProcess.describe(input.pid).displayName
            agentName = name
            log.agent = name
        }
        let x = Double(input.location.x - captureFrame.minX)
        let y = Double(input.location.y - captureFrame.minY)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        recorder.add(AgentInputEvent(input.event, t: input.timestamp - origin, x: x, y: y, app: front,
                                     secure: IsSecureEventInputEnabled()))
    }
}

/// Which app a process belongs to: its own app, or the app bundle a
/// helper process sits inside (Claude's computer use runs in a helper).
struct AgentProcess {
    var bundleID: String?
    var name: String?
    var processName: String?

    /// "Claude", or the process's own name for command line tools.
    var displayName: String {
        AgentApps.match(bundleID: bundleID, processName: processName ?? name) ?? name ?? processName ?? "An agent"
    }

    static func describe(_ pid: Int32) -> AgentProcess {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
            return AgentProcess(bundleID: app.bundleIdentifier, name: app.localizedName,
                                processName: app.executableURL?.lastPathComponent)
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return AgentProcess() }
        let path = String(cString: buffer)
        let process = (path as NSString).lastPathComponent
        // The outermost .app in the path is the app the helper belongs to.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = parts[...index].joined(separator: "/")
            let bundle = Bundle(path: appPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? String(parts[index].dropLast(4))
            return AgentProcess(bundleID: bundle?.bundleIdentifier, name: name, processName: process)
        }
        return AgentProcess(bundleID: nil, name: nil, processName: process)
    }
}

/// Whether the event that pressed a button came from the person. A
/// computer-use agent can click anywhere, including on Vision One's own
/// approval cards, so a "yes" only counts from the real keyboard, mouse
/// or trackpad.
enum PersonInput {
    @MainActor
    static func pressedByPerson(_ event: NSEvent? = NSApp.currentEvent) -> Bool {
        guard let cg = event?.cgEvent else { return true }
        let origin = InputOrigin.of(sourcePID: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                    userData: cg.getIntegerValueField(.eventSourceUserData),
                                    ownPID: ProcessInfo.processInfo.processIdentifier)
        return !origin.isAgent
    }
}
