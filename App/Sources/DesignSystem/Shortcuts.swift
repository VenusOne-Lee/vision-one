import AppKit
import SwiftUI
import VisionOneKit

extension KeyboardShortcut {
    /// The SwiftUI shortcut for an entry in VisionOneKit's ShortcutMap.
    init(_ spec: ShortcutSpec) {
        let key: KeyEquivalent = switch spec.key {
        case .character(let c): KeyEquivalent(c)
        case .space: .space
        case .return: .return
        case .delete: .delete
        case .escape: .escape
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        }
        var modifiers: EventModifiers = []
        if spec.modifiers.contains(.command) { modifiers.insert(.command) }
        if spec.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if spec.modifiers.contains(.option) { modifiers.insert(.option) }
        if spec.modifiers.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers: modifiers)
    }
}

extension View {
    /// Binds a ShortcutMap entry. Global ones (⇧⌘R) belong to the hot key,
    /// so bind those only where no hot key is registered.
    ///
    ///     Button("Export") { … }.keyboardShortcut(ShortcutMap.export)
    func keyboardShortcut(_ spec: ShortcutSpec) -> some View {
        keyboardShortcut(KeyboardShortcut(spec))
    }

    /// A tooltip that names the shortcut: "Export (⌘E)".
    func help(_ text: String, shortcut spec: ShortcutSpec) -> some View {
        help("\(text) (\(spec.display))")
    }
}

// MARK: Keyboard Shortcuts window (⌘/)

/// Every shortcut, grouped by menu, read from ShortcutMap so it's always
/// what the app actually does.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(ShortcutMap.menus, id: \.self) { menu in
                    let specs = ShortcutMap.all.filter { $0.menu == menu }
                    if !specs.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(menu).textStyle(.label).foregroundStyle(Theme.textMuted)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(specs) { spec in
                                HStack {
                                    Text(spec.title).textStyle(.body).foregroundStyle(Theme.text)
                                    if spec.isGlobal { Tag("Any app") }
                                    Spacer(minLength: Theme.Space.md)
                                    KeyCaps(spec: spec)
                                }
                                .frame(minHeight: Theme.Size.control)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(spec.title): \(spoken(spec))")
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.lg)
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 420)
        .background(Theme.paper)
        .themed()
    }

    private func spoken(_ spec: ShortcutSpec) -> String {
        let names: [(ShortcutSpec.Modifier, String)] = [(.control, "Control"), (.option, "Option"),
                                                       (.shift, "Shift"), (.command, "Command")]
        let mods = names.filter { spec.modifiers.contains($0.0) }.map(\.1)
        let key: String = switch spec.key {
        case .character(let c): String(c).uppercased()
        case .space: "Space"
        case .return: "Return"
        case .delete: "Delete"
        case .escape: "Escape"
        case .leftArrow: "Left arrow"
        case .rightArrow: "Right arrow"
        }
        return (mods + [key]).joined(separator: " ")
    }
}

private struct KeyCaps: View {
    let spec: ShortcutSpec

    var body: some View {
        Text(spec.display)
            .textStyle(.mono)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.line))
    }
}

@MainActor
final class ShortcutsWindowController {
    static let shared = ShortcutsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Keyboard Shortcuts"
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            window.setFrameAutosaveName("VisionOneShortcuts")
            window.contentViewController = NSHostingController(rootView: ShortcutsView())
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
