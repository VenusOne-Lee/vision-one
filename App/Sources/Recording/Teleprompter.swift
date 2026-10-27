import AppKit
import Combine
import SwiftUI
import VisionOneKit

/// The script, floating near the camera while you record. Like every
/// Vision One window it's left out of the capture. It follows your voice
/// (on-device) or scrolls at a steady pace; drag it anywhere, resize it
/// from its edges, and it opens where you left it.
@MainActor
final class Teleprompter {
    static let shared = Teleprompter()
    private var panel: NSPanel?
    private let model = TeleprompterModel()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Shows the script before the countdown, so the first line is
    /// already in view. Does nothing without a script or with the
    /// prompter turned off.
    func prepare(on screen: NSScreen) {
        let store = ScriptStore.shared
        store.reload()
        guard store.showsPrompter, let script = store.script else {
            hide()
            return
        }
        model.load(script)
        show(on: screen)
    }

    /// Recording has started: follow the voice, or scroll.
    func begin(withMicrophone: Bool) {
        guard panel != nil else { return }
        Task {
            let canFollow = withMicrophone && model.mode == .voice ? await ScriptVoice.prepare() : false
            guard panel != nil else { return }
            model.isFollowingVoice = canFollow
            if canFollow {
                ScriptVoice.shared.start { word in
                    Task { @MainActor in Teleprompter.shared.model.hear(word) }
                }
            } else {
                startScrolling()
            }
        }
        // A steady scroll waits while recording is paused.
        ScreenRecorder.shared.$pauses
            .map(\.isPaused)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] paused in
                guard let self, !self.model.isFollowingVoice, self.panel != nil else { return }
                if paused { self.stopScrolling() } else { self.startScrolling() }
            }
            .store(in: &cancellables)
    }

    var isShowing: Bool { panel != nil }

    func hide() {
        ScriptVoice.shared.stop()
        stopScrolling()
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func startScrolling() {
        stopScrolling()
        let interval = 60 / max(60, model.wordsPerMinute)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { Teleprompter.shared.model.advance() }
        }
    }

    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
    }

    private func show(on screen: NSScreen) {
        if panel == nil { makePanel(on: screen) }
        panel?.orderFrontRegardless()
    }

    private func makePanel(on screen: NSScreen) {
        let visible = screen.visibleFrame
        // Top centre, just under the menu bar: close to the camera, so
        // your eyes stay near the lens.
        let size = CGSize(width: min(640, visible.width - 40), height: 180)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8,
                           width: size.width, height: size.height)
        let panel = PrompterPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = CGSize(width: 320, height: 110)
        panel.contentView = PrompterHostingView(rootView: TeleprompterView(model: model))
        // Opens where it was left, if that's still on a screen.
        panel.setFrameAutosaveName("Teleprompter")
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrame(frame, display: false)
        }
        self.panel = panel
    }
}

private final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PrompterHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class TeleprompterModel: ObservableObject {
    enum Mode: String { case voice, scroll }
    enum TextSize: String, CaseIterable {
        case small, medium, large
        var points: CGFloat { self == .small ? 18 : self == .medium ? 24 : 32 }
        var title: String { rawValue.capitalized }
    }

    @Published private(set) var script = Script(text: "")
    @Published private(set) var follower = ScriptFollower(script: Script(text: ""))
    @Published var isFollowingVoice = false
    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "prompter.mode") }
    }
    @Published var textSize: TextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "prompter.textSize") }
    }
    /// For the steady scroll. 150 is a calm demo pace.
    @Published var wordsPerMinute: Double {
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "prompter.wpm") }
    }

    init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: "prompter.mode").flatMap(Mode.init(rawValue:)) ?? .voice
        textSize = defaults.string(forKey: "prompter.textSize").flatMap(TextSize.init(rawValue:)) ?? .medium
        let wpm = defaults.double(forKey: "prompter.wpm")
        wordsPerMinute = wpm > 0 ? wpm : 150
    }

    func load(_ script: Script) {
        self.script = script
        follower = ScriptFollower(script: script)
        isFollowingVoice = false
    }

    func hear(_ word: String) { follower.hear(word) }
    func advance() { follower.advance() }
    func restart() { follower.reset() }
}

private struct TeleprompterView: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.script.lines) { line in
                            lineText(line)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Room for the last line to reach the top.
                        Color.clear.frame(height: 120)
                    }
                }
                .onChange(of: model.follower.currentLine) { _, line in
                    guard let line else { return }
                    withAnimation(Theme.Motion.reduced ? nil : .easeOut(duration: Theme.Motion.medium)) {
                        proxy.scrollTo(max(0, line - 1), anchor: .top)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.text.opacity(0.9)))
        .themed()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Teleprompter. Not in the recording.")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(status)
                .textStyle(.monoSmall)
                .foregroundStyle(Theme.cutText)
            Spacer(minLength: 8)
            if let line = model.follower.currentLine {
                Text("Line \(line + 1) of \(model.script.lines.count)")
                    .textStyle(.monoSmall)
                    .foregroundStyle(Theme.cutText)
            }
            Menu {
                Picker("Follow", selection: $model.mode) {
                    Text("Follow my voice").tag(TeleprompterModel.Mode.voice)
                    Text("Scroll steadily").tag(TeleprompterModel.Mode.scroll)
                }
                Picker("Text size", selection: $model.textSize) {
                    ForEach(TeleprompterModel.TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Menu("Scroll speed") {
                    ForEach([120.0, 150.0, 180.0], id: \.self) { wpm in
                        Button { model.wordsPerMinute = wpm } label: {
                            if model.wordsPerMinute == wpm {
                                Label("\(Int(wpm)) words a minute", systemImage: "checkmark")
                            } else {
                                Text("\(Int(wpm)) words a minute")
                            }
                        }
                    }
                }
                Divider()
                Button("Back to the first line") { model.restart() }
                Button("Hide the teleprompter") { Teleprompter.shared.hide() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.paper)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Teleprompter settings")
            .accessibilityLabel("Teleprompter settings")
        }
    }

    private var status: String {
        let live = recorder.phase.isLive
        if !live { return "Not in the recording · starts with your take" }
        return model.isFollowingVoice ? "Not in the recording · following your voice" : "Not in the recording · scrolling"
    }

    /// Said words fade; the next word to say is underlined.
    private func lineText(_ line: ScriptLine) -> Text {
        let position = model.follower.position
        let words = model.follower.words
        let shown = line.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Shown words map onto script words in order; a piece with no
        // letters (a dash) looks like the word before it.
        var lineStart = 0
        if let first = words.firstIndex(where: { $0.line == line.id }) { lineStart = first }
        var result = Text("")
        var wordIndex = 0
        var previousSaid = false
        for (i, piece) in shown.enumerated() {
            var said = previousSaid
            var isNext = false
            if !Script.normalize(piece).isEmpty {
                let global = lineStart + wordIndex
                said = global < position
                isNext = global == position
                wordIndex += 1
            }
            previousSaid = said
            var text = Text(piece + (i < shown.count - 1 ? " " : ""))
                .foregroundColor(said ? Theme.cutText : Theme.paper)
            if isNext { text = text.underline(true, color: Theme.paper) }
            result = result + text
        }
        return result
            .font(TypeStyle.transcript.font(scale: model.textSize.points / TypeStyle.transcript.size))
    }
}
