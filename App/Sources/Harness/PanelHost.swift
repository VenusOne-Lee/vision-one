import AppKit
import SwiftUI
import VisionOneKit

/// The right-hand panel: tabs of components (drag to reorder, × to
/// close, + to add), ◫ to split two of them top and bottom, ⤢ to fill the
/// window with one, and a button to hide the panel. Saved per task.
struct PanelHost: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject var workspace: TaskWorkspace
    let expand: (PanelKind) -> Void

    var body: some View {
        let layout = model.layout
        VStack(spacing: 0) {
            if let selected = layout.selected {
                if let split = layout.split {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            panel(selected)
                                .frame(height: proxy.size.height * layout.splitFraction)
                            DragDivider(axis: .horizontal, value: splitBinding(height: proxy.size.height),
                                        range: 0...Double(proxy.size.height))
                            splitHeader(split)
                            PanelContent(kind: split, workspace: workspace, model: model)
                                .frame(maxHeight: .infinity)
                        }
                    }
                } else {
                    panel(selected)
                        .frame(maxHeight: .infinity)
                }
            } else {
                panel(.video)
            }
        }
        .background(Theme.paper)
    }

    /// The video with Transcript | Changes by default; Clips | Thumbnail |
    /// Post as delivery; anything else (sound, captions, formats) with a
    /// title and a way back to the video.
    @ViewBuilder
    private func panel(_ kind: PanelKind) -> some View {
        switch kind {
        case .video, .changes:
            EditorPanel(model: workspace.editor, onExpand: { model.mode = .editor })
                .onAppear {
                    if kind == .changes {
                        UserDefaults.standard.set(EditorAside.changes.rawValue, forKey: "editorPanel.pane")
                    }
                }
        case .clips, .thumbnail, .post:
            VStack(spacing: 0) {
                SegmentBar(selection: Binding(get: { kind }, set: { next in model.updateLayout { $0.show(next) } }),
                           options: [PanelKind.clips, .thumbnail, .post]) { $0.title }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
                PanelContent(kind: kind, workspace: workspace, model: model)
            }
        default:
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.sm) {
                    Label(kind.title, systemImage: kind.symbol).textStyle(.headline)
                    Spacer()
                    Button("Back to video") { model.updateLayout { $0.show(.video) } }
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: Theme.Size.toolbar)
                Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
                PanelContent(kind: kind, workspace: workspace, model: model)
            }
        }
    }

    private func splitBinding(height: CGFloat) -> Binding<Double> {
        Binding(get: { model.layout.splitFraction * Double(height) },
                set: { value in model.updateLayout { $0.setSplitFraction(value / max(Double(height), 1)) } })
    }

    private func splitHeader(_ kind: PanelKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text(kind.title).textStyle(.label).foregroundStyle(Theme.textMuted)
            Spacer()
            IconButton("Close \(kind.title)", systemImage: "xmark") {
                model.updateLayout { $0.toggleSplit() }
            }
        }
        .padding(.horizontal, Theme.Space.md - 4)
        .frame(height: 30)
    }

    private func badge(for kind: PanelKind) -> Int {
        switch kind {
        case .changes: return workspace.editor.proposedChangeCount
        case .clips: return workspace.clips.proposedCount
        default: return 0
        }
    }
}

