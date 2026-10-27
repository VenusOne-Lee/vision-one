import Foundation

/// What an agent wants to do that waits for the user's yes: shown on a
/// card in Vision One, never decided by the agent.
public struct MCPQuestion: Identifiable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case record, keep, share

        /// Shares ask every time. The others can be allowed until quit.
        public var canRemember: Bool { self != .share }
    }

    public struct Detail: Equatable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public let id: UUID
    public var action: Action
    public var client: MCPClient
    /// "Record your screen for Claude Code?"
    public var title: String
    public var details: [Detail]
    /// The words of a post, so the user sees exactly what goes out.
    public var preview: String?
    /// The task it belongs to, so the card can sit on it too.
    public var jobID: UUID?

    public init(id: UUID = UUID(), action: Action, client: MCPClient, title: String, details: [Detail] = [],
                preview: String? = nil, jobID: UUID? = nil) {
        self.id = id
        self.action = action
        self.client = client
        self.title = title
        self.details = details
        self.preview = preview
        self.jobID = jobID
    }

    public var canRemember: Bool { action.canRemember }
}

/// The user's answer. A "no" may carry a note for the agent ("record the
/// window, not the whole screen"), which goes back in the tool's reply.
public struct MCPAnswer: Equatable, Sendable {
    public var decision: OutboundDecision
    public var note: String?

    public init(_ decision: OutboundDecision, note: String? = nil) {
        self.decision = decision
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = trimmed.isEmpty ? nil : trimmed
    }

    public static let no = MCPAnswer(.deny)
    public var allowed: Bool { decision != .deny }
}

/// Which agents may skip the card until Vision One quits. Shares are never
/// remembered, so a share always asks.
public actor MCPPermissions {
    private var allowed: [String: Set<MCPQuestion.Action>] = [:]

    public init() {}

    public func allows(_ client: MCPClient, _ action: MCPQuestion.Action) -> Bool {
        action.canRemember && allowed[client.id]?.contains(action) == true
    }

    /// "Allow until quit" on a card: only that kind of request.
    public func allow(_ client: MCPClient, _ action: MCPQuestion.Action) {
        guard action.canRemember else { return }
        allowed[client.id, default: []].insert(action)
    }

    /// Settings › Agents, "Allow until quit": everything that can be remembered.
    public func allowAll(_ clientID: String) {
        allowed[clientID] = Set(MCPQuestion.Action.allCases.filter(\.canRemember))
    }

    /// Settings › Agents, "Ask first".
    public func askFirst(_ clientID: String) {
        allowed[clientID] = nil
    }

    public func allowsAll(_ clientID: String) -> Bool {
        MCPQuestion.Action.allCases.filter(\.canRemember).allSatisfy { allowed[clientID]?.contains($0) == true }
    }

    public func reset() {
        allowed.removeAll()
    }
}

/// The parts of the server only the app can do: show the approval card,
/// record, export, open a share. Tests pass a stand-in.
public protocol VisionOneMCPHost: Sendable {
    /// Shows the card and waits for the user.
    func ask(_ question: MCPQuestion) async -> MCPAnswer
    /// Takes the card away when the user answered on the task instead.
    func dismiss(_ questionID: UUID) async
    /// For a question on a task: whether the floating card asks too. No
    /// when the task's card is in view (the main window is in front), so
    /// the user is asked once (`ApprovalSurface`).
    func showsCard(for question: MCPQuestion) async -> Bool
    /// An agent connected (for Settings › Agents).
    func connected(_ client: MCPClient) async
    func isRecording() async -> Bool
    /// Starts recording with the user's last screen and sound choices,
    /// and returns the new take once frames are being written.
    func startRecording() async throws -> Take
    /// Stops and saves; the app transcribes the take after.
    func stopRecording() async throws -> Take
    /// The app's agents, on its AI ladder and approval gate.
    func runner() async -> AgentRunner
    func plan(for take: Take) async -> TakePlan
    func brief(for plan: TakePlan) async -> AgentBrief
    /// Exports with the brand kit, like the Export sheet. Returns the file.
    func export(_ take: Take, preset: ExportPreset) async throws -> URL
    /// Shows the file, copies the words and opens the post. The user posts.
    func share(_ file: URL, text: String?, to target: ShareTarget) async throws
    /// The Autopilot demos on this Mac and in linked repos.
    func demos() async -> [DemoFile]
    /// Starts Autopilot on the demo called `name` and returns its job id
    /// on the board, or nil when there's no such demo. Autopilot asks the
    /// user itself unless they let these steps run on their own.
    func rerecordDemo(_ name: String, release: String?, requestedBy: String) async -> UUID?
}

extension VisionOneMCPHost {
    public func demos() async -> [DemoFile] { [] }
    public func rerecordDemo(_ name: String, release: String?, requestedBy: String) async -> UUID? { nil }
}

public extension VisionOneMCPHost {
    /// Hosts without a window always show the card.
    func showsCard(for question: MCPQuestion) async -> Bool { true }
}

/// A plain message from the app for the agent ("Pick an area first").
public struct MCPHostError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Who started the job about to run and the id it should take, so a tool
/// can follow a job the agents create. `AgentRunner` reads it.
public struct AgentJobOrigin: Sendable {
    public var jobID: UUID
    public var requestedBy: String

    public init(jobID: UUID = UUID(), requestedBy: String) {
        self.jobID = jobID
        self.requestedBy = requestedBy
    }
}

public enum MCPJobContext {
    @TaskLocal public static var origin: AgentJobOrigin?
}

extension AgentJob.Approval {
    /// An agent's request, as the task's approve card shows it.
    init(_ question: MCPQuestion, destination: String) {
        id = question.id
        isPost = question.action == .share
        summary = question.title
        providerName = question.client.displayName
        self.destination = destination
        let text = question.preview ?? question.details.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        preview = String(text.prefix(600))
        characters = text.count
        estimatedRand = nil
        fromPlan = false
        askedBy = question.client.displayName
        canRemember = question.canRemember
    }
}
