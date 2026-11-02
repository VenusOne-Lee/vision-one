import AppKit
import Combine
import SwiftUI
import VisionOneKit

/// The look in use, readable from any thread (drawing code, NSViews).
/// Only ThemeStore writes it, on the main thread.
enum ThemeState {
    nonisolated(unsafe) static var appearance: Appearance = .standard
    nonisolated(unsafe) static var palette: ThemePalette = .resolve(.standard)
}

/// Holds the person's Appearance choices, saves them to theme.json and
/// repaints every window when they change. Also follows the macOS
/// Increase Contrast setting, on top of whichever look is picked.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// Posted after a change, for AppKit views that cache colours
    /// (attributed transcript text, layers).
    static let didChange = Notification.Name("VisionOneThemeDidChange")

    @Published var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            if undoing { undoing = false } else { history = Array((history + [oldValue]).suffix(20)) }
            apply()
            if !transient { try? AppearanceFile.save(appearance) }
        }
    }

    /// Earlier looks, newest last, so Undo is one click.
    @Published private(set) var history: [Appearance] = []
    private var undoing = false
    private var transient = false

    /// CI renders both appearances without writing the person's theme file.
    func renderAppearance(_ value: Appearance) {
        transient = true
        appearance = value
        transient = false
    }

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        undoing = true
        appearance = last
        undoing = false
    }

    /// Bumps on every change; `.themed()` rebuilds views from it.
    @Published private(set) var revision = 0
    private(set) var palette: ThemePalette
    private var observers: [NSObjectProtocol] = []

    private init() {
        let saved = AppearanceFile.load()
        appearance = saved
        palette = ThemePalette.resolve(saved, increaseContrast: Self.systemIncreaseContrast)
        ThemeState.appearance = saved
        ThemeState.palette = palette
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.apply() }
        })
    }

    /// Call once at launch, so windows and menus pick up a dark look.
    func start() {
        NSApp.appearance = nsAppearance
    }

    var nsAppearance: NSAppearance? {
        NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
    }

    var colorScheme: ColorScheme { palette.isDark ? .dark : .light }

    func apply(_ preset: ThemePreset) {
        appearance.apply(preset)
    }

    /// Back to Paper, keeping nothing.
    func reset() {
        appearance = .standard
    }

    /// Loads a shared theme file. Returns false if it isn't one.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let loaded = try? AppearanceFile.decode(data) else { return false }
        appearance = loaded
        return true
    }

    func export(to url: URL) throws {
        try AppearanceFile.encode(appearance).write(to: url, options: .atomic)
    }

    private func apply() {
        palette = ThemePalette.resolve(appearance, increaseContrast: Self.systemIncreaseContrast)
        ThemeState.appearance = appearance
        ThemeState.palette = palette
        NSApp.appearance = nsAppearance
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static var systemIncreaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

@MainActor
private struct ThemedModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            // Theme's colours are plain reads, so a new look rebuilds the
            // tree. Models live outside views, so nothing real is lost.
            .id(store.revision)
            .environment(\.colorScheme, store.colorScheme)
            .tint(Theme.selection)
            .transaction { WorkspaceMotion.constrain(&$0, reduced: reduceMotion) }
    }
}

extension View {
    /// Follows Settings → Appearance. Put it once on each window's root
    /// view (and the menu bar panel), where `.environment(\.colorScheme,
    /// .light)` used to be.
    func themed() -> some View {
        modifier(ThemedModifier())
    }
}
