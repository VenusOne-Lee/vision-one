import AppKit
import SwiftUI
import VisionOneKit

// The Codex-style harness from the signed-off spec: projects and tasks on
// the left, the task's thread in the middle, and a component panel on
// the right that drags, hides or goes full screen. These are its parts;
// Agents.swift has the task rows, steps, cards and dividers.

// MARK: Sidebar

/// A project in the sidebar: initial tile, name, task count and a fold
/// arrow. Its TaskRows sit under it while open.
///
///     ProjectRow(name: "RankRide", taskCount: jobs.count, isOpen: $open)
struct ProjectRow: View {
    let name: String
    var taskCount = 0
    @Binding var isOpen: Bool
    @State private var hovering = false

    init(name: String, taskCount: Int = 0, isOpen: Binding<Bool>) {
        self.name = name
        self.taskCount = taskCount
        self._isOpen = isOpen
    }

    var body: some View {
        Button {
            withAnimation(Theme.Motion.reduced ? nil : Theme.Motion.move) { isOpen.toggle() }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(name.prefix(1).uppercased())
                    .textStyle(.label)
                    .foregroundStyle(Theme.onButton)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.button))
                    .accessibilityHidden(true)
                Text(name).textStyle(.headline).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if taskCount > 0 {
                    Mono("\(taskCount)", small: true).foregroundStyle(Theme.textMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(minHeight: Theme.Size.control)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovering ? Theme.canvas : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .accessibilityLabel("\(name), \(taskCount) \(taskCount == 1 ? "task" : "tasks")")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }
}

// MARK: Thread

/// One cell in a task's thread. Four kinds, as in Codex:
/// - `.user`: what you asked, in a bubble on the right.
/// - `.agent(name)`: the agent's reply, plain on the page with its name.
/// - `.take`: a take or clip card, framed.
/// - `.log`: the quiet activity log, in mono.
///
///     ThreadCell(user: "make it 60s")
///     ThreadCell(.agent("Editor")) { StepList(steps: job.steps) }
///     ThreadCell(log: ["Read transcript.json", "Found 14 fillers"])
struct ThreadCell<Content: View>: View {
    enum Kind: Equatable {
        case user
        case agent(String)
        case take
        case log
    }

    let kind: Kind
    let content: Content

    init(_ kind: Kind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        switch kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                content
                    .textStyle(.body)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, Theme.Space.sm)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.canvas))
            }
        case .agent(let name):
            VStack(alignment: .leading, spacing: 6) {
                Text(name).textStyle(.label).foregroundStyle(Theme.textMuted).accessibilityAddTraits(.isHeader)
                content.textStyle(.body).foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        case .take:
            content
                .padding(Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line))
        case .log:
            content
                .textStyle(.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, Theme.Space.sm)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ThreadCell where Content == Text {
    init(user text: String) {
        self.init(.user) { Text(text) }
    }
}

extension ThreadCell where Content == AnyView {
    /// The activity log: one line per thing the agent did.
    init(log lines: [String]) {
        self.init(.log) {
            AnyView(VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).lineLimit(1) }
            })
        }
    }
}

/// What's running now, under the thread: a shimmering verb, a clock and
/// how to stop. "◌ Clipper is making clips (12s · Esc to stop)". The
/// shimmer holds still with Reduce Motion on.
struct StatusLine: View {
    let verb: String
    var since: Date = Date()
    var onStop: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    init(verb: String, since: Date = Date(), onStop: (() -> Void)? = nil) {
        self.verb = verb
        self.since = since
        self.onStop = onStop
    }

    /// For previews: as if it started `elapsed` seconds ago.
    init(verb: String, elapsed: TimeInterval) {
        self.init(verb: verb, since: Date().addingTimeInterval(-elapsed))
    }

    var body: some View {
        HStack(spacing: 6) {
            BuilderRing(state: .running, size: 11)
            Text(verb)
                .textStyle(.bodyStrong)
                .foregroundStyle(Theme.text)
                .overlay(shimmer.mask(Text(verb).textStyle(.bodyStrong)))
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("(\(Int(context.date.timeIntervalSince(since)))s · Esc to stop)")
                    .textStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .background {
            if let onStop {
                Button("Stop", action: onStop).keyboardShortcut(.cancelAction).hidden()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(verb). Press Escape to stop.")
    }

    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Theme.paper.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.5)
                .offset(x: phase * geo.size.width)
        }
        .allowsHitTesting(false)
    }
}

/// A message typed while an agent is still working: a dashed chip above
/// the composer, because it hasn't been sent yet. ↑ in an empty composer
/// edits it (Composer's `onEditQueued`).
struct QueuedInput: View {
    let text: String
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Queued").textStyle(.label).foregroundStyle(Theme.textMuted)
            Text(text).textStyle(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Theme.Space.sm)
            Text("↑ to edit").textStyle(.caption).foregroundStyle(Theme.textFaint)
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textMuted)
            .minimumHitTarget()
            .accessibilityLabel("Don't send")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Theme.Size.control)
        .statusOutline(.proposed, cornerRadius: Theme.Radius.md, lineWidth: Theme.Stroke.hairline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued: \(text)")
    }
}

