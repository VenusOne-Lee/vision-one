import AppKit
import AVFoundation
import CoreGraphics
import VisionOneKit

/// Reads and requests Screen Recording and Microphone access, and keeps
/// the checklist fresh while the setup window is open so it notices the
/// moment access is turned on in System Settings.
@MainActor
final class AccessCenter: ObservableObject {
    static let shared = AccessCenter()

    @Published private(set) var checklist: AccessChecklist

    private var timer: Timer?
    private static let askedScreenKey = "askedForScreenRecording"

    private init() {
        let screen = Self.currentScreenState()
        checklist = AccessChecklist(
            states: [.screen: screen, .microphone: Self.currentMicrophoneState()],
            screenAtLaunch: screen
        )
    }

    func refresh() {
        checklist.states[.screen] = Self.currentScreenState()
        checklist.states[.microphone] = Self.currentMicrophoneState()
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
        case (_, .denied):
            openSettings(for: kind)
        }
    }

    func openSettings(for kind: AccessKind) {
        let pane = kind == .screen ? "Privacy_ScreenCapture" : "Privacy_Microphone"
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

    private static func currentMicrophoneState() -> AccessState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}
