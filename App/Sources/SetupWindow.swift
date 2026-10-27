import AppKit
import SwiftUI
import VisionOneKit

/// "Get set up": the first-run flow, one thing at a time. A welcome, one
/// step per missing permission that moves on by itself once granted, then
/// a finish. Returning users land straight on what's missing, and with
/// nothing missing they get the compact checklist.
struct SetupView: View {
    @ObservedObject var access: AccessCenter
    @State private var flow: OnboardingFlow
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set once the welcome's Get started is pressed.
    static let welcomeSeenKey = "onboarding.welcomeSeen"

    init(access: AccessCenter) {
        _access = ObservedObject(wrappedValue: access)
        let welcomeSeen = UserDefaults.standard.bool(forKey: Self.welcomeSeenKey)
        _flow = State(initialValue: OnboardingFlow(checklist: access.checklist, welcomeSeen: welcomeSeen))
    }

    var body: some View {
        Group {
            if flow.isOverview {
                AccessOverview(access: access)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if flow.steps.count > 1 {
                        StepIndicator(count: flow.steps.count, current: index) { step in
                            flow.isDone(step, current: index, checklist: access.checklist)
                        }
                    }
                    // Stacked, so the leaving and arriving steps cross-fade
                    // in place instead of sitting one above the other.
                    ZStack(alignment: .topLeading) {
                        stepContent
                            .id(index)
                            .transition(stepTransition)
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
        .onAppear { index = flow.advanced(from: index, checklist: access.checklist) }
        .onChange(of: access.checklist) { _, checklist in
            autoAdvance(checklist)
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return AnyTransition.opacity }
        return AnyTransition.asymmetric(
            insertion: AnyTransition.opacity.combined(with: AnyTransition.offset(x: 16)),
            removal: AnyTransition.opacity
        )
    }

    private var currentStep: OnboardingStep {
        flow.steps.indices.contains(index) ? flow.steps[index] : .finish
    }

    @ViewBuilder private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WelcomeStep(access: access) {
                UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
                moveOn()
            }
        case .access(let kind):
            AccessStep(kind: kind, state: access.checklist.state(of: kind)) {
                access.request(kind)
            } dismiss: {
                if kind.isOptional { moveOn() } else { SetupWindowController.shared.close() }
            }
        case .finish:
            if access.checklist.needsRestart || access.checklist.canRecord {
                FinishStep(access: access)
            } else {
                // Access was turned off again on the way: show it all.
                AccessOverview(access: access)
            }
        }
    }

    private func moveOn() {
        guard let next = flow.next(after: index, checklist: access.checklist) else { return }
        go(to: next)
    }

    private func go(to step: Int) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { index = step }
    }

    /// Once the current permission turns on, wait a beat so the ring is
    /// seen going solid, then move on without a Next button.
    private func autoAdvance(_ checklist: AccessChecklist) {
        let from = index
        guard flow.advanced(from: from, checklist: checklist) != from else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard index == from else { return }
            go(to: flow.advanced(from: from, checklist: access.checklist))
        }
    }
}

/// Every permission at once: the view for returning users with nothing
/// missing. Rows are dashed until granted and solid once done, the app's
/// one grammar.
struct AccessOverview: View {
    @ObservedObject var access: AccessCenter

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Access")
                    .font(.system(size: 28, weight: .light))
                    .accessibilityAddTraits(.isHeader)
                Text("What Vision One may use on this Mac. Your recordings stay on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Space.sm) {
                ForEach(AccessKind.allCases, id: \.self) { kind in
                    AccessRow(kind: kind, state: access.checklist.state(of: kind)) {
                        access.request(kind)
                    } openSettings: {
                        access.openSettings(for: kind)
                    }
                }
            }

            if access.checklist.needsRestart {
                RestartBanner { access.relaunch() }
            } else if access.checklist.state(of: .screen) != .granted {
                DragHint()
            }

            Text("macOS asks again about once a month whether Vision One may still record. Choose Allow.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !access.isInApplications {
                MoveToApplicationsLine(access: access)
            }

            HStack {
                Spacer()
                Button(access.checklist.canRecord ? "Done" : "Later") {
                    SetupWindowController.shared.close()
                }
                .buttonStyle(PillButtonStyle(kind: access.checklist.canRecord ? .primary : .secondary))
                .keyboardShortcut(access.checklist.canRecord ? KeyboardShortcut.defaultAction : KeyboardShortcut.cancelAction)
            }
        }
    }
}

private struct AccessRow: View {
    let kind: AccessKind
    let state: AccessState
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            StatusRing(done: state == .granted)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(state == .denied ? Theme.error : Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Text("On").font(.system(size: 12, weight: .medium))
            case .notAsked:
                Button("Allow", action: allow).buttonStyle(PillButtonStyle(kind: .primary))
            case .denied:
                Button("Open Settings", action: openSettings).buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(state == .granted ? Theme.text : Theme.line,
                              style: StrokeStyle(lineWidth: 1, dash: state == .granted ? [] : [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch state {
        case .granted: return kind.why
        case .notAsked: return kind.why
        case .denied: return "Turned off. Switch on Vision One in System Settings."
        }
    }
}

/// Dashed ring until done, solid ink ring with a tick once granted.
struct StatusRing: View {
    let done: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: done ? [] : [3, 3]))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct RestartBanner: View {
    let restart: () -> Void

    var body: some View {
        HStack {
            Text("Screen Recording is on. Restart Vision One to start using it.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Restart Vision One", action: restart)
                .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// When Vision One doesn't show up in the list, it can be dragged in.
struct DragHint: View {
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 36, height: 36)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag into the Screen Recording list")
            Text("Not in the list? Drag this icon into it, or click + under the list and choose Vision One.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Owns the setup window. A menu bar app has no window of its own, so
/// this makes one on demand and brings the app forward.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?
    /// Set when setup opens at launch: closing it once recording is
    /// allowed opens the main window on New task, so first run never
    /// ends on nothing.
    var opensHarnessWhenDone = false

    func show() {
        AccessCenter.shared.startWatching()
        if window == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Vision One"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.delegate = self
            self.window = window
            window.contentViewController = makeContent()
            window.center()
        } else if window?.isVisible == false {
            // Reopened later (the Access… menu): start a fresh flow so it
            // lands on whatever is missing now.
            window?.contentViewController = makeContent()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fixed width; the window's height follows each step's content.
    private func makeContent() -> NSViewController {
        let hosting = NSHostingController(rootView: SetupView(access: AccessCenter.shared))
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize, .preferredContentSize]
        return hosting
    }

    func close() {
        window?.close()
    }

    /// The end of setup: the main window on New task, and the first
    /// recording straight away when asked.
    func finish(record: Bool) {
        opensHarnessWhenDone = false
        window?.close()
        EditorWindowController.shared.showNewTask()
        if record { Task { await ScreenRecorder.shared.toggle() } }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            AccessCenter.shared.stopWatching()
            // Closed with the window's own button after the first run's
            // access was granted: land on New task anyway.
            if opensHarnessWhenDone, AccessCenter.shared.checklist.canRecord {
                opensHarnessWhenDone = false
                Task { @MainActor in EditorWindowController.shared.showNewTask() }
            }
        }
    }
}
