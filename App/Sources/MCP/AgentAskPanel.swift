import AppKit
import SwiftUI
import VisionOneKit

/// The floating card an agent's request waits on: "Record your screen for
/// Claude Code?". One at a time, kept out of recordings like every Vision
/// One window. The same question also sits on the task in the Agent Desk;
/// answering either one closes both.
@MainActor
final class AgentAskCenter: ObservableObject {
    static let shared = AgentAskCenter()

    private struct Pending {
        let question: MCPQuestion
        let reply: CheckedContinuation<MCPAnswer, Never>
    }

    @Published private(set) var current: MCPQuestion?
    @Published var note = ""
    private var queue: [Pending] = []
    private var active: Pending?
    private var panel: NSPanel?

    func ask(_ question: MCPQuestion) async -> MCPAnswer {
        await withCheckedContinuation { continuation in
            queue.append(Pending(question: question, reply: continuation))
            showNext()
        }
    }

    func answer(_ decision: OutboundDecision) {
        let note = decision == .deny ? self.note : ""
        finish(MCPAnswer(decision, note: note))
    }

    /// The user answered on the task instead.
    func dismiss(_ questionID: UUID) {
        if active?.question.id == questionID {
            finish(.no)
        } else if let i = queue.firstIndex(where: { $0.question.id == questionID }) {
            queue.remove(at: i).reply.resume(returning: .no)
        }
    }

    private func finish(_ answer: MCPAnswer) {
        active?.reply.resume(returning: answer)
        active = nil
        current = nil
        note = ""
        if queue.isEmpty { panel?.orderOut(nil) }
        showNext()
    }

    private func showNext() {
        guard active == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        active = next
        current = next.question
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .aqua)
            panel.sharingType = .none
            panel.contentViewController = NSHostingController(rootView: AgentAskView(center: self))
            panel.standardWindowButton(.closeButton)?.isHidden = true
            self.panel = panel
        }
        panel?.center()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }
}

struct AgentAskView: View {
    @ObservedObject var center: AgentAskCenter

    var body: some View {
        Group {
            if let question = center.current {
                content(question)
            } else {
                Color.clear.frame(width: 440, height: 10)
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
    }

    private func content(_ q: MCPQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.text)
                    .frame(width: 18, height: 18)
                    .overlay(Text(String(q.client.displayName.prefix(1)))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.paper))
                Text(q.client.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Text(q.title)
                .font(.system(size: 17, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(q.details.enumerated()), id: \.offset) { _, detail in
                    GridRow {
                        Text(detail.label).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        Text(detail.value).font(.system(size: 12))
                    }
                }
            }
            if let preview = q.preview {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 12, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 96)
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            if q.action == .share {
                Text("Vision One opens the post with the video ready. You press Post.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            TextField("Or tell \(q.client.displayName) what to do instead…", text: $center.note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { if !center.note.isEmpty { center.answer(.deny) } }
            HStack {
                Button(center.note.isEmpty ? "Don't allow" : "Send note") { center.answer(.deny) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if q.canRemember {
                    Button("Allow until quit") { center.answer(.allowForSession) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .help("Don't ask again for \(q.client.displayName) until Vision One quits")
                }
                Button(q.action == .share ? "Open the post" : "Allow once") { center.answer(.allowOnce) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 440)
    }
}
