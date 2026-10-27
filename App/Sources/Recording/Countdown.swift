import AppKit
import SwiftUI
import VisionOneKit

/// 3, 2, 1 in the middle of the screen about to be recorded. Ink, not
/// orange: nothing is recording yet. Click anywhere or press Space to
/// start now; Esc or Cancel stops it. The panel never activates Vision
/// One, so the app you're about to show stays in front.
@MainActor
final class Countdown {
    static let shared = Countdown()
    private static let lengthKey = "countdownSeconds"

    private var panel: CountdownPanel?
    private var timer: Timer?
    private var finish: ((Bool) -> Void)?
    private let model = CountdownModel()

    var isRunning: Bool { finish != nil }

    /// Off, 3 s or 5 s. Saved, picked under the record button.
    var length: CountdownLength {
        get {
            let saved = UserDefaults.standard.object(forKey: Self.lengthKey) as? Int
            return CountdownLength(saved: saved)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.lengthKey) }
    }

    /// Counts down on `screen`. True when it ran out or was skipped, false
    /// when it was cancelled. Returns true at once when the length is Off.
    func run(on screen: NSScreen) async -> Bool {
        let seconds = length.rawValue
        guard seconds > 0 else { return true }
        cancel()
        return await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            show(seconds: seconds, on: screen)
        }
    }

    /// Start recording now (a click, Space, or ⌘⇧R again).
    func skip() { end(true) }

    func cancel() { end(false) }

    private func show(seconds: Int, on screen: NSScreen) {
        model.total = seconds
        model.remaining = seconds
        let view = CountdownView(model: model, skip: { [weak self] in self?.skip() },
                                 cancel: { [weak self] in self?.cancel() })
        let panel = CountdownPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = CountdownHostingView(rootView: view)
        panel.setFrame(screen.frame, display: true)
        panel.onKey = { [weak self] key in
            switch key {
            case .skip: self?.skip()
            case .cancel: self?.cancel()
            }
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = Countdown.shared
                shared.model.remaining -= 1
                if shared.model.remaining <= 0 { shared.skip() }
            }
        }
    }

    private func end(_ go: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let finish = self.finish
        self.finish = nil
        finish?(go)
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var total = 3
    @Published var remaining = 3
}

/// Takes Space and Esc without activating Vision One.
private final class CountdownPanel: NSPanel {
    enum Key { case skip, cancel }
    var onKey: ((Key) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: onKey?(.skip) // Space, Return, Enter
        case 53: onKey?(.cancel) // Esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.cancel) }
}

/// A click on the panel works first time, though Vision One isn't active.
private final class CountdownHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let skip: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drained = 0.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture(perform: skip)

            ZStack {
                Circle().fill(Theme.paper)
                Circle().stroke(Theme.line, lineWidth: 4).padding(4)
                Circle()
                    .trim(from: 0, to: 1 - drained)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
                Text("\(max(1, model.remaining))")
                    .font(.system(size: 64, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 128, height: 128)
            .shadow(color: .black.opacity(0.35), radius: 15, y: 10)
            .onTapGesture(perform: skip)
            .accessibilityElement()
            .accessibilityLabel("Recording starts in \(model.remaining)")
            .accessibilityAddTraits(.updatesFrequently)

            VStack {
                Spacer()
                HStack(spacing: Theme.Space.sm) {
                    Text("Click or press Space to start now")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                    Button("Cancel", action: cancel)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Theme.paper, in: Capsule())
                .padding(.bottom, 48)
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            // The ring drains once over the whole countdown.
            if reduceMotion {
                drained = 0
            } else {
                withAnimation(.linear(duration: Double(model.total))) { drained = 1 }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.remaining)
    }
}
