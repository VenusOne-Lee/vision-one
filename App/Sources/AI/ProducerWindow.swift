import AppKit
import AVFoundation
import IOKit.ps
import SwiftUI
import VisionOneKit

/// "Before you record": pick what it's for, see the Producer's pre-flight
/// notes, and optionally get talking points. The choice carries over to
/// the next take's agents.
@MainActor
final class ProducerModel: ObservableObject {
    @Published var purposeID: String {
        didSet {
            UserDefaults.standard.set(purposeID, forKey: "ai.nextPurpose")
            recheck()
        }
    }
    @Published private(set) var notes: [ProducerAgent.Note] = []
    @Published var topic = ""
    @Published private(set) var outline: ProducerAgent.Outline?
    @Published private(set) var run: AgentsModel.Run = .idle

    init() {
        purposeID = UserDefaults.standard.string(forKey: "ai.nextPurpose") ?? Purpose.demo.id
        recheck()
    }

    var purpose: Purpose { Purpose.named(purposeID) ?? .demo }

    func recheck() {
        notes = ProducerAgent.check(Self.situation(purposeID: purposeID, choice: ScreenRecorder.shared.choice))
    }

    func suggestOutline() {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return }
        run = .running("Thinking of talking points…")
        let agent = ProducerAgent(ladder: AIServices.shared.ladder())
        Task {
            do {
                let presetName = UserDefaults.standard.string(forKey: "ai.preset")
                let preset = PresetLibrary.standard.all().first { $0.name == presetName }
                outline = try await agent.outline(about: topic, brief: purpose.brief(preset: preset))
                run = .idle
            } catch {
                run = .failed(AgentsModel.message(for: error))
            }
        }
    }

    /// What the Mac can tell us right now. Notifications stay unknown:
    /// macOS doesn't let apps read the Focus state.
    static func situation(purposeID: String, choice: CaptureChoice) -> ProducerAgent.Situation {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let screen = NSScreen.main.map { ($0.frame.width * $0.backingScaleFactor, $0.frame.height * $0.backingScaleFactor) }
        let battery = batteryState()
        return ProducerAgent.Situation(
            micName: choice.includeMicrophone ? AVCaptureDevice.default(for: .audio)?.localizedName : nil,
            systemAudioOn: choice.includeSystemSound,
            // The camera bubble isn't built yet, so the camera is off.
            cameraOn: false,
            screenWidth: Int(screen?.0 ?? 1920), screenHeight: Int(screen?.1 ?? 1080),
            freeDiskGB: Double(free) / 1_000_000_000,
            onBattery: battery.onBattery, batteryPercent: battery.percent,
            notificationsSilenced: nil, purposeID: purposeID)
    }

    static func batteryState() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, nil)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let max = description[kIOPSMaxCapacityKey] as? Int
            let percent = current.flatMap { c in max.map { m in m > 0 ? c * 100 / m : c } }
            return (onBattery, percent)
        }
        return (false, nil)
    }
}

struct ProducerView: View {
    @ObservedObject var model: ProducerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                PurposePicker(selected: model.purposeID) { model.purposeID = $0.id }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack {
                        Text("BEFORE YOU RECORD").font(.system(size: 11, weight: .medium)).tracking(0.6)
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Check again") { model.recheck() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    if model.notes.isEmpty {
                        Text("All set. Press ⌘⇧R when you're ready.").font(.system(size: 13))
                    }
                    ForEach(model.notes) { note in
                        HStack(alignment: .top, spacing: 10) {
                            Text(note.level == .fix ? "FIX" : "TIP")
                                .font(.system(size: 10, weight: .bold)).tracking(0.6)
                                .foregroundStyle(note.level == .fix ? Theme.error : Theme.textMuted)
                                .frame(width: 26, alignment: .leading)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).font(.system(size: 13, weight: .semibold))
                                Text(note.detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(note.level == .fix ? Theme.errorSoft : Theme.canvas,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("TALKING POINTS").font(.system(size: 11, weight: .medium)).tracking(0.6)
                        .foregroundStyle(Theme.textMuted)
                    HStack(spacing: Theme.Space.sm) {
                        TextField("What are you showing? e.g. how to export for WhatsApp", text: $model.topic)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.suggestOutline() }
                        Button("Suggest") { model.suggestOutline() }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    RunStatus(run: model.run)
                    if let outline = model.outline {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(outline.hook).font(.system(size: 14, weight: .semibold))
                            ForEach(Array(outline.points.enumerated()), id: \.offset) { i, point in
                                Text("\(i + 1). \(point)").font(.system(size: 13))
                            }
                            Text(outline.payoff).font(.system(size: 13))
                            Text(outline.cta).font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .padding(Theme.Space.lg)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 480)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .themed()
    }
}

@MainActor
final class ProducerWindowController {
    static let shared = ProducerWindowController()
    private var window: NSWindow?
    private let model = ProducerModel()

    func show() {
        model.recheck()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Before you record"
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            window.setFrameAutosaveName("VisionOneProducer")
            window.contentViewController = NSHostingController(rootView: ProducerView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
