import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rung 4: Claude with the user's own Anthropic key (Messages API).
public struct AnthropicProvider: AIProvider {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public let apiKey: String
    public let model: String
    public let http: any HTTPClient

    public var id: AIProviderID { .anthropicKey }
    public var rung: AIRung { .ownKey }
    public var displayName: String { "Claude (your key)" }
    public var leavesDevice: Bool { true }
    public var destination: String { "api.anthropic.com" }
    public var contextTokens: Int { 200_000 }
    public var price: AIPrice? {
        model.contains("haiku") ? AIPrice(inputPerMillion: 0.10, outputPerMillion: 0.50)
            : AIPrice(inputPerMillion: 2, outputPerMillion: 10)
    }

    public init(apiKey: String, model: String = "claude-haiku-5-5", http: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    public func availability() async -> AIAvailability {
        apiKey.isEmpty ? .unavailable("Add an Anthropic API key") : .ready
    }

    public func body(for request: AIRequest) -> [String: Any] {
        [
            "model": request.model ?? model,
            "max_tokens": 4096,
            "system": request.fullInstructions,
            "messages": [["role": "user", "content": request.input]],
        ]
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let urlRequest = try URLRequest.json(Self.endpoint, body: body(for: request), headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ])
        let (data, response) = try await http.send(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 { throw AIError.usageLimit(id) }
            throw AIError.http(id, status: response.statusCode, message: errorMessage(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(id, "The reply wasn't JSON.")
        }
        let content = object["content"] as? [[String: Any]] ?? []
        let text = content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        if (object["stop_reason"] as? String) == "refusal" { throw AIError.refused(id, text) }
        var usage: AIUsage?
        if let u = object["usage"] as? [String: Any], let input = u["input_tokens"] as? Int {
            usage = AIUsage(inputTokens: input, outputTokens: u["output_tokens"] as? Int ?? 0)
        }
        return AIResponse(text: text, provider: id, model: (object["model"] as? String) ?? model, usage: usage)
    }
}

/// Rung 4: anything that speaks OpenAI's chat completions: OpenRouter with
/// the user's key, or a local server on the Mac (mlx_lm.server, LM Studio,
/// Ollama), which never leaves the device and needs no approval.
public struct OpenAICompatibleProvider: AIProvider {
    public let id: AIProviderID
    public let displayName: String
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let contextTokens: Int
    public let http: any HTTPClient

    public var rung: AIRung { .ownKey }
    public var destination: String { baseURL.host ?? baseURL.absoluteString }
    public var leavesDevice: Bool {
        let host = (baseURL.host ?? "").lowercased()
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }

    public static func openRouter(apiKey: String, model: String = "openai/gpt-6.1-terra",
                                  http: any HTTPClient = URLSessionHTTPClient()) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: .openRouterKey, displayName: "OpenRouter (your key)",
                                 baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                                 apiKey: apiKey, model: model, contextTokens: 128_000, http: http)
    }

    /// mlx_lm.server listens on 8080 by default; LM Studio on 1234, Ollama on 11434.
    public static func local(baseURL: URL = URL(string: "http://127.0.0.1:8080/v1")!, model: String,
                             contextTokens: Int = 8_192,
                             http: any HTTPClient = URLSessionHTTPClient()) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: .localServer, displayName: "Local model (\(model))", baseURL: baseURL,
                                 apiKey: nil, model: model, contextTokens: contextTokens, http: http)
    }

    public init(id: AIProviderID, displayName: String, baseURL: URL, apiKey: String?, model: String,
                contextTokens: Int, http: any HTTPClient = URLSessionHTTPClient()) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.contextTokens = contextTokens
        self.http = http
    }

    public func availability() async -> AIAvailability {
        if let apiKey, apiKey.isEmpty { return .unavailable("Add an OpenRouter API key") }
        if model.isEmpty { return .unavailable("Pick a model") }
        return .ready
    }

    public func body(for request: AIRequest) -> [String: Any] {
        [
            "model": request.model ?? model,
            "messages": [
                ["role": "system", "content": request.fullInstructions],
                ["role": "user", "content": request.input],
            ],
        ]
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        var headers: [String: String] = ["X-Title": "Vision One"]
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        let urlRequest = try URLRequest.json(baseURL.appendingPathComponent("chat/completions"),
                                             body: body(for: request), headers: headers)
        let result: (Data, HTTPURLResponse)
        do {
            result = try await http.send(urlRequest)
        } catch {
            // A local server that isn't running is just an unavailable rung.
            throw AIError.unavailable(id, "Couldn't reach \(destination).")
        }
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 || response.statusCode == 402 { throw AIError.usageLimit(id) }
            throw AIError.http(id, status: response.statusCode, message: errorMessage(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.badResponse(id, "No reply in the response.")
        }
        var usage: AIUsage?
        if let u = object["usage"] as? [String: Any], let input = u["prompt_tokens"] as? Int {
            usage = AIUsage(inputTokens: input, outputTokens: u["completion_tokens"] as? Int ?? 0)
        }
        return AIResponse(text: (message["content"] as? String) ?? "", provider: id,
                          model: (object["model"] as? String) ?? model, usage: usage)
    }
}