/// One tab: name, a count when something waits, × on hover.
private struct PanelTab: View {
    let kind: PanelKind
    let isOn: Bool
    let isSplit: Bool
    let badge: Int
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                Text(kind.title)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 10, design: .monospaced).monospacedDigit()).opacity(0.75)
                }
                if hovering {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .onTapGesture(perform: close)
                        .accessibilityLabel("Close \(kind.title)")
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(TabPillStyle(isOn: isOn || isSplit))
        .onHover { hovering = $0 }
        .help(kind.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A component in the panel, built from the open task's models.
struct PanelContent: View {
    let kind: PanelKind
    @ObservedObject var workspace: TaskWorkspace
    @ObservedObject var model: HarnessModel

    var body: some View {
        Group {
            switch kind {
            case .video:
                EditorPanel(model: workspace.editor, onExpand: { model.mode = .editor })
            case .changes:
                ChangesPanel(model: workspace.editor, effects: workspace.editor.effects)
            case .clips:
                DeliveryPanel(workspace: workspace, model: model)
                    .id(workspace.take.folder)
            case .sound:
                SoundPanelContent(model: workspace.editor)
            case .post:
                PostPanel(take: workspace.take)
            case .captions:
                CaptionsPanel(take: workspace.take)
            case .thumbnail:
                ThumbnailPane(model: workspace.thumbnail)
                    .task { await workspace.thumbnail.loadIfNeeded() }
            case .formats:
                FormatsPanel(editor: workspace.editor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }
}

/// The Sound panel: with no music and no effects yet, a short note and
/// the two ways to add some; otherwise the full controls.
struct SoundPanelContent: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            if model.sound.music == nil && model.sound.effects.isEmpty {
                empty
            } else {
                SoundPanel(model: model).padding(Theme.Space.md - 2)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: Theme.Space.xs) {
                Text("No music or effects yet")
                    .textStyle(.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Add a music bed under your voice, or a sound effect at the playhead.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                Menu {
                    ForEach(SoundLibrary.music) { sound in
                        Button("\(sound.title) · \(sound.summary)") { model.setMusic(.library(sound)) }
                    }
                    Divider()
                    Button("Choose a file…") { model.chooseMusicFile() }
                } label: {
                    Text("Add music")
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(kind: .primary))
                .fixedSize()
                Menu {
                    ForEach(SoundLibrary.effects) { sound in
                        Button("\(sound.title) · \(sound.summary)") { model.addEffect(sound.id) }
                    }
                } label: {
                    Text("Add effect")
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .fixedSize()
                .help("Adds a sound effect at the playhead")
            }
            if let problem = model.soundProblem {
                Text(problem)
                    .textStyle(.caption)
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.lg)
    }
}

/// Caption style, size and files for the take, saved to captions.json.
struct CaptionsPanel: View {
    let take: Take
    @State private var settings = CaptionSettings()
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            if let problem { Text(problem).textStyle(.caption).foregroundStyle(Theme.error).padding(Theme.Space.md) }
            CaptionControls(settings: $settings)
                .padding(Theme.Space.md)
        }
        .task(id: take.name) {
            settings = take.loadCaptionSettings()
            loaded = true
        }
        .onChange(of: settings) { _, value in
            guard loaded else { return }
            do {
                try take.saveCaptionSettings(value)
                problem = nil
                NotificationCenter.default.post(name: .takeStyleChanged, object: take.folder)
            } catch { problem = "Couldn't save captions: \(error.localizedDescription)" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .takeStyleChanged)) { note in
            if note.object as? URL == take.folder { settings = take.loadCaptionSettings() }
        }
    }
}

/// Every export format for the take, with the export sheet one press away.
struct FormatsPanel: View {
    @ObservedObject var editor: EditorModel
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(ExportPreset.allCases, id: \.self) { preset in
                    let exists = FileManager.default.fileExists(atPath: editor.take.exportURL(for: preset).path)
                    ListRow(preset.title, subtitle: exists ? "Exported" : "Not exported yet",
                            systemImage: exists ? "checkmark.circle.fill" : "circle.dashed") {
                        if exists {
                            Button("Show") {
                                NSWorkspace.shared.activateFileViewerSelecting([editor.take.exportURL(for: preset)])
                            }
                            .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                        }
                    }
                }
                Button("Export…") { showExport = true }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(editor.phase != .ready)
                    .padding(.top, Theme.Space.sm)
            }
            .padding(Theme.Space.md)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(take: editor.take, keep: editor.edits.keptSpans.map { $0.start..<$0.end }) {
                showExport = false
            }
        }
    }
}
