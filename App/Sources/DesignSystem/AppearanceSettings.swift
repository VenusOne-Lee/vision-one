import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionOneKit

/// Settings › Appearance, the ThemePicker. Pick a preset look, or start
/// from one and change the details. Every change repaints the app at
/// once and Undo is one click. What carries meaning never changes:
/// orange means recording, red means an error, dashed means proposed.
struct AppearanceSettingsView: View {
    @ObservedObject var store: ThemeStore
    @AppStorage(TextSize.storageKey) private var textSize: TextSize = .medium

    private var appearance: Binding<Appearance> { $store.appearance }

    var body: some View {
        HSplitView {
            ScrollView {
                form.padding(Theme.Space.lg)
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: 520)
            .background(Theme.paper)

            AppearancePreview()
                .padding(Theme.Space.lg)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .foregroundStyle(Theme.text)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Appearance").textStyle(.title).accessibilityAddTraits(.isHeader)
                    Text(store.appearance.preset.map { "\($0.title) look" } ?? "Your own look")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Undo") { store.undo() }
                    .buttonStyle(.quiet)
                    .disabled(!store.canUndo)
                    .help("Go back to the look before this change")
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Preset looks").textStyle(.label).foregroundStyle(Theme.textMuted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: Theme.Space.sm)],
                          spacing: Theme.Space.sm) {
                    ForEach(ThemePreset.allCases) { preset in
                        PresetCard(preset: preset, base: store.appearance,
                                   isOn: store.appearance.preset == preset) {
                            store.apply(preset)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Accent · your ring").textStyle(.label).foregroundStyle(Theme.textMuted)
                AccentRingPicker(selection: appearance.accent)
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                row("Buttons") {
                    SegmentedTabs(selection: appearance.buttons, options: Appearance.Buttons.allCases) {
                        $0 == .ink ? "Ink" : "Ring colour"
                    }
                }
                if store.appearance.buttons == .accent,
                   let why = ThemePalette.buttonRefusal(for: store.appearance.accent) {
                    Text(why).textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                if store.appearance.mode == .light, store.appearance.contrast == .standard {
                    row("Paper") {
                        SegmentedTabs(selection: appearance.tone, options: Appearance.Tone.allCases) {
                            $0.rawValue.capitalized
                        }
                    }
                }
                row("Corners") {
                    SegmentedTabs(selection: appearance.corners, options: Appearance.Corners.allCases) {
                        $0.rawValue.capitalized
                    }
                }
                row("Density") {
                    SegmentedTabs(selection: appearance.density, options: Appearance.Density.allCases) {
                        $0.rawValue.capitalized
                    }
                }
                row("Transcript font") {
                    SegmentedTabs(selection: appearance.transcriptFont, options: Appearance.TranscriptFont.allCases,
                                  title: Self.fontTitle)
                }
                row("Text size") {
                    SegmentedTabs(selection: $textSize, options: TextSize.allCases) { $0.title }
                }
                row("Panel side") {
                    SegmentedTabs(selection: appearance.panelSide, options: Appearance.PanelSide.allCases) {
                        $0.rawValue.capitalized
                    }
                }
            }

            Notice(.info, lead: "Never changes",
                   detail: "Orange means recording. Red means an error. Dashed means proposed, solid means kept.")

            HStack(spacing: Theme.Space.sm) {
                Button("Share theme…", action: exportTheme).buttonStyle(.secondary)
                Button("Open theme…", action: openTheme).buttonStyle(.quiet)
                Spacer()
                Button("Reset to Paper") { store.reset() }
                    .buttonStyle(.quiet)
                    .disabled(store.appearance == .standard)
            }
        }
    }

    private static func fontTitle(_ font: Appearance.TranscriptFont) -> String {
        switch font {
        case .serif: "Serif"
        case .sans: "Sans"
        case .easyRead: "Easy read"
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(title).textStyle(.body)
            Spacer(minLength: Theme.Space.sm)
            control()
        }
        .frame(minHeight: Theme.Size.control)
    }

    // MARK: Theme files

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Vision One theme.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.export(to: url)
    }

    private func openTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.open(url)
    }
}

// MARK: Preset card

