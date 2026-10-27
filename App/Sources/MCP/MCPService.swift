import AppKit
import SwiftUI
import VisionOneKit

/// Runs Vision One's MCP server for Claude Code, Codex and other agents:
/// a socket only this Mac user can reach, one session per connected
/// agent. Settings › Agents turns it on or off, adds Vision One to
/// Claude Code or Codex in one click, and sets each agent's rule.
@MainActor
final class MCPService: ObservableObject {
    static let shared = MCPService()

    /// Passed by the bridge when it opens the app, so no window pops up.
    nonisolated static let backgroundFlag = "--opened-by-agent"
    private static let enabledKey = "mcp.enabled"
    private static let seenKey = "mcp.seenAgents"

    /// An agent that has connected, newest first.
    struct Agent: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var lastUsed: Date
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    @Published private(set) var agents: [Agent] = []
    /// Agents set to "Allow until quit" in Settings.
    @Published private(set) var trusted: Set<String> = []
    /// Why the server isn't running, in plain words.
    @Published private(set) var problem: String?
    /// The last one-click setup's result.
    @Published var setupNote: String?

    let permissions = MCPPermissions()
    private var server: MCPSocketServer?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.seenKey),
           let saved = try? JSONDecoder().decode([Agent].self, from: data) {
            agents = saved
        }
    }

    var isRunning: Bool { server?.isRunning ?? false }

    func start() {
        guard enabled, server == nil else { return }
        let ai = AIServices.shared
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let mcp = VisionOneMCP(library: ScreenRecorder.shared.library, board: ai.jobs, desk: ai.desk,
                               host: AppMCPHost(), permissions: permissions, version: version)
        let socket = MCPSocketServer(path: MCPSocketPath.standard) { MCPSession(server: mcp) }
        do {
            try socket.start()
            server = socket
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        server?.stop()
        server = nil
        Task { await permissions.reset() }
        trusted.removeAll()
    }

    func connected(_ client: MCPClient) {
        agents.removeAll { $0.id == client.id }
        agents.insert(Agent(id: client.id, name: client.displayName, lastUsed: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(agents.prefix(20))) {
            UserDefaults.standard.set(data, forKey: Self.seenKey)
        }
    }

    func setTrusted(_ agent: Agent, _ on: Bool) {
        if on { trusted.insert(agent.id) } else { trusted.remove(agent.id) }
        let permissions = self.permissions
        Task {
            if on { await permissions.allowAll(agent.id) } else { await permissions.askFirst(agent.id) }
        }
    }

    func forget(_ agent: Agent) {
        setTrusted(agent, false)
        agents.removeAll { $0.id == agent.id }
        if let data = try? JSONEncoder().encode(agents) { UserDefaults.standard.set(data, forKey: Self.seenKey) }
    }

    // MARK: Setup

    /// The command an agent runs to start the bridge.
    static var command: [String] {
        [Bundle.main.executableURL?.path ?? "/Applications/Vision One.app/Contents/MacOS/Vision One", "--mcp"]
    }

    /// For apps that take a JSON config (Cursor, Claude Desktop).
    static var jsonConfig: String {
        let command = Self.command
        let config: JSONValue = ["mcpServers": ["vision-one": [
            "command": .string(command[0]),
            "args": .array(command.dropFirst().map { .string($0) }),
        ]]]
        return config.pretty()
    }

    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user vision-one -- " + command.map(shellQuoted).joined(separator: " ")
    }

    static var codexCommand: String {
        "codex mcp add vision-one -- " + command.map(shellQuoted).joined(separator: " ")
    }

    /// Runs the agent's own setup command in a login shell, so it finds
    /// `claude` or `codex` wherever they're installed. If that fails, the
    /// command goes on the clipboard to paste into Terminal.
    func addTo(_ agentName: String, command: String) {
        setupNote = "Adding Vision One to \(agentName)…"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var ok = false
            var said = ""
            do {
                try process.run()
                process.waitUntilExit()
                said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                ok = process.terminationStatus == 0
            } catch {
                said = error.localizedDescription
            }
            let alreadyThere = said.lowercased().contains("already exists")
            await MainActor.run {
                if ok || alreadyThere {
                    self.setupNote = "Added to \(agentName). Start a new \(agentName) session and ask it to use Vision One."
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    self.setupNote = "Couldn't find \(agentName) here, so the setup command is on your clipboard. Paste it into Terminal."
                }
            }
        }
    }

    func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setupNote = note
    }
}

