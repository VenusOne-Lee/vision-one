import AppKit
import SwiftUI
import VisionOneKit

/// Vision One lives in the menu bar (LSUIElement), like Loom. The menu
/// bar icon is the builder's ring: dashed when idle, filled while live.
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
        // Finish any transcript a quit left undone.
        Task { @MainActor in Transcriber.shared.catchUp(in: ScreenRecorder.shared.library) }
        // First launch, or access was turned off: show what's missing.
        if !AccessCenter.shared.checklist.canRecord {
            SetupWindowController.shared.show()
        }
    }
}
