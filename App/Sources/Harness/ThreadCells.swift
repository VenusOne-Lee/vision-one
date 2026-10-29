import AppKit
import SwiftUI
import VisionOneKit

/// One entry in a task's thread, from the Desk.
struct ThreadCellView: View {
    let cell: TaskCell
    let task: DeskTask
    @ObservedObject var model: HarnessModel

    var body: some View {
        switch cell.kind {
        case let .ask(text, mode):
            AskBubble(text: text, at: cell.at, planFirst: mode == .planFirst)
        case let .take(folder):
            let take = Take(folder: folder)
            TakeThreadCard(take: take, title: model.title(of: take)) {
                model.mode = .editor
            }
        case let .reply(agent, text):
            AgentReply(agent: agent, text: text)
        case let .log(text):
            Text(text)
                .textStyle(.caption)
                .foregroundStyle(Theme.textFaint)
        case let .plan(plan):
            PlanCell(plan: plan, jobs: model.snapshot.jobs(for: task))
        case let .receipt(jobID, agent, text):
            let job = model.snapshot.jobs.first { $0.id == jobID }
            let review = job?.state == .needsReview
            ReceiptCell(agent: agent, from: job?.requestedBy, text: text, canKeep: review,
                        canUndo: review && !(job?.changes.isEmpty ?? true),
                        undone: job?.state == .undone,
                        keep: { model.settle(jobID, keep: true) },
                        undo: { model.settle(jobID, keep: false) },
                        review: { model.updateLayout { $0.show(.changes) } })
        case let .approval(card):
            if card.isOpen {
                ApprovalCard(agent: agent(for: card).title,
                             question: card.question,
                             quote: card.detail,
                             options: card.options.map(\.label),
                             feedbackOption: card.options.firstIndex { $0.effect == .deny },
                             onAnswer: { model.answer(card, $0) })
            } else {
                AnsweredCard(card: card)
            }
        case let .failed(agent, message):
            Notice(.error, lead: "\(agent.title) didn't finish", detail: message)
        }
    }

    private func agent(for card: ApprovalCardModel) -> AgentKind {
        if case let .job(id) = card.subject, let job = model.snapshot.jobs.first(where: { $0.id == id }) {
            return job.agent
        }
        return .producer
    }
}

/// An approval once answered: the question and what you said, quietly.
struct AnsweredCard: View {
    let card: ApprovalCardModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.question).textStyle(.caption).foregroundStyle(Theme.textMuted)
                if let answer = card.answer, card.options.indices.contains(answer) {
                    Text(card.options[answer].label + (card.note.map { ": \($0)" } ?? ""))
                        .textStyle(.body)
                }
            }
        }
    }
}

/// An agent's short reply, on the left.
struct AgentReply: View {
    let agent: AgentKind
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.title).textStyle(.label).foregroundStyle(Theme.textFaint)
            Text(text).textStyle(.body).textSelection(.enabled)
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
            .frame(width: 72, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).textStyle(.headline).lineLimit(2)
                Text(take.shortLabel()).textStyle(.caption).foregroundStyle(Theme.textMuted)
                HStack(spacing: Theme.Space.sm) {
                    Button("Edit video", action: openEditor)
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([take.screenURL]) }
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
    var planFirst = false

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
                .help(at.formatted(date: .abbreviated, time: .shortened) + (planFirst ? " · Plan first" : ""))
        }
    }
}

/// The Producer's plan: one line per agent step, ticked when its job is
/// done, a spinner on the one running, dashed circles for what's to come.
struct PlanCell: View {
    let plan: DeskPlan
    let jobs: [AgentJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.inCopy ? "Plan · in a copy, the main cut stays as it is" : "Plan")
                .textStyle(.label).foregroundStyle(Theme.textFaint)
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                let state = self.state(of: step)
                HStack(spacing: Theme.Space.sm) {
                    mark(state)
                        .frame(width: 14, height: 14)
                    Text(step.title)
                        .textStyle(.body)
                        .foregroundStyle(state == nil ? Theme.textMuted : Theme.text)
                    Text(step.agent.title)
                        .textStyle(.caption)
                        .foregroundStyle(Theme.textFaint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func state(of step: DeskPlan.Step) -> AgentJob.State? {
        step.jobID.flatMap { id in jobs.first { $0.id == id }?.state }
    }

    @ViewBuilder
    private func mark(_ state: AgentJob.State?) -> some View {
        switch state {
        case .none, .queued?:
            Circle().strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: Theme.Stroke.hairline,
                                                                      dash: Theme.Stroke.dashSmall))
        case .running?, .needsApproval?:
            ProgressView().controlSize(.mini)
        case .needsReview?:
            Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.ring, dash: Theme.Stroke.dashSmall))
        case .done?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.text)
        case .undone?, .cancelled?:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
        case .failed?:
            Image(systemName: "xmark.circle").foregroundStyle(Theme.error)
        }
    }
}

/// "Clipper is making clips (12 s · Esc to stop)", ticking each second.
struct StatusCell: View {
    let snapshot: DeskSnapshot
    let task: DeskTask
    let stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            if let line = snapshot.activity(of: task, now: context.date) {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(line).textStyle(.body).monospacedDigit()
                    Spacer(minLength: 0)
                    Button("Stop", action: stop)
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// What the agent did. Dashed while its proposals wait for Keep or
/// Undo, solid once kept, faint once undone.
struct ReceiptCell: View {
    let agent: AgentKind
    /// The outside agent that asked for it over MCP, like "Claude Code".
    var from: String? = nil
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
                if let from {
                    Text("from \(from)").textStyle(.label).foregroundStyle(Theme.textMuted)
                }
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
    let drop: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued · sent when the agent is free").textStyle(.label).foregroundStyle(Theme.textFaint)
            ForEach(Array(asks.enumerated()), id: \.offset) { index, ask in
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Text(ask).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(2)
                    Spacer(minLength: 0)
                    IconButton("Remove from queue", systemImage: "xmark") { drop(index) }
                }
            }
        }
        .padding(Theme.Space.sm + 4)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dash)))
    }
}
