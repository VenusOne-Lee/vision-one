import Foundation
import Security
import SwiftUI
import VisionOneKit

/// Keys and the ChatGPT tokens, in the login Keychain. Never in a take
/// folder or UserDefaults.
struct KeychainSecretStore: AISecretStore {
    let service = "za.co.versionone.visionone.ai"

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    func read(_ name: String) -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ data: Data, for name: String) throws {
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(name)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}

/// The app's one AI setup: settings, keys, the ChatGPT account, the
/// approval gate, and a fresh ladder for each job. Agents, zoom, music and
/// clips all get their ladder from here.
@MainActor
final class AIServices: ObservableObject {
    static let shared = AIServices()

    let secrets = KeychainSecretStore()
    let chatGPT: ChatGPTSession
    /// Every agent job, for the Agent Desk's task list (saved to jobs.json).
    let jobs: AgentJobBoard
    /// Projects and tasks: what the main window's sidebar, the task
    /// threads and the menu bar's Tasks list show (saved to desk.json).
    let desk: Desk
    /// One gate for the whole app, so "Allow for this session" holds until
    /// quit. A job's approvals wait on its task's card; the floating panel
    /// asks too only when the main window is out of view, and anything
    /// outside a task asks on the panel alone (`ApprovalPlacement`).
    let gate: OutboundGate
    /// Start the agents on their own once a take is transcribed.
    @Published var autoAgents: Bool {
        didSet { UserDefaults.standard.set(autoAgents, forKey: "ai.autoAgents") }
    }

