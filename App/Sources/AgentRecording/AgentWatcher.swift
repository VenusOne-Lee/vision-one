import AppKit
import VisionOneKit

/// Offers to record when a known agent app (Claude, ChatGPT, Codex,
/// Cursor) starts clicking or typing on this Mac: "Claude is using your
/// Mac. Record it?" on the usual card. Only clicks and keys from those
/// apps count, and nothing is recorded until you say yes. Settings ›
/// Agents turns the offer off.
@MainActor
final class AgentWatcher {
    static let shared = AgentWatcher()

    private static let enabledKey = "agents.offerToRecord"
    private var monitor: Any?
    private var detector = AgentTakeoverDetector()
    /// Agent apps the person said "Allow until quit" to: recorded without
    /// asking again until Vision One quits.
    private var allowed: Set<String> = []
    private var asking = false

    /// Settings › Agents, "Offer to record when an agent uses this Mac".
    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Call once at launch.
    func start() {
        guard enabled, monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let cg = event.cgEvent else { return }
            let origin = InputOrigin.of(sourcePID: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                        userData: cg.getIntegerValueField(.eventSourceUserData),
                                        ownPID: ProcessInfo.processInfo.processIdentifier)
            guard case let .agent(pid) = origin else { return }
            let time = event.timestamp
            MainActor.assumeIsolated { self?.saw(pid: pid, at: time) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func saw(pid: Int32, at time: TimeInterval) {
        let recorder = ScreenRecorder.shared
        guard !asking, !recorder.phase.isLive, !recorder.phase.isBusy, !recorder.isCountingDown,
              !AgentSession.shared.isArmed else { return }
        let process = AgentProcess.describe(pid)
        guard let name = AgentApps.match(bundleID: process.bundleID, processName: process.processName ?? process.name),
              detector.see(pid: pid, at: time) else { return }
        if allowed.contains(name) {
            record(name)
            return
        }
        asking = true
        Task {
            let client = MCPClient(name: name.lowercased(), title: name)
            let question = MCPQuestion(action: .record, client: client,
                                       title: "\(name) is using your Mac. Record it?",
                                       details: [
                                           .init("Records", "Your screen, as you last set it"),
                                           .init("Marks", "\(name)'s clicks and typing, never yours. Passwords hidden."),
                                           .init("Stops", "When you press Stop"),
                                       ])
            let answer = await AgentAskCenter.shared.ask(question)
            asking = false
            guard answer.allowed else { return }
            if answer.decision == .allowForSession { allowed.insert(name) }
            record(name)
        }
    }

    private func record(_ name: String) {
        let session = AgentSession.shared
        session.arm(agent: name, task: nil)
        Task {
            // No countdown: the agent is already moving.
            await ScreenRecorder.shared.start()
            if !ScreenRecorder.shared.phase.isLive { session.disarm() }
        }
    }
}
