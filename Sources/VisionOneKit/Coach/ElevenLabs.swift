import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AIProviderID {
    /// ElevenLabs with the user's own key: voices, the voice isolator,
    /// voice cloning and the talk-it-through coach. Not a ladder rung; it
    /// doesn't write text.
    public static let elevenLabs = AIProviderID("elevenlabs")
}

extension AISecretName {
    public static let elevenLabsKey = "elevenlabs-api-key"
}

extension AITask {
    /// "Hear it first": the script read aloud.
    public static let coachHear = AITask("coach.hear")
    /// "Talk it through": a spoken back-and-forth with the coach agent.
    public static let coachTalk = AITask("coach.talk")
    /// Setting up the coach agent on the user's ElevenLabs account, once.
    public static let coachAgentSetup = AITask("coach.agentSetup")
    public static let voiceIsolate = AITask("voice.isolate")
    public static let voiceClone = AITask("voice.clone")
    /// One word re-said in the user's cloned voice.
    public static let voiceFix = AITask("voice.fix")
}

/// A voice on the user's ElevenLabs account or in its library.
public struct ElevenVoice: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String { voiceID }
    public var voiceID: String
    public var name: String
    /// "premade", "cloned", "generated", "professional".
    public var category: String?
    public var labels: [String: String]?
    public var previewURL: URL?

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id", name, category, labels, previewURL = "preview_url"
    }

    public init(voiceID: String, name: String, category: String? = nil, labels: [String: String]? = nil, previewURL: URL? = nil) {
        self.voiceID = voiceID
        self.name = name
        self.category = category
        self.labels = labels
        self.previewURL = previewURL
    }

    public var isClone: Bool { category == "cloned" || category == "professional" }

    /// "Warm · South African · young": the labels that help pick one.
    public var summary: String {
        guard let labels else { return category?.capitalized ?? "" }
        return ["description", "accent", "age", "use_case"].compactMap { labels[$0] }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: " · ")
    }
}

/// How much of the month's ElevenLabs credit is left.
public struct ElevenCredits: Codable, Equatable, Sendable {
    public var used: Int
    public var limit: Int
    public var tier: String?

    enum CodingKeys: String, CodingKey {
        case used = "character_count", limit = "character_limit", tier
    }

    public init(used: Int, limit: Int, tier: String? = nil) {
        self.used = used
        self.limit = limit
        self.tier = tier
    }

    public var remaining: Int { max(0, limit - used) }
}

/// Speech from ElevenLabs with when each word is said, so the script can
/// light up word by word as it's read.
public struct SpokenAudio: Equatable, Sendable {
    /// MP3 at 44.1 kHz.
    public var audio: Data
    public var words: [HeardWord]

    public init(audio: Data, words: [HeardWord]) {
        self.audio = audio
        self.words = words
    }

    public var duration: Double { words.last?.end ?? 0 }

    /// Groups ElevenLabs' per-character timings into words. Characters
    /// inside [audio tags] aren't spoken, so they're skipped.
    public static func words(characters: [String], starts: [Double], ends: [Double]) -> [HeardWord] {
        var words: [HeardWord] = []
        var text = ""
        var start: Double?
        var end = 0.0
        var inTag = false
        func flush() {
            if let start, !text.isEmpty { words.append(HeardWord(text: text, start: start, end: end)) }
            text = ""
            start = nil
        }
        for i in 0..<min(characters.count, starts.count, ends.count) {
            let ch = characters[i]
            if ch == "[" { flush(); inTag = true; continue }
            if ch == "]" { inTag = false; continue }
            if inTag { continue }
            if ch.allSatisfy(\.isWhitespace) { flush(); continue }
            if start == nil { start = starts[i] }
            text += ch
            end = ends[i]
        }
        flush()
        return words
    }
}

/// The ElevenLabs API, with the user's own key. Every call that sends the
/// user's words or audio passes the outbound gate first; listing voices
/// and credits sends nothing but the key. See docs/COACH.md.
public struct ElevenLabsClient: Sendable {
    public static let base = URL(string: "https://api.elevenlabs.io")!
    public static let host = "api.elevenlabs.io"
    /// Highest quality, with audio tags. Replaces Eleven v3.
    public static let speechModel = "eleven_v4"
    /// Low latency, for the coach agent's voice.
    public static let agentModel = "eleven_v4_turbo"

    public let apiKey: String
    public let http: any HTTPClient
    public let gate: OutboundGate?

    public init(apiKey: String, gate: OutboundGate?, http: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.gate = gate
        self.http = http
    }

    public var isSetUp: Bool { !apiKey.isEmpty }

    // MARK: Account

