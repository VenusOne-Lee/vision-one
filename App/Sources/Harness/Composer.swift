import AppKit
import SwiftUI
import VisionOneKit

/// The box at the bottom of every task: type what you want, / for
/// commands, @ for a take, and Send; or press record. The two pills say
/// how the agents behave: "Just do it" lets them start on their own and
/// leave dashed proposals; "On this Mac" keeps the AI on this Mac.
struct Composer: View {
    @ObservedObject var model: HarnessModel
    var placeholder = "Ask for a change, or describe what to do…"
    @ObservedObject private var ai = AIServices.shared
    @ObservedObject private var recorder = ScreenRecorder.shared
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let completion {
                CompletionList(completion: completion, highlighted: highlighted) { pick($0) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    TextField(placeholder, text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.custom(BundledFont.sansRegular, size: 14))
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(submit)
                        .onKeyPress(.upArrow) { moveHighlight(-1) }
                        .onKeyPress(.downArrow) { moveHighlight(1) }
                        .onKeyPress(.tab) { acceptHighlighted() }
                        .onChange(of: model.draft) { _, _ in highlighted = 0 }
                        .accessibilityLabel("Ask Vision One")
                        .padding(.top, 6)
                    if recorder.phase.isLive { recordButton }
                    sendButton
                }
                HStack(spacing: Theme.Space.xs) {
                    WhereMenu(model: model)
                    Spacer(minLength: 0)
                }
            }
            .padding(Theme.Space.md - 2)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(focused ? Theme.lineStrong : Theme.line, lineWidth: Theme.Stroke.hairline)
            )
            .floatShadow()
        }
        .onChange(of: model.focusComposer) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    // MARK: Completion

    private var completion: ComposerCompletion? {
        guard focused else { return nil }
        return ComposerCompletion.suggest(for: model.draft, candidates: model.mentionCandidates)
    }

    private var completionCount: Int {
        switch completion {
        case let .commands(list)?: return list.count
        case let .takes(list)?: return list.count
        case nil: return 0
        }
    }

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        guard completionCount > 0 else { return .ignored }
        highlighted = min(completionCount - 1, max(0, highlighted + step))
        return .handled
    }

    private func acceptHighlighted() -> KeyPress.Result {
        guard let completion else { return .ignored }
        switch completion {
        case let .commands(list): pick("/" + list[min(highlighted, list.count - 1)].name)
        case let .takes(list): pick(list[min(highlighted, list.count - 1)].token)
        }
        return .handled
    }

    private func pick(_ replacement: String) {
        model.draft = ComposerCompletion.apply(replacement, to: model.draft)
        focused = true
    }

    private func submit() {
        // Return with the list open picks the highlighted item instead.
        if completion != nil, acceptHighlighted() == .handled { return }
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.draft = ""
        model.send(text)
    }

    // MARK: Buttons

    private var recordButton: some View {
        Button {
            if recorder.phase.isLive { Task { await recorder.toggle() } }
            else { model.preparingRecording = true }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Theme.text, lineWidth: Theme.Stroke.ring)
                if recorder.phase.isLive {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.tally).frame(width: 10, height: 10)
                } else {
                    Circle().fill(Theme.text).padding(7)
                }
            }
            .frame(width: Theme.Size.control, height: Theme.Size.control)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.phase.isBusy)
        .help(recorder.phase.isLive ? "Stop recording (⇧⌘R)"
              : recorder.choice.mode == .camera ? "Record yourself (⇧⌘R)" : "Record your screen (⇧⌘R)")
        .accessibilityLabel(recorder.phase.isLive ? "Stop recording" : "Record")
    }

    private var sendButton: some View {
        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: submit) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 32, height: 32)
                .background(empty ? Theme.textFaint : Theme.text, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .help("Send (Return)")
        .accessibilityLabel("Send")
    }
}

/// "Just do it ▾": a quiet pill in the composer.
struct ComposerPill: View {
    let title: String
    let systemImage: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 12))
            Text(title).font(.custom(BundledFont.sansMedium, size: 13))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: Theme.Size.control + 2)
        .background(hovering ? Theme.canvas : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

/// The pop-up above the composer for / commands and @ takes.
struct CompletionList: View {
    let completion: ComposerCompletion
    let highlighted: Int
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch completion {
            case let .commands(list):
                ForEach(Array(list.enumerated()), id: \.element.name) { index, command in
                    row(title: "/" + command.name, detail: command.summary, isOn: index == highlighted) { pick("/" + command.name) }
                }
            case let .takes(list):
                ForEach(Array(list.enumerated()), id: \.element.take.name) { index, candidate in
                    row(title: candidate.title, detail: candidate.token, isOn: index == highlighted) { pick(candidate.token) }
                }
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
        .floatShadow()
    }

    private func row(title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Text(title).textStyle(.bodyStrong).foregroundStyle(Theme.text)
                Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 26)
            .background(isOn ? Theme.canvas : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A menu item with a tick when it's the current choice.
struct MenuCheck: View {
    let title: String
    let isOn: Bool

    init(_ title: String, isOn: Bool) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// "On this Mac ▾": where the AI runs, how asks behave and what records.
struct WhereMenu: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject private var ai = AIServices.shared
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        Menu {
            Button {
                ai.settings.onDeviceOnly = true
            } label: {
                MenuCheck("On this Mac", isOn: ai.settings.onDeviceOnly)
            }
            Button {
                ai.settings.onDeviceOnly = false
            } label: {
                MenuCheck("Best available", isOn: !ai.settings.onDeviceOnly)
            }
            Divider()
            Section("When you ask") {
                ForEach(AskMode.allCases, id: \.self) { mode in
                    Button { model.askMode = mode } label: { MenuCheck(mode.title, isOn: model.askMode == mode) }
                }
            }
            Section("Record") {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Button { recorder.choice.mode = mode } label: {
                        MenuCheck(mode.menuTitle, isOn: recorder.choice.mode == mode)
                    }
                    .disabled(recorder.phase.isLive || recorder.phase.isBusy)
                }
                Button("Prepare a recording…") { model.preparingRecording = true }
            }
            Divider()
            Button("AI settings…") { SettingsWindowController.shared.show(.ai) }
        } label: {
            ComposerPill(title: ai.settings.onDeviceOnly ? "On this Mac" : "Best available",
                         systemImage: ai.settings.onDeviceOnly ? "laptopcomputer" : "sparkles")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the AI runs. On this Mac keeps everything private; Best available can ask before using your keys.")
    }
}
