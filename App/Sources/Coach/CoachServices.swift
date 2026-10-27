import Foundation
import SwiftUI
import VisionOneKit

/// The coach's setup: the ElevenLabs key and voice, the tone, the coach
/// agent's id, and the user's own pace learned from their takes. The key
/// lives in the Keychain with the AI keys; the rest in UserDefaults.
@MainActor
final class CoachServices: ObservableObject {
    static let shared = CoachServices()

    /// Shared with the prompter and Home's script box (the recording thread's ScriptStore).
    static let scriptKey = "script.text"

    @Published var scriptText: String {
        didSet { UserDefaults.standard.set(scriptText, forKey: Self.scriptKey) }
    }
    @Published var tone: DeliveryTone {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: "coach.tone") }
    }
    /// The ElevenLabs voice for Hear it first; empty picks the first one listed.
    @Published var voiceID: String {
        didSet { UserDefaults.standard.set(voiceID, forKey: "coach.voiceID") }
    }
    /// The user's own cloned voice, once made, for word fixes.
    @Published var cloneVoiceID: String {
        didSet { UserDefaults.standard.set(cloneVoiceID, forKey: "coach.cloneVoiceID") }
    }
    /// Which meters Rehearse shows.
    @Published var meters: [RehearsalMeter] {
        didSet { UserDefaults.standard.set(meters.map(\.rawValue), forKey: "coach.meters") }
    }
    /// Whether the coach speaks its notes (with Talk it through) or only shows them.
    @Published var spokenCoach: Bool {
        didSet { UserDefaults.standard.set(spokenCoach, forKey: "coach.spoken") }
    }
    @Published private(set) var voices: [ElevenVoice] = []
    @Published private(set) var credits: ElevenCredits?
    @Published private(set) var pace = SpeakingPace()
    @Published private(set) var keyVersion = 0
    @Published var problem: String?

    private init() {
        let defaults = UserDefaults.standard
        scriptText = defaults.string(forKey: Self.scriptKey) ?? ""
        tone = defaults.string(forKey: "coach.tone").flatMap(DeliveryTone.init(rawValue:)) ?? .lively
        voiceID = defaults.string(forKey: "coach.voiceID") ?? ""
        cloneVoiceID = defaults.string(forKey: "coach.cloneVoiceID") ?? ""
        meters = (defaults.stringArray(forKey: "coach.meters") ?? []).compactMap(RehearsalMeter.init(rawValue:))
        if meters.isEmpty { meters = RehearsalMeter.allCases }
        spokenCoach = defaults.object(forKey: "coach.spoken") as? Bool ?? true
    }

    var script: Script { Script(text: scriptText) }

    // MARK: ElevenLabs

    var apiKey: String { AIServices.shared.key(AISecretName.elevenLabsKey) }

    /// ElevenLabs is off when there's no key, or the user chose "On this Mac only".
    var elevenLabsReady: Bool { !apiKey.isEmpty && !AIServices.shared.settings.onDeviceOnly }

    var elevenLabsNote: String {
        if AIServices.shared.settings.onDeviceOnly { return "Off: Settings → AI is set to On this Mac only." }
        if apiKey.isEmpty { return "Add your ElevenLabs key in Settings → AI to use ElevenLabs voices." }
        if let credits { return "\(credits.remaining.formatted()) ElevenLabs credits left this month." }
        return "Uses your ElevenLabs account."
    }

    func setKey(_ key: String) {
        AIServices.shared.setKey(key, for: AISecretName.elevenLabsKey)
        keyVersion += 1
        voices = []
        credits = nil
        Task { await refresh() }
    }

    func client() -> ElevenLabsClient {
        ElevenLabsClient(apiKey: elevenLabsReady ? apiKey : "", gate: AIServices.shared.gate)
    }

    /// Lists voices and credits. Sends only the key.
    func refresh() async {
        guard elevenLabsReady else { return }
        let client = client()
        do {
            voices = try await client.voices()
            credits = try? await client.credits()
            if voiceID.isEmpty || !voices.contains(where: { $0.voiceID == voiceID }) {
                voiceID = voices.first(where: { !$0.isClone })?.voiceID ?? voices.first?.voiceID ?? ""
            }
            problem = nil
        } catch {
            problem = Self.message(for: error)
        }
    }

    var voiceName: String {
        voices.first { $0.voiceID == voiceID }?.name ?? "ElevenLabs voice"
    }

    /// The coach agent on the user's account, made the first time it's needed.
    func coachAgentID() async throws -> String {
        let key = "coach.agentID.\(apiKey.suffix(6))"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let id = try await client().createCoachAgent(CoachAgentConfig(voiceID: voiceID.isEmpty ? nil : voiceID))
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: Pace

    /// Learns the user's pace from their last ten transcribed takes.
    func learnPace() {
        Task.detached(priority: .utility) {
            let takes = TakeLibrary.standard.takes().prefix(10)
            let transcripts = takes.compactMap { try? Transcript.read(from: $0.transcriptURL) }
            let pace = SpeakingPace.learn(from: Array(transcripts))
            await MainActor.run { self.pace = pace }
        }
    }

    var targets: RehearsalTargets {
        var targets = RehearsalTargets.around(pace)
        targets.meters = meters
        return targets
    }

    /// The target length from the purpose picked on Home, when it has one.
    var targetLength: ClosedRange<Double>? {
        UserDefaults.standard.string(forKey: "ai.nextPurpose").flatMap(Purpose.named)?.targetSeconds
    }

    static func message(for error: Error) -> String {
        switch error as? AIError {
        case .notApproved?: return "Not sent. Nothing left your Mac."
        case .usageLimit?: return "Your ElevenLabs credits are used up for this month."
        case let .http(_, status, message)?:
            return status == 401 ? "ElevenLabs didn't accept the key. Check it in Settings → AI." : message
        case let .unavailable(_, why)?: return why
        case let .badResponse(_, why)?: return why
        default: return error.localizedDescription
        }
    }
}
