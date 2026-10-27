import SwiftUI
import VisionOneKit

/// Runs the Editor agent from the ask bar, the same way the Agents
/// window does. Its cuts are written to edits.json and arrive in the
/// editor dashed, through the outside-cut merge.
@MainActor
final class AskModel: ObservableObject {
    enum Run: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    @Published var text = ""
    @Published private(set) var run: Run = .idle

    var isRunning: Bool {
        if case .running = run { return true }
        return false
    }

    func go(on editor: EditorModel) {
        let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !isRunning else { return }
        let take = editor.take
        // What it's for, as the Agents window picks it: the take's own
        // plan, else the next purpose chosen, else a demo.
        let next = UserDefaults.standard.string(forKey: "ai.nextPurpose").flatMap(Purpose.named) ?? .demo
        let plan = TakePlan.load(for: take) ?? TakePlan(purpose: next)
        let presetName = UserDefaults.standard.string(forKey: "ai.preset") ?? ""
        let preset = PresetLibrary.standard.all().first { $0.name == presetName }
        let brief = plan.purpose.brief(preset: preset)
        if SilenceCut.isSilenceAsk(ask) {
            cutSilence(on: editor)
            return
        }
        let goal = EditorAgent.Goal.parse(ask)
        run = .running(goal.targetSeconds.map { "Cutting to about \(Timecode.short(from: $0))…" } ?? "Reading every sentence…")
        let agent = EditorAgent(ladder: AIServices.shared.ladder())
        Task { [weak self, weak editor] in
            do {
                let added = try await agent.run(on: take, brief: brief, goal: goal, energy: plan.energy)
                editor?.pickUpOutsideCuts()
                self?.run = .done(added.isEmpty
                    ? "Every sentence earns its place, so there's nothing new to cut. To take out quiet parts, ask “cut the silence”."
                    : "\(added.count) suggested \(added.count == 1 ? "cut" : "cuts"), dashed in Changes until you accept.")
                if !added.isEmpty { self?.text = "" }
            } catch {
                self?.run = .failed(AgentsModel.message(for: error))
            }
        }
    }
}

extension AskModel {
    /// "Cut where nobody's talking": done on the spot from the mic, as
    /// one undo step, rather than asking the Editor agent, which only
    /// weighs whole sentences.
    fileprivate func cutSilence(on editor: EditorModel) {
        run = .running("Listening for the quiet parts…")
        Task { [weak self, weak editor] in
            guard let editor else { return }
            let before = editor.edits.outputDuration
            let result = await editor.cutSilence()
            guard let self else { return }
            if result.stretches == 0 {
                self.run = .done("No quiet stretches over a second left to cut.")
            } else {
                let after = editor.edits.outputDuration
                let what = result.stretches == 1 ? "1 quiet stretch" : "\(result.stretches) quiet stretches"
                self.run = .done("Cut \(what): \(Timecode.short(from: before)) → \(Timecode.short(from: after)). ⌘Z brings them back.")
                self.text = ""
            }
        }
    }
}

/// "Ask" at the foot of the editor: one field and a black Go pill in an
/// ink-bordered capsule, with a small line saying what happened.
struct AskBar: View {
    @ObservedObject var model: EditorModel
    @StateObject private var ask = AskModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.sm) {
                Text("Ask")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
                TextField("Ask", text: $ask.text,
                          prompt: Text("Make a 45 second TikTok, hook first"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .labelsHidden()
                    .onSubmit { ask.go(on: model) }
                    .disabled(ask.isRunning)
                Button("Go") { ask.go(on: model) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(ask.isRunning || ask.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("The Editor suggests cuts for what you asked. They arrive dashed in Changes.")
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1.5))
            status
                .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch ask.run {
        case .idle:
            EmptyView()
        case let .running(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(message)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
        case let .done(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        case let .failed(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.error)
                .lineLimit(2)
                .help(message)
        }
    }
}
