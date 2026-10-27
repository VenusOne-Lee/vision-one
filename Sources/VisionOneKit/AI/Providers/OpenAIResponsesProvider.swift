import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gives a fresh bearer token, refreshing it when needed. ChatGPTSession
/// is the one the app uses.
public protocol AIAccessTokenSource: Sendable {
    /// Nil when signed out or when plan usage wasn't granted.
    func accessToken() async throws -> String?
}

/// OpenAI's Responses API, used two ways: rung 2 with a Sign in with
/// ChatGPT token (plan usage), and rung 4 with the user's own API key.
///
/// Plan usage rules (developers.openai.com/siwc): `store: false` and
/// `stream: true` on every request; no system-role items (use
/// `instructions`); no `temperature`, `max_output_tokens`, `metadata` or
/// `previous_response_id`. The same body works with an API key, so both
/// modes share it.
public struct OpenAIResponsesProvider: AIProvider {
    public enum Auth: Sendable {
        case chatGPT(any AIAccessTokenSource)
        case apiKey(String)
    }

    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public let id: AIProviderID
    public let rung: AIRung
    public let displayName: String
    public let model: String
    public let auth: Auth
    public let http: any HTTPClient
    public var leavesDevice: Bool { true }
    public var destination: String { "api.openai.com" }
    public var contextTokens: Int { 200_000 }
    public var price: AIPrice? {
        // GPT-6.1 Terra list price; plan usage shows R0 on the sheet.
        AIPrice(inputPerMillion: 1, outputPerMillion: 5)
    }

    /// Rung 2: the user's ChatGPT plan.
    public static func chatGPT(tokens: any AIAccessTokenSource, model: String = "gpt-6.1-terra",
                               http: any HTTPClient = URLSessionHTTPClient()) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(id: .chatGPT, rung: .chatGPT, displayName: "ChatGPT plan", model: model,
                                auth: .chatGPT(tokens), http: http)
    }

    /// Rung 4: the user's own OpenAI API key.
    public static func apiKey(_ key: String, model: String = "gpt-6.1-terra",
                              http: any HTTPClient = URLSessionHTTPClient()) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(id: .openAIKey, rung: .ownKey, displayName: "OpenAI (your key)", model: model,
                                auth: .apiKey(key), http: http)
    }

    public init(id: AIProviderID, rung: AIRung, displayName: String, model: String, auth: Auth,
                http: any HTTPClient = URLSessionHTTPClient()) {
        self.id = id
        self.rung = rung
        self.displayName = displayName
        self.model = model
        self.auth = auth
        self.http = http
    }

    public func availability() async -> AIAvailability {
        switch auth {
        case .apiKey(let key):
            return key.isEmpty ? .unavailable("Add an OpenAI API key") : .ready
        case .chatGPT(let source):
            let token = try? await source.accessToken()
            return token == nil ? .unavailable("Sign in with ChatGPT") : .ready
        }
    }

    func bearer() async throws -> String {
        switch auth {
        case .apiKey(let key): return key
        case .chatGPT(let source):
            guard let token = try await source.accessToken() else {
                throw AIError.unavailable(id, "Sign in with ChatGPT")
            }
            return token
        }
    }

    /// The request body, kept to fields plan usage accepts.
    public func body(for request: AIRequest) -> [String: Any] {
        [
            "model": request.model ?? model,
            "instructions": request.fullInstructions,
            "input": [[
                "role": "user",
                "content": [["type": "input_text", "text": request.input]],
            ]],
            "store": false,
            "stream": true,
        ]
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let token = try await bearer()
        let urlRequest = try URLRequest.json(Self.endpoint, body: body(for: request),
                                             headers: ["Authorization": "Bearer \(token)",
                                                       "Accept": "text/event-stream"])
        let (data, response) = try await http.send(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            let message = errorMessage(from: data)
            if response.statusCode == 429 || message.contains("usage_limit") { throw AIError.usageLimit(id) }
            throw AIError.http(id, status: response.statusCode, message: message)
        }
        return try Self.parseStream(String(decoding: data, as: UTF8.self), provider: id,
                                    fallbackModel: request.model ?? model)
    }

    /// Reads a Responses stream. Only `response.completed` counts as done;
    /// `response.failed` carries the plan's usage-limit codes.
    public static func parseStream(_ text: String, provider: AIProviderID, fallbackModel: String) throws -> AIResponse {
        var deltas = ""
        for event in ServerSentEvents.parse(text) {
            guard event.data != "[DONE]",
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
            else { continue }
            let type = (object["type"] as? String) ?? event.name ?? ""
            switch type {
            case "response.output_text.delta":
                deltas += (object["delta"] as? String) ?? ""
            case "response.completed":
                let response = object["response"] as? [String: Any] ?? [:]
                let text = outputText(response)
                return AIResponse(text: text.isEmpty ? deltas : text, provider: provider,
                                  model: (response["model"] as? String) ?? fallbackModel,
                                  usage: usage(response))
            case "response.failed", "error":
                let response = object["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? object
                let code = (error["code"] as? String) ?? ""
                if code.hasPrefix("subscription_sharing_usage") || code == "insufficient_quota" {
                    throw AIError.usageLimit(provider)
                }
                throw AIError.badResponse(provider, (error["message"] as? String) ?? code)
            case "response.incomplete":
                throw AIError.tooLong(provider)
            default:
                continue
            }
        }
        throw AIError.badResponse(provider, "The reply stopped before it finished.")
    }

    static func outputText(_ response: [String: Any]) -> String {
        let output = response["output"] as? [[String: Any]] ?? []
        return output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    static func usage(_ response: [String: Any]) -> AIUsage? {
        guard let usage = response["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int else { return nil }
        return AIUsage(inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0)
    }
}
