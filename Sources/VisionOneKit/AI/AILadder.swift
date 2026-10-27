import Foundation

/// The user's ladder choices, saved by the app (Settings → AI).
public struct AISettings: Codable, Equatable, Sendable {
    /// Providers in the order to try them. Missing ones go at the end in
    /// ladder order, so a new build's providers show up.
    public var order: [AIProviderID]
    /// Providers the user switched off.
    public var disabled: Set<AIProviderID>
    /// Model per provider, when the user picked one.
    public var models: [AIProviderID: String]
    /// Send keep/cut and clip picks to the Decisions API first when it is
    /// set up: it is about ten times faster and costs R0.002 a 10-minute take.
    public var preferDecisionsAPI: Bool
    /// Never send anything off the Mac, whatever else is set up.
    public var onDeviceOnly: Bool
    /// A provider for one job, such as Claude for posts.
    public var taskProviders: [AITask: AIProviderID]

    public init(order: [AIProviderID] = AIProviderID.ladderOrder, disabled: Set<AIProviderID> = [],
                models: [AIProviderID: String] = [:], preferDecisionsAPI: Bool = true,
                onDeviceOnly: Bool = false, taskProviders: [AITask: AIProviderID] = [:]) {
        self.order = order
        self.disabled = disabled
        self.models = models
        self.preferDecisionsAPI = preferDecisionsAPI
        self.onDeviceOnly = onDeviceOnly
        self.taskProviders = taskProviders
    }

    /// `order` with any unknown ladder providers added at the end.
    public var fullOrder: [AIProviderID] {
        order + AIProviderID.ladderOrder.filter { !order.contains($0) }
    }
}

/// Picks a rung for each job and runs it: cheapest available first, skipping
/// rungs the job won't fit, falling through on usage limits and outages,
/// and asking the user before anything leaves the Mac. A "no" stops the
/// job; it is never quietly sent somewhere else.
public final class AILadder: Sendable {
    public let providers: [any AIProvider]
    public let gate: OutboundGate
    public let settings: AISettings

    public init(providers: [any AIProvider], gate: OutboundGate, settings: AISettings = AISettings()) {
        self.providers = providers
        self.gate = gate
        self.settings = settings
    }

    /// Providers that may run `task`, in the order they'll be tried.
    func ordered(for task: AITask, decisions: Bool) -> [any AIProvider] {
        let rank = Dictionary(uniqueKeysWithValues: settings.fullOrder.enumerated().map { ($1, $0) })
        var list = providers
            .filter { !settings.disabled.contains($0.id) }
            .filter { !settings.onDeviceOnly || !$0.leavesDevice }
            .filter { decisions || !$0.decisionsOnly }
            .sorted { (rank[$0.id] ?? .max, $0.rung) < (rank[$1.id] ?? .max, $1.rung) }
        if decisions, settings.preferDecisionsAPI {
            let native = list.filter { $0.answersDecisionsNatively }
            list = native + list.filter { !$0.answersDecisionsNatively }
        }
        if let pinned = settings.taskProviders[task], let i = list.firstIndex(where: { $0.id == pinned }) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }

    /// The provider that would run `task` right now, for the UI.
    public func provider(for task: AITask, decisions: Bool = false, tokens: Int = 0) async -> (any AIProvider)? {
        for p in ordered(for: task, decisions: decisions) where tokens <= p.contextTokens {
            if await p.availability().isReady { return p }
        }
        return nil
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        var request = request
        let tokens = request.estimatedTokens
        var lastError: AIError = .noProvider
        for provider in ordered(for: request.task, decisions: false) {
            // Leave a quarter of the window for the reply.
            guard tokens <= provider.contextTokens * 3 / 4 else {
                lastError = .tooLong(provider.id)
                continue
            }
            guard await provider.availability().isReady else { continue }
            request.model = request.model ?? settings.models[provider.id]
            try await approve(provider, task: request.task, summary: request.summary,
                              payload: request.fullInstructions + "\n\n" + request.input,
                              inputTokens: tokens, outputTokens: 800)
            do {
                return try await provider.complete(request)
            } catch let error as AIError where error.fallsThrough {
                lastError = error
            } catch let error as URLError {
                lastError = .unavailable(provider.id, error.localizedDescription)
            }
        }
        throw lastError
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        var lastError: AIError = .noProvider
        for provider in ordered(for: request.task, decisions: true) {
            guard await provider.availability().isReady else { continue }
            let payload = request.input + "\n" + request.questions.map(\.instructions).joined(separator: "\n")
            try await approve(provider, task: request.task, summary: request.summary, payload: payload,
                              inputTokens: request.estimatedTokens,
                              outputTokens: provider.answersDecisionsNatively ? 0 : request.questions.count * 12)
            do {
                return try await provider.decide(request)
            } catch let error as AIError where error.fallsThrough {
                lastError = error
            } catch let error as URLError {
                lastError = .unavailable(provider.id, error.localizedDescription)
            }
        }
        throw lastError
    }

    private func approve(_ provider: any AIProvider, task: AITask, summary: String, payload: String,
                         inputTokens: Int, outputTokens: Int) async throws {
        guard provider.leavesDevice else { return }
        let fromPlan = provider.rung == .chatGPT
        let cost = fromPlan ? 0 : provider.price?.estimateRand(inputTokens: inputTokens, outputTokens: outputTokens)
        try await gate.check(OutboundRequest(
            provider: provider.id, providerName: provider.displayName, destination: provider.destination,
            task: task, summary: summary, payload: payload, estimatedRand: cost, fromPlan: fromPlan))
    }
}
