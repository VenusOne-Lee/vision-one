import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import VisionOneKit

/// Reads and requests Screen Recording, Microphone and Camera access, and keeps
/// the checklist fresh while the setup window is open so it notices the
/// moment access is turned on in System Settings.
@MainActor
final class AccessCenter: ObservableObject {
    static let shared = AccessCenter()

    @Published private(set) var checklist: AccessChecklist

    private var timer: Timer?
    private static let askedScreenKey = "askedForScreenRecording"
    private static let reopenedForScreenKey = "reopenedForScreenRecording"
    /// ScreenCaptureKit said yes while CGPreflight still says no.
    private var screenLive = false
    private var probing = false

    private init() {
        let screen = Self.currentScreenState()
        checklist = AccessChecklist(
            states: [.screen: screen, .microphone: Self.currentState(for: .audio),
                     .camera: Self.currentState(for: .video)],
            screenAtLaunch: screen
        )
    }

    func refresh() {
        checklist.states[.screen] = screenLive ? .granted : Self.currentScreenState()
        checklist.states[.microphone] = Self.currentState(for: .audio)
        checklist.states[.camera] = Self.currentState(for: .video)
        if checklist.state(of: .screen) == .granted {
            UserDefaults.standard.removeObject(forKey: Self.reopenedForScreenKey)
        } else {
            probeScreen()
        }
    }

    /// CGPreflightScreenCaptureAccess keeps its first answer until the app
    /// restarts, so a switch turned on in System Settings goes unnoticed.
    /// ScreenCaptureKit asks macOS afresh each time: when it lists windows,
    /// recording works in this process and no restart is needed. Only once
    /// asked, so it never brings up the system prompt by itself.
    private func probeScreen() {
        guard checklist.state(of: .screen) == .denied, !probing else { return }
        probing = true
        Task {
            let allowed = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
            probing = false
            guard allowed, !screenLive else { return }
            screenLive = true
            var states = checklist.states
            states[.screen] = .granted
            checklist = AccessChecklist(states: states, screenAtLaunch: .granted)
            UserDefaults.standard.removeObject(forKey: Self.reopenedForScreenKey)
        }
    }

    /// Vision One was reopened for Screen Recording and it's still off:
    /// the entry in System Settings likely belongs to an older copy.
    var reopenedForScreen: Bool {
        UserDefaults.standard.bool(forKey: Self.reopenedForScreenKey)
    }

    /// Reopens so macOS hands over a switch it hasn't passed on yet.
    func reopenForScreen() {
        UserDefaults.standard.set(true, forKey: Self.reopenedForScreenKey)
        relaunch()
    }

    /// Clears Vision One's Screen Recording entry, which may point at an
    /// older or differently signed copy, then adds this copy afresh and
    /// opens System Settings on it.
    func resetScreenAccess() {
        UserDefaults.standard.removeObject(forKey: Self.reopenedForScreenKey)
        if let id = Bundle.main.bundleIdentifier {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "ScreenCapture", id]
            try? task.run()
            task.waitUntilExit()
        }
        CGRequestScreenCaptureAccess()
        openSettings(for: .screen)
        refresh()
    }

    /// Checks once a second while the setup window is open.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AccessCenter.shared.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Shows the system prompt the first time. After that only System
    /// Settings can change it, so it opens the right page there.
    func request(_ kind: AccessKind) {
        switch (kind, checklist.state(of: kind)) {
        case (_, .granted):
            return
        case (.screen, .notAsked):
            UserDefaults.standard.set(true, forKey: Self.askedScreenKey)
            // Also adds Vision One to the list in System Settings.
            CGRequestScreenCaptureAccess()
            refresh()
        case (.microphone, .notAsked):
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AccessCenter.shared.refresh() }
            }
        case (.camera, .notAsked):
            AVCaptureDevice.requestAccess(for: .video) { _ in
                Task { @MainActor in
                    AccessCenter.shared.refresh()
                    CaptureDevices.shared.refresh()
                }
            }
        case (_, .denied):
            openSettings(for: kind)
        }
    }

    func openSettings(for kind: AccessKind) {
        let pane: String
        switch kind {
        case .screen: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording only takes effect in a new process.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Access sticks best when the app always runs from one place.
    var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Copies the app into /Applications and opens that copy.
    func moveToApplications() throws {
        let source = Bundle.main.bundleURL
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", target.path]
        try task.run()
        NSApp.terminate(nil)
    }

    private static func currentScreenState() -> AccessState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: askedScreenKey) ? .denied : .notAsked
    }

    private static func currentState(for media: AVMediaType) -> AccessState {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}
