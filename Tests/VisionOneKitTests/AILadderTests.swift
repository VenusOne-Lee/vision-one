import XCTest
@testable import VisionOneKit

/// A provider that answers from a closure and counts its calls.
final class FakeProvider: AIProvider, @unchecked Sendable {
    let id: AIProviderID
    let rung: AIRung
    var displayName: String { id.rawValue }
    var model: String { "fake" }
    let leavesDevice: Bool
    var destination: String { "fake.example" }
    let contextTokens: Int
    let answersDecisionsNatively: Bool
    var ready = true
    var calls = 0
    var error: AIError?
    var reply: (AIRequest) -> String

    init(_ id: AIProviderID, rung: AIRung, leavesDevice: Bool = true, contextTokens: Int = 100_000,
         native: Bool = false, reply: @escaping (AIRequest) -> String = { _ in "ok" }) {
        self.id = id
        self.rung = rung
        self.leavesDevice = leavesDevice
        self.contextTokens = contextTokens
        self.answersDecisionsNatively = native
        self.reply = reply
    }

    func availability() async -> AIAvailability { ready ? .ready : .unavailable("off") }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        calls += 1
        if let error { throw error }
        return AIResponse(text: reply(request), provider: id, model: model)
    }
}

/// Records what the approval sheet was asked.
actor RecordingApprover: OutboundApprover {
    var asked: [OutboundRequest] = []
    let decision: OutboundDecision
    init(_ decision: OutboundDecision) { self.decision = decision }
    func approve(_ request: OutboundRequest) async -> OutboundDecision {
        asked.append(request)
        return decision
    }
}

final class AILadderTests: XCTestCase {
    func request(_ input: String = "hello") -> AIRequest {
        AIRequest(task: .custom, summary: "test", instructions: "be brief", input: input)
    }

    func testOnDeviceRunsFirstWithoutAsking() async throws {
        let device = FakeProvider(.appleOnDevice, rung: .onDevice, leavesDevice: false, contextTokens: 4096)
        let cloud = FakeProvider(.chatGPT, rung: .chatGPT)
        let approver = RecordingApprover(.allowOnce)
        let ladder = AILadder(providers: [cloud, device], gate: OutboundGate(approver: approver))
        let reply = try await ladder.complete(request())
        XCTAssertEqual(reply.provider, .appleOnDevice)
        XCTAssertEqual(cloud.calls, 0)
        let asked = await approver.asked
        XCTAssertTrue(asked.isEmpty)
    }