// MARK: Approvals

/// A question that needs a yes before anything leaves the Mac: a solid
/// ink border, numbered options with one picked already, Return confirms
/// and Esc decides later. 1 to 9 pick an option.
///
///     ApprovalChoices(title: "Post to Version One?", detail: "Title, 3 chapters and a launch note",
///                     options: ["Post now", "Edit first", "Don't post"], selection: $choice,
///                     onConfirm: post, onDefer: later)
struct ApprovalChoices: View {
    let title: String
    var detail: String?
    let options: [String]
    @Binding var selection: Int
    let onConfirm: (Int) -> Void
    var onDefer: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).textStyle(.headline).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).textStyle(.body).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    let isOn = index == selection
                    Button {
                        selection = index
                    } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Mono("\(index + 1)", small: true)
                                .foregroundStyle(isOn ? Theme.onButton : Theme.textMuted)
                                .frame(width: 14)
                            Text(option).textStyle(.bodyStrong).foregroundStyle(isOn ? Theme.onButton : Theme.text)
                            Spacer(minLength: 0)
                            if isOn {
                                Text("⏎").textStyle(.caption).foregroundStyle(Theme.onButton.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: Theme.Size.control)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(isOn ? Theme.button : (Theme.canvas)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            HStack {
                if let onDefer {
                    Button("Decide later", action: onDefer)
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(options.indices.contains(selection) ? options[selection] : "OK") { onConfirm(selection) }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!options.indices.contains(selection))
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
        .statusOutline(.accepted, cornerRadius: Theme.Radius.lg)
        // 1 to 9 pick an option while the card has focus.
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), options.indices.contains(n - 1) else { return .ignored }
            selection = n - 1
            return .handled
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Composer

/// A job the agents can do, typed after "/".
struct SlashCommand: Identifiable, Hashable {
    let name: String
    /// One line on what it does: "Find 3 clips for 9:16".
    let meaning: String
    var id: String { name }

    /// The jobs from the spec; screens can add their own.
    static let standard: [SlashCommand] = [
        SlashCommand(name: "edit", meaning: "Cut fillers and long pauses"),
        SlashCommand(name: "shorter", meaning: "Trim to a length you pick"),
        SlashCommand(name: "clips", meaning: "Find clips that stand on their own"),
        SlashCommand(name: "captions", meaning: "Add captions in your brand style"),
        SlashCommand(name: "music", meaning: "Add a music bed, quieter under speech"),
        SlashCommand(name: "thumbnail", meaning: "Make thumbnail options"),
        SlashCommand(name: "post", meaning: "Write posts and share, after you approve"),
        SlashCommand(name: "style", meaning: "Copy a video's style"),
    ]

    static func matching(_ query: String, in commands: [SlashCommand] = standard) -> [SlashCommand] {
        let q = query.lowercased()
        return q.isEmpty ? commands : commands.filter { $0.name.hasPrefix(q) || $0.meaning.lowercased().contains(q) }
    }
}

/// The popup above the composer while you type "/": command and meaning,
/// arrows move, Return picks, Esc closes.
struct SlashMenu: View {
    let commands: [SlashCommand]
    let selection: Int
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No command matches").textStyle(.caption).foregroundStyle(Theme.textMuted).padding(10)
            }
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                Button {
                    onPick(command)
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Mono("/\(command.name)").foregroundStyle(Theme.text).frame(minWidth: 84, alignment: .leading)
                        Text(command.meaning).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: Theme.Size.control)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(index == selection ? Theme.canvas : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("/\(command.name): \(command.meaning)")
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(maxWidth: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .floatShadow()
    }
}

/// How agents act on an ask: straight away, or with a plan you approve.
enum AskMode: String, CaseIterable {
    case justDoIt, planFirst

    var title: String { self == .justDoIt ? "Just do it" : "Plan first" }
}

/// One box to ask the agents for anything. Rounded 14, a mode pill, "@"
/// for a take, "/" for the slash menu, Return sends, and the record
/// button beside Send. Chips (attached takes, the AI in use) sit above
/// the text.
///
///     Composer(text: $ask, mode: $mode, onSend: send) { RecordButton(size: .extraSmall) { record() } }
struct Composer<Trailing: View>: View {
    @Binding var text: String
    @Binding var mode: AskMode
    var placeholder = "Ask for anything, / for jobs, @ for a take"
    var chips: [String] = []
    var commands: [SlashCommand] = SlashCommand.standard
    let onSend: () -> Void
    var onMention: (() -> Void)?
    /// ↑ in an empty composer, to edit a QueuedInput.
    var onEditQueued: (() -> Void)?
    let trailing: Trailing
    @FocusState private var focused: Bool
    @State private var slashIndex = 0

    init(text: Binding<String>, mode: Binding<AskMode>,
         placeholder: String = "Ask for anything, / for jobs, @ for a take",
         chips: [String] = [], commands: [SlashCommand] = SlashCommand.standard,
         onSend: @escaping () -> Void, onMention: (() -> Void)? = nil, onEditQueued: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self._text = text
        self._mode = mode
        self.placeholder = placeholder
        self.chips = chips
        self.commands = commands
        self.onSend = onSend
        self.onMention = onMention
        self.onEditQueued = onEditQueued
        self.trailing = trailing()
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "/cl" shows the menu filtered to "cl"; a space closes it.
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains(" ") else { return nil }
        return String(text.dropFirst())
    }

    private var matches: [SlashCommand] {
        slashQuery.map { SlashCommand.matching($0, in: commands) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !chips.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(chips, id: \.self) { Tag($0) }
                }
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .textStyle(.body)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: text) { _, new in
                    slashIndex = 0
                    if new.hasSuffix("@"), let onMention { onMention() }
                }
                .onKeyPress(.downArrow) { moveSlash(1) }
                .onKeyPress(.upArrow) {
                    if text.isEmpty, let onEditQueued {
                        onEditQueued()
                        return .handled
                    }
                    return moveSlash(-1)
                }
                .onKeyPress(.escape) {
                    guard slashQuery != nil else { return .ignored }
                    text = ""
                    return .handled
                }
                .accessibilityLabel("Ask the agents")
            HStack(spacing: Theme.Space.sm) {
                Menu {
                    ForEach(AskMode.allCases, id: \.self) { m in
                        Button(m.title) { mode = m }
                    }
                } label: {
                    Text(mode.title).textStyle(.caption).fontWeight(.medium)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .foregroundStyle(Theme.textMuted)
                .help("Just do it acts straight away. Plan first shows a plan to approve.")
                if let onMention {
                    Button("@", action: onMention)
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                        .help("Point at a take, clip or moment")
                }
                Spacer(minLength: 0)
                trailing
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.composer).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.composer)
            .strokeBorder(focused ? Theme.selection : Theme.lineStrong,
                          lineWidth: focused ? Theme.Stroke.focus : Theme.Stroke.hairline))
        .overlay(alignment: .topLeading) {
            if slashQuery != nil {
                SlashMenu(commands: matches, selection: slashIndex) { pick($0) }
                    .alignmentGuide(.top) { $0[.bottom] + Theme.Space.xs }
                    .transition(.opacity)
            }
        }
    }

    private func moveSlash(_ by: Int) -> KeyPress.Result {
        guard slashQuery != nil, !matches.isEmpty else { return .ignored }
        slashIndex = (slashIndex + by + matches.count) % matches.count
        return .handled
    }

    private func pick(_ command: SlashCommand) {
        text = "/\(command.name) "
        focused = true
    }

    private func submit() {
        if slashQuery != nil, matches.indices.contains(slashIndex) {
            pick(matches[slashIndex])
            return
        }
        if canSend { onSend() }
    }
}

