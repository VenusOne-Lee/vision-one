import Foundation

/// Something about to leave the Mac: a request to a cloud model, or a post
/// to Version One or a social network. The approval sheet shows this.
public struct OutboundRequest: Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Words of the take sent to a model.
        case aiRequest
        /// A post or launch the user is publishing.
        case post
    }

    public let id: UUID
    public var kind: Kind
    public var provider: AIProviderID
    public var providerName: String
    /// Host it goes to ("api.openai.com", "versionone.co.za").
    public var destination: String
    public var task: AITask
    public var summary: String
    /// The start of what is sent, so the user can see it's only text.
    public var preview: String
    public var characters: Int
    /// Rand, or nil when unknown. Zero when it comes from a ChatGPT plan.
    public var estimatedRand: Double?
    public var fromPlan: Bool

    public init(id: UUID = UUID(), kind: Kind = .aiRequest, provider: AIProviderID, providerName: String,
                destination: String, task: AITask, summary: String, payload: String,
                estimatedRand: Double? = nil, fromPlan: Bool = false) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.providerName = providerName
        self.destination = destination
        self.task = task
        self.summary = summary
        self.preview = String(payload.prefix(600))
        self.characters = payload.count
        self.estimatedRand = estimatedRand
        self.fromPlan = fromPlan
    }
}

public enum OutboundDecision: Equatable, Sendable {
    case allowOnce
    /// Don't ask again for this provider and job until the app quits.
    case allowForSession
    case deny
}

/// Shows the approval sheet. The app implements this with a SwiftUI sheet;
/// tests and the MCP server pass their own.
public protocol OutboundApprover: Sendable {
    func approve(_ request: OutboundRequest) async -> OutboundDecision
}

/// Approves or denies everything; for tests and headless runs.
public struct FixedApprover: OutboundApprover {
    public let decision: OutboundDecision
    public init(_ decision: OutboundDecision) { self.decision = decision }
    public func approve(_ request: OutboundRequest) async -> OutboundDecision { decision }
}

/// Every request that leaves the Mac passes through here first. Nothing on
/// the device needs approval; everything else does, unless the user chose
/// "Allow for this session" for that provider and job. Posts are never
/// remembered: each one is approved on its own.
public actor OutboundGate {
    public struct Record: Sendable {
        public let request: OutboundRequest
        public let decision: OutboundDecision
        public let at: Date
    }

    private let approver: any OutboundApprover
    private var allowed = Set<String>()
    public private(set) var history: [Record] = []

    public init(approver: any OutboundApprover) {
        self.approver = approver
    }

    /// Throws `AIError.notApproved` when the user says no.
    public func check(_ request: OutboundRequest) async throws {
        let key = "\(request.provider.rawValue)|\(request.task.rawValue)"
        if request.kind == .aiRequest, allowed.contains(key) {
            history.append(Record(request: request, decision: .allowForSession, at: Date()))
            return
        }
        let decision = await approver.approve(request)
        history.append(Record(request: request, decision: decision, at: Date()))
        switch decision {
        case .allowOnce: return
        case .allowForSession:
            if request.kind == .aiRequest { allowed.insert(key) }
        case .deny: throw AIError.notApproved
        }
    }

    /// Records a post the user approved on a card that showed its exact
    /// words and where it goes (the export sheet's share card), so it
    /// isn't asked a second time. Only posts: model requests always come
    /// through `check`.
    public func approvedInPlace(_ request: OutboundRequest) {
        guard request.kind == .post else { return }
        history.append(Record(request: request, decision: .allowOnce, at: Date()))
    }

    /// Forget every "Allow for this session".
    public func reset() {
        allowed.removeAll()
    }
}
