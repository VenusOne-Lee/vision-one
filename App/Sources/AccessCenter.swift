import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import VisionOneKit

/// Reads and requests Screen Recording, Microphone, Camera and
/// Accessibility access, and keeps
/// the checklist fresh while the setup window is open so it notices the
/// moment access is turned on in System Settings.
@MainActor
final class AccessCenter: ObservableObject {
    static let shared = AccessCenter()

    @Published private(set) var checklist: AccessChecklist

    private var timer: Timer?
    private static let askedScreenKey = "askedForScreenRecording"
    private static let askedAccessibilityKey = "askedForAccessibility"
    /// ScreenCaptureKit said yes while CGPreflight still says no.
    private var screenLive = false
    private var probing = false

    private init() {
        let screen = Self.currentScreenState()
        checklist = AccessChecklist(
            states: [.screen: screen, .microphone: Self.currentState(for: .audio),
                     .camera: Self.currentState(for: .video), .accessibility: Self.currentAccessibilityState()],
            screenAtLaunch: screen
        )
    }

    func refresh() {
        checklist.states[.screen] = screenLive ? .granted : Self.currentScreenState()
        checklist.states[.microphone] = Self.currentState(for: .audio)
        checklist.states[.camera] = Self.currentState(for: .video)
        checklist.states[.accessibility] = Self.currentAccessibilityState()
        probeScreen()
    }

    /// CGPreflightScreenCaptureAccess keeps its first answer until the app
    /// restarts, so a switch turned on in System Settings goes unnoticed.
    /// ScreenCaptureKit asks macOS afresh each time: when it lists windows,
    /// recording works in this process and no restart is needed. Only once
    /// asked, so it never brings up the system prompt by itself.
    private func probeScreen() {
        // Only after asking in this launch: on a stale entry the probe
        // itself makes macOS show its "would like to record" box, which
        // shouldn't appear unasked.
        guard screenAskedThisLaunch, checklist.state(of: .screen) == .denied, !probing else { return }
        probing = true
        Task {
            let allowed = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
            probing = false
            guard allowed, !screenLive else { return }
            screenLive = true
            var states = checklist.states
            states[.screen] = .granted
            checklist = AccessChecklist(states: states, screenAtLaunch: .granted)
        }
    }

    /// Clears Vision One's Screen Recording entry, which may point at an
    /// older or differently signed copy (its switch then does nothing),
    /// adds this copy afresh and opens System Settings on it, so the only
    /// thing left is one switch.
    ///
    /// Only macOS's own box shows the first time (its Open System Settings
    /// button goes to the pane). Opening the pane as well left that box
    /// sitting over System Settings after the switch was on. Pressed
    /// again, it just opens the pane.
    private func resetScreenAccess() {
        if screenResetDone {
            openSettings(for: .screen)
        } else {
            screenResetDone = true
            Self.resetEntry(for: .screen)
            CGRequestScreenCaptureAccess()
        }
        refresh()
    }
    private var screenResetDone = false
    private var screenAskedThisLaunch = false

    /// Removes Vision One's entry for `kind` from macOS's privacy list.
    /// A switch tied to an older or differently signed copy looks on but
    /// does nothing, and a "Don't Allow" can't be asked again; after this
    /// macOS treats Vision One as new and asks once more.
    private static func resetEntry(for kind: AccessKind) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let service: String
        switch kind {
        case .screen: service = "ScreenCapture"
        case .microphone: service = "Microphone"
        case .camera: service = "Camera"
        case .accessibility: service = "Accessibility"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, id]
        if (try? task.run()) != nil { task.waitUntilExit() }
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

    /// Shows the system prompt the first time. Once off, it clears the
    /// old entry and asks again: macOS's own prompt for the mic and camera,
    /// one switch in System Settings for Screen Recording and Accessibility.
    func request(_ kind: AccessKind) {
        if kind == .screen { screenAskedThisLaunch = true }
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
        case (.accessibility, .notAsked):
            UserDefaults.standard.set(true, forKey: Self.askedAccessibilityKey)
            // Shows macOS's prompt, which adds Vision One to the list.
            _ = Self.askForAccessibility()
            refresh()
        case (.screen, .denied):
            resetScreenAccess()
        case (.accessibility, .denied):
            Self.resetEntry(for: .accessibility)
            _ = Self.askForAccessibility()
            openSettings(for: .accessibility)
            refresh()
        case (.microphone, .denied), (.camera, .denied):
            Self.resetEntry(for: kind)
            let asked = Date()
            AVCaptureDevice.requestAccess(for: kind == .camera ? .video : .audio) { granted in
                Task { @MainActor in
                    AccessCenter.shared.refresh()
                    if kind == .camera { CaptureDevices.shared.refresh() }
                    // An answer this fast means macOS showed no prompt:
                    // fall back to the switch in System Settings.
                    if !granted, Date().timeIntervalSince(asked) < 0.5 {
                        AccessCenter.shared.openSettings(for: kind)
                    }
                }
            }
        }
    }

    func openSettings(for kind: AccessKind) {
        let pane: String
        switch kind {
        case .screen: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .camera: pane = "Privacy_Camera"
        case .accessibility: pane = "Privacy_Accessibility"
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

    /// AXIsProcessTrusted is live: a switch turned on shows at once.
    private static func currentAccessibilityState() -> AccessState {
        if AXIsProcessTrusted() { return .granted }
        return UserDefaults.standard.bool(forKey: askedAccessibilityKey) ? .denied : .notAsked
    }

    private static func askForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func currentState(for media: AVMediaType) -> AccessState {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}
