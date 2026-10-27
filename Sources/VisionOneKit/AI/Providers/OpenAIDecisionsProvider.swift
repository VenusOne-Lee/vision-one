import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rung 3: OpenAI's Decisions API (`POST /v1/decisions`, gpt-6-luna). It
/// answers yes/no, choice and score questions with probabilities, up to
/// 400 a request, about ten times faster than Responses, and charges only
/// for input ($0.10 per million tokens).
///
/// It needs an API key. Sign in with ChatGPT plan usage is documented for
/// the Responses API only (checked 27 Oct 2026), so a ChatGPT token isn't
/// sent here.
public struct OpenAIDecisionsProvider: AIProvider {
    public static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    public static let maxQuestions = 400

    public let apiKey: String
    public let http: any HTTPClient
    public let model: String

    public var id: AIProviderID { .openAIDecisions }
    public var rung: AIRung { .decisions }
    public var displayName: String { "OpenAI Decisions" }
    public var leavesDevice: Bool { true }
    public var destination: String { "api.openai.com" }
    public var contextTokens: Int { 200_000 }
    public var answersDecisionsNatively: Bool { true }
    public var decisionsOnly: Bool { true }
    public var price: AIPrice? { AIPrice(inputPerMillion: 0.10, outputPerMillion: 0) }

    public init(apiKey: String, model: String = "gpt-6-luna", http: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    public func availability() async -> AIAvailability {
        apiKey.isEmpty ? .unavailable("Add an OpenAI API key") : .ready
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        throw AIError.unavailable(id, "The Decisions API only answers questions.")
    }

    public func body(for request: DecisionRequest, questions: ArraySlice<DecisionQuestion>) -> [String: Any] {
        [
            "model": model,
            "input": request.input.isEmpty ? " " : request.input,
            "questions": questions.map { q -> [String: Any] in
                var item: [String: Any] = ["type": q.kind.rawValue, "name": q.name, "instructions": q.instructions]
                switch q.kind {
                case .predicate: break
                case .choice: item["choices"] = q.choices.map { ["value": $0.value, "description": $0.description] }
                case .score: item["levels"] = q.levels.map { ["label": $0.label, "description": $0.description] }
                }
                return item
            },
        ]
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        var answers: [DecisionAnswer] = []
        var start = 0
        while start < request.questions.count {
            let end = min(start + Self.maxQuestions, request.questions.count)
            let urlRequest = try URLRequest.json(Self.endpoint,
                                                 body: body(for: request, questions: request.questions[start..<end]),
                                                 headers: ["Authorization": "Bearer \(apiKey)"])
            let (data, response) = try await http.send(urlRequest)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 429 { throw AIError.usageLimit(id) }
                throw AIError.http(id, status: response.statusCode, message: errorMessage(from: data))
            }
            answers += try Self.parse(data, provider: id)
            start = end
        }
        return DecisionResult(answers: answers, provider: id, model: model)
    }

    public static func parse(_ data: Data, provider: AIProviderID) throws -> [DecisionAnswer] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [[String: Any]] else {
            throw AIError.badResponse(provider, "No answers in the reply.")
        }
        return answers.compactMap { a in
            guard let name = a["name"] as? String else { return nil }
            let type = a["type"] as? String
            return DecisionAnswer(name: name,
                                  probability: a["probability"] as? Double,
                                  choice: a["choice"] as? String,
                                  score: a["score"] as? Double,
                                  confidence: a["confidence"] as? Double,
                                  refused: type == "refusal")
        }
    }
}