// MARK: Panels

/// The right-hand component panel's tabs.
enum PanelTab: String, CaseIterable, Identifiable {
    case video, changes, clips, sound, post

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The component panel: ptabs along the top (Video · Changes · Clips ·
/// Sound · Post), ⤢ for full mode and a button to hide it. Put it beside
/// the thread with a ResizableDivider so it drags; Settings › Appearance
/// › Panel side says which side.
///
///     PanelHost(selection: $tab, isFull: $full, onHide: { shown = false }) { tab in … }
struct PanelHost<Content: View>: View {
    var tabs: [PanelTab] = PanelTab.allCases
    @Binding var selection: PanelTab
    @Binding var isFull: Bool
    var onHide: (() -> Void)?
    let content: (PanelTab) -> Content

    init(tabs: [PanelTab] = PanelTab.allCases, selection: Binding<PanelTab>, isFull: Binding<Bool>,
         onHide: (() -> Void)? = nil, @ViewBuilder content: @escaping (PanelTab) -> Content) {
        self.tabs = tabs
        self._selection = selection
        self._isFull = isFull
        self.onHide = onHide
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                SegmentedTabs(selection: $selection, options: tabs) { $0.title }
                Spacer(minLength: Theme.Space.xs)
                IconButton(isFull ? "Leave full mode" : "Full mode",
                           systemImage: isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    withAnimation(Theme.Motion.reduced ? nil : Theme.Motion.move) { isFull.toggle() }
                }
                if let onHide {
                    IconButton("Hide panel", systemImage: "sidebar.right", action: onHide)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: Theme.Size.toolbar)
            Rectangle().fill(Theme.line).frame(height: 1)
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.paper)
    }
}

/// The harness modes, switched in the title bar.
enum HarnessMode: String, CaseIterable, Identifiable {
    case tasks, editor, sound

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Tasks / Editor / Sound in the title bar. ⌘1 to ⌘3 follow ShortcutMap.
struct TitleModeSwitch: View {
    @Binding var selection: HarnessMode

    var body: some View {
        SegmentedTabs(selection: $selection, options: HarnessMode.allCases) { $0.title }
            .accessibilityLabel("Mode")
    }
}
