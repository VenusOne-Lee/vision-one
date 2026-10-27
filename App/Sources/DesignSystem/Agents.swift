import AppKit
import SwiftUI
import VisionOneKit

// Pieces of the Codex-style harness (the signed-off spec, 27 Oct 2026):
// the task sidebar, plan steps, keep-or-undo cards, dividers and the
// review diff. Harness.swift has the thread, composer and panels.
// Running work is a turning dashed ink ring, never orange.

// MARK: Record button

/// The round record button: white circle, ink edge, orange dot. While
/// live the edge turns orange and the dot becomes an ink stop square.
/// The dot is the record button's own; nothing else borrows it.
struct RecordButton: View {
    enum Size {
        case extraSmall, small, regular, large
        var diameter: CGFloat {
            switch self {
            case .extraSmall: 26
            case .small: 36
            case .regular: 56
            case .large: 76
            }
        }
    }

    var isLive = false
    var size: Size = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.paper)
                Circle().strokeBorder(isLive ? Theme.tally : Theme.text, lineWidth: size == .extraSmall ? 1.5 : 2)
                if isLive {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.text)
                        .frame(width: size.diameter * 0.32, height: size.diameter * 0.32)
                } else {
                    Circle().fill(Theme.tally).frame(width: size.diameter * 0.4, height: size.diameter * 0.4)
                }
            }
            .frame(width: size.diameter, height: size.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusRing(Circle())
        .help(isLive ? "Stop recording" : "Record", shortcut: ShortcutMap.record)
        .accessibilityLabel(isLive ? "Stop recording" : "Record")
    }
}

// MARK: Task sidebar

/// A task's ring, from its AgentJob state. Running turns slowly in ink,
/// needs-you is dashed with a dot, queued is dashed and still, done is
/// solid. Never orange: orange is only for a live recording.
struct TaskRing: View {
    enum State: Equatable { case queued, running, needsYou, done, failed }

    let state: State
    var size: CGFloat = 12

    init(state: State, size: CGFloat = 12) {
        self.state = state
        self.size = size
    }

    init(_ job: AgentJob.State, size: CGFloat = 12) {
        self.size = size
        switch job {
        case .queued: state = .queued
        case .running: state = .running
        case .needsApproval, .needsReview: state = .needsYou
        case .done: state = .done
        case .failed: state = .failed
        case .undone, .cancelled: state = .queued
        }
    }

    var body: some View {
        switch state {
        case .queued: BuilderRing(state: .draft, size: size)
        case .running: BuilderRing(state: .running, size: size)
        case .needsYou: BuilderRing(state: .needsYou, size: size)
        case .done: BuilderRing(state: .exported, size: size)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(Theme.error)
                .frame(width: size, height: size)
                .accessibilityLabel("Didn't finish")
        }
    }
}

// MARK: Steps

/// The Producer's plan, Codex-style: ✓ done (struck through), ◌ running,
/// ○ still to do, – skipped, ! failed.
///
///     StepList(steps: job.steps)
struct StepList: View {
    let steps: [AgentJob.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(mark(step.state))
                        .textStyle(.mono)
                        .foregroundStyle(step.state == .failed ? Theme.error : Theme.text)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(step.title)
                        .textStyle(.body)
                        .strikethrough(step.state == .done || step.state == .skipped, color: Theme.textMuted)
                        .foregroundStyle(step.state == .pending || step.state == .done ? Theme.textMuted : Theme.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(spoken(step.state))
            }
        }
    }

    private func mark(_ state: AgentJob.Step.State) -> String {
        switch state {
        case .done: "✓"
        case .running: "◌"
        case .pending: "○"
        case .skipped: "–"
        case .failed: "!"
        }
    }

    private func spoken(_ state: AgentJob.Step.State) -> String {
        switch state {
        case .done: "Done"
        case .running: "In progress"
        case .pending: "Not started"
        case .skipped: "Skipped"
        case .failed: "Didn't finish"
        }
    }
}

// MARK: Ready to Share cards

/// One thing an agent did, to keep or undo. Dashed until kept, solid
/// once kept. Undo puts it back the way it was.
///
///     AgentCard("Cut 39 s", detail: "14 ums and 6 long pauses", isKept: $kept, onUndo: undo)
struct AgentCard: View {
    let title: String
    let detail: String
    @Binding var isKept: Bool
    let onUndo: () -> Void

