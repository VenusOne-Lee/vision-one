import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import VisionOneKit

/// One preparation surface. Capture and source controls are shared with the
/// menu bar, so this never introduces a second set of recording choices.
struct RecordingPreparationView: View {
    @ObservedObject var model: HarnessModel
    var availableHeight: CGFloat? = nil
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var access = AccessCenter.shared
    @ObservedObject private var devices = CaptureDevices.shared
    @ObservedObject private var script = ScriptStore.shared
    @StateObject private var inputs = RecordingInputCheck()
    @State private var countdown = Countdown.shared.length
    @State private var showingScript = false
    @State private var starting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to record").textStyle(.title)
                    Text("Check your source, audio, camera and script.")
                        .textStyle(.body).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                IconButton("Close recording preparation", systemImage: "xmark") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    CapturePicker().environmentObject(recorder)
                    if let image = inputs.image {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit().frame(maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                            .accessibilityLabel("Snapshot of the selected recording source")
                    } else {
                        VStack(spacing: Theme.Space.sm) {
                            Image(systemName: "display").font(.system(size: 32))
                            Text("Source preview").textStyle(.bodyStrong)
                            Text(inputs.sourceStatus).textStyle(.caption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity)
                        .frame(height: 160).background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
                    }
                    HStack {
                        Text(inputs.sourceStatus).textStyle(.caption).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Refresh source preview") { Task { await inputs.preview(recorder.choice) } }
                            .buttonStyle(.secondary)
                            .disabled(!recorder.choice.mode.recordsScreen || starting)
                    }
                    SourcesList().environmentObject(recorder)
                    HStack {
                        Button(inputs.testing ? "Stop mic test" : "Test selected microphone") {
                            Task {
                                if inputs.testing { await inputs.stop() }
                                else { await inputs.testMicrophone(recorder.choice) }
                            }
                        }.buttonStyle(.secondary)
                        ProgressView(value: inputs.level).progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                            .accessibilityLabel("Microphone level")
                    }
                    if let message = inputs.problem {
                        Text(message).textStyle(.caption).foregroundStyle(Theme.error)
                    }
                    ForEach(requiredAccess, id: \.rawValue) { kind in
                        HStack {
                            Label(kind.title, systemImage: access.checklist.state(of: kind) == .granted ? "checkmark.circle" : "exclamationmark.circle")
                                .textStyle(.body)
                            Spacer()
                            if access.checklist.state(of: kind) != .granted {
                                Button(access.checklist.state(of: kind) == .notAsked ? "Allow…" : "Open System Settings…") {
                                    if access.checklist.state(of: kind) == .notAsked { access.request(kind) }
                                    else { access.openSettings(for: kind) }
                                }.buttonStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Label(script.script.map { "Script · \($0.lines.count) lines" } ?? "Add a script", systemImage: "doc.text")
                        Spacer()
                        Button("Edit script…") { showingScript = true }.buttonStyle(.secondary)
                    }
                    if !script.text.isEmpty {
                        Text(script.text).textStyle(.body).lineLimit(3).foregroundStyle(Theme.textMuted)
                        Toggle("Show teleprompter", isOn: $script.showsPrompter).toggleStyle(.ink)
                    }
                    HStack {
                        Button("Script Coach") { ScriptCoachWindowController.shared.show() }.buttonStyle(.quiet)
                        Button("Rehearse") { RehearseWindowController.shared.show() }.buttonStyle(.quiet)
                        Spacer()
                        Picker("Countdown", selection: $countdown) {
                            ForEach(CountdownLength.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(maxWidth: 200)
                    }
                }
            }
            .disabled(starting)
            Text("Saved on this Mac. The camera preview floats above your source when enabled. Recording adds a task with its original video and an on-device transcript when audio is available.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Button(starting ? "Preparing…" : "Start recording") {
                starting = true
                Task {
                    await inputs.stop()
                    guard starting else { return }
                    Countdown.shared.length = countdown
                    if let project = model.currentProject {
                        let choice = recorder.choice
                        let seconds = countdown.rawValue
                        await AIServices.shared.desk.updateProject(project.id) {
                            var defaults = $0.mediaDefaults ?? ProjectMediaDefaults()
                            defaults.captureChoice = choice
                            defaults.countdownSeconds = seconds
                            $0.mediaDefaults = defaults
                        }
                    }
                    guard starting else { return }
                    // Close first so preparation never sits over the source.
                    starting = false
                    dismiss()
                    await recorder.record()
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
            .disabled(starting || recorder.phase.isBusy || recorder.phase.isLive || recorder.choice.missingStep != nil || !permissionsReady)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Space.lg)
        .frame(width: min(660, (NSScreen.main?.visibleFrame.width ?? 900) - 80),
               height: min(760, max(380, availableHeight.map { $0 - 48 } ?? ((NSScreen.main?.visibleFrame.height ?? 900) - 120))))
        .background(Theme.canvas).foregroundStyle(Theme.text).themed()
        .sheet(isPresented: $showingScript) { ScriptSheet(store: script) }
        .task {
            guard !model.isFixture else { return }
            if let saved = model.currentProject?.mediaDefaults {
                if let choice = saved.captureChoice { recorder.choice = choice }
                if let seconds = saved.countdownSeconds { countdown = CountdownLength(saved: seconds) }
            }
            access.refresh(); script.reload(); await inputs.preview(recorder.choice)
        }
        .onChange(of: recorder.choice) { _, _ in
            inputs.cancel()
            Task { await inputs.preview(recorder.choice) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in access.refresh() }
        .onDisappear { starting = false; inputs.cancel(); inputs.cancelPreview() }
    }

    private var requiredAccess: [AccessKind] {
        var kinds: [AccessKind] = recorder.choice.mode.recordsScreen ? [.screen] : [.camera]
        if recorder.choice.includeMicrophone { kinds.append(.microphone) }
        if recorder.choice.mode.recordsScreen, devices.cameraChoice != .off { kinds.append(.camera) }
        return kinds
    }
    private var permissionsReady: Bool {
        requiredAccess.allSatisfy { access.checklist.state(of: $0) == .granted }
    }
}

@MainActor
final class RecordingInputCheck: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var sourceStatus = "Source preview has not been loaded."
    @Published private(set) var level = 0.0
    @Published private(set) var testing = false
    @Published private(set) var problem: String?
    private var probe: (any PreparationMicSession)?
    private let microphoneID: @MainActor (CaptureChoice) -> String?
    private let hasMicrophoneAccess: @MainActor () -> Bool
    private let makeProbe: @MainActor (@escaping @Sendable (Double) -> Void) -> any PreparationMicSession

    init(microphoneID: @escaping @MainActor (CaptureChoice) -> String? = { Microphones.shared.resolved(for: $0)?.id },
         hasAccess: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         makeProbe: @escaping @MainActor (@escaping @Sendable (Double) -> Void) -> any PreparationMicSession = { PreparationMicProbe(peak: $0) }) {
        self.microphoneID = microphoneID
        self.hasMicrophoneAccess = hasAccess
        self.makeProbe = makeProbe
    }
    private var previewGeneration = 0
    private var micGeneration = 0

    func preview(_ choice: CaptureChoice) async {
        previewGeneration += 1
        let generation = previewGeneration
        image = nil
        guard choice.mode.recordsScreen else { sourceStatus = "Camera only. Check the camera and microphone below."; return }
        guard choice.missingStep == nil else { sourceStatus = "Choose a source to preview."; return }
        guard AccessCenter.shared.checklist.state(of: .screen) == .granted else {
            sourceStatus = "Allow Screen Recording to preview this source."; return
        }
        sourceStatus = "Loading source snapshot…"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let target = try CaptureTarget.resolve(choice, in: content)
            let config = SCStreamConfiguration()
            config.width = target.width
            config.height = target.height
            if let rect = target.sourceRect { config.sourceRect = rect }
            let captured = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: config)
            guard generation == previewGeneration else { return }
            image = captured
            sourceStatus = "Selected source · \(target.width) × \(target.height) · snapshot"
        } catch {
            guard generation == previewGeneration else { return }
            sourceStatus = "Couldn't preview this source. Choose it again or refresh."
        }
    }

    func cancelPreview() { previewGeneration += 1 }

    func testMicrophone(_ choice: CaptureChoice) async {
        // Establish ownership before the first suspension. Stop, another test,
        // a source change, and sheet dismissal revoke this generation at once.
        micGeneration += 1
        let generation = micGeneration
        let old = probe
        probe = nil
        testing = false
        level = 0
        await old?.stop()
        guard generation == micGeneration else { return }
        problem = nil
        guard choice.includeMicrophone else { problem = "Turn on Microphone to test it."; return }
        guard hasMicrophoneAccess() else {
            problem = "Allow Microphone access below, then test again."; return
        }
        guard let id = microphoneID(choice) else { problem = "No microphone is connected."; return }
        let next = makeProbe { [weak self] peak in
            Task { @MainActor in
                guard let self, generation == self.micGeneration, self.testing else { return }
                self.level = min(1, max(0, (MicLevelMeter.decibels(peak) + 60) / 60))
            }
        }
        probe = next
        do {
            try await next.start(id)
            guard generation == micGeneration, probe === next else { await next.stop(); return }
            testing = true
        } catch {
            guard generation == micGeneration else { await next.stop(); return }
            problem = "Couldn't test this microphone: \(error.localizedDescription)"
            await stop()
        }
    }

    /// Synchronous invalidation prevents callbacks queued before dismissal from
    /// changing any UI, even before the session queue has finished draining.
    func cancel() {
        micGeneration += 1
        let old = probe
        probe = nil
        testing = false
        level = 0
        Task { await old?.stop() }
    }

    func stop() async {
        micGeneration += 1
        let old = probe
        probe = nil
        testing = false
        level = 0
        await old?.stop()
    }

}

/// All session work stays off the main queue. Nothing is recorded to disk.
protocol PreparationMicSession: AnyObject {
    func start(_ id: String) async throws
    func stop() async
}

final class PreparationMicProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, PreparationMicSession, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VisionOne.preparation-mic")
    private let peak: @Sendable (Double) -> Void
    init(peak: @escaping @Sendable (Double) -> Void) { self.peak = peak }

    func start(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = AVCaptureDevice(uniqueID: id) else { throw CocoaError(.fileReadNoSuchFile) }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in session.stopRunning(); continuation.resume() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let value = AudioSamples.peak(of: buffer) { peak(value) }
    }
}
