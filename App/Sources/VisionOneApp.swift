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

/// The app's menus. The global hot key already owns ⌘⇧R, so Record only
/// names it in its title instead of binding it a second time.
struct AppCommands: Commands {
    @ObservedObject var recorder: ScreenRecorder

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(recorder.phase.isLive ? "Stop Recording  ⌘⇧R" : "Start Recording  ⌘⇧R") {
                Task { await recorder.toggle() }
            }
            .disabled(recorder.phase.isBusy)
            Button("Show Library") { EditorWindowController.shared.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Brand…") { SettingsWindowController.shared.show(.brand) }
            Button("AI…") { SettingsWindowController.shared.show(.ai) }
            Button("Access…") { SettingsWindowController.shared.show(.access) }
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
