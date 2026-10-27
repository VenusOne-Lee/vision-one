import SwiftUI

// MARK: Tabs

/// Tabs as ink pills. Labels never wrap: when the row runs out of room
/// it turns into one menu button showing the current tab.
///
///     SegmentedTabs(selection: $pane, options: Pane.allCases) { $0.title }
struct SegmentedTabs<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    init(selection: Binding<Option>, options: [Option], title: @escaping (Option) -> String) {
        self._selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip
            menu
        }
        .accessibilityElement(children: .contain)
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button(title(option)) { selection = option }
                    .buttonStyle(TabPillStyle(isOn: option == selection))
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var menu: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title(selection)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .textStyle(.headline)
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 12)
            .frame(height: Theme.Size.controlSmall + 2)
            .background(Capsule().fill(Theme.text))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Tab: \(title(selection))")
    }
}

/// One tab: an ink pill when selected, muted text when not.
struct TabPillStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.headline)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.controlSmall + 2)
            .foregroundStyle(isOn ? Theme.paper : Theme.textMuted)
            .background(Capsule().fill(isOn ? Theme.text : .clear))
            .contentShape(Capsule())
            .focusRing(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: Switch

/// The design's switch: ink track with a white knob when on; white track,
/// strong edge and ink knob when off. No accent colour.
/// `Toggle("Captions", isOn: $on).toggleStyle(.ink)`
struct InkSwitchStyle: ToggleStyle {
    /// With a label, the switch stands alone (its row shows the title)
    /// and VoiceOver reads this instead. Without one, the toggle's own
    /// label sits to the left of the switch.
    var label: String?

    init(label: String? = nil) {
        self.label = label
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if label == nil { configuration.label }
            InkSwitch(isOn: configuration.$isOn)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                if let label { Text(label) } else { configuration.label }
            }
        }
    }
}

extension ToggleStyle where Self == InkSwitchStyle {
    static var ink: InkSwitchStyle { InkSwitchStyle() }
}

private struct InkSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.text : Theme.paper)
                Capsule().strokeBorder(isOn ? Theme.text : Theme.lineStrong, lineWidth: Theme.Stroke.ring)
                Circle()
                    .fill(isOn ? Theme.paper : Theme.text)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 4)
            }
            .frame(width: 36, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(Capsule())
        .opacity(isEnabled ? 1 : 0.4)
        .motion(.easeInOut(duration: Theme.Motion.short), value: isOn)
    }
}

// MARK: Text field

/// Paper field, strong edge, selection blue while typing.
/// `TextField("Title", text: $title).textFieldStyle(.ink)`
struct InkTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        InkField(field: configuration)
    }
}

extension TextFieldStyle where Self == InkTextFieldStyle {
    static var ink: InkTextFieldStyle { InkTextFieldStyle() }
}

private struct InkField<Field: View>: View {
    let field: Field
    @FocusState private var focused: Bool

    var body: some View {
        field
            .textFieldStyle(.plain)
            .textStyle(.body)
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, Theme.Space.sm)
            .frame(minHeight: Theme.Size.control)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.paper))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(focused ? Theme.selection : Theme.lineStrong,
                                  lineWidth: focused ? Theme.Stroke.focus : Theme.Stroke.hairline)
            )
    }
}
