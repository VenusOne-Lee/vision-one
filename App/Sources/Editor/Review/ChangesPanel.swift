import SwiftUI
import VisionOneKit

/// The "Changes" tab: one row per group of AI suggestions, each with a
/// switch. Dashed while proposed, solid ink once accepted, a muted line
/// when switched off. "Accept all" turns every dashed row solid.
struct ChangesPanel: View {
    @ObservedObject var model: EditorModel
    /// Observed too, so zoom and blur rows follow their own changes.
    @ObservedObject var effects: EffectsModel

    var body: some View {
        let groups = model.changeGroups
        VStack(spacing: 0) {
            if groups.isEmpty {
                EditorNotice(title: "No suggestions yet.",
                             message: "They appear here once the transcript is written.",
                             isError: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(groups) { group in
                            ChangeRow(group: group) { on in model.setChange(group.kind, on: on) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                Divider().overlay(Theme.line)
                footer
            }
        }
        .background(Theme.paper)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Dashed until you accept")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            Button("Accept all") { model.acceptAllChanges() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(model.proposedChangeCount == 0)
                .help("Accept every dashed suggestion. ⌘Z undoes it.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One group of suggestions with its switch.
private struct ChangeRow: View {
    let group: ChangeGroup
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !group.detail.isEmpty {
                    Text(group.detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            Toggle(group.title, isOn: Binding(get: { group.state != .off }, set: set))
                .toggleStyle(InkSwitchStyle(label: "Keep: \(group.title)"))
        }
        .foregroundStyle(group.state == .off ? Theme.textMuted : Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(group.state == .off ? Theme.line : Theme.text,
                              style: StrokeStyle(lineWidth: 1.5, dash: group.state == .proposed ? [4, 3] : []))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .contextMenu {
            if group.state != .accepted { Button("Accept") { set(true) } }
            if group.state != .off { Button("Turn off") { set(false) } }
        }
        .help(help)
    }

    private var help: String {
        switch group.state {
        case .proposed: return "Suggested. Right-click to accept just this row, or switch it off."
        case .accepted: return "Accepted. Switch it off to bring these back."
        case .off: return "Off. Switch it on to accept these."
        }
    }
}

/// The design's switch: an ink-bordered pill, filled ink when on with a
/// white knob, white when off with an ink knob. No accent colour.
struct InkSwitchStyle: ToggleStyle {
    let label: String

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.text : Theme.paper)
                Capsule().strokeBorder(Theme.text, lineWidth: 1.5)
                Circle()
                    .fill(configuration.isOn ? Theme.paper : Theme.text)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 4)
            }
            .frame(width: 40, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
