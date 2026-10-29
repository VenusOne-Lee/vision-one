import AppKit
import SwiftUI
import VisionOneKit

/// Vision One is a regular Mac app with a Dock icon and one main window
/// (the harness: New task, tasks, the Library and the editor), plus a
/// menu bar panel for quick recording, like Loom. The menu bar icon is
/// the builder's ring: dashed when idle, filled while live, with an ink
/// mark when a task needs you or an agent is working.
/// Started from main.swift, which runs the MCP bridge instead when the
/// app is launched as `Vision One --mcp`.
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
            MenuBarLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
        .commands { AppCommands(recorder: recorder) }
    }
}

/// The menu bar icon: the filled record ring while live, as before;
/// otherwise a mark when a task needs you or an agent is working, and
/// the dashed ring when all is quiet (MenuBarMark). Template SF Symbols,
/// so ink only.
struct MenuBarLabel: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject private var desk = DeskFeed.shared

    var body: some View {
        let mark = MenuBarMark.current(isLive: recorder.phase.isLive, statuses: desk.snapshot.openStatuses)
        Image(systemName: mark.systemImage)
            .accessibilityLabel(mark.accessibilityLabel)
    }
}

/// The app's menus, from VisionOneKit's ShortcutMap so menus, tooltips
/// and the Keyboard Shortcuts window agree. The global hot key already
/// owns ⇧⌘R, so Record only names it in its title instead of binding it
/// a second time.
struct AppCommands: Commands {
    @ObservedObject var recorder: ScreenRecorder

    var body: some Commands {
        // File › New is a new task. The main window's ⌘B and ⌥⌘B live
        // here too, so they show in the menus and never fire twice.
        CommandGroup(replacing: .newItem) {
            Button("New Task") { EditorWindowController.shared.showNewTask() }
                .keyboardShortcut(ShortcutMap.newTask)
        }
        CommandGroup(after: .newItem) {
            Button(recorder.phase.isLive ? "Stop Recording  \(ShortcutMap.record.display)"
                                         : "Start Recording  \(ShortcutMap.record.display)") {
                Task { await recorder.toggle() }
            }
            .disabled(recorder.phase.isBusy)
            Button(recorder.isPaused ? "Resume Recording  \(ShortcutMap.pauseRecording.display)"
                                     : "Pause Recording  \(ShortcutMap.pauseRecording.display)") {
                recorder.togglePause()
            }
            .disabled(!recorder.phase.isLive)
            Button("Record an Agent…") {
                // Counts down like any take, which gives time to start the
                // agent. Only the agent's clicks and typing are marked.
                AgentSession.shared.arm(agent: nil, task: nil)
                Task {
                    await recorder.record()
                    if !recorder.phase.isLive { AgentSession.shared.disarm() }
                }
            }
            .disabled(recorder.phase.isBusy || recorder.phase.isLive)
            Button("Show Library") { EditorWindowController.shared.showLibrary() }
                .keyboardShortcut(ShortcutMap.library)
            Button("Copy a Style…") { CopyStyleWindowController.shared.show() }
            Button("Autopilot…") { AutopilotWindowController.shared.show() }
            Divider()
            Button("Script Coach…") { ScriptCoachWindowController.shared.show() }
            Button("Rehearse…") { RehearseWindowController.shared.show() }
            Button("Voice Tools…") { VoiceToolsWindowController.shared.show(for: EditorWindowController.shared.currentTake) }
        }
        CommandGroup(after: .appSettings) {
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Brand…") { SettingsWindowController.shared.show(.brand) }
            Button("AI…") { SettingsWindowController.shared.show(.ai) }
            Button("Access…") { SettingsWindowController.shared.show(.access) }
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { EditorWindowController.shared.toggleSidebar() }
                .keyboardShortcut(ShortcutMap.toggleSidebar)
            Button("Toggle Panel") { EditorWindowController.shared.togglePanel() }
                .keyboardShortcut(ShortcutMap.togglePanel)
            Divider()
            Button("Bigger Text") { TextSize.step(1) }
                .keyboardShortcut(ShortcutMap.textBigger)
            Button("Smaller Text") { TextSize.step(-1) }
                .keyboardShortcut(ShortcutMap.textSmaller)
            Button("Actual Text Size") {
                UserDefaults.standard.set(TextSize.medium.rawValue, forKey: TextSize.storageKey)
            }
            Divider()
        }
        // Brings the main window back, even once it's been closed.
        CommandGroup(before: .windowList) {
            Button("Vision One") { EditorWindowController.shared.show() }
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
        // The look from Settings → Appearance (theme.json), before any window.
        ThemeStore.shared.start()
        // ⌘⇧R from anywhere starts or stops recording.
        hotKey.register {
            Task { @MainActor in await ScreenRecorder.shared.toggle() }
        }
        // ⌥⇧P pauses and resumes while live.
        hotKey.registerPause {
            Task { @MainActor in ScreenRecorder.shared.togglePause() }
        }
        FrontmostApp.shared.start()
        // Release builds check for updates once a day (Sparkle).
        Updater.shared.start()
        CameraBubble.shared.start()
        RecordingBarController.shared.start()
        // Re-record demos tied to a repo when it ships a release.
        ReleaseWatcher.shared.start()
        // Finish any transcript a quit left undone.
        Task { @MainActor in Transcriber.shared.catchUp(in: ScreenRecorder.shared.library) }
        // Claude Code, Codex and other agents connect through here.
        MCPService.shared.start()
        AgentWatcher.shared.start()
        // Opened in the background by an agent: stay out of the way, and
        // get a Dock icon back once the person opens a real window.
        if CommandLine.arguments.contains(MCPService.backgroundFlag) {
            NSApp.setActivationPolicy(.accessory)
            _ = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil,
                                                   queue: .main) { _ in
                MainActor.assumeIsolated {
                    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
                }
            }
            return
        }
        // First launch, or the mic was never asked: show only what's
        // missing, then New task. Screen Recording waits for the first
        // screen recording, so camera-only never needs it. Otherwise open
        // straight on New task, ready to record or ask.
        let welcomeSeen = UserDefaults.standard.bool(forKey: SetupView.welcomeSeenKey)
        if !welcomeSeen || AccessCenter.shared.checklist.state(of: .microphone) == .notAsked {
            SetupWindowController.shared.opensHarnessWhenDone = true
            SetupWindowController.shared.show(askScreen: false)
        } else {
            EditorWindowController.shared.showNewTask()
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

    /// Clicking the Dock icon with no window open brings the main window
    /// back, on New task (closing it ends the open task).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opened in the background by an agent, now opened by the person.
        if sender.activationPolicy() != .regular { sender.setActivationPolicy(.regular) }
        if !flag { EditorWindowController.shared.show() }
        return true
    }

    /// Closing the window leaves the menu bar recorder and ⌘⇧R running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
