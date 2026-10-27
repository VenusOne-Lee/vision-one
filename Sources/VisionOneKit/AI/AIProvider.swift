import Foundation

/// The AI ladder, cheapest first. Vision One tries the lowest rung that
/// can do a job, and only climbs when the user has set the next one up.
/// See docs/AI.md.
public enum AIRung: Int, Codable, CaseIterable, Comparable, Sendable {
    /// Apple Foundation Models on the Mac. R0, nothing leaves the device.
    case onDevice = 1
    /// Sign in with ChatGPT: runs on the user's Go, Plus or Pro plan.
    case chatGPT = 2
    /// OpenAI's Decisions API (gpt-6-luna) for keep/cut and clip picks.
    /// Needs an OpenAI API key: plan usage only covers the Responses API.
    case decisions = 3
    /// The user's own key: OpenAI, Claude, OpenRouter, or a local MLX server.
    case ownKey = 4

    public static func < (lhs: AIRung, rhs: AIRung) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .onDevice: return "On this Mac"
        case .chatGPT: return "Sign in with ChatGPT"
        case .decisions: return "Decisions API"
        case .ownKey: return "Your own key"
        }
    }
}

/// Names one provider. A struct rather than an enum so a later build can
/// add providers without breaking saved settings.
public struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let appleOnDevice = AIProviderID("apple-on-device")
    public static let chatGPT = AIProviderID("chatgpt")
    public static let openAIDecisions = AIProviderID("openai-decisions")
    public static let openAIKey = AIProviderID("openai-key")
    public static let anthropicKey = AIProviderID("anthropic-key")
    public static let openRouterKey = AIProviderID("openrouter-key")
    public static let localServer = AIProviderID("local-server")

    /// Default ladder order, cheapest first.
    public static let ladderOrder: [AIProviderID] = [
        .appleOnDevice, .chatGPT, .openAIDecisions, .openAIKey, .anthropicKey, .openRouterKey, .localServer,
    ]
}

/// What a request is for. Shown on the approval sheet, and used to pick a
/// provider per job. Other features add their own (`AITask("zoomPick")`).
public struct AITask: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let producerOutline = AITask("producer.outline")
    public static let editorKeepCut = AITask("editor.keepCut")
    public static let clipScore = AITask("clipper.score")
    public static let clipTitle = AITask("clipper.title")
    public static let sharePack = AITask("sharer.pack")
    public static let custom = AITask("custom")
}

public enum AIOutputFormat: Equatable, Sendable {
    case text
    /// Ask for JSON. `shape` is a short example of the JSON wanted; it is
    /// added to the instructions, and the reply is pulled out of any prose
    /// around it, so every rung (including the 3B on-device model) can do it.
    case json(shape: String)
}

/// One job for a model: instructions (system side) plus input (user side).
public struct AIRequest: Sendable {
    public var task: AITask
    /// One line for the approval sheet: "Write a title and posts for this take".
    public var summary: String
    public var instructions: String
    public var input: String
    public var format: AIOutputFormat
    /// Overrides the provider's model for this one request.
    public var model: String?

    public init(task: AITask, summary: String, instructions: String, input: String,
                format: AIOutputFormat = .text, model: String? = nil) {
        self.task = task
        self.summary = summary
        self.instructions = instructions
        self.input = input
        self.format = format
        self.model = model
    }

    /// Instructions with the JSON shape appended when JSON is wanted.
    public var fullInstructions: String {
        switch format {
        case .text: return instructions
        case .json(let shape):
            return instructions + "\n\nReply with JSON only, no prose, shaped like this:\n" + shape
        }
    }

    /// A rough token count (4 characters a token), good enough to decide
    /// whether a request fits a small context window.
    public var estimatedTokens: Int {
        AITokens.estimate(fullInstructions) + AITokens.estimate(input)
    }
}

public enum AITokens {
    public static func estimate(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}

public struct AIUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AIResponse: Sendable {
    public var text: String
    public var provider: AIProviderID
    public var model: String
    public var usage: AIUsage?

    public init(text: String, provider: AIProviderID, model: String, usage: AIUsage? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
        self.usage = usage
    }

    /// Decodes the JSON in the reply, ignoring any prose or code fences
    /// the model wrapped around it.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try AIJSON.decode(type, from: text)
    }
}

public enum AIAvailability: Equatable, Sendable {
    case ready
    /// Why not, phrased as what the user can do: "Turn on Apple Intelligence
    /// in System Settings", "Sign in with ChatGPT", "Add an OpenAI key".
    case unavailable(String)

    public var isReady: Bool { self == .ready }
}

public enum AIError: Error, Equatable, Sendable {
    /// No rung is set up for this job.
    case noProvider
    case unavailable(AIProviderID, String)
    /// The user said no on the approval sheet. Never retried elsewhere.
    case notApproved
    /// The plan's usage limit (or the key's quota) is used up.
    case usageLimit(AIProviderID)
    case tooLong(AIProviderID)
    case refused(AIProviderID, String)
    case http(AIProviderID, status: Int, message: String)
    case badResponse(AIProviderID, String)

    /// Errors that mean "try the next rung" rather than "stop".
    public var fallsThrough: Bool {
        switch self {
        case .unavailable, .usageLimit, .tooLong, .badResponse: return true
        case .http(_, let status, _): return status == 429 || status >= 500 || status == 401 || status == 403
        case .noProvider, .notApproved, .refused: return false
        }
    }
}

/// Prices in US dollars per million tokens, for the cost line on the
/// approval sheet. Plan usage shows as "from your ChatGPT plan".
public struct AIPrice: Equatable, Sendable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// Rand per US dollar, rounded; only used for the estimate.
    public static let randPerDollar = 18.5

    public func estimateRand(inputTokens: Int, outputTokens: Int) -> Double {
        (Double(inputTokens) * inputPerMillion + Double(outputTokens) * outputPerMillion) / 1_000_000 * Self.randPerDollar
    }
}

/// One rung's worth of model. Providers are plain values; the ladder
/// decides which one runs and the gate asks the user first when it leaves
/// the Mac.
public protocol AIProvider: Sendable {
    var id: AIProviderID { get }
    var rung: AIRung { get }
    var displayName: String { get }
    /// The model used when a request doesn't name one.
    var model: String { get }
    /// True when requests go over the internet. Localhost doesn't count.
    var leavesDevice: Bool { get }
    /// Host shown on the approval sheet ("api.openai.com").
    var destination: String { get }
    /// Context window in tokens, so the ladder skips rungs a job won't fit.
    var contextTokens: Int { get }
    /// True when the provider answers `DecisionRequest`s natively (Decisions
    /// API); other providers answer them through `complete`.
    var answersDecisionsNatively: Bool { get }
    /// True when it can only answer decisions, not write text.
    var decisionsOnly: Bool { get }
    var price: AIPrice? { get }

    func availability() async -> AIAvailability
    func complete(_ request: AIRequest) async throws -> AIResponse
    func decide(_ request: DecisionRequest) async throws -> DecisionResult
}

extension AIProvider {
    public var answersDecisionsNatively: Bool { false }
    public var decisionsOnly: Bool { false }
    public var price: AIPrice? { nil }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try await DecisionEmulator(provider: self).decide(request)
    }
}
