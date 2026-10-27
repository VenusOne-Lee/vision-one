import SwiftUI
import VisionOneKit

/// A Codex-style approval: who's asking, the question, the exact words
/// that would leave the Mac, then numbered options. ↑↓ choose, Return
/// confirms, 1 to 3 answer straight away, Esc decides later. The last
/// option asks what to do differently and passes it back. Dashed while
/// it waits for you, like everything proposed.
struct ApprovalCard: View {
    let agent: String
    let question: String
    var quote: String? = nil
    let options: [String]
    /// The option that takes a note ("No, and tell the Sharer…"), or nil.
    var feedbackOption: Int? = 2
    let onAnswer: (ApprovalAnswer) -> Void
    var onLater: (() -> Void)? = nil

    @State private var selection: ApprovalSelection
    @State private var asking = false
    @State private var feedback = ""
    @FocusState private var focused: Bool
    @FocusState private var noteFocused: Bool

    init(agent: String, question: String, quote: String? = nil, options: [String],
         feedbackOption: Int? = 2, onAnswer: @escaping (ApprovalAnswer) -> Void,
         onLater: (() -> Void)? = nil) {
        self.agent = agent
        self.question = question
        self.quote = quote
        self.options = options
        self.feedbackOption = feedbackOption
        self.onAnswer = onAnswer
        self.onLater = onLater
        _selection = State(initialValue: ApprovalSelection(count: options.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(agent.uppercased())
                .textStyle(.caption)
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            Text(question)
                .textStyle(.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let quote, !quote.isEmpty {
                Text("“\(quote)”")
                    .textStyle(.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Space.sm)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.line).frame(width: 2)
                    }
            }
            VStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, title in
                    option(index, title)
                }
            }
            if asking {
                TextField("What should the Sharer do differently?", text: $feedback, axis: .vertical)
                    .textFieldStyle(InkTextFieldStyle())
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .onSubmit { answer(feedbackOption ?? 0) }
                HStack(spacing: Theme.Space.sm) {
                    Button("Send to the Sharer") { answer(feedbackOption ?? 0) }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    Button("Back") { asking = false; focused = true }
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
            }
            Text(PostApprovalText.keys)
                .textStyle(.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(.proposed, cornerRadius: Theme.Radius.lg)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selection.up(); return .handled }
        .onKeyPress(.downArrow) { selection.down(); return .handled }
        .onKeyPress(.return) {
            guard !asking else { return .ignored }
            answer(selection.index)
            return .handled
        }
        .onKeyPress(.escape) {
            if asking { asking = false; return .handled }
            guard let onLater else { return .ignored }
            onLater()
            return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard !asking, let n = Int(press.characters), selection.pick(n) else { return .ignored }
            answer(selection.index)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent) asks: \(question)")
    }

    private func option(_ index: Int, _ title: String) -> some View {
        let picked = selection.index == index
        return Button {
            _ = selection.pick(index + 1)
            answer(index)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text("\(index + 1)")
                    .textStyle(.monoSmall)
                    .foregroundStyle(picked ? Theme.paper : Theme.textMuted)
                    .frame(width: 18, height: 18)
                    .background(picked ? Theme.text : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(picked ? Color.clear : Theme.line, lineWidth: Theme.Stroke.hairline))
                Text(title)
                    .textStyle(picked ? .bodyStrong : .body)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 6)
            .frame(minHeight: Theme.Size.hitMin)
            .background(picked ? Theme.canvas : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { _ = selection.pick(index + 1) } }
        .accessibilityLabel("\(index + 1). \(title)")
    }

    private func answer(_ index: Int) {
        if index == feedbackOption, !asking {
            asking = true
            noteFocused = true
            return
        }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let answer = ApprovalAnswer(number: index + 1, feedback: note) else { return }
        onAnswer(answer)
    }
}
