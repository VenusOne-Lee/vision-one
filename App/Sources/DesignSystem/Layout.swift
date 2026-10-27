import SwiftUI

// MARK: Panel

extension View {
    /// A white panel on the canvas: 12 pt corners, one hairline, no
    /// shadow. Don't put a panel inside a panel.
    func panelStyle(padding: CGFloat = Theme.Space.md) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line))
    }

    /// The one shadow, for things that float (recorder bar, popovers).
    func floatShadow() -> some View {
        shadow(color: Theme.floatShadow.color, radius: Theme.floatShadow.radius, y: Theme.floatShadow.y)
    }
}

// MARK: Collapsible section

/// A labelled part of a panel that folds away. Remembers open or closed
/// per `id`, so the layout comes back the way the person left it.
///
///     CollapsibleSection("Sound", id: "editor.sound") { … }
struct CollapsibleSection<Content: View, Accessory: View>: View {
    let title: String
    var summary: String?
    @AppStorage private var isOpen: Bool
    let accessory: Accessory
    let content: Content

    init(_ title: String, id: String, summary: String? = nil, openByDefault: Bool = true,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self._isOpen = AppStorage(wrappedValue: openByDefault, "section.\(id).open")
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Button {
                    withAnimation(Theme.Motion.reduced ? nil : Theme.Motion.move) { isOpen.toggle() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text(title).textStyle(.label)
                        if !isOpen, let summary {
                            Text(summary)
                                .textStyle(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .accessibilityLabel(title)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .accessibilityHint(isOpen ? "Folds this section away" : "Shows this section")
                Spacer(minLength: 0)
                accessory
            }
            if isOpen {
                content.transition(.opacity)
            }
        }
    }
}

// MARK: Row

/// A list row: optional icon, title, optional subtitle, and whatever
/// sits on the right (a switch, a value, a button). Hover tints it;
/// selected rows take the selection tint.
struct ListRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var isSelected = false
    let trailing: Trailing
    @State private var hovering = false

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, isSelected: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            trailing
        }
        .padding(.horizontal, Theme.Space.sm + 4)
        .frame(minHeight: Theme.Size.row)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.selectionSoft : (hovering ? Theme.canvas : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Sheet

/// The frame every sheet uses: title, optional subtitle, content, and a
/// footer with Cancel (Esc) and one primary action (Return), primary on
/// the right as macOS does it.
///
///     SheetScaffold("Export", subtitle: "Every format at once",
///                   primary: "Export", onPrimary: export, onCancel: close) { … }
struct SheetScaffold<Content: View, Leading: View>: View {
    let title: String
    var subtitle: String?
    let primary: String
    var primaryDisabled = false
    var cancel = "Cancel"
    let onPrimary: () -> Void
    let onCancel: () -> Void
    let leading: Leading
    let content: Content

    init(_ title: String, subtitle: String? = nil, primary: String, primaryDisabled: Bool = false,
         cancel: String = "Cancel", onPrimary: @escaping () -> Void, onCancel: @escaping () -> Void,
         @ViewBuilder footerLeading: () -> Leading = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.primaryDisabled = primaryDisabled
        self.cancel = cancel
        self.onPrimary = onPrimary
        self.onCancel = onCancel
        self.leading = footerLeading()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).textStyle(.title).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).textStyle(.body).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], Theme.Space.lg)
            .padding(.bottom, Theme.Space.md)
            content
                .padding(.horizontal, Theme.Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(Theme.line)
            HStack(spacing: Theme.Space.sm) {
                leading
                Spacer(minLength: Theme.Space.sm)
                Button(cancel, action: onCancel)
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(primary, action: onPrimary)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryDisabled)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
        }
        .background(Theme.paper)
    }
}

// MARK: Empty state

/// Never a blank screen: say what goes here and offer the one next step.
///
///     EmptyState("No recordings yet",
///                message: "Press ⇧⌘R from anywhere to record your screen.",
///                action: ("Record", record))
struct EmptyState: View {
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    init(_ title: String, message: String, action: (title: String, run: () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Text(title)
                .textStyle(.displayLight)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .textStyle(.body)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
