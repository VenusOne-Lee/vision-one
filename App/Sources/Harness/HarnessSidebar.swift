import AppKit
import SwiftUI
import VisionOneKit

/// Projects and their tasks, Codex style: New task and Library on top,
/// each project folds open to its tasks, needing-you first. Drag a task
/// onto a project to move it there.
struct HarnessSidebar: View {
    @ObservedObject var model: HarnessModel
    @AppStorage("harness.collapsed") private var collapsedRaw = ""
    @State private var renaming: UUID?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                SidebarButton("New task", systemImage: "square.and.pencil", isSelected: model.page == .newTask,
                              shortcut: "⌘N") {
                    model.page = .newTask
                }
                SidebarButton("Library", systemImage: "square.grid.2x2", isSelected: model.page == .library) {
                    model.page = .library
                }
            }
            .padding(Theme.Space.sm)

            HStack {
                Text("PROJECTS").textStyle(.label).foregroundStyle(Theme.textFaint)
                Spacer()
                IconButton("New project", systemImage: "folder.badge.plus") { model.addProject() }
            }
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, Theme.Space.sm)
            .padding(.top, Theme.Space.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.snapshot.projects) { project in
                        projectHeader(project)
                        if !collapsed.contains(project.id) {
                            let tasks = model.snapshot.tasks(in: project)
                            if tasks.isEmpty {
                                Text("No tasks yet")
                                    .textStyle(.caption)
                                    .foregroundStyle(Theme.textFaint)
                                    .padding(.leading, 34)
                                    .padding(.vertical, 4)
                            }
                            ForEach(tasks) { task in
                                TaskRow(title: task.title, status: model.snapshot.status(of: task),
                                        line: model.snapshot.statusLine(of: task),
                                        isSelected: model.page.taskID == task.id)
                                    .onTapGesture { model.open(task.id) }
                                    .draggable(task.id.uuidString)
                                    .contextMenu { taskMenu(task) }
                            }
                        }
                    }
                    if model.snapshot.projects.isEmpty {
                        Text("Record something and its task shows up here.")
                            .textStyle(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .padding(Theme.Space.sm)
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.bottom, Theme.Space.md)
            }

            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            HStack(spacing: Theme.Space.xs) {
                IconButton("Settings", systemImage: "gearshape", shortcut: "⌘,") {
                    SettingsWindowController.shared.show()
                }
                Spacer()
                let waiting = model.snapshot.needsYou.count
                if waiting > 0 {
                    Text("\(waiting) need\(waiting == 1 ? "s" : "") you")
                        .textStyle(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: Theme.Size.toolbar)
        }
        .background(Theme.canvas)
    }

    // MARK: Projects

    private var collapsed: Set<UUID> {
        Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func toggle(_ id: UUID) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedRaw = set.map(\.uuidString).joined(separator: ",")
    }

    @ViewBuilder
    private func projectHeader(_ project: DeskProject) -> some View {
        let isOpen = !collapsed.contains(project.id)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 10)
            Image(systemName: isOpen ? "folder" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            if renaming == project.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .textStyle(.bodyStrong)
                    .focused($nameFocused)
                    .onSubmit { finishRenaming(project.id) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(project.name)
                    .textStyle(.bodyStrong)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: 28)
        .background(model.currentProject?.id == project.id && model.page == .newTask ? Theme.paper : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture {
            toggle(project.id)
            model.project = project.id
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init(uuidString:)) { model.move(id, to: project.id) }
            return !ids.isEmpty
        }
        .contextMenu {
            Button("New task here") {
                model.project = project.id
                model.page = .newTask
            }
            Button("Rename…") { startRenaming(project) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Folds the project" : "Shows the project's tasks")
    }

    private func startRenaming(_ project: DeskProject) {
        draft = project.name
        renaming = project.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming(_ id: UUID) {
        model.renameProject(id, to: draft)
        renaming = nil
    }

    @ViewBuilder
    private func taskMenu(_ task: DeskTask) -> some View {
        Button("Open") { model.open(task.id) }
        Button("Open in Editor") {
            model.open(task.id)
            model.mode = .editor
        }
        .disabled(task.take == nil)
        Menu("Move to") {
            ForEach(model.snapshot.projects) { project in
                Button(project.name) { model.move(task.id, to: project.id) }
                    .disabled(task.projectID == project.id)
            }
        }
        if let take = task.take {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.screenURL]) }
        }
        Divider()
        Button("Archive") { model.archive(task.id) }
    }
}

/// A top-of-sidebar row: New task, Library.
struct SidebarButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String, isSelected: Bool = false, shortcut: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title).textStyle(.bodyStrong)
                Spacer(minLength: 0)
                if let shortcut, hovering {
                    Text(shortcut).textStyle(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 30)
            .background(isSelected ? Theme.paper : (hovering ? Theme.line.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One task under its project: title, where it's up to, and a mark:
/// a spinner while an agent works, a dashed ring while something waits
/// for you (proposed), a solid one once it's done.
struct TaskRow: View {
    let title: String
    let status: TaskStatus
    let line: String
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            TaskMark(status: status)
                .frame(width: 14, height: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .textStyle(isSelected ? .bodyStrong : .body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(line)
                    .textStyle(.caption)
                    .foregroundStyle(status == .failed ? Theme.error : Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.paper : (hovering ? Theme.line.opacity(0.5) : .clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isSelected ? Theme.line : .clear, lineWidth: Theme.Stroke.hairline)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The ring before a task: needs you, working, ready, done, didn't finish.
struct TaskMark: View {
    let status: TaskStatus

    var body: some View {
        switch status {
        case .working:
            ProgressView().controlSize(.mini)
        case .needsYou:
            Circle()
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.ring, dash: Theme.Stroke.dashSmall))
                .overlay(Circle().fill(Theme.text).padding(4))
        case .ready:
            Circle()
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.ring, dash: Theme.Stroke.dashSmall))
        case .done:
            Circle().strokeBorder(Theme.text, lineWidth: Theme.Stroke.ring)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.error)
        }
    }
}

/// The slim column of tasks beside a full mode: back, new, and the
/// project's tasks as marks. Hover for the name.
struct TaskRail: View {
    @ObservedObject var model: HarnessModel
    let back: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(width: Theme.Stroke.hairline)
            VStack(spacing: Theme.Space.sm) {
                IconButton("Back to tasks", systemImage: "arrow.uturn.left", shortcut: "Esc", action: back)
                IconButton("New task", systemImage: "square.and.pencil", shortcut: "⌘N") {
                    model.mode = .tasks
                    model.page = .newTask
                }
                Rectangle().fill(Theme.line).frame(width: 24, height: Theme.Stroke.hairline)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if let project = model.currentProject {
                            ForEach(model.snapshot.tasks(in: project)) { task in
                                Button { model.open(task.id) } label: {
                                    RailItem(title: task.title, status: model.snapshot.status(of: task),
                                             isSelected: model.page.taskID == task.id)
                                }
                                .buttonStyle(.plain)
                                .help("\(task.title) · \(model.snapshot.statusLine(of: task))")
                                .accessibilityLabel(task.title)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.sm)
            .frame(width: 56)
            .background(Theme.canvas)
        }
    }
}

private struct RailItem: View {
    let title: String
    let status: TaskStatus
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials)
                .textStyle(.label)
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)
                .background(isSelected ? Theme.paper : Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(isSelected ? Theme.text : Theme.line, lineWidth: Theme.Stroke.hairline)
                )
            if status != .done {
                TaskMark(status: status)
                    .frame(width: 12, height: 12)
                    .background(Theme.paper, in: Circle())
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}
