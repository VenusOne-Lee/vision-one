import SwiftUI
import VisionOneKit

/// The Steps pane for a take an AI agent recorded (actions.json): what
/// it did, in order, with its own notes as headings. Click a step to
/// jump there. Steps inside a cut are faded, and the one playing now is
/// marked.
struct AgentStepsPane: View {
    @ObservedObject var model: EditorModel
    @State private var log: AgentActionLog?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let log {
                header(log)
                Divider().overlay(Theme.line)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log.sorted) { action in
                                row(action, current: action.id == current(in: log)?.id)
                                    .id(action.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: current(in: log)?.id) { _, id in
                        guard let id, model.isPlaying else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            } else {
                EditorNotice(title: "No steps",
                             message: "This take has no record of an agent's clicks and typing.",
                             isError: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .task(id: model.take.folder) { log = AgentActionLog.load(for: model.take) }
    }

    private func header(_ log: AgentActionLog) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(log.task.map { "\(log.agent): \($0)" } ?? "\(log.agent) was driving")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(log.summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The last step that started at or before the playhead.
    private func current(in log: AgentActionLog) -> AgentAction? {
        log.sorted.last { $0.t <= model.sourceTime + 0.05 }
    }

    private func row(_ action: AgentAction, current: Bool) -> some View {
        let removed = model.edits.isRemoved(action.t)
        let isNote = action.kind == .step
        return Button {
            model.seek(toSource: max(0, action.t - 0.5))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(Timecode.short(from: action.t))
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 44, alignment: .leading)
                Image(systemName: Self.symbol(action.kind))
                    .font(.system(size: 11))
                    .frame(width: 14)
                    .foregroundStyle(isNote ? Theme.text : Theme.textMuted)
                Text(action.line)
                    .font(.system(size: isNote ? 13 : 12, weight: isNote ? .semibold : .regular))
                    .strikethrough(removed)
                    .lineLimit(isNote ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if action.source == .told && !isNote {
                    Text("told")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                        .help("The agent reported this step; Vision One didn't see the input.")
                }
            }
            .opacity(removed ? 0.45 : 1)
            .padding(.vertical, isNote ? 7 : 4)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if current { Rectangle().fill(Theme.text).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(removed ? "Cut from the video. Click to jump there." : "Jump to this step")
    }

    static func symbol(_ kind: AgentAction.Kind) -> String {
        switch kind {
        case .click: return "cursorarrow.click"
        case .doubleClick: return "cursorarrow.click.2"
        case .rightClick: return "contextualmenu.and.cursorarrow"
        case .drag: return "hand.draw"
        case .scroll: return "scroll"
        case .type: return "keyboard"
        case .key: return "command"
        case .step: return "flag"
        }
    }

    /// Whether this take was an agent's, so the Steps tab shows.
    static func has(_ take: Take) -> Bool {
        FileManager.default.fileExists(atPath: AgentActionLog.url(in: take).path)
    }
}
