import AppKit
import Combine
import SwiftUI
import VisionOneKit

/// The floating control bar while recording ("Recording, out of the way"):
/// a white pill with an orange border, a blinking dot, the running time and
/// Stop. It shows only while live, sits bottom centre of the recorded
/// display, can be dragged anywhere and remembers where it was left.
///
/// It never lands in screen.mov: screen and area recordings exclude Vision
/// One's whole app from the capture filter (CaptureTarget.resolve), and a
/// window recording only captures the chosen window.
@MainActor
final class RecordingBarController {
    static let shared = RecordingBarController()

    private var panel: RecordingBarPanel?
    private var cancellables: Set<AnyCancellable> = []
    private static let originKey = "recordingBarOrigin"
    /// Room around the pill so its shadow isn't clipped by the panel.
    fileprivate static let margin: CGFloat = 16

    private init() {}

    /// Call once at launch. The bar then follows the recorder's phase.
    func start() {
        ScreenRecorder.shared.$phase
            .map(\.isLive)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] live in
                if live { self?.show() } else { self?.hide() }
            }
            .store(in: &cancellables)
    }

    private func show() {
        if panel == nil { makePanel() }
        guard let panel else { return }
        if let size = panel.contentView?.fittingSize {
            panel.setContentSize(size)
        }
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let panel = RecordingBarPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 72),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let bar = RecordingBarView(recorder: ScreenRecorder.shared) { [weak self] translation, done in
            self?.dragged(by: translation, done: done)
        }
        panel.contentView = FirstClickHostingView(rootView: bar)
        self.panel = panel
    }

    // MARK: Position

    private var dragStartOrigin: CGPoint?
    private var dragStartMouse: CGPoint?

    /// Moves the panel with the mouse (screen points, so the panel moving
    /// under the gesture doesn't feed back), and saves the spot on release.
    private func dragged(by _: CGSize, done: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
            dragStartMouse = mouse
        }
        guard let startOrigin = dragStartOrigin, let startMouse = dragStartMouse else { return }
        panel.setFrameOrigin(CGPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                     y: startOrigin.y + mouse.y - startMouse.y))
        if done {
            dragStartOrigin = nil
            dragStartMouse = nil
            let origin = panel.frame.origin
            UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
        }
    }

    /// Where the user left it, if that's still on a screen; otherwise
    /// bottom centre of the display being recorded.
    private func origin(for size: CGSize) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            let frame = CGRect(x: saved[0], y: saved[1], width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return frame.origin
            }
        }
        let visible = recordedScreen().visibleFrame
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + Theme.Space.lg)
    }

    private func recordedScreen() -> NSScreen {
        let choice = ScreenRecorder.shared.choice
        if choice.mode != .window, let id = choice.displayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class RecordingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets Stop work on the first click, though the panel never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill itself. Orange here means live, per docs/DESIGN.md.
private struct RecordingBarView: View {
    @ObservedObject var recorder: ScreenRecorder
    /// Called while the pill is dragged, and once more with `done` on release.
    let onDrag: (CGSize, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.tally)
                                .frame(width: 10, height: 10)
                                .opacity(blinkOn(at: context.date) ? 1 : 0.25)
                            Text("REC")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text(Timecode.string(from: recorder.phase.elapsed(at: context.date) ?? 0))
                            .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                    }
                }
                Text("Your windows are hidden from the recording")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onDrag($0.translation, false) }
                    .onEnded { onDrag($0.translation, true) }
            )
            .accessibilityElement(children: .combine)

            Button("Stop") {
                Task { await ScreenRecorder.shared.toggle() }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(recorder.phase.isBusy)
            .accessibilityLabel("Stop recording")
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.tally, lineWidth: 1.5))
        .shadow(color: Theme.text.opacity(0.3), radius: 10, y: 6)
        .fixedSize()
        .padding(RecordingBarController.margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controls")
    }

    private func blinkOn(at date: Date) -> Bool {
        reduceMotion || Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 0
    }
}
