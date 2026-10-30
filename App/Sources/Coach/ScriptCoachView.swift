import AppKit
import SwiftUI
import VisionOneKit

/// The script coach's state: the report on the script, dismissed flags,
/// and model rewrites.
@MainActor
final class ScriptCoachModel: ObservableObject {
    let coach = CoachServices.shared
    @Published private(set) var report = ScriptReport(flags: [], length: ScriptLength(seconds: 0, wordsPerMinute: 150, target: nil))
    @Published private(set) var dismissed = Set<String>()
    @Published private(set) var rewriting = false
    @Published var problem: String?
    let player = SpeechPlayer()
    private var pending: Task<Void, Never>?

    init(learnPace: Bool = true) {
        recheck()
        if learnPace { coach.learnPace() }
    }

    var flags: [ScriptFlag] { report.flags.filter { !dismissed.contains($0.id) } }

    /// Re-reads the script a moment after typing stops.
    func scriptChanged() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            recheck()
        }
    }

    func recheck() {
        report = ScriptCoach().check(coach.script, pace: coach.pace, target: coach.targetLength)
    }

    func apply(_ flag: ScriptFlag) {
        coach.scriptText = coach.script.applying(flag).text
        recheck()
    }

    func dismiss(_ flag: ScriptFlag) {
        dismissed.insert(flag.id)
    }

    /// Asks the ladder (on this Mac first) for easier ways to say the flagged lines.
    func suggestRewrites() {
        guard let request = ScriptCoach().rewriteRequest(coach.script, flags: flags, tone: coach.tone) else { return }
        guard !rewriting else { return }
        let requestedText = coach.scriptText
        rewriting = true
        problem = nil
        let ladder = AIServices.shared.ladder()
        Task {
            defer { rewriting = false }
            do {
                let rewrites = try await ladder.complete(request).decode([ScriptCoach.Rewrite].self)
                guard coach.scriptText == requestedText else {
                    problem = "Your script changed while the coach was thinking. Ask again for the current version."
                    return
                }
                let updated = ScriptCoach().applying(rewrites, to: report, script: coach.script)
                guard updated.flags != report.flags else {
                    problem = "The coach returned no usable changes for these lines. Try again, or edit the script yourself."
                    return
                }
                report = updated
            } catch {
                problem = CoachServices.message(for: error)
            }
        }
    }

    var needsRewrite: Bool { flags.contains { $0.suggestion == nil } }

    func hear() {
        if player.isPlaying { player.stop(); return }
        player.play(coach.script, tone: coach.tone, flags: flags, coach: coach)
    }

    /// Hands the script to the prompter and starts recording.
    func record() {
        player.stop()
        UserDefaults.standard.set(coach.scriptText, forKey: CoachServices.scriptKey)
        ScriptCoachWindowController.shared.close()
        ScriptStore.shared.reload()
        ScriptStore.shared.showsPrompter = true
        EditorWindowController.shared.show()
        HarnessModel.shared.preparingRecording = true
    }
}

/// Before you record: write or paste the script on the left, the coach's
/// read on the right. The divider drags; both sides fold to fit.
struct ScriptCoachView: View {
    @ObservedObject var model: ScriptCoachModel
    @Environment(\.workspaceRender) private var workspaceRender
    @ObservedObject private var coach = CoachServices.shared
    @ObservedObject private var player: SpeechPlayer

