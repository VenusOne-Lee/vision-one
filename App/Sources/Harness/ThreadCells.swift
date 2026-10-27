import AppKit
import SwiftUI
import VisionOneKit

/// One block in a task's thread.
struct ThreadCellView: View {
    let cell: ThreadCell
    @ObservedObject var model: HarnessModel
    let take: Take

    var body: some View {
        switch cell {
        case let .take(take):
            TakeThreadCard(take: take, title: model.title(of: take)) {
                model.mode = .editor
            }
        case let .ask(_, text, at):
            AskBubble(text: text, at: at)
        case let .plan(_, agent, steps):
            PlanCell(agent: agent, steps: steps)
        case let .status(jobID, line, since):
            StatusCell(line: line, since: since) { model.stop(jobID) }
        case let .approval(jobID, agent, approval):
            ThreadApprovalCell(agent: agent, approval: approval) { choice in
                model.answer(jobID, choice, agent: agent)
            }
        case let .receipt(jobID, agent, text, canKeep, canUndo, undone):
            ReceiptCell(agent: agent, text: text, canKeep: canKeep, canUndo: canUndo, undone: undone,
                        keep: { model.settle(jobID, keep: true) },
                        undo: { model.settle(jobID, keep: false) },
                        review: { model.updateLayout { $0.show(.changes) } })
        case let .failed(_, agent, message):
            Notice(.error, lead: "\(agent.title) didn't finish", detail: message)
        case let .queued(asks):
            QueuedCell(asks: asks) { model.dropQueued($0, on: take) }
        }
    }
}

/// The take the task is about: its first frame, name and length.
struct TakeThreadCard: View {
    let take: Take
    let title: String
    let openEditor: () -> Void
    @State private var frame: CGImage?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            ZStack {
                Rectangle().fill(Theme.canvas)
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(Theme.textFaint)
                }
            }
            .frame(width: 128, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).textStyle(.headline).lineLimit(2)
                Text(take.shortLabel()).textStyle(.caption).foregroundStyle(Theme.textMuted)
                HStack(spacing: Theme.Space.sm) {
                    Button("Open in Editor", action: openEditor)
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.screenURL]) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .panelStyle(padding: Theme.Space.sm + 4)
        .task(id: take.name) { frame = await LibraryPreviews.shared.firstFrame(for: take) }
    }
}

/// What the builder asked, on the right like a message.
struct AskBubble: View {
    let text: String
    let at: Date

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .textStyle(.body)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.md - 4)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                .help(at.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

/// The agent's checklist: ticked when done, a spinner on the step it's
/// on, dashed circles for what's still to come.
struct PlanCell: View {
    let agent: AgentKind
    let steps: [AgentJob.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(agent.title)'s plan").textStyle(.label).foregroundStyle(Theme.textFaint)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: Theme.Space.sm) {
                    mark(step.state)
                        .frame(width: 14, height: 14)
                    Text(step.title)
                        .textStyle(.body)
                        .foregroundStyle(step.state == .pending || step.state == .skipped ? Theme.textMuted : Theme.text)
                        .strikethrough(step.state == .skipped)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(label(step.state))
            }
        }
    }

    @ViewBuilder
    private func mark(_ state: AgentJob.Step.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.text)
        case .running:
            ProgressView().controlSize(.mini)
        case .pending:
            Circle().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: Theme.Stroke.hairline,
                                                                      dash: Theme.Stroke.dashSmall))
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
        case .failed:
            Image(systemName: "xmark.circle").foregroundStyle(Theme.error)
        }
    }

    private func label(_ state: AgentJob.Step.State) -> String {
        switch state {
        case .done: return "Done"
        case .running: return "Working on it"
        case .pending: return "Not started"
        case .skipped: return "Skipped"
        case .failed: return "Didn't work"
        }
    }
}

/// "Clipper · Finding moments (12s · Esc to stop)".
struct StatusCell: View {
    let line: String
    let since: Date
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: since, by: 1)) { context in
                (Text(line).foregroundStyle(Theme.text)
                    + Text("  (\(TaskThread.elapsed(since: since, now: context.date)) · Esc to stop)")
                    .foregroundStyle(Theme.textMuted))
                    .textStyle(.body)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("Stop", action: stop)
                .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
        }
        .accessibilityElement(children: .combine)
    }
}

