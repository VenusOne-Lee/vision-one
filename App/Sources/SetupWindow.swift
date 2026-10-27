import AppKit
import SwiftUI
import VisionOneKit

/// "Get set up": one window with every permission Vision One needs, a
/// button for each, and a restart once Screen Recording is on. Rows are
/// dashed until granted and solid once done, the app's one grammar.
struct SetupView: View {
    @ObservedObject var access: AccessCenter
    @State private var moveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Get set up")
                    .font(.system(size: 28, weight: .light))
                Text("Vision One needs two things from macOS before it can record, and Camera if you want the camera bubble. Your recordings stay on this Mac.")
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
                HStack(spacing: Theme.Space.sm) {
                    Text("Access sticks best when Vision One lives in Applications.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
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

            HStack {
                Spacer()
                Button(access.checklist.canRecord ? "Done" : "Later") {
                    SetupWindowController.shared.close()
                }
                .buttonStyle(PillButtonStyle(kind: access.checklist.canRecord ? .primary : .secondary))
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 440)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
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
private struct StatusRing: View {
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
private struct DragHint: View {
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
            window.contentViewController = NSHostingController(rootView: SetupView(access: AccessCenter.shared))
            window.appearance = NSAppearance(named: .aqua)
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AccessCenter.shared.stopWatching() }
    }
}
