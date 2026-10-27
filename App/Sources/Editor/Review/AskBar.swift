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
        let goal = EditorAgent.Goal.parse(ask)
        run = .running(goal.targetSeconds.map { "Cutting to about \(Timecode.short(from: $0))…" } ?? "Reading every sentence…")
        let agent = EditorAgent(ladder: AIServices.shared.ladder())
        Task { [weak self, weak editor] in
            do {
                let added = try await agent.run(on: take, brief: brief, goal: goal, energy: plan.energy)
                editor?.pickUpOutsideCuts()
                self?.run = .done(added.isEmpty
                    ? "Nothing more to cut."
                    : "\(added.count) suggested \(added.count == 1 ? "cut" : "cuts"), dashed in Changes until you accept.")
                if !added.isEmpty { self?.text = "" }
            } catch {
                self?.run = .failed(AgentsModel.message(for: error))
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

/// Under the timeline: "3:12 → 2:41" and what changed to get there.
struct EditSummaryLine: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var effects: EffectsModel

    var body: some View {
        let source = model.edits.sourceDuration
        let kept = model.edits.outputDuration
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("\(Timecode.short(from: source)) → ")
                Text(Timecode.short(from: kept)).fontWeight(.semibold)
            }
            .font(.system(size: 12, design: .monospaced).monospacedDigit())
            .help("Length of the take → length after your cuts")
            Text(changes(removed: max(0, source - kept)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func changes(removed: Double) -> String {
        var parts: [String] = []
        if removed >= 0.5 { parts.append("\(Int(removed.rounded())) s removed") }
        let zooms = effects.zooms.zooms.filter { $0.state != .rejected }.count
        if zooms > 0 { parts.append("\(zooms) \(zooms == 1 ? "zoom" : "zooms")") }
        let blurs = effects.blurs.blurs.filter { $0.hides }.count
        if blurs > 0 { parts.append("\(blurs) \(blurs == 1 ? "blur" : "blurs")") }
        return parts.isEmpty ? "No changes yet" : parts.joined(separator: " · ")
    }
}
