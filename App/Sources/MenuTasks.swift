import SwiftUI
import VisionOneKit

/// The Desk as the menu bar panel sees it: the latest snapshot, kept
/// current from `desk.updates()`.
@MainActor
final class DeskFeed: ObservableObject {
    static let shared = DeskFeed()

    @Published private(set) var snapshot = DeskSnapshot()
    private var watcher: Task<Void, Never>?

    private init() {
        let desk = AIServices.shared.desk
        watcher = Task { [weak self] in
            for await snapshot in await desk.updates() {
                self?.snapshot = snapshot
            }
        }
    }

    /// Up to `limit` tasks for the panel: the ones waiting on you first,
    /// then the most recently touched.
    func panelTasks(limit: Int = 3) -> [DeskTask] {
        let needsYou = snapshot.needsYou
        let rest = snapshot.tasks
            .filter { !$0.archived && !needsYou.contains($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Array((needsYou + rest).prefix(limit))
    }

    var hasTasks: Bool { snapshot.tasks.contains { !$0.archived } }

    /// "2 need you", or how many tasks there are.
    var summary: String {
        let waiting = snapshot.needsYou.count
        if waiting > 0 { return waiting == 1 ? "1 needs you" : "\(waiting) need you" }
        let count = snapshot.tasks.filter { !$0.archived }.count
        return count == 1 ? "1 task" : "\(count) tasks"
    }

    /// Shows the task in the main window.
    func open(_ task: DeskTask) {
        let desk = AIServices.shared.desk
        EditorWindowController.shared.show()
        Task { await desk.requestOpen(task.id) }
    }

    /// A new task from the ask box; the Producer starts on it straight away.
    func ask(_ text: String) {
        let ask = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { return }
        let desk = AIServices.shared.desk
        Task { await desk.newTask(ask: ask) }
    }
}

/// "Or ask…" under the record button. Return starts a task; it shows up
/// in the Tasks list below while the agents work.
struct PanelAskBox: View {
    @ObservedObject var feed: DeskFeed
    @State private var text = ""

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            TextField("Or ask: make clips from yesterday's demo", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(send)
            if !text.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.text))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Theme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))
    }

    private func send() {
        feed.ask(text)
        text = ""
    }
}

/// The few tasks that matter right now. Click one to open it in the main
/// window.
struct PanelTasksList: View {
    @ObservedObject var feed: DeskFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(feed.panelTasks()) { task in
                Button(action: MenuPanel.closing { feed.open(task) }) {
                    HStack(alignment: .top, spacing: Theme.Space.sm) {
                        TaskStatusIcon(status: feed.snapshot.status(of: task))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Text(feed.snapshot.statusLine(of: task))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Vision One")
            }
        }
        .padding(.horizontal, -6)
    }
}

/// A task's state as a small ring, in the app's grammar: dashed and
/// turning while an agent works, dashed when there's something to keep or
/// undo, solid ink when it's waiting on you or done. Never orange.
struct TaskStatusIcon: View {
    let status: TaskStatus
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        ZStack {
            switch status {
            case .needsYou:
                Circle().fill(Theme.text)
                Text("!")
                    .font(.system(size: size * 0.7, weight: .heavy))
                    .foregroundStyle(Theme.paper)
            case .working:
                Circle()
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { turn = true }
                    }
            case .ready:
                Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            case .done:
                Circle().strokeBorder(Theme.text, lineWidth: 1.5)
            case .failed:
                Circle().strokeBorder(Theme.error, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.title)
    }
}