/// The app's side of the MCP server: approval cards, recording, export
/// and share, each on the main actor.
struct AppMCPHost: VisionOneMCPHost {
    func ask(_ question: MCPQuestion) async -> MCPAnswer {
        await AgentAskCenter.shared.ask(question)
    }

    func dismiss(_ questionID: UUID) async {
        await AgentAskCenter.shared.dismiss(questionID)
    }

    /// The floating card asks only when the task's card is out of view.
    func showsCard(for question: MCPQuestion) async -> Bool {
        guard let jobID = question.jobID else { return true }
        let desk = await MainActor.run { AIServices.shared.desk }
        return await ApprovalPlacement.panelAsks(jobID: jobID, desk: desk)
    }

    func connected(_ client: MCPClient) async {
        await MCPService.shared.connected(client)
    }

    func isRecording() async -> Bool {
        await MainActor.run { ScreenRecorder.shared.phase.isLive }
    }

    func startRecording() async throws -> Take {
        try await Self.start()
    }

    func stopRecording() async throws -> Take {
        try await Self.stop()
    }

    func runner() async -> AgentRunner {
        await MainActor.run { AIServices.shared.runner() }
    }

    func plan(for take: Take) async -> TakePlan {
        await MainActor.run { AIServices.shared.plan(for: take) }
    }

    func brief(for plan: TakePlan) async -> AgentBrief {
        await MainActor.run { AIServices.shared.brief(for: plan) }
    }

    func export(_ take: Take, preset: ExportPreset) async throws -> URL {
        try await Self.export(take, preset: preset)
    }

    func share(_ file: URL, text: String?, to target: ShareTarget) async throws {
        await Self.share(file, text: text, to: target)
    }

    @MainActor
    private static func start() async throws -> Take {
        let recorder = ScreenRecorder.shared
        await recorder.start()
        if let take = recorder.currentTake { return take }
        if case let .failed(message) = recorder.phase { throw MCPHostError(message) }
        // Setup is missing, or Area mode wants an area dragged first:
        // Vision One is showing that now.
        throw MCPHostError("Vision One needs something from the user before it can record (Screen Recording access, or an area to drag). It's showing that now; try again once it's done.")
    }

    @MainActor
    private static func stop() async throws -> Take {
        let recorder = ScreenRecorder.shared
        guard let take = recorder.currentTake else { throw MCPHostError("Nothing is recording.") }
        await recorder.stop()
        if case let .failed(message) = recorder.phase { throw MCPHostError(message) }
        return take
    }

    @MainActor
    private static func export(_ take: Take, preset: ExportPreset) async throws -> URL {
        let controller = ExportController.shared
        let queue = ExportQueue.shared
        guard !queue.isRunning, !controller.phase.isBusy else {
            throw MCPHostError("Vision One is already exporting. Try again when that's done.")
        }
        queue.export(take, presets: [preset], keep: nil)
        var started = false
        for await phase in controller.$phase.values {
            switch phase {
            case .exporting:
                started = true
            case let .done(done, url, _) where done == preset && started:
                return url
            case let .failed(message) where started:
                throw MCPHostError(message)
            case .idle where started:
                throw MCPHostError("The export was stopped.")
            default:
                if !started, !queue.isRunning {
                    throw MCPHostError("The \(preset.title) export didn't start.")
                }
            }
        }
        throw MCPHostError("The export was stopped.")
    }

    @MainActor
    private static func share(_ file: URL, text: String?, to target: ShareTarget) {
        if let text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        NSWorkspace.shared.open(target.composer(text: text))
    }
}