    func testTooLongForDeviceClimbsAndAsks() async throws {
        let device = FakeProvider(.appleOnDevice, rung: .onDevice, leavesDevice: false, contextTokens: 4096)
        let cloud = FakeProvider(.chatGPT, rung: .chatGPT)
        let approver = RecordingApprover(.allowOnce)
        let ladder = AILadder(providers: [device, cloud], gate: OutboundGate(approver: approver))
        let reply = try await ladder.complete(request(String(repeating: "word ", count: 5000)))
        XCTAssertEqual(reply.provider, .chatGPT)
        XCTAssertEqual(device.calls, 0)
        let asked = await approver.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].fromPlan)
        XCTAssertEqual(asked[0].estimatedRand, 0)
    }

    func testDenyStopsAndNeverTriesAnotherRung() async {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        let claude = FakeProvider(.anthropicKey, rung: .ownKey)
        let ladder = AILadder(providers: [chat, claude], gate: OutboundGate(approver: FixedApprover(.deny)))
        do {
            _ = try await ladder.complete(request())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AIError, .notApproved)
        }
        XCTAssertEqual(chat.calls + claude.calls, 0)
    }

    func testUsageLimitFallsThroughToNextRung() async throws {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        chat.error = .usageLimit(.chatGPT)
        let claude = FakeProvider(.anthropicKey, rung: .ownKey)
        let ladder = AILadder(providers: [claude, chat], gate: OutboundGate(approver: FixedApprover(.allowOnce)))
        let reply = try await ladder.complete(request())
        XCTAssertEqual(reply.provider, .anthropicKey)
        XCTAssertEqual(chat.calls, 1)
    }

    func testOnDeviceOnlySkipsCloud() async {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        let ladder = AILadder(providers: [chat], gate: OutboundGate(approver: FixedApprover(.allowOnce)),
                              settings: AISettings(onDeviceOnly: true))
        do {
            _ = try await ladder.complete(request())
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AIError, .noProvider)
        }
    }

    func testUnavailableAndDisabledAreSkipped() async throws {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        chat.ready = false
        let openai = FakeProvider(.openAIKey, rung: .ownKey)
        let claude = FakeProvider(.anthropicKey, rung: .ownKey)
        let ladder = AILadder(providers: [chat, openai, claude], gate: OutboundGate(approver: FixedApprover(.allowOnce)),
                              settings: AISettings(disabled: [.openAIKey]))
        let reply = try await ladder.complete(request())
        XCTAssertEqual(reply.provider, .anthropicKey)
    }

    func testTaskPinWins() async throws {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        let claude = FakeProvider(.anthropicKey, rung: .ownKey)
        let ladder = AILadder(providers: [chat, claude], gate: OutboundGate(approver: FixedApprover(.allowOnce)),
                              settings: AISettings(taskProviders: [.custom: .anthropicKey]))
        let reply = try await ladder.complete(request())
        XCTAssertEqual(reply.provider, .anthropicKey)
    }

    func testAllowForSessionAsksOnce() async throws {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        let approver = RecordingApprover(.allowForSession)
        let ladder = AILadder(providers: [chat], gate: OutboundGate(approver: approver))
        _ = try await ladder.complete(request())
        _ = try await ladder.complete(request())
        let asked = await approver.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(chat.calls, 2)
    }

    func testPostsAreAlwaysAsked() async throws {
        let approver = RecordingApprover(.allowForSession)
        let gate = OutboundGate(approver: approver)
        try await SharerAgent.approvePost("hi", to: "versionone.co.za", network: "versionone", gate: gate)
        try await SharerAgent.approvePost("hi", to: "versionone.co.za", network: "versionone", gate: gate)
        let asked = await approver.asked
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked[0].kind, .post)
    }

    func testDecisionsPreferNativeProvider() async throws {
        let chat = FakeProvider(.chatGPT, rung: .chatGPT)
        let decisions = FakeProvider(.openAIDecisions, rung: .decisions, native: true)
        let ladder = AILadder(providers: [chat, decisions], gate: OutboundGate(approver: FixedApprover(.allowOnce)))
        let order = ladder.ordered(for: .editorKeepCut, decisions: true).map { $0.id }
        XCTAssertEqual(order, [.openAIDecisions, .chatGPT])
        // Text jobs keep ladder order.
        XCTAssertEqual(ladder.ordered(for: .sharePack, decisions: false).map { $0.id }.first, .chatGPT)
    }

    func testCostEstimateInRand() {
        let price = AIPrice(inputPerMillion: 0.10, outputPerMillion: 0)
        XCTAssertEqual(price.estimateRand(inputTokens: 1_000_000, outputTokens: 0), 1.85, accuracy: 0.001)
    }
}

final class DecisionTests: XCTestCase {
    func testEmulatorAnswersEveryQuestionAndClamps() async throws {
        let provider = FakeProvider(.chatGPT, rung: .chatGPT) { _ in
            #"Sure! ```json [{"name":"a","probability":1.4},{"name":"b","choice":"x"},{"name":"c","score":7},{"name":"zzz","probability":0.5}] ```"#
        }
        let request = DecisionRequest(task: .custom, summary: "t", input: "", questions: [
            .predicate("a", "yes?"),
            .choice("b", "which?", [.init(value: "x", description: "X"), .init(value: "y", description: "Y")]),
            .score("c", "how good?", [.init(label: "low", description: ""), .init(label: "high", description: "")]),
            .predicate("d", "missing?"),
        ])
        let result = try await provider.decide(request)
        XCTAssertEqual(result["a"]?.probability, 1)
        XCTAssertEqual(result["b"]?.choice, "x")
        XCTAssertEqual(result["c"]?.score, 1)
        XCTAssertEqual(result["d"]?.refused, true)
        XCTAssertNil(result["zzz"])
    }