    init(_ title: String, detail: String, isKept: Binding<Bool>, onUndo: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self._isKept = isKept
        self.onUndo = onUndo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).textStyle(.headline).foregroundStyle(Theme.text).lineLimit(1)
            Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.xs) {
                if isKept {
                    Label("Kept", systemImage: "checkmark")
                        .textStyle(.caption)
                        .foregroundStyle(Theme.textMuted)
                } else {
                    Button("Keep") { isKept = true }
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                }
                Spacer(minLength: 0)
                Button("Undo", action: onUndo)
                    .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg - 2).fill(Theme.paper))
        .statusOutline(isKept ? .accepted : .proposed, cornerRadius: Theme.Radius.lg - 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(isKept ? "kept" : "suggested")")
    }
}

/// A row in the editor's Changes list: which agent, what it did, an
/// optional time saved, and a switch. Dashed until switched on.
struct ProposalRow: View {
    let agent: String
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(agent: String, title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.agent = agent
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent).textStyle(.label).foregroundStyle(Theme.textMuted)
                HStack(spacing: 6) {
                    Text(title).textStyle(.bodyStrong).foregroundStyle(Theme.text).lineLimit(2)
                    if let detail { Mono(detail, small: true).foregroundStyle(Theme.textMuted) }
                }
            }
            Spacer(minLength: Theme.Space.sm)
            Toggle(title, isOn: $isOn).toggleStyle(InkSwitchStyle(label: "Keep: \(title)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
        .statusOutline(isOn ? .accepted : .proposed)
    }
}

// MARK: Suggestions

/// A suggested ask or starter ("Record a launch video"). Dashed: it's a
/// proposal until you tap it.
struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .textStyle(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: Theme.Size.controlSmall)
                .statusOutline(.proposed, cornerRadius: Theme.Size.controlSmall / 2, lineWidth: Theme.Stroke.ring)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(Capsule())
    }
}

// MARK: Dividers

/// A draggable divider between panes. Drag to resize; double-click to
/// put it back. The size is remembered per `id`, so the layout comes
/// back the way the person left it. Below `collapseBelow` the pane folds
/// shut (size 0), like the takes list in the Paper Desk.
///
///     @AppStorage("layout.sidebar") var sidebar: Double = 240
///     HStack(spacing: 0) {
///         Sidebar().frame(width: sidebar)
///         ResizableDivider(size: $sidebar, range: 180...360, defaultSize: 240)
///         Content()
///     }
struct ResizableDivider: View {
    enum Axis { case vertical, horizontal }

    @Binding var size: Double
    let range: ClosedRange<Double>
    let defaultSize: Double
    var axis: Axis = .vertical
    /// Grows the pane when dragging right/down (+1) or left/up (-1).
    var direction: Double = 1
    var collapseBelow: Double?
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.line)
                .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            Capsule()
                .fill(hovering || start != nil ? Theme.text : Theme.lineStrong)
                .frame(width: axis == .vertical ? 3 : 28, height: axis == .vertical ? 28 : 3)
        }
        .frame(width: axis == .vertical ? 8 : nil, height: axis == .horizontal ? 8 : nil)
        .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = start ?? size
                    if start == nil { start = size }
                    let delta = Double(axis == .vertical ? value.translation.width : value.translation.height) * direction
                    var next = origin + delta
                    if let collapseBelow, next < collapseBelow {
                        next = 0
                    } else {
                        next = min(max(next, range.lowerBound), range.upperBound)
                    }
                    size = next
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { size = defaultSize }
        .accessibilityElement()
        .accessibilityLabel("Divider")
        .accessibilityValue("\(Int(size)) points")
        .accessibilityAdjustableAction { change in
            let step = 20.0
            switch change {
            case .increment: size = min(size + step, range.upperBound)
            case .decrement: size = max(size - step, collapseBelow == nil ? range.lowerBound : 0)
            @unknown default: break
            }
        }
    }
}

// MARK: Review diff

/// A line in a task's before-and-after review: removed lines on a grey
/// tint with the words struck through, added ones on the selection tint.
struct DiffRow: View {
    enum Kind { case same, removed, added }
    let time: String
    let text: String
    var kind: Kind = .same

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Mono(time, small: true).foregroundStyle(Theme.textMuted).frame(width: 44, alignment: .leading)
            Text(text)
                .font(.ds(.transcript))
                .strikethrough(kind == .removed)
                .foregroundStyle(kind == .removed ? Theme.cutText : (kind == .added ? Theme.selection : Theme.text))
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(
            kind == .removed ? Theme.canvas : (kind == .added ? Theme.selectionSoft : .clear)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind == .removed ? "Removed" : kind == .added ? "Added" : "") \(time): \(text)")
    }
}