    @Published var settings: AISettings {
        didSet { saveSettings() }
    }
    @Published var localServerURL: String {
        didSet { UserDefaults.standard.set(localServerURL, forKey: "ai.localURL") }
    }
    @Published var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "ai.localModel") }
    }
    @Published private(set) var chatGPTAccount: String?
    @Published private(set) var availability: [AIProviderID: AIAvailability] = [:]
    /// Bumped when a key changes, so views re-read what's set.
    @Published private(set) var keysVersion = 0

    private init() {
        chatGPT = ChatGPTSession(store: secrets)
        let board = AgentJobBoard(storeURL: AgentJobBoard.standardURL)
        jobs = board
        let desk = Desk(board: board, storeURL: Desk.standardURL)
        self.desk = desk
        gate = OutboundGate(approver: board.approver(fallback: PanelApprover(), panelFor: { jobID in
            await ApprovalPlacement.panelAsks(jobID: jobID, desk: desk)
        }))
        autoAgents = UserDefaults.standard.object(forKey: "ai.autoAgents") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: "ai.settings"),
           let saved = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = saved
        } else {
            settings = AISettings()
        }
        localServerURL = UserDefaults.standard.string(forKey: "ai.localURL") ?? "http://127.0.0.1:8080/v1"
        localModel = UserDefaults.standard.string(forKey: "ai.localModel") ?? ""
        startDesk()
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "ai.settings")
        }
    }

    // MARK: Keys

    func key(_ name: String) -> String { secrets.string(name) ?? "" }

    func setKey(_ value: String, for name: String) {
        try? secrets.setString(value.trimmingCharacters(in: .whitespacesAndNewlines), for: name)
        keysVersion += 1
        Task { await refresh() }
    }

    // MARK: Ladder

    /// Every provider that could run, set up or not, in ladder order.
    func providers() -> [any AIProvider] {
        var list: [any AIProvider] = []
        if let device = AppleOnDevice.provider() { list.append(device) }
        list.append(OpenAIResponsesProvider.chatGPT(tokens: chatGPT, model: settings.models[.chatGPT] ?? "gpt-6.1-terra"))
        let openAI = key(AISecretName.openAIKey)
        list.append(OpenAIDecisionsProvider(apiKey: openAI))
        list.append(OpenAIResponsesProvider.apiKey(openAI, model: settings.models[.openAIKey] ?? "gpt-6.1-terra"))
        list.append(AnthropicProvider(apiKey: key(AISecretName.anthropicKey),
                                      model: settings.models[.anthropicKey] ?? "claude-haiku-5-5"))
        list.append(OpenAICompatibleProvider.openRouter(apiKey: key(AISecretName.openRouterKey),
                                                        model: settings.models[.openRouterKey] ?? "openai/gpt-6.1-terra"))
        if let url = URL(string: localServerURL), !localModel.isEmpty {
            list.append(OpenAICompatibleProvider.local(baseURL: url, model: localModel))
        }
        return list
    }

    func ladder() -> AILadder {
        AILadder(providers: providers(), gate: gate, settings: settings)
    }

    func runner() -> AgentRunner {
        AgentRunner(board: jobs, ladder: ladder())
    }

    /// Hooks the Desk up; called once at launch.
    func startDesk() {
        let secrets = self.secrets
        Task {
            await desk.connect(
                runner: { await MainActor.run { AIServices.shared.runner() } },
                brief: { project, plan in
                    let name = project.presetName ?? UserDefaults.standard.string(forKey: "ai.preset") ?? ""
                    var brief = plan.purpose.brief(preset: PresetLibrary.standard.all().first { $0.name == name })
                    if !project.notes.isEmpty {
                        brief.houseStyle = [brief.houseStyle, project.notes].compactMap { $0 }.joined(separator: "\n")
                    }
                    return brief
                },
                sources: ScriptSources(secrets: secrets))
        }
    }

    /// The take's plan, or the purpose picked in "Before you record…".
    func plan(for take: Take) -> TakePlan {
        TakePlan.load(for: take) ?? TakePlan.next() ?? TakePlan(purpose: .demo)
    }

    /// The brief with the chosen prompt preset layered in.
    func brief(for plan: TakePlan) -> AgentBrief {
        let name = UserDefaults.standard.string(forKey: "ai.preset") ?? ""
        return plan.purpose.brief(preset: PresetLibrary.standard.all().first { $0.name == name })
    }

    /// Called when a take's transcript is written: the Editor (and, by the
    /// Energy dial, the Sharer and Clipper) start on their own. What they
    /// make waits as dashed proposals with Keep and Undo.
    func transcriptReady(for take: Take) {
        guard Self.isRecent(take) else { return }
        guard autoAgents else {
            let desk = self.desk
            Task { await desk.transcribed(take, runAgents: false) }
            return
        }
        let takePlan = plan(for: take)
        try? takePlan.write(for: take)
        let desk = self.desk
        Task { await desk.transcribed(take) }
    }

    /// Old takes transcribed on launch don't wake the agents.
    private static func isRecent(_ take: Take) -> Bool {
        let created = (try? take.folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        return Date().timeIntervalSince(created) < 24 * 3600
    }

    /// Re-checks which rungs are ready, for Settings and the agents panel.
    func refresh() async {
        let signedIn = await chatGPT.isSignedIn
        let account = await chatGPT.account
        chatGPTAccount = signedIn ? (account ?? "Signed in") : nil
        var result: [AIProviderID: AIAvailability] = [:]
        for provider in providers() { result[provider.id] = await provider.availability() }
        if AppleOnDevice.provider() == nil { result[.appleOnDevice] = .unavailable(AppleOnDevice.needsNewerMac) }
        if localModel.isEmpty { result[.localServer] = .unavailable("Add a local server and model") }
        availability = result
    }

    func signOutOfChatGPT() {
        Task {
            await chatGPT.signOut()
            await refresh()
        }
    }

    /// Names and one-line roles for Settings, in ladder order.
    struct Row: Identifiable {
        let id: AIProviderID
        let title: String
        let detail: String
        init(_ id: AIProviderID, _ title: String, _ detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    static let rows: [Row] = [
        Row(.appleOnDevice, "On this Mac", "Apple Intelligence. Free, private, small jobs."),
        Row(.chatGPT, "ChatGPT plan", "Your Go, Plus or Pro plan. Nothing extra to pay."),
        Row(.openAIDecisions, "Decisions API", "Fast keep/cut and clip scores. Uses your OpenAI key."),
        Row(.openAIKey, "OpenAI", "Your own OpenAI key. Also makes thumbnails."),
        Row(.anthropicKey, "Claude", "Your own Anthropic key."),
        Row(.openRouterKey, "OpenRouter", "Your own OpenRouter key, any model."),
        Row(.localServer, "Local model", "A server on this Mac: mlx_lm.server, LM Studio or Ollama."),
    ]
}

/// The approval sheet as a gate approver: asks on the main thread and
/// waits for the user's answer. When the board cancels it (the task's card
/// was answered first), the panel takes the request away.
struct PanelApprover: OutboundApprover {
    func approve(_ request: OutboundRequest) async -> OutboundDecision {
        let id = request.id
        return await withTaskCancellationHandler {
            await ApprovalCenter.shared.ask(request)
        } onCancel: {
            Task { @MainActor in ApprovalCenter.shared.dismiss(id) }
        }
    }
}
