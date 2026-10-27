import AppKit
import VisionOneKit

/// "Record steps": the person clicks through their app once and each click
/// becomes a named step (`Click the "Pay now" button`), typing becomes a
/// Type step and shortcuts become Press steps. Only the demo's app is
/// recorded, password fields are skipped, and the pill shows it's on.
/// Esc or Done finishes.
@MainActor
final class StepRecorder: ObservableObject {
    static let shared = StepRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var steps: [DemoStep] = []

    private var bundleID = ""
    private var monitors: [Any] = []
    private var typing: (target: UITarget?, text: String)?
    private var onFinish: (([DemoStep]) -> Void)?
    private let pill = AutopilotPill.shared

    func start(appBundleID: String, appName: String, onFinish: @escaping ([DemoStep]) -> Void) {
        guard !isRecording else { return }
        guard AXReader.isTrusted || AXReader.askForAccess() else { return }
        bundleID = appBundleID
        steps = []
        typing = nil
        self.onFinish = onFinish
        isRecording = true

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first {
            _ = app.activate()
            AXReader.wakeWebContent(AXReader.app(app.processIdentifier))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }

        pill.appName = appName
        pill.mode = .recordingSteps
        pill.isLive = false
        pill.stepLine = ""
        pill.onStop = { [weak self] in self?.finish() }
        pill.show(on: NSScreen.main)

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let input = Input(event)
            MainActor.assumeIsolated { self?.handle(input) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.finish() }
            return nil
        }) {
            monitors.append(local)
        }
    }

    func finish() {
        guard isRecording else { return }
        flushTyping()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isRecording = false
        pill.hide()
        NSApp.activate()
        onFinish?(steps)
        onFinish = nil
    }

    // MARK: Events

    private struct Input {
        let isClick: Bool
        let location: CGPoint?
        let keyCode: UInt16
        let characters: String
        let modifiers: KeyCombo.Modifiers

        init(_ event: NSEvent) {
            isClick = event.type == .leftMouseDown
            location = event.cgEvent?.location
            keyCode = isClick ? 0 : event.keyCode
            characters = isClick ? "" : (event.characters ?? "")
            var mods: KeyCombo.Modifiers = []
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            modifiers = mods
        }
    }

    private func handle(_ input: Input) {
        if input.isClick {
            if let location = input.location { click(at: location) }
        } else {
            key(input)
        }
    }

    private func click(at point: CGPoint) {
        guard let hit = AXReader.element(at: point), AXReader.bundleID(of: hit) == bundleID else { return }
        flushTyping()
        let element = AXReader.actionable(hit)
        guard let candidate = AXReader.candidate(for: element), !candidate.isSecure else { return }
        let app = AXReader.app(AXReader.pid(of: element) ?? 0)
        guard let window = AXReader.window(of: app), let frame = AXReader.frame(of: window) else { return }
        let area = CaptureRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        let all = AXReader.read(window).map(\.candidate)
        let target = TargetMatcher.target(for: candidate, among: all, window: area)
        // Clicking into a field starts a Type step there; the click itself
        // is part of typing.
        if AXReader.fields.contains(candidate.role) {
            typing = (target, "")
        } else {
            append(DemoStep(.click, target: target))
        }
    }

    private func key(_ input: Input) {
        if input.keyCode == 53 {
            finish()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        // Never record what goes into a password field.
        if let front = NSWorkspace.shared.frontmostApplication,
           let focused = AXReader.focused(in: AXReader.app(front.processIdentifier)),
           AXReader.candidate(for: focused)?.isSecure == true {
            return
        }
        let shortcut = input.modifiers.contains(.command) || input.modifiers.contains(.control)
        let special: Set<UInt16> = [36, 48, 53, 51, 123, 124, 125, 126, 116, 121, 115, 119]
        if shortcut || (special.contains(input.keyCode) && input.keyCode != 51) {
            flushTyping()
            if let keys = KeyCombo.text(keyCode: input.keyCode, modifiers: input.modifiers) {
                append(DemoStep(.press, keys: keys))
            }
            return
        }
        if input.keyCode == 51 {
            if var pending = typing, !pending.text.isEmpty {
                pending.text.removeLast()
                typing = pending
            }
            return
        }
        let printable = input.characters.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } }
        guard !printable.isEmpty else { return }
        var pending = typing ?? (nil, "")
        pending.text += printable
        typing = pending
        pill.stepLine = "Typing “\(pending.text)”"
    }

    private func flushTyping() {
        guard let pending = typing else { return }
        typing = nil
        if pending.text.isEmpty {
            // Clicked a field but typed nothing: keep it as a click.
            if let target = pending.target { append(DemoStep(.click, target: target)) }
            return
        }
        append(DemoStep(.type, target: pending.target, text: pending.text))
    }

    private func append(_ step: DemoStep) {
        steps.append(step)
        pill.stepNumber = steps.count
        pill.stepLine = StepWords.line(for: step)
    }
}
