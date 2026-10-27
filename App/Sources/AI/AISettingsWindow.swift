import AppKit
import SwiftUI
import VisionOneKit

/// Settings → AI: the ladder in the order it's tried (drag to change),
/// a switch per rung, keys, Sign in with ChatGPT, and "On this Mac only".
struct AISettingsView: View {
    @ObservedObject private var ai = AIServices.shared
    @ObservedObject private var signIn = ChatGPTSignIn.shared
    @State private var editingKey: AIProviderID?
    @State private var draftKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI").font(.system(size: 22, weight: .light))
                Text("Vision One tries the cheapest rung first and asks before anything leaves your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Toggle(isOn: $ai.settings.onDeviceOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On this Mac only").font(.system(size: 13, weight: .semibold))
                    Text("Never send anything to the cloud, even with keys set up.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.text)

            Text("TRY IN THIS ORDER · DRAG TO CHANGE")
                .font(.system(size: 11, weight: .medium)).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            List {
                ForEach(orderedRows) { row in
                    rowView(row)
                        .listRowSeparatorTint(Theme.line)
                }
                .onMove { from, to in
                    var ids = orderedRows.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    ai.settings.order = ids
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 340)

            Toggle("Send keep/cut and clip scores to the Decisions API first when it's set up",
                   isOn: $ai.settings.preferDecisionsAPI)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)

            if case let .failed(message) = signIn.phase {
                EditorNotice(title: "Sign in with ChatGPT", message: message, isError: true)
            }
        }
        .padding(Theme.Space.lg)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 600)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
        .task { await ai.refresh() }
        .sheet(item: $editingKey) { id in keySheet(id) }
    }

    private var orderedRows: [AIServices.Row] {
        ai.settings.fullOrder.compactMap { id in AIServices.rows.first { $0.id == id } }
    }

    @ViewBuilder
    private func rowView(_ row: AIServices.Row) -> some View {
        let state = ai.availability[row.id]
        let enabled = Binding(get: { !ai.settings.disabled.contains(row.id) },
                              set: { on in
                                  if on { ai.settings.disabled.remove(row.id) } else { ai.settings.disabled.insert(row.id) }
                              })
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.cutText)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                Text(detail(row, state)).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
            Spacer()
            action(row.id, state)
            StatusChip(ready: state == .ready)
            Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).tint(Theme.text).controlSize(.small)
        }
        .padding(.vertical, 6)
        .opacity(ai.settings.onDeviceOnly && row.id != .appleOnDevice && row.id != .localServer ? 0.45 : 1)
    }

    private func detail(_ row: AIServices.Row, _ state: AIAvailability?) -> String {
        if row.id == .chatGPT, let account = ai.chatGPTAccount { return "Signed in as \(account)" }
        if case let .unavailable(why) = state { return "\(row.detail) \(why)." }
        return row.detail
    }

    @ViewBuilder
    private func action(_ id: AIProviderID, _ state: AIAvailability?) -> some View {
        switch id {
        case .appleOnDevice:
            EmptyView()
        case .chatGPT:
            if ai.chatGPTAccount != nil {
                Button("Sign out") { ai.signOutOfChatGPT() }.buttonStyle(PillButtonStyle(kind: .secondary))
            } else if signIn.phase == .waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { signIn.stop() }.buttonStyle(.plain).font(.system(size: 12))
                }
            } else {
                Button("Sign in with ChatGPT") { signIn.start() }.buttonStyle(PillButtonStyle(kind: .primary))
            }
        default:
            Button(state == .ready ? "Change" : (id == .localServer ? "Set up" : "Add key")) {
                draftKey = id == .localServer ? ai.localServerURL : ""
                editingKey = id
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
    }

    private func secretName(_ id: AIProviderID) -> String? {
        switch id {
        case .openAIKey, .openAIDecisions: return AISecretName.openAIKey
        case .anthropicKey: return AISecretName.anthropicKey
        case .openRouterKey: return AISecretName.openRouterKey
        default: return nil
        }
    }

    @ViewBuilder
    private func keySheet(_ id: AIProviderID) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if id == .localServer {
                Text("Local model").font(.system(size: 15, weight: .bold))
                Text("Start mlx_lm.server, LM Studio or Ollama on this Mac, then give its address and model name. Nothing sent to it leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                TextField("http://127.0.0.1:8080/v1", text: $draftKey).textFieldStyle(.roundedBorder)
                TextField("Model, such as mlx-community/Qwen3-8B-4bit", text: $ai.localModel).textFieldStyle(.roundedBorder)
            } else {
                Text(id == .anthropicKey ? "Anthropic API key" : id == .openRouterKey ? "OpenRouter API key" : "OpenAI API key")
                    .font(.system(size: 15, weight: .bold))
                Text("Kept in your Keychain. Used only for jobs you approve.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                SecureField("Paste your key", text: $draftKey).textFieldStyle(.roundedBorder)
            }
            HStack {
                if let name = secretName(id), !ai.key(name).isEmpty {
                    Button("Remove key") {
                        ai.setKey("", for: name)
                        editingKey = nil
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.error)
                }
                Spacer()
                Button("Cancel") { editingKey = nil }.buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Save") {
                    if id == .localServer {
                        ai.localServerURL = draftKey
                        Task { await ai.refresh() }
                    } else if let name = secretName(id) {
                        ai.setKey(draftKey, for: name)
                    }
                    editingKey = nil
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
        .background(Theme.paper)
        .environment(\.colorScheme, .light)
    }
}

/// Dashed until a rung is ready, solid once it is: the app's one grammar.
struct StatusChip: View {
    let ready: Bool

    var body: some View {
        Text(ready ? "Ready" : "Not set up")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ready ? Theme.text : Theme.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(ready ? Theme.text : Theme.textMuted,
                                            style: StrokeStyle(lineWidth: 1, dash: ready ? [] : [3, 2])))
    }
}

extension AIProviderID: Identifiable {
    public var id: String { rawValue }
}

/// AI lives in the Settings window; this keeps the old entry point.
@MainActor
final class AISettingsWindowController {
    static let shared = AISettingsWindowController()

    func show() {
        SettingsWindowController.shared.show(.ai)
    }
}