/// A small drawing of the app in that look: sidebar, thread, panel and
/// the primary button. Drawn from the preset's own palette, so every card
/// shows its look whatever look is on now.
private struct PresetCard: View {
    let preset: ThemePreset
    let base: Appearance
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let p = ThemePalette.resolve(base.applying(preset))
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.paper)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Color(hex: p.text).opacity(0.8)).frame(width: 34, height: 4)
                        Capsule().fill(Color(hex: p.text).opacity(0.4)).frame(width: 24, height: 4)
                        Spacer(minLength: 0)
                        Capsule().fill(Color(hex: p.button)).frame(width: 22, height: 8)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: p.paper)).frame(width: 30)
                }
                .padding(4)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: p.canvas)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: p.line)))
                Text(preset.title).textStyle(.bodyStrong).foregroundStyle(Theme.text)
                Text(preset.blurb).textStyle(.caption).foregroundStyle(Theme.textMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isOn ? Theme.text : Theme.line, lineWidth: isOn ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .accessibilityLabel("\(preset.title) look. \(preset.blurb)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Ring picker

/// The six ring colours, plus any colour from the system picker.
struct AccentRingPicker: View {
    @Binding var selection: UInt32

    struct Ring: Identifiable {
        let hex: UInt32
        let name: String
        var id: UInt32 { hex }
    }

    static let rings: [Ring] = [
        Ring(hex: DesignTokens.ringBlue, name: "Blue"), Ring(hex: DesignTokens.ringRed, name: "Red"),
        Ring(hex: DesignTokens.ringGold, name: "Gold"), Ring(hex: DesignTokens.accentPurple, name: "Purple"),
        Ring(hex: DesignTokens.accentPink, name: "Pink"), Ring(hex: DesignTokens.ringBlack, name: "Black"),
    ]

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Self.rings) { ring in
                Button {
                    selection = ring.hex
                } label: {
                    Circle()
                        .strokeBorder(Color(hex: ring.hex), lineWidth: 3)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selection == ring.hex ? Theme.text : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusRing(Circle())
                .accessibilityLabel("\(ring.name) ring")
                .accessibilityAddTraits(selection == ring.hex ? .isSelected : [])
            }
            ColorPicker("Any colour", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .help("Pick any ring colour")
            Mono(Appearance.hexString(selection), small: true).foregroundStyle(Theme.textMuted)
        }
    }

    private var custom: Binding<Color> {
        Binding {
            Color(hex: selection)
        } set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = UInt32((c.redComponent * 255).rounded()), g = UInt32((c.greenComponent * 255).rounded())
            let b = UInt32((c.blueComponent * 255).rounded())
            selection = (r << 16) | (g << 8) | b
        }
    }
}

// MARK: Preview

/// The harness in miniature, built from the real components, so what you
/// see here is what every window will look like.
private struct AppearancePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Preview").textStyle(.label).foregroundStyle(Theme.textMuted)
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    ProjectRow(name: "RankRide", taskCount: 3, isOpen: .constant(true))
                    TaskRowPreview(title: "Edit launch demo", status: "Editor · running, step 2 of 4", state: .running)
                    TaskRowPreview(title: "Post to Version One", status: "Sharer · waiting to post", state: .needsYou)
                    TaskRowPreview(title: "Make 3 clips", status: "Clipper · done", state: .done)
                }
                .frame(width: 190)
                .panelStyle(padding: Theme.Space.sm)

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ThreadCell(user: "make it 60s and cut the ums")
                    ThreadCell(.agent("Editor")) {
                        StepList(steps: [.init("Find fillers", state: .done), .init("Cut long pauses", state: .running),
                                         .init("Trim to 60 s")])
                    }
                    StatusLine(verb: "Editor is cutting", elapsed: 12)
                    HStack(spacing: Theme.Space.sm) {
                        Button("Keep all") {}.buttonStyle(.primary)
                        Button("Undo") {}.buttonStyle(.secondary)
                        StateChip(.proposed, "Suggested")
                        StateChip(.accepted, "Kept")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelStyle()
            }
            HStack(spacing: Theme.Space.sm) {
                BuilderRing(state: .draft, colour: Theme.accent, size: 18)
                BuilderRing(state: .exported, colour: Theme.accent, size: 18)
                BuilderRing(state: .recording, colour: Theme.accent, size: 18)
                Text("Recording").textStyle(.caption).foregroundStyle(Theme.textMuted)
                LiveDot()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Static rows for the preview, without a real job behind them.
private struct TaskRowPreview: View {
    let title: String
    let status: String
    let state: TaskRing.State

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            TaskRing(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).textStyle(.bodyStrong).lineLimit(1)
                Text(status).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, Theme.Space.md)
    }
}
