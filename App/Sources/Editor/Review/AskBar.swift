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
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isRunning else { return }
        if SilenceCut.isSilenceAsk(typed) {
            cutSilence(on: editor)
            return
        }
        switch AskRouter.route(typed) {
        case let .clarify(message):
            run = .failed(message)
        case .open:
            HarnessModel.shared.open(editor.take, then: typed, mode: .editor)
            text = ""
            run = .done("Opened the requested tool for this task.")
        case .plan:
            // The task owns routing, plan approvals, retry/cancel, jobs and
            // proposed results, including compound asks and alternate cuts.
            HarnessModel.shared.open(editor.take, then: typed)
            text = ""
            run = .done("Review the plan and results in this task.")
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
        // Said while holding Space, and not one of the edits done on the spot.
        .onChange(of: model.pendingAsk) { _, said in
            guard let said else { return }
            model.pendingAsk = nil
            ask.text = said
            ask.go(on: model)
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