    public func voices() async throws -> [ElevenVoice] {
        var components = URLComponents(url: Self.base.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
        let data = try await send(get(components.url!))
        struct Page: Decodable { var voices: [ElevenVoice] }
        return try decode(Page.self, data).voices
    }

    public func credits() async throws -> ElevenCredits {
        try decode(ElevenCredits.self, await send(get(Self.base.appendingPathComponent("v1/user/subscription"))))
    }

    // MARK: Speech

    /// Reads `text` (audio tags allowed) in `voiceID`, with word timings.
    public func speak(_ text: String, voiceID: String, model: String = ElevenLabsClient.speechModel,
                      task: AITask = .coachHear, summary: String = "Read your script aloud") async throws -> SpokenAudio {
        try await check(.aiRequest, task: task, summary: summary, payload: text)
        var components = URLComponents(url: Self.base.appendingPathComponent("v1/text-to-speech/\(voiceID)/with-timestamps"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        let request = try URLRequest.json(components.url!, body: Self.speechBody(text, model: model), headers: headers)
        let data = try await send(request)
        return try Self.parseSpeech(data)
    }

    static func speechBody(_ text: String, model: String) -> [String: Any] {
        ["text": text, "model_id": model, "apply_text_normalization": "auto"]
    }

    static func parseSpeech(_ data: Data) throws -> SpokenAudio {
        struct Alignment: Decodable {
            var characters: [String]
            var character_start_times_seconds: [Double]
            var character_end_times_seconds: [Double]
        }
        struct Reply: Decodable {
            var audio_base64: String
            var alignment: Alignment?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let audio = Data(base64Encoded: reply.audio_base64) else {
            throw AIError.badResponse(.elevenLabs, "The audio didn't decode.")
        }
        let words = reply.alignment.map {
            SpokenAudio.words(characters: $0.characters, starts: $0.character_start_times_seconds,
                              ends: $0.character_end_times_seconds)
        } ?? []
        return SpokenAudio(audio: audio, words: words)
    }

    // MARK: Voice tools

    /// Sends one take's mic track to the voice isolator and returns the
    /// cleaned audio. Only the mic track goes, never the screen.
    public func isolate(audio: Data, fileName: String, mimeType: String = "audio/mp4", seconds: Double) async throws -> Data {
        try await check(.audio, task: .voiceIsolate, summary: "Clean the voice in this take (\(Self.clock(seconds)) of audio)",
                        payload: "The mic track of this take: \(Self.clock(seconds)) of audio, \(ByteCountFormatter.string(fromByteCount: Int64(audio.count), countStyle: .file)). Your screen and camera aren't sent.")
        var form = MultipartForm()
        form.addFile(name: "audio", fileName: fileName, mimeType: mimeType, data: audio)
        return try await send(form.request(Self.base.appendingPathComponent("v1/audio-isolation"), headers: headers))
    }

    /// Makes an instant voice clone from the user's own recordings. Only
    /// call after the user has agreed in the consent sheet.
    public func cloneVoice(name: String, samples: [(fileName: String, data: Data)], seconds: Double) async throws -> String {
        try await check(.audio, task: .voiceClone, summary: "Make a voice clone from \(samples.count) of your takes",
                        payload: "\(Self.clock(seconds)) of your own voice from \(samples.count) take(s), to make \"\(name)\" on your ElevenLabs account. It's stored there, and you can delete it any time.")
        var form = MultipartForm()
        form.addField(name: "name", value: name)
        form.addField(name: "description", value: "Made by Vision One from the owner's own recordings, with their consent.")
        form.addField(name: "remove_background_noise", value: "true")
        for sample in samples {
            form.addFile(name: "files", fileName: sample.fileName, mimeType: "audio/mp4", data: sample.data)
        }
        let data = try await send(form.request(Self.base.appendingPathComponent("v1/voices/add"), headers: headers))
        struct Reply: Decodable { var voice_id: String }
        return try decode(Reply.self, data).voice_id
    }

    // MARK: Coach agent

    /// Creates the coach agent on the user's account, once; its id is kept.
    public func createCoachAgent(_ config: CoachAgentConfig = CoachAgentConfig()) async throws -> String {
        try await check(.aiRequest, task: .coachAgentSetup, summary: "Set up the voice coach on your ElevenLabs account",
                        payload: config.prompt)
        let request = try URLRequest.json(Self.base.appendingPathComponent("v1/convai/agents/create"),
                                          body: config.body, headers: headers)
        let data = try await send(request)
        struct Reply: Decodable { var agent_id: String }
        return try decode(Reply.self, data).agent_id
    }

    /// A one-off address for a conversation; it expires after 15 minutes
    /// if unused. The gate asks first, because the mic is streamed live.
    public func conversationURL(agentID: String, context: CoachContext) async throws -> URL {
        try await check(.audio, task: .coachTalk, summary: "Talk it through with the coach",
                        payload: "Your mic, live, while the conversation is open. The coach also gets your script and this run's notes:\n\n" + context.notes + "\n\n" + context.script)
        var components = URLComponents(url: Self.base.appendingPathComponent("v1/convai/conversation/get-signed-url"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
        let data = try await send(get(components.url!))
        struct Reply: Decodable { var signed_url: String }
        guard let url = URL(string: try decode(Reply.self, data).signed_url) else {
            throw AIError.badResponse(.elevenLabs, "No conversation address came back.")
        }
        return url
    }

    // MARK: Plumbing

    var headers: [String: String] { ["xi-api-key": apiKey] }

    func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func check(_ kind: OutboundRequest.Kind, task: AITask, summary: String, payload: String) async throws {
        guard isSetUp else { throw AIError.unavailable(.elevenLabs, "Add an ElevenLabs API key") }
        guard let gate else { return }
        try await gate.check(OutboundRequest(kind: kind, provider: .elevenLabs, providerName: "ElevenLabs",
                                             destination: Self.host, task: task, summary: summary, payload: payload))
    }

    func send(_ request: URLRequest) async throws -> Data {
        guard isSetUp else { throw AIError.unavailable(.elevenLabs, "Add an ElevenLabs API key") }
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 { throw AIError.usageLimit(.elevenLabs) }
            throw AIError.http(.elevenLabs, status: response.statusCode, message: Self.errorText(data))
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw AIError.badResponse(.elevenLabs, "ElevenLabs sent something unexpected.")
        }
    }

    /// ElevenLabs errors come as {"detail": {"message": …}} or {"detail": "…"}.
    static func errorText(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        return errorMessage(from: data)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
