import AppKit
import SwiftUI
import VisionOneKit

/// The display title every step uses: light and large, read as a heading.
private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .light))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One plain sentence under a step title.
private struct StepBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// First run only: what Vision One is, and one button to begin.
struct WelcomeStep: View {
    @ObservedObject var access: AccessCenter
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                StepTitle(text: "Record your screen. Vision One does the first edit.")
                StepBody(text: "Your recordings stay on this Mac.")
            }
            if !access.isInApplications {
                MoveToApplicationsLine(access: access)
            }
            HStack {
                Spacer()
                Button("Get started", action: start)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// One permission: why it's needed and the one button that gets it.
/// Moves on by itself once macOS says yes (see SetupView).
struct AccessStep: View {
    let kind: AccessKind
    let state: AccessState
    /// Shows the system prompt, or opens System Settings once denied.
    let allow: () -> Void
    /// Later for required access, Skip for the optional camera.
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                StepTitle(text: title)
                StepBody(text: kind.why)
                if state == .denied {
                    // Screen Recording reads as "denied" as soon as it's been
                    // asked, so it gets a calm note rather than an error.
                    Text("Switch on Vision One in System Settings. This moves on by itself.")
                        .font(.system(size: 12))
                        .foregroundStyle(kind == .screen ? Theme.textMuted : Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if kind == .screen {
                if state == .denied {
                    DragHint()
                }
                Text("macOS asks again about once a month whether Vision One may still record. Choose Allow.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.sm) {
                Spacer()
                if state == .granted {
                    StatusRing(done: true)
                    Text("On").font(.system(size: 12, weight: .medium))
                } else {
                    Button(dismissTitle, action: dismiss)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(dismissLabel)
                    Button(allowTitle, action: allow)
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(allowLabel)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var dismissTitle: String { kind.isOptional ? "Skip" : "Later" }
    private var dismissLabel: String { kind.isOptional ? "Skip \(kind.title)" : "Set up later" }
    private var allowTitle: String { state == .denied ? "Open System Settings" : "Allow" }
    private var allowLabel: String {
        state == .denied ? "Open System Settings for \(kind.title)" : "Allow \(kind.title)"
    }

    private var title: String {
        switch kind {
        case .screen: return "Let Vision One see your screen"
        case .microphone: return "Let Vision One hear you"
        case .camera: return "Show your face, if you like"
        }
    }
}

/// The last step: a restart when Screen Recording needs one, otherwise
/// the shortcut and one button that starts the first recording. Either
/// way out lands on the main window's New task.
struct FinishStep: View {
    @ObservedObject var access: AccessCenter
    @ObservedObject private var hotKey = GlobalHotKey.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if access.checklist.needsRestart {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    StepTitle(text: "One restart and you're set")
                    StepBody(text: "macOS turns on Screen Recording for Vision One the next time it opens.")
                }
                buttons {
                    Button("Later") { SetupWindowController.shared.close() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Restart Vision One") { access.relaunch() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    StepTitle(text: "You're set")
                    if hotKey.isRegistered {
                        HStack(spacing: Theme.Space.sm) {
                            KeyCap(keys: "⌘⇧R")
                            StepBody(text: "starts and stops recording from anywhere.")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Command Shift R starts and stops recording from anywhere.")
                    } else {
                        StepBody(text: "Record from the Vision One menu in the menu bar. Another app already uses ⌘⇧R.")
                    }
                }
                buttons {
                    Button("Not now") { SetupWindowController.shared.finish(record: false) }
                        .buttonStyle(PillButtonStyle(kind: .quiet))
                        .keyboardShortcut(.cancelAction)
                        .help("Open Vision One on New task")
                    Button("Start recording") { SetupWindowController.shared.finish(record: true) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            if !access.isInApplications {
                MoveToApplicationsLine(access: access)
            }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Spacer()
            content()
        }
    }
}

/// A shortcut set in mono on a small paper key.
private struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
    }
}

/// Where the user is in the flow: one small ring per step, dashed until
/// done and solid ink once done. The current step's ring is larger.
struct StepIndicator: View {
    let count: Int
    let current: Int
    let isDone: (Int) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                let done = isDone(index)
                let size: CGFloat = index == current ? 12 : 8
                Circle()
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.25, dash: done ? [] : [2, 2]))
                    .background(Circle().fill(done ? Theme.text : Color.clear))
                    .frame(width: size, height: size)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// A quiet offer to move into Applications, where access sticks best.
struct MoveToApplicationsLine: View {
    @ObservedObject var access: AccessCenter
    @State private var moveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Text("Access sticks best when Vision One lives in Applications.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Move to Applications") {
                    do { try access.moveToApplications() } catch { moveError = error.localizedDescription }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            if let moveError {
                Text(moveError).font(.system(size: 12)).foregroundStyle(Theme.error)
            }
        }
    }
}
