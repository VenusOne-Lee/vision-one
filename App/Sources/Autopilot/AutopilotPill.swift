import AppKit
import SwiftUI
import VisionOneKit

/// The pill at the top of the screen for the whole run: "Autopilot is
/// driving Safari · step 3 of 8 · Esc to stop". It floats over every app,
/// never takes focus, and is kept out of every recording.
@MainActor
final class AutopilotPill: ObservableObject {
    static let shared = AutopilotPill()

    enum Mode: Equatable {
        case countdown(Int)
        case driving
        case paused
        case recordingSteps
    }

    @Published var mode: Mode = .driving
    @Published var appName = ""
    @Published var stepLine = ""
    @Published var stepNumber = 0
    @Published var stepCount = 0
    @Published var isLive = false
    var onStop: (() -> Void)?
    var onResume: (() -> Void)?

    private var panel: NSPanel?

    func show(on screen: NSScreen?) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 44),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.contentViewController = NSHostingController(rootView: AutopilotPillView(pill: self))
            self.panel = panel
        }
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel?.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.maxY - 56))
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct AutopilotPillView: View {
    @ObservedObject var pill: AutopilotPill

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if pill.isLive { LiveDot() }
            Text(headline)
                .textStyle(.bodyStrong)
                .lineLimit(1)
            if !pill.stepLine.isEmpty, pill.mode != .recordingSteps {
                Text(pill.stepLine)
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.sm)
            if pill.mode == .paused {
                Button("Resume") { pill.onResume?() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            Button(pill.mode == .recordingSteps ? "Done" : "Stop") { pill.onStop?() }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            Text("esc")
                .textStyle(.monoSmall)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 5)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.lineStrong))
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(width: 520, height: 40)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.line))
        .floatShadow()
        .foregroundStyle(Theme.text)
        .themed()
        .padding(2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private var headline: String {
        switch pill.mode {
        case .countdown(let n): return "Autopilot starts in \(n)"
        case .driving:
            let step = pill.stepCount > 0 ? " · step \(pill.stepNumber) of \(pill.stepCount)" : ""
            return "Autopilot is driving \(pill.appName)\(step)"
        case .paused: return "You took over. Autopilot is paused."
        case .recordingSteps: return "Recording steps. Click through \(pill.appName)."
        }
    }
}
