import AppKit
import SwiftUI
import VisionOneKit

/// Vision One is a regular Mac app with a Dock icon and one main window
/// (the Library, and the editor once a take is open), plus a menu bar
/// panel for quick recording, like Loom. The menu bar icon is the
/// builder's ring: dashed when idle, filled while live.
@main
struct VisionOneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recorder = ScreenRecorder.shared

    init() {
        // Bricolage Grotesque, Source Serif 4 and JetBrains Mono, before
        // anything draws.
        BundledFont.registerAll()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.phase.isLive ? "record.circle.fill" : "circle.dashed")
                .accessibilityLabel(recorder.phase.isLive ? "Vision One, recording" : "Vision One")
        }
        .menuBarExtraStyle(.window)
        .commands { AppCommands(recorder: recorder) }
    }
}

/// The app's menus, from VisionOneKit's ShortcutMap so menus, tooltips
/// and the Keyboard Shortcuts window agree. The global hot key already
/// owns ⇧⌘R, so Record only names it in its title instead of binding it
/// a second time.
struct AppCommands: Commands {
    @ObservedObject var recorder: ScreenRecorder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(recorder.phase.isLive ? "Stop Recording  \(ShortcutMap.record.display)"
                                         : "Start Recording  \(ShortcutMap.record.display)") {
                Task { await recorder.toggle() }
            }
            .disabled(recorder.phase.isBusy)
            Button("Show Library") { EditorWindowController.shared.showLibrary() }
                .keyboardShortcut(ShortcutMap.library)
            Button("Copy a Style…") { CopyStyleWindowController.shared.show() }
            Button("Autopilot…") { AutopilotWindowController.shared.show() }
        }
        CommandGroup(after: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Brand…") { SettingsWindowController.shared.show(.brand) }
            Button("AI…") { SettingsWindowController.shared.show(.ai) }
            Button("Access…") { SettingsWindowController.shared.show(.access) }
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { TextSize.step(1) }
                .keyboardShortcut(ShortcutMap.textBigger)
            Button("Smaller Text") { TextSize.step(-1) }
                .keyboardShortcut(ShortcutMap.textSmaller)
            Button("Actual Text Size") {
                UserDefaults.standard.set(TextSize.medium.rawValue, forKey: TextSize.storageKey)
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { ShortcutsWindowController.shared.show() }
                .keyboardShortcut(ShortcutMap.shortcuts)
            Button("Vision One on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/VenusOne-Lee/vision-one")!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘⇧R from anywhere starts or stops recording.
        hotKey.register {
            Task { @MainActor in await ScreenRecorder.shared.toggle() }
        }
        // Release builds check for updates once a day (Sparkle).
        Updater.shared.start()
        CameraBubble.shared.start()
        RecordingBarController.shared.start()
        // Re-record demos tied to a repo when it ships a release.
        ReleaseWatcher.shared.start()
        // Finish any transcript a quit left undone.
        Task { @MainActor in Transcriber.shared.catchUp(in: ScreenRecorder.shared.library) }
        // First launch, or access was turned off: show only what's
        // missing. Otherwise open on the Library.
        if !AccessCenter.shared.checklist.canRecord {
            SetupWindowController.shared.show()
        } else {
            EditorWindowController.shared.showLibrary()
        }
    }

    /// visionone://demo/rerecord?name=…&release=… from the rerecord-demos
    /// GitHub Action (or any script): Autopilot records the demo again.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let request = RerecordRequest(url: url) {
                AutopilotService.shared.rerecord(request)
            }
        }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { EditorWindowController.shared.show() }
        return true
    }

    /// Closing the window leaves the menu bar recorder and ⌘⇧R running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