    init(model: ScriptCoachModel) {
        self.model = model
        self._player = ObservedObject(wrappedValue: model.player)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            HSplitView {
                editor
                    .frame(minWidth: 320, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                coachPanel
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .task { if !workspaceRender { await coach.refresh() } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Script coach").textStyle(.title)
            Text(coach.pace.isLearned ? "Knows your pace from \(coach.pace.takes) take\(coach.pace.takes == 1 ? "" : "s")" : "On this Mac · free")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            SegmentedTabs(selection: $coach.tone, options: DeliveryTone.allCases) { $0.title }
                .fixedSize()
                .help("How it should sound: sets the reading and the rewrites")
            Button("Rehearse") { RehearseWindowController.shared.show() }
                .buttonStyle(.secondary)
                .disabled(coach.script.isEmpty)
                .help("A practice run with live meters. Not saved as a take.")
            Button("Record with the script") { model.record() }
                .buttonStyle(.primary)
                .disabled(coach.script.isEmpty)
                .help("Checks source and audio before recording with the prompter")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: Theme.Size.toolbar)
        .background(Theme.paper)
    }

    // MARK: Script

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("SCRIPT").textStyle(.label).foregroundStyle(Theme.textMuted)
                Spacer()
                Text("\(coach.script.wordCount) words").textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
            if player.isPlaying || player.isLoading, !player.words.isEmpty {
                ScrollView {
                    readingText
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(Theme.Space.sm)
                }
            } else {
                TextEditor(text: $coach.scriptText)
                    .font(Font(Theme.transcriptFont(size: 16) as CTFont))
                    .scrollContentBackground(.hidden)
                    .onChange(of: coach.scriptText) { model.scriptChanged() }
                    .overlay(alignment: .topLeading) {
                        if coach.scriptText.isEmpty {
                            Text("Paste or write what you'll say. Add [pause] or [slower] where you want a beat.")
                                .font(Font(Theme.transcriptFont(size: 16) as CTFont))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.top, 1).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .panelStyle()
        .padding(Theme.Space.md)
    }

    /// The script while it's read aloud, the current word underlined in ink.
    private var readingText: some View {
        let words = player.words
        let current = player.currentWord
        return words.indices.reduce(Text("")) { text, i in
            let word = Text(words[i] + " ")
            return text + (i == current ? word.underline().bold() : word.foregroundColor(i < (current ?? 0) ? Theme.text : Theme.textMuted))
        }
        .font(Font(Theme.transcriptFont(size: 16) as CTFont))
        .lineSpacing(4)
    }

    // MARK: Coach

    private var coachPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                lengthCard
                hearCard
                CollapsibleSection("Coach's notes", id: "coach.flags",
                                   summary: model.flags.isEmpty ? "All clear" : "\(model.flags.count) to look at") {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        if model.flags.isEmpty {
                            Text(coach.script.isEmpty ? "Write a script and the coach reads it like a director."
                                 : "Nothing hard to say. Rehearse it once, then record.")
                                .textStyle(.body).foregroundStyle(Theme.textMuted)
                        }
                        ForEach(model.flags) { flag in flagCard(flag) }
                        if model.needsRewrite {
                            Button(model.rewriting ? "Thinking…" : "Suggest rewrites") { model.suggestRewrites() }
                                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                                .disabled(model.rewriting)
                                .help("Uses the AI ladder: Apple's model on this Mac first, and asks before anything leaves it")
                        }
                        if let problem = model.problem { Notice(.error, lead: problem) }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.canvas)
    }

    private var lengthCard: some View {
        let length = model.report.length
        let target = length.target
        let maxSeconds = max(90, (target?.upperBound ?? 60) * 1.5, length.seconds * 1.1)
        return CoachGauge(label: "Length", value: length.text, unit: coach.pace.label,
                          position: coach.script.isEmpty ? nil : length.seconds / maxSeconds,
                          band: target.map { ($0.lowerBound / maxSeconds)...($0.upperBound / maxSeconds) } ?? 0...0,
                          zone: length.fit == .short ? .low : length.fit == .long ? .high : length.fit == .fits ? .inBand : .unknown)
    }

    private var hearCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("HEAR IT FIRST").textStyle(.label).foregroundStyle(Theme.textMuted)
                Spacer()
                Tag(coach.elevenLabsReady ? "ElevenLabs" : "On this Mac")
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    model.hear()
                } label: {
                    Label(player.isPlaying ? "Stop" : (player.isLoading ? "Reading…" : "Play"),
                          systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.primary)
                .disabled(coach.script.isEmpty || player.isLoading)
                if coach.elevenLabsReady, !coach.voices.isEmpty {
                    Picker("Voice", selection: $coach.voiceID) {
                        ForEach(coach.voices) { voice in
                            Text(voice.summary.isEmpty ? voice.name : "\(voice.name) · \(voice.summary)").tag(voice.voiceID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            Text(coach.elevenLabsReady
                 ? "Only the script's words are sent, never your recordings. \(coach.elevenLabsNote)"
                 : "A free Apple voice reads it. \(coach.elevenLabsNote)")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = player.problem ?? coach.problem { Notice(.error, lead: problem) }
        }
        .panelStyle()
    }

    private func flagCard(_ flag: ScriptFlag) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Coach · \(flag.title.lowercased())").textStyle(.caption).fontWeight(.medium).foregroundStyle(Theme.textMuted)
                Spacer()
                Button {
                    model.dismiss(flag)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Leave it as it is")
                .accessibilityLabel("Leave it as it is")
            }
            Text(flag.detail).textStyle(.body).fixedSize(horizontal: false, vertical: true)
            if let suggestion = flag.suggestion {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Text("“\(suggestion)”")
                        .font(Font(Theme.transcriptFont(size: 14) as CTFont))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Use it") { model.apply(flag) }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                }
            }
        }
        .padding(Theme.Space.sm + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
        .statusOutline(.proposed)
    }
}

@MainActor
final class ScriptCoachWindowController: NSObject {
    static let shared = ScriptCoachWindowController()
    private var window: NSWindow?
    private lazy var model = ScriptCoachModel()

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Script Coach"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScriptCoachView(model: model))
            window.minSize = NSSize(width: 640, height: 460)
            window.setFrameAutosaveName("VisionOneScriptCoachWindow")
            // Kept out of recordings, like every Vision One window.
            window.sharingType = .none
            window.center()
            self.window = window
        }
        model.recheck()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}
