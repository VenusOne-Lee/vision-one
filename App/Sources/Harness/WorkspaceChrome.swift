import AppKit
import SwiftUI
import VisionOneKit

/// The Vision One ring: an ink circle, thick enough to read at 20pt.
struct RingLogo: View {
    var size: CGFloat = 22
    var color: Color = Theme.text

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: max(2, size * 0.16))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Room for the traffic lights when the content runs under a hidden title bar.
enum WindowChrome {
    static let titleBarHeight: CGFloat = 28
    static let trafficLightsWidth: CGFloat = 78
}

/// A page's own header: big title, a muted line under it, actions on the right.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var titleMenu: (() -> AnyView)?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom(BundledFont.sansBold, size: 22))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.sm)
            trailing()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, WindowChrome.titleBarHeight)
        .padding(.bottom, Theme.Space.md)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
                .padding(.horizontal, Theme.Space.md)
        }
    }
}

/// "Export" with the share icon: the secondary pill every page header carries.
struct ExportPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, size: .regular))
        .help("Export the video (⌘E)")
    }
}

/// Grouped equal segments in a soft track: the selected one is an ink pill.
/// Screen | Window | Area, Transcript | Changes, Clips | Thumbnail | Post…
struct SegmentBar<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    var fill = true
    var icon: (Option) -> String? = { _ in nil }
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 6) {
                        if let name = icon(option) { Image(systemName: name).font(.system(size: 13)) }
                        Text(title(option)).textStyle(.bodyStrong).lineLimit(1)
                    }
                    .foregroundStyle(isOn ? Theme.onButton : Theme.textMuted)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: Theme.Size.control + 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(isOn ? Theme.button : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
        .accessibilityElement(children: .contain)
    }
}

/// "…": everything the old top bar held that the pictures don't show.
/// Modes, panels, appearance and the task tools are all one click away.
struct WorkspaceMoreMenu: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject private var theme = ThemeStore.shared
    @Binding var showingTools: Bool
    @Binding var showingTemplate: Bool
    var setMode: (HarnessMode) -> Void

    var body: some View {
        Menu {
            if model.workspace != nil {
                Section("Open in") {
                    ForEach(HarnessMode.allCases) { mode in
                        Button(mode.title) { setMode(mode) }.disabled(model.mode == mode)
                    }
                }
            }
            if model.workspace != nil, model.mode == .tasks {
                Section("Review") {
                    ForEach([PanelKind.video, .clips, .thumbnail, .post, .sound, .captions, .formats], id: \.self) { kind in
                        Button(kind.title) { model.updateLayout { $0.show(kind) } }
                    }
                    Menu("Show below the video") {
                        ForEach([PanelKind.changes, .clips, .sound, .post, .captions, .thumbnail, .formats], id: \.self) { kind in
                            Button(kind.title) { model.updateLayout { $0.show(.video); $0.splitWith(kind) } }
                        }
                        if model.layout.split != nil {
                            Divider()
                            Button("Nothing below") { model.updateLayout { $0.toggleSplit() } }
                        }
                    }
                    Button(model.layout.isHidden ? "Show review" : "Hide review") {
                        model.updateLayout { $0.isHidden.toggle() }
                    }
                    .keyboardShortcut(ShortcutMap.togglePanel)
                }
            }
            Button("All task tools…") { showingTools = true }
            Divider()
            Button("Prepare a recording…") { model.preparingRecording = true }
            Button("Import a video…") { model.importVideo() }
            Divider()
            Button("Script Coach…") { ScriptCoachWindowController.shared.show() }
            Button("Rehearse…") { RehearseWindowController.shared.show() }
            Button("Voice tools…") { VoiceToolsWindowController.shared.show(for: model.workspace?.take) }
            Button("Autopilot…") { AutopilotWindowController.shared.show() }
            Button("Agent recording and MCP…") { SettingsWindowController.shared.show(.agents) }
            Divider()
            Button("Apply a reusable style…") { showingTemplate = true }.disabled(model.workspace == nil)
            Button("Copy a style…") { CopyStyleWindowController.shared.show() }
            Button("Languages and dubbing…") {
                if let take = model.workspace?.take { LanguagesWindowController.shared.show(for: take) }
            }
            .disabled(model.workspace == nil)
            Divider()
            Button(theme.palette.isDark ? "Use light appearance" : "Use dark appearance") {
                theme.appearance.toggleMode()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Theme.Size.controlLarge, height: Theme.Size.controlLarge)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .help("More: modes, review panels, task tools and appearance")
    }
}

/// Edit's slim sidebar: logo, New task, Library, the project, Sound, Settings.
struct IconRail: View {
    @ObservedObject var model: HarnessModel

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Color.clear.frame(height: WindowChrome.titleBarHeight)
            RingLogo(size: 24).padding(.bottom, Theme.Space.sm)
            railButton("New task", "plus.square", selected: false) {
                model.mode = .tasks
                model.page = .newTask
            }
            railButton("Library", "square.grid.2x2", selected: false) {
                model.mode = .tasks
                model.page = .library
            }
            railButton(model.currentProject?.name ?? "Project", "folder.fill", selected: model.mode == .editor) {
                model.mode = .tasks
            }
            railButton("Sound", "waveform", selected: model.mode == .sound) { model.mode = .sound }
            Spacer(minLength: 0)
            railButton("Settings", "gearshape", selected: false) { SettingsWindowController.shared.show() }
                .padding(.bottom, Theme.Space.md)
        }
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: Theme.Stroke.hairline) }
    }

    private func railButton(_ title: String, _ image: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(selected ? Theme.onButton : Theme.text)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(selected ? Theme.button : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Editor and Sound share this header: title, saved line, Task | Edit | Sound
/// in the middle, then undo/redo, Export and "…".
struct ModeHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @Binding var mode: HarnessMode
    var leadingInset: CGFloat = 0
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack(spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.custom(BundledFont.sansBold, size: 19)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(subtitle).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                .frame(maxWidth: 300, alignment: .leading)
                Spacer(minLength: 280)
                trailing()
            }
            SegmentBar(selection: $mode, options: HarnessMode.allCases, fill: false) { $0.title }
                .fixedSize()
        }
        .padding(.leading, Theme.Space.lg + leadingInset)
        .padding(.trailing, Theme.Space.md)
        .padding(.top, 6)
        .frame(height: WindowChrome.titleBarHeight + 34)
    }
}
