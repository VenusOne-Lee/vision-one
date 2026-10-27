import Foundation

/// The "Talk it through" coach, made once on the user's ElevenLabs
/// account. Its prompt reads the script and the run's notes from dynamic
/// variables, so one agent serves every script without changing it.
public struct CoachAgentConfig: Equatable, Sendable {
    public var name = "Vision One coach"
    /// A voice from the user's account; nil keeps ElevenLabs' default.
    public var voiceID: String?
    public var language = "en"

    public init(voiceID: String? = nil) {
        self.voiceID = voiceID
    }

    public var prompt: String {
        """
        You are a friendly, direct delivery coach for someone about to record a short video about their product. \
        They are South African; keep their accent and their words. You have their script and the notes from the \
        practice run they just did.

        Script:
        {{script}}

        Notes from this run:
        {{notes}}

        Talk like a director between takes: one point at a time, two sentences at most, then let them answer. Start \
        with what went well, then the most useful fix, tied to a line. Offer to run just that line. If they say a line \
        aloud, react to how it sounded. Never rewrite the whole script. When they say they're ready, wish them luck \
        and tell them to press Record for real.
        """
    }

    public var firstMessage: String {
        "That was a good run. Want to talk about {{focus}} first?"
    }

    /// The body for POST /v1/convai/agents/create.
    public var body: [String: Any] {
        var tts: [String: Any] = ["model_id": ElevenLabsClient.agentModel]
        if let voiceID { tts["voice_id"] = voiceID }
        return [
            "name": name,
            "conversation_config": [
                "agent": [
                    "first_message": firstMessage,
                    "language": language,
                    "prompt": ["prompt": prompt],
                    "dynamic_variables": [
                        "dynamic_variable_placeholders": ["script": "", "notes": "", "focus": "the script"],
                    ],
                ] as [String: Any],
                "tts": tts,
            ] as [String: Any],
        ]
    }
}

/// What the coach is told about this run, as dynamic variables.
public struct CoachContext: Equatable, Sendable {
    public var script: String
    public var notes: String
    /// What the first message offers to talk about: "the SnapScan line".
    public var focus: String

    public init(script: String, notes: String, focus: String) {
        self.script = script
        self.notes = notes
        self.focus = focus
    }

    public init(script: Script, review: RehearsalReview) {
        self.script = script.lines.map { "\($0.id + 1). \($0.text)" }.joined(separator: "\n")
        self.notes = review.notes.map { "- \($0.title): \($0.detail)" }.joined(separator: "\n")
        if let line = review.focusLine, let scriptLine = script.lines.first(where: { $0.id == line }) {
            focus = CoachNotes.handle(for: scriptLine, index: line, count: script.lines.count)
        } else {
            focus = "how it felt"
        }
    }

    public var variables: [String: String] { ["script": script, "notes": notes, "focus": focus] }
}

/// Messages on the coach conversation's WebSocket (ElevenLabs Agents).
/// The app owns the socket and the audio; this is only the wire format,
/// so it can be tested.
public enum CoachWire {
    /// Mic audio the agent expects: 16-bit PCM, mono, 16 kHz.
    public static let inputSampleRate = 16_000.0

    /// The first message: the script and notes for this conversation.
    public static func start(_ context: CoachContext) -> String {
        json(["type": "conversation_initiation_client_data", "dynamic_variables": context.variables])
    }

    /// One chunk of mic audio (PCM16 little-endian), base64 in JSON.
    public static func audio(_ pcm16: Data) -> String {
        json(["user_audio_chunk": pcm16.base64EncodedString()])
    }

    public static func pong(_ eventID: Int) -> String {
        json(["type": "pong", "event_id": eventID])
    }

    /// Tells the coach something without interrupting it, such as which
    /// line the user picked to run again.
    public static func context(_ text: String) -> String {
        json(["type": "contextual_update", "text": text])
    }

    /// A typed message, for when the user would rather not speak.
    public static func say(_ text: String) -> String {
        json(["type": "user_message", "text": text])
    }

    public enum Event: Equatable, Sendable {
        /// The agent's voice, as audio in the format the metadata named.
        case audio(Data, eventID: Int)
        case agentSaid(String)
        case userSaid(String)
        /// The user talked over the agent: stop playing its audio.
        case interrupted
        case ping(eventID: Int, delayMS: Int)
        /// The conversation is open; the agent's audio format ("pcm_16000").
        case started(conversationID: String, audioFormat: String)
        case other(String)
    }

    public static func parse(_ text: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "audio":
            guard let event = object["audio_event"] as? [String: Any],
                  let base64 = event["audio_base_64"] as? String,
                  let data = Data(base64Encoded: base64) else { return nil }
            return .audio(data, eventID: event["event_id"] as? Int ?? 0)
        case "agent_response":
            let event = object["agent_response_event"] as? [String: Any]
            return .agentSaid(event?["agent_response"] as? String ?? "")
        case "user_transcript":
            let event = object["user_transcription_event"] as? [String: Any]
            return .userSaid(event?["user_transcript"] as? String ?? "")
        case "interruption":
            return .interrupted
        case "ping":
            let event = object["ping_event"] as? [String: Any]
            return .ping(eventID: event?["event_id"] as? Int ?? 0, delayMS: event?["ping_ms"] as? Int ?? 0)
        case "conversation_initiation_metadata":
            let event = object["conversation_initiation_metadata_event"] as? [String: Any]
            return .started(conversationID: event?["conversation_id"] as? String ?? "",
                            audioFormat: event?["agent_output_audio_format"] as? String ?? "pcm_16000")
        default:
            return .other(type)
        }
    }

    /// Sample rate from a format name like "pcm_16000" or "pcm_44100".
    public static func sampleRate(of format: String) -> Double {
        Double(format.split(separator: "_").last.flatMap { Int($0) } ?? 16_000)
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
