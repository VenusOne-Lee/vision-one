import AppKit
import Combine
import SwiftUI
import VisionOneKit

/// The floating control bar while recording ("Recording, out of the way"):
/// a white pill with an orange border, a blinking dot, the running time,
/// the mic meter, pause, restart, delete and Stop. It shows only while
/// live, sits bottom centre of the recorded display, can be dragged
/// anywhere and remembers where it was left.
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

        let bar = RecordingBarView(recorder: ScreenRecorder.shared, mic: MicMonitor.shared) { [weak self] translation, done in
            self?.dragged(by: translation, done: done)
        } onSize: { [weak self] size in
            self?.fit(size)
        }
        panel.contentView = FirstClickHostingView(rootView: bar.themed())
        self.panel = panel
    }

    // MARK: Position

    /// The pill changes width (paused, asking to delete); keep its middle
    /// where it was.
    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        let old = panel.frame
        panel.setFrame(CGRect(x: old.midX - size.width / 2, y: old.minY, width: size.width, height: size.height),
                       display: true)
    }

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
        let visible = ScreenRecorder.shared.recordedScreen().visibleFrame
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + Theme.Space.lg)
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

/// The pill itself. Orange here means live, per docs/DESIGN.md: while
/// paused the border turns to dashed ink and the dot goes hollow, because
/// nothing is being recorded.
private struct RecordingBarView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var mic: MicMonitor
    @ObservedObject private var agent = AgentSession.shared
    /// Called while the pill is dragged, and once more with `done` on release.
    let onDrag: (CGSize, Bool) -> Void
    let onSize: (CGSize) -> Void
    /// Restart and delete ask first, in the pill itself.
    private enum Asking { case restart, delete }
    @State private var asking: Asking?
    /// Whether recording was already paused when the question came up.
    @State private var wasPaused = false

    var body: some View {
        Group {
            if let asking {
                question(asking)
            } else {
                controls
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.paper))
        .overlay(border)
        .floatShadow()
        .fixedSize()
        .padding(RecordingBarController.margin)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BarSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(BarSizeKey.self, perform: onSize)
        .onChange(of: recorder.phase.isLive) { _, live in
            if !live { asking = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording controls")
    }

    @ViewBuilder
    private var border: some View {
        if recorder.isPaused {
            Capsule().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            Capsule().strokeBorder(Theme.tally, lineWidth: 1.5)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                HStack(spacing: 10) {
                    status()
                    Mono(Timecode.string(from: recorder.recordedTime(at: context.date)))
                    if mic.isActive, !recorder.isPaused {
                        if mic.isSilent() {
                            Text("Can't hear you · check the mic")
                                .textStyle(.caption)
                                .foregroundStyle(Theme.fillerText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.fillerBackground, in: Capsule())
                                .fixedSize()
                        } else {
                            MicBars(lit: mic.meter.litBars(of: 5))
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { onDrag($0.translation, false) }
                    .onEnded { onDrag($0.translation, true) }
            )
            .help("Drag to move. Your windows are hidden from the recording.")
            .accessibilityElement(children: .combine)

            Divider().frame(height: 18).padding(.horizontal, 2)

            IconButton(recorder.isPaused ? "Resume" : "Pause",
                       systemImage: recorder.isPaused ? "play.fill" : "pause.fill",
                       shortcut: ShortcutMap.pauseRecording.display) {
                recorder.togglePause()
            }
            IconButton("Start over (this take goes to the Bin)", systemImage: "arrow.counterclockwise") {
                ask(.restart)
            }
            IconButton("Delete this take", systemImage: "trash") {
                ask(.delete)
            }

            Button("Stop") {
                Task { await recorder.stop() }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(recorder.phase.isBusy)
            .padding(.leading, 4)
            .accessibilityLabel("Stop recording")
        }
        .disabled(recorder.phase.isBusy)
    }

    @ViewBuilder
    private func status() -> some View {
        HStack(spacing: 6) {
            if recorder.isPaused {
                Circle()
                    .strokeBorder(Theme.text, lineWidth: Theme.Stroke.ring)
                    .frame(width: 10, height: 10)
                Text("Paused").textStyle(.headline)
            } else {
                LiveDot(size: 10)
                Text("REC").textStyle(.headline)
            }
            if agent.isLive {
                // Who is driving, in ink: orange stays for "live" only.
                Text("\(agent.agentName ?? "An agent") is driving")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1.5))
                    .accessibilityLabel("\(agent.agentName ?? "An agent") is using this Mac")
            }
        }
    }

    // MARK: Asking first

    private func ask(_ what: Asking) {
        wasPaused = recorder.isPaused
        recorder.pause()
        asking = what
    }

    private func question(_ what: Asking) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(what == .restart ? "Start over? This take goes to the Bin." : "Delete this take? It goes to the Bin.")
                .textStyle(.bodyStrong)
                .fixedSize()
            Button("Keep recording") {
                asking = nil
                if !wasPaused { recorder.resume() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            Button(what == .restart ? "Start over" : "Delete") {
                asking = nil
                Task {
                    if what == .restart {
                        await recorder.restart()
                    } else {
                        await recorder.deleteTake()
                    }
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .padding(.vertical, 1)
    }
}

/// Five ink bars for the mic level. Unlit bars stay as faint lines so the
/// meter keeps its size.
private struct MicBars: View {
    let lit: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? Theme.text : Theme.line)
                    .frame(width: 3, height: CGFloat(5 + index * 2))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Mic level")
        .accessibilityValue(lit == 0 ? "Quiet" : "\(lit) of 5")
    }
}

private struct BarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
