import AppKit
import SwiftUI
import VisionOneKit

/// One project's settings: its name, the house notes every agent reads,
/// the prompt preset, and where /script looks for what's new (GitHub
/// releases, Linear teams). Opened from the project's row in the sidebar.
/// Keys stay in AI settings; this only links there when one is missing.
struct ProjectSettingsSheet: View {
    let project: DeskProject
    let close: () -> Void

    @State private var draft: DeskProject
    @State private var newKind: ScriptSourceRef.Kind = .github
    @State private var newSource = ""
    @State private var sourceProblem: String?
    @ObservedObject private var ai = AIServices.shared
    private let presets = PresetLibrary.standard.all()

    init(project: DeskProject, close: @escaping () -> Void) {
        self.project = project
        self.close = close
        _draft = State(initialValue: project)
    }

    var body: some View {
        SheetScaffold("Project settings",
                      subtitle: "Every agent working in this project reads these.",
                      primary: "Save",
                      primaryDisabled: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      onPrimary: save, onCancel: close, content: {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    nameField
                    notesField
                    presetField
                    mediaDefaultsField
                    sourcesField
                }
                .padding(.bottom, Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        })
        .frame(width: 520, height: 620)
        .foregroundStyle(Theme.text)
        .themed()
    }

    // MARK: Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            sectionLabel("NAME")
            TextField("Project name", text: $draft.name)
                .textFieldStyle(.ink)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            sectionLabel("HOUSE STYLE")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.notes)
                    .textStyle(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if draft.notes.isEmpty {
                    Text("Who it's for, words to use or avoid. For example: South African drivers; say rand, not dollars; no hype words.")
                        .textStyle(.body)
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 110, maxHeight: 180)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.lineStrong, lineWidth: Theme.Stroke.hairline))
            .accessibilityLabel("House style")
            Text("Added to every brief in this project, like a repo's AGENTS.md.")
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var presetField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            sectionLabel("PROMPT PRESET")
            Picker("Prompt preset", selection: presetSelection) {
                Text(appDefaultTitle).tag("")
                ForEach(presetNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var mediaDefaultsField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("NEW VIDEO DEFAULTS")
            TemplatePicker(selection: Binding(
                get: { draft.mediaDefaults?.templateID ?? "" },
                set: { id in
                    var defaults = draft.mediaDefaults ?? ProjectMediaDefaults()
                    defaults.templateID = id.isEmpty ? nil : id
                    draft.mediaDefaults = defaults
                }))
            Toggle("Captions on new videos", isOn: Binding(
                get: { draft.mediaDefaults?.captions ?? true },
                set: { on in
                    var defaults = draft.mediaDefaults ?? ProjectMediaDefaults()
                    defaults.captions = on
                    draft.mediaDefaults = defaults
                })).toggleStyle(.ink)
            Text("Applies when a recording or import first joins this project. Existing videos keep their edits and overrides.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
        }
    }

    private var sourcesField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("WHERE /SCRIPT LOOKS FOR WHAT'S NEW")
            if draft.sources.isEmpty {
                Text("No sources yet. Add a GitHub repo for its releases or a Linear team for its finished issues.")
                    .textStyle(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(draft.sources, id: \.rowID) { ref in
                        sourceRow(ref)
                        if ref.rowID != draft.sources.last?.rowID {
                            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
                        }
                    }
                }
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
            }

            HStack(spacing: Theme.Space.sm) {
                SegmentedTabs(selection: $newKind, options: [.github, .linear]) { $0.label }
                TextField(newKind == .github ? "owner/repo" : "Team key, like ENG", text: $newSource)
                    .textFieldStyle(.ink)
                    .onSubmit { addSource() }
                Button("Add") { addSource() }
                    .buttonStyle(.secondary)
                    .disabled(newSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: newKind) { sourceProblem = nil }
            if let sourceProblem {
                Text(sourceProblem)
                    .textStyle(.caption)
                    .foregroundStyle(Theme.error)
            }
            keyHint
        }
    }

    @ViewBuilder
    private func sourceRow(_ ref: ScriptSourceRef) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: ref.kind == .github ? "chevron.left.forwardslash.chevron.right" : "checklist")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(ref.title)
                .textStyle(.body)
                .foregroundStyle(ref.enabled ? Theme.text : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.sm)
            Toggle("", isOn: enabledBinding(ref))
                .toggleStyle(InkSwitchStyle(label: "Read \(ref.title)"))
            IconButton("Remove \(ref.title)", systemImage: "xmark") {
                draft.sources.removeAll { $0.rowID == ref.rowID }
            }
        }
        .padding(.leading, Theme.Space.sm + 4)
        .padding(.trailing, Theme.Space.xs)
        .frame(minHeight: 40)
    }

    /// One line, only when a key /script needs is missing. Keys are
    /// typed in AI settings, never here.
    @ViewBuilder
    private var keyHint: some View {
        let usesLinear = draft.sources.contains { $0.kind == .linear } || newKind == .linear
        let usesGitHub = draft.sources.contains { $0.kind == .github } || newKind == .github
        if usesLinear, ai.key(ScriptSources.linearKeyName).isEmpty {
            keyLink("Linear needs an API key to read finished issues.")
        } else if usesGitHub, ai.key(ScriptSources.githubTokenName).isEmpty {
            keyLink("Public repos work as is. A private repo needs a GitHub token.")
        }
    }

    private func keyLink(_ text: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text(text)
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
            Button("AI settings…") { SettingsWindowController.shared.show(.ai) }
                .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .textStyle(.label)
            .foregroundStyle(Theme.textMuted)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Presets

    private var presetNames: [String] {
        var names = presets.map(\.name)
        // Keep a preset the project names even if its file is gone.
        if let current = draft.presetName, !current.isEmpty, !names.contains(current) { names.append(current) }
        return names
    }

    private var appDefaultTitle: String {
        let name = UserDefaults.standard.string(forKey: "ai.preset") ?? ""
        return name.isEmpty ? "App default" : "App default (\(name))"
    }

    private var presetSelection: Binding<String> {
        Binding(get: { draft.presetName ?? "" },
                set: { draft.presetName = $0.isEmpty ? nil : $0 })
    }

    // MARK: Sources

    private func enabledBinding(_ ref: ScriptSourceRef) -> Binding<Bool> {
        Binding(get: { draft.sources.first { $0.rowID == ref.rowID }?.enabled ?? false },
                set: { on in
                    if let i = draft.sources.firstIndex(where: { $0.rowID == ref.rowID }) { draft.sources[i].enabled = on }
                })
    }

    /// Adds what's typed. Returns false when it can't be a source.
    @discardableResult
    private func addSource() -> Bool {
        let typed = newSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return true }
        guard let ref = DeskProject.sourceRef(newKind, from: typed) else {
            sourceProblem = newKind == .github
                ? "Type the repo as owner/name, like rankride/app, or paste its GitHub link."
                : "Type the team key, like ENG, or paste a Linear team link."
            return false
        }
        if !draft.sources.contains(where: { $0.rowID == ref.rowID }) { draft.sources.append(ref) }
        newSource = ""
        sourceProblem = nil
        return true
    }

    // MARK: Saving

    private func save() {
        // Something typed but not added yet counts, so Save never drops it.
        guard addSource() else { return }
        let settings = draft
        let id = project.id
        let desk = AIServices.shared.desk
        Task { await desk.updateProject(id) { $0.applySettings(settings) } }
        close()
    }
}

private extension ScriptSourceRef {
    /// One row per source: GitHub repos and Linear keys match case-insensitively.
    var rowID: String { "\(kind.rawValue):\(id.lowercased())" }
}

private extension ScriptSourceRef.Kind {
    var label: String { self == .github ? "GitHub" : "Linear" }
}
