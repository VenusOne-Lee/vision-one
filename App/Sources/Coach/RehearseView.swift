import AppKit
import SwiftUI
import VisionOneKit

/// Rehearse: the script big in the middle with the line you're on in
/// ink, live meters down the side, and afterwards three notes from the
/// coach. Practice runs are never saved as takes.
struct RehearseView: View {
    @ObservedObject var model: RehearseModel
    @ObservedObject var talk: CoachConversation
    @ObservedObject private var coach = CoachServices.shared
    @AppStorage("coach.rehearse.metersWidth") private var metersWidth: Double = 260

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            HSplitView {
                stage
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                side
                    .frame(minWidth: 220, idealWidth: metersWidth, maxWidth: 420, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                ScriptCoachWindowController.shared.show()
            } label: {
                Label("Script", systemImage: "chevron.left")
            }
            .buttonStyle(.quiet)
            StateChip(.proposed, model.onlyLine == nil ? "Practice · not saved" : "One line · not saved")
            Spacer(minLength: Theme.Space.sm)
            Tag(talk.isOpen ? "ElevenLabs" : "On this Mac")
            switch model.phase {
            case .running:
                Button("I'm done") { model.finish() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.space, modifiers: [])
            default:
                Button(model.phase == .ready ? "Start practice" : "Run again") { model.start() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.space, modifiers: [])
            }
            Button("Record for real") { recordForReal() }
                .buttonStyle(.primary)
                .help("Checks source and audio before recording with the prompter")
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: Theme.Size.toolbar)
        .background(Theme.paper)
    }

    private func recordForReal() {
        model.cancel()
        talk.stop()
        RehearseWindowController.shared.close()
        UserDefaults.standard.set(coach.scriptText, forKey: CoachServices.scriptKey)
        ScriptStore.shared.reload()
        ScriptStore.shared.showsPrompter = true
        EditorWindowController.shared.show()
        HarnessModel.shared.preparingRecording = true
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: Theme.Space.md) {
            if case let .failed(why) = model.phase {
                Notice(.error, lead: "Rehearse can't listen", detail: why)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(Font(Theme.transcriptFont(size: 24) as CTFont))
                                .foregroundStyle(isCurrent(line) ? Theme.text : Theme.textMuted)
                                .fontWeight(isCurrent(line) ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                .onChange(of: model.currentLine) {
                    guard let line = model.currentLine else { return }
                    withAnimation(Theme.Motion.reduced ? nil : Theme.Motion.move) { proxy.scrollTo(line, anchor: .center) }
                }
            }
            .panelStyle(padding: 0)
            if model.phase == .ready {
                Text("Press Space and say your script. The meters listen on this Mac; nothing is recorded as a take.")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.md)
    }

    private var lines: [ScriptLine] {
        model.phase == .ready ? coach.script.lines : model.script.lines
    }

    private func isCurrent(_ line: ScriptLine) -> Bool {
        model.phase == .running ? line.id == model.currentLine : true
    }

    // MARK: Side

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if model.phase == .notes, let review = model.review {
                    notes(review)
                    talkCard(review)
                } else {
                    meters
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.canvas)
    }

    private var meters: some View {
        let r = model.reading
        let t = model.targets
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(coach.meters) { meter in
                switch meter {
                case .pace:
                    CoachGauge(label: "Pace", value: r.pace.map { "\(Int($0.rounded()))" } ?? "–", unit: "words / min",
                               position: r.pace.map { scale($0, 60, 220) }, band: scale(t.pace, 60, 220),
                               zone: MeterZone.of(r.pace, in: t.pace))
                case .ums:
                    let allowed = max(1, t.umsPerMinute * max(1, model.elapsed / 60))
                    CoachGauge(label: "Ums", value: "\(r.ums)", unit: "this run",
                               position: model.phase == .running || r.ums > 0 ? min(1, Double(r.ums) / (allowed * 3)) : nil,
                               band: 0...(1.0 / 3), zone: Double(r.ums) > allowed ? .high : .inBand)
                case .energy:
                    CoachGauge(label: "Energy", value: r.energyLabel, position: r.energy, band: t.energy,
                               zone: MeterZone.of(r.energy, in: t.energy))
                case .pauses:
                    CoachGauge(label: "Pauses", value: r.pause.map { String(format: "%.1f s", $0) } ?? "–", unit: "average",
                               position: r.pause.map { scale($0, 0, 1.5) }, band: scale(t.pause, 0, 1.5),
                               zone: MeterZone.of(r.pause, in: t.pause))
                }
            }
            Menu("Meters") {
                ForEach(RehearsalMeter.allCases) { meter in
                    Toggle(meter.title, isOn: Binding(
                        get: { coach.meters.contains(meter) },
                        set: { on in
                            if on { coach.meters = RehearsalMeter.allCases.filter { coach.meters.contains($0) || $0 == meter } }
                            else if coach.meters.count > 1 { coach.meters.removeAll { $0 == meter } }
                        }))
                }
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
            .fixedSize()
            Text("Meters run on this Mac: speech recognition for words, pitch and loudness for energy. Nothing leaves your Mac unless you use Talk it through.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notes(_ review: RehearsalReview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("COACH'S NOTES").textStyle(.label).foregroundStyle(Theme.textMuted)
            ForEach(review.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.sm) {
                        Text(note.title).textStyle(.headline)
                        Spacer(minLength: 0)
                        Mono(Timecode.short(from: note.time), small: true).foregroundStyle(Theme.textMuted)
                        PlayMomentButton { model.play(from: note.time) }
                    }
                    Text(note.detail).textStyle(.body).fixedSize(horizontal: false, vertical: true)
                    if !note.isStrength, let line = note.line, model.onlyLine == nil {
                        Button("Run just that line") { model.start(line: line) }
                            .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    }
                }
                .padding(Theme.Space.sm + 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
                .statusOutline(note.isStrength ? .accepted : .proposed)
            }
        }
    }

    private func talkCard(_ review: RehearsalReview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("TALK IT THROUGH").textStyle(.label).foregroundStyle(Theme.textMuted)
                Spacer()
                Tag("ElevenLabs")
            }
            ForEach(talk.lines.suffix(4)) { line in
                Text(line.fromCoach ? "“\(line.text)”" : "You: \(line.text)")
                    .font(line.fromCoach ? Font(Theme.transcriptFont(size: 14) as CTFont) : .ds(.caption))
                    .foregroundStyle(line.fromCoach ? Theme.text : Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch talk.state {
            case .connecting:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Calling the coach…").textStyle(.caption) }
            case .listening, .coachSpeaking:
                HStack {
                    Text(talk.state == .listening ? "Listening. Just talk." : "Coach is talking. Talk over it to answer.")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("I'm done") { talk.stop() }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                }
            case let .failed(why):
                Notice(.error, lead: why)
                startTalkButton(review)
            default:
                startTalkButton(review)
            }
            Text(coach.elevenLabsReady
                 ? "A spoken back-and-forth about this run. Your mic streams to ElevenLabs only while it's open, after you say yes."
                 : coach.elevenLabsNote)
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }

    private func startTalkButton(_ review: RehearsalReview) -> some View {
        Button("Talk it through") { talk.start(script: model.script, review: review) }
            .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            .disabled(!coach.elevenLabsReady)
    }

    private func scale(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(1, max(0, (value - low) / (high - low)))
    }

    private func scale(_ band: ClosedRange<Double>, _ low: Double, _ high: Double) -> ClosedRange<Double> {
        scale(band.lowerBound, low, high)...max(scale(band.lowerBound, low, high), scale(band.upperBound, low, high))
    }
}

@MainActor
final class RehearseWindowController: NSObject, NSWindowDelegate {
    static let shared = RehearseWindowController()
    private var window: NSWindow?
    private let model = RehearseModel()
    private let talk = CoachConversation()

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Rehearse"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: RehearseView(model: model, talk: talk))
            window.minSize = NSSize(width: 680, height: 460)
            window.setFrameAutosaveName("VisionOneRehearseWindow")
            window.sharingType = .none
            window.delegate = self
            window.center()
            self.window = window
        }
        if model.phase != .running { model.cancel() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        talk.stop()
    }
}