    func testEmulatorBatchesForSmallContext() async throws {
        let provider = FakeProvider(.appleOnDevice, rung: .onDevice, leavesDevice: false, contextTokens: 4096) { req in
            // Answer every question named in this batch with 0.9.
            let names = req.input.split(separator: "\n").compactMap { line -> String? in
                guard let name = line.split(separator: " ").first, name.hasPrefix("s") else { return nil }
                return String(name)
            }
            return "[" + names.map { #"{"name":"\#($0)","probability":0.9}"# }.joined(separator: ",") + "]"
        }
        let sentence = String(repeating: "this is a fairly long sentence about the product ", count: 6)
        let questions = (0..<60).map { DecisionQuestion.predicate("s\($0)", "Keep \"\(sentence)\"?") }
        let result = try await provider.decide(DecisionRequest(task: .editorKeepCut, summary: "t", input: "ctx",
                                                               questions: questions))
        XCTAssertGreaterThan(provider.calls, 1)
        XCTAssertEqual(result.answers.count, 60)
        XCTAssertTrue(result.answers.allSatisfy { $0.probability == 0.9 })
    }

    func testDecisionsAPIBodyAndParse() throws {
        let provider = OpenAIDecisionsProvider(apiKey: "k")
        let request = DecisionRequest(task: .custom, summary: "t", input: "ctx", questions: [
            .predicate("a", "yes?"),
            .score("b", "how?", [.init(label: "lo", description: "l"), .init(label: "hi", description: "h")]),
        ])
        let body = provider.body(for: request, questions: request.questions[...])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        let qs = body["questions"] as! [[String: Any]]
        XCTAssertEqual(qs[0]["type"] as? String, "predicate")
        XCTAssertEqual((qs[1]["levels"] as? [[String: String]])?.first?["label"], "lo")

        let json = #"{"answers":[{"type":"predicate","name":"a","probability":0.25},{"type":"refusal","name":"b"}]}"#
        let answers = try OpenAIDecisionsProvider.parse(Data(json.utf8), provider: .openAIDecisions)
        XCTAssertEqual(answers[0].probability, 0.25)
        XCTAssertTrue(answers[1].refused)
    }

    func testJSONExtraction() throws {
        XCTAssertEqual(AIJSON.extract("Here: {\"a\": \"}\"} thanks"), "{\"a\": \"}\"}")
        XCTAssertEqual(AIJSON.extract("[1,[2]] and [3]"), "[1,[2]]")
    }
}

final class ProviderWireTests: XCTestCase {
    func testResponsesBodyFollowsPlanRules() {
        struct NoTokens: AIAccessTokenSource { func accessToken() async throws -> String? { "t" } }
        let provider = OpenAIResponsesProvider.chatGPT(tokens: NoTokens())
        let body = provider.body(for: AIRequest(task: .custom, summary: "", instructions: "inst", input: "in"))
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertEqual(body["instructions"] as? String, "inst")
        let input = body["input"] as! [[String: Any]]
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func testResponsesStreamCompleted() throws {
        let stream = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hel"}

        event: response.completed
        data: {"type":"response.completed","response":{"model":"gpt-6.1-terra","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":12,"output_tokens":3}}}

        """
        let reply = try OpenAIResponsesProvider.parseStream(stream, provider: .chatGPT, fallbackModel: "x")
        XCTAssertEqual(reply.text, "Hello")
        XCTAssertEqual(reply.model, "gpt-6.1-terra")
        XCTAssertEqual(reply.usage, AIUsage(inputTokens: 12, outputTokens: 3))
    }

    func testResponsesStreamUsageLimit() {
        let stream = """
        data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}