/// An agent asks before anything leaves the Mac: what, where, to whom,
/// and what it costs. 1, 2, 3 or ↑ ↓ and Return pick; Esc decides later.
struct ThreadApprovalCell: View {
    let agent: AgentKind
    let approval: AgentJob.Approval
    let answer: (ApprovalChoice) -> Void

    @State private var highlighted = ApprovalChoice.yes
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            Text(question).textStyle(.headline)
            if !approval.preview.isEmpty {
                Text(approval.preview)
                    .textStyle(.monoSmall)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ApprovalChoice.allCases, id: \.self) { choice in
                    Button { answer(choice) } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Text("\(choice.number).")
                                .textStyle(.mono)
                                .foregroundStyle(Theme.textMuted)
                            Text(choice.label(agent: agent)).textStyle(.body)
                            Spacer(minLength: 0)
                            if choice == highlighted {
                                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                            }
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.sm)
                        .frame(height: 28)
                        .background(choice == highlighted ? Theme.canvas : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { highlighted = choice } }
                }
            }
            Text("Esc decides later. Nothing leaves your Mac until you say yes.")
                .textStyle(.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .panelStyle(padding: Theme.Space.md)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(focused ? Theme.text : .clear, lineWidth: Theme.Stroke.focus))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { highlighted = highlighted.moved(by: -1); return .handled }
        .onKeyPress(.downArrow) { highlighted = highlighted.moved(by: 1); return .handled }
        .onKeyPress(.return) { answer(highlighted); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            guard let n = Int(press.characters), let choice = ApprovalChoice(rawValue: n) else { return .ignored }
            answer(choice)
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }

    private var question: String {
        approval.isPost
            ? "\(agent.title) wants to post to \(approval.destination)"
            : "\(agent.title) wants to use \(approval.providerName)"
    }

    private var detail: String {
        var parts = [approval.summary]
        if !approval.isPost { parts.append("\(approval.characters) characters to \(approval.destination)") }
        if let rand = approval.estimatedRand { parts.append(String(format: "about R%.2f", rand)) }
        if approval.fromPlan { parts.append("covered by your plan") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What the agent did. Dashed while its proposals wait for Keep or
/// Undo, solid once kept, faint once undone.
struct ReceiptCell: View {
    let agent: AgentKind
    let text: String
    let canKeep: Bool
    let canUndo: Bool
    let undone: Bool
    let keep: () -> Void
    let undo: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(agent.title).textStyle(.label).foregroundStyle(Theme.textFaint)
                if undone {
                    Text("Undone").textStyle(.label).foregroundStyle(Theme.textMuted)
                } else if !canKeep {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text)
                        .accessibilityLabel("Kept")
                }
            }
            Text(text)
                .textStyle(.body)
                .foregroundStyle(undone ? Theme.textMuted : Theme.text)
                .strikethrough(undone)
                .textSelection(.enabled)
            if canKeep {
                HStack(spacing: Theme.Space.sm) {
                    Button("Keep", action: keep)
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    if canUndo {
                        Button("Undo", action: undo)
                            .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    }
                    Button("Review", action: review)
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                        .help("Open Changes to go through them one by one")
                }
            }
        }
        .padding(Theme.Space.md - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(canKeep ? Theme.text : Theme.line,
                              style: StrokeStyle(lineWidth: canKeep ? Theme.Stroke.hairline : Theme.Stroke.hairline,
                                                 dash: canKeep ? Theme.Stroke.dash : []))
        )
        .opacity(undone ? 0.7 : 1)
    }
}

/// Asks waiting for the agent that's working to finish.
struct QueuedCell: View {
    let asks: [String]
    let drop: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued · sent when the agent is free").textStyle(.label).foregroundStyle(Theme.textFaint)
            ForEach(Array(asks.enumerated()), id: \.offset) { _, ask in
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Text(ask).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(2)
                    Spacer(minLength: 0)
                    IconButton("Remove from queue", systemImage: "xmark") { drop(ask) }
                }
            }
        }
        .padding(Theme.Space.sm + 4)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dash)))
    }
}
