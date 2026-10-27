import SwiftUI

/// Pill buttons. One primary (black pill) per view: the thing most
/// people came to do. Everything else is secondary (white pill, ink
/// border) or quiet (text only). Destructive is for removing work.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    enum Size { case small, regular, large }

    let kind: Kind
    var size: Size = .regular

    init(kind: Kind, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, kind: kind, size: size)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var primary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var quiet: PillButtonStyle { PillButtonStyle(kind: .quiet) }
    static var destructive: PillButtonStyle { PillButtonStyle(kind: .destructive) }
}

private struct PillButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let size: PillButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var height: CGFloat {
        switch size {
        case .small: Theme.Size.controlSmall
        case .regular: Theme.Size.control
        case .large: Theme.Size.controlLarge
        }
    }

    private var style: TypeStyle { size == .large ? .headline : .bodyStrong }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.onButton
        case .secondary: Theme.text
        case .quiet: hovering ? Theme.text : Theme.textMuted
        case .destructive: Theme.error
        }
    }

    private var fill: Color {
        switch kind {
        // Ink, or the ring colour with Bold buttons.
        case .primary: Theme.button
        case .secondary, .destructive: hovering ? Theme.canvas : Theme.paper
        case .quiet: hovering ? Theme.canvas : .clear
        }
    }

    private var border: Color? {
        switch kind {
        case .primary, .quiet: nil
        case .secondary: Theme.text
        case .destructive: Theme.error
        }
    }

    var body: some View {
        configuration.label
            .textStyle(style)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 10 : 14)
            .frame(minHeight: height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay {
                if let border { Capsule().strokeBorder(border, lineWidth: 1) }
            }
            .contentShape(Capsule())
            .focusRing(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .onHover { hovering = isEnabled && $0 }
            .animation(.easeOut(duration: Theme.Motion.micro), value: hovering)
    }
}

/// A square icon-only button. The label is required: it's what VoiceOver
/// reads and what the tooltip says, so no icon is ever unnamed.
///
///     IconButton("Move transcript", systemImage: "arrow.left.arrow.right") { … }
struct IconButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var isOn = false
    let action: () -> Void

    init(_ title: String, systemImage: String, shortcut: String? = nil, isOn: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(IconButtonStyle(isOn: isOn))
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct IconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isOn: isOn)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? Theme.paper : Theme.text)
            .frame(width: Theme.Size.control, height: Theme.Size.control)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isOn ? Theme.text : (hovering ? Theme.canvas : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .onHover { hovering = isEnabled && $0 }
    }
}