        """
        XCTAssertThrowsError(try OpenAIResponsesProvider.parseStream(stream, provider: .chatGPT, fallbackModel: "x")) {
            XCTAssertEqual($0 as? AIError, .usageLimit(.chatGPT))
        }
    }

    func testStreamWithoutCompletedIsAnError() {
        let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n"
        XCTAssertThrowsError(try OpenAIResponsesProvider.parseStream(stream, provider: .chatGPT, fallbackModel: "x"))
    }

    func testLocalServerStaysOnDevice() {
        XCTAssertFalse(OpenAICompatibleProvider.local(model: "qwen").leavesDevice)
        XCTAssertTrue(OpenAICompatibleProvider.openRouter(apiKey: "k").leavesDevice)
    }

    func testAnthropicBody() {
        let body = AnthropicProvider(apiKey: "k").body(for: AIRequest(task: .custom, summary: "", instructions: "i", input: "u"))
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["system"] as? String, "i")
    }
}

final class ChatGPTAuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        let pkce = ChatGPTAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationURLForFirstRegistration() throws {
        let attempt = ChatGPTAuth.Attempt(port: 1455, clientID: nil, state: "st", nonce: "no",
                                          pkce: ChatGPTAuth.PKCE(verifier: "v"))
        let url = ChatGPTAuth.authorizationURL(for: attempt, hostID: "urn:uuid:abc")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(value("client_id"), "dynamic_agent_client")
        XCTAssertEqual(value("agent_name_hint"), "Vision One")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertTrue(value("scope")!.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(value("resource"), "https://api.openai.com/v1")
    }

    func testCallbackChecksState() throws {
        let attempt = ChatGPTAuth.Attempt(port: 1455, clientID: nil, state: "good")
        let ok = URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&state=good&client_id=oaiapp_1")!
        XCTAssertEqual(try ChatGPTAuth.parseCallback(ok, attempt: attempt),
                       ChatGPTAuth.Callback(code: "abc", issuedClientID: "oaiapp_1"))
        let bad = URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&state=evil")!
        XCTAssertThrowsError(try ChatGPTAuth.parseCallback(bad, attempt: attempt))
    }

    func jwt(_ claims: [String: Any]) -> String {
        let payload = ChatGPTAuth.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }

    func testCredentialsNeedPlanScopeAndMatchingNonce() throws {
        let id = jwt(["iss": "https://auth.openai.com", "aud": "oaiapp_1", "nonce": "n1", "email": "lee@example.com"])
        let good = #"{"access_token":"a","refresh_token":"r","id_token":"\#(id)","expires_in":3600,"scope":"openid email offline_access resource.invoke chatgpt.tokens.use.direct"}"#
        let creds = try ChatGPTAuth.credentials(from: Data(good.utf8), clientID: "oaiapp_1", nonce: "n1")
        XCTAssertTrue(creds.canUsePlan)
        XCTAssertEqual(creds.email, "lee@example.com")
        XCTAssertThrowsError(try ChatGPTAuth.credentials(from: Data(good.utf8), clientID: "oaiapp_1", nonce: "other"))
        let noPlan = #"{"access_token":"a","scope":"openid email"}"#
        XCTAssertThrowsError(try ChatGPTAuth.credentials(from: Data(noPlan.utf8), clientID: "c", nonce: nil)) {
            XCTAssertEqual($0 as? ChatGPTAuth.AuthError, .noPlanAccess)
        }
    }

    func testSessionKeepsHostIDAcrossSignOut() async {
        let store = MemorySecretStore()
        let session = ChatGPTSession(store: store)
        let first = await session.hostID()
        await session.signOut()
        let second = await session.hostID()
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("urn:uuid:"))
        let token = try? await session.accessToken()
        XCTAssertNil(token ?? nil)
    }
}
