import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import VisionOneKit

/// Ready to record, as the task page's review column: what to capture,
/// a snapshot of it, mic, system audio, camera, the script, then one
/// Start recording. Capture and source controls are shared with the menu
/// bar, so this never introduces a second set of recording choices.
struct RecordingPreparationView: View {
    @ObservedObject var model: HarnessModel
    var availableHeight: CGFloat? = nil
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var access = AccessCenter.shared
    @ObservedObject private var devices = CaptureDevices.shared
    @ObservedObject private var microphones = Microphones.shared
    @ObservedObject private var script = ScriptStore.shared
    @StateObject private var inputs = RecordingInputCheck()
    @State private var countdown = Countdown.shared.length
    @State private var showingScript = false
    @State private var showingScriptText = true
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ready to record").font(.custom(BundledFont.sansBold, size: 28))
                            Text("Choose what to capture and check your audio, camera, and script.")
                                .font(.custom(BundledFont.sansRegular, size: 14))
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        IconButton("Close recording setup", systemImage: "xmark", shortcut: "Esc") { close() }
                    }
                    SegmentBar(selection: $recorder.choice.mode, options: modes,
                               icon: { $0.symbol }) { $0.title }
                    CapturePicker(showsModeSwitch: false).environmentObject(recorder)
                    preview
                    sourceRows
                    if let message = inputs.problem {
                        Text(message).textStyle(.caption).foregroundStyle(Theme.error)
                    }
                    ForEach(requiredAccess.filter { access.checklist.state(of: $0) != .granted }, id: \.rawValue) { kind in
                        HStack {
                            Label("\(kind.title) needs your OK", systemImage: "exclamationmark.circle").textStyle(.body)
                            Spacer()
                            // One button either way: Allow the first time;
                            // once off, Fix clears Vision One's old entry
                            // (a switch that looks on but does nothing) and
                            // asks again.
                            Button(access.checklist.state(of: kind) == .notAsked ? "Allow…" : "Fix…") {
                                access.request(kind)
                            }.buttonStyle(.secondary)
                        }
                        .padding(Theme.Space.sm + 4)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    }
                }
                .padding(Theme.Space.lg)
            }
            .disabled(starting)
            VStack(spacing: Theme.Space.sm) {
                Button(action: startRecording) {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.onButton).frame(width: 14, height: 14)
                        Text(starting ? "Preparing…" : "Start recording")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(WideButtonStyle(kind: .primary, height: 46))
                .disabled(starting || recorder.phase.isBusy || recorder.phase.isLive || recorder.choice.missingStep != nil || !permissionsReady)
                .keyboardShortcut(.defaultAction)
                Menu {
                    ForEach(CountdownLength.allCases, id: \.self) { length in
                        Button { countdown = length } label: {
                            MenuCheck(length == .off ? "No countdown" : "\(length.rawValue) second countdown", isOn: countdown == length)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "timer")
                        Text(countdown == .off ? "No countdown" : "\(countdown.rawValue) second countdown")
                    }
                    .font(.custom(BundledFont.sansSemiBold, size: 15))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.lineStrong, lineWidth: Theme.Stroke.hairline))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Countdown before recording starts")
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
        }
        .background(Theme.paper).foregroundStyle(Theme.text)
        .sheet(isPresented: $showingScript) { ScriptSheet(store: script) }
        .task {
            guard !model.isFixture else { return }
            if let saved = model.currentProject?.mediaDefaults {
                if let choice = saved.captureChoice { recorder.choice = choice }
                if let seconds = saved.countdownSeconds { countdown = CountdownLength(saved: seconds) }
            }
            access.refresh(); script.reload(); microphones.refresh(); await inputs.preview(recorder.choice)
        }
        .onChange(of: recorder.choice) { _, _ in
            inputs.cancel()
            Task { await inputs.preview(recorder.choice) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if !model.isFixture { access.refresh() } }
        .onDisappear { starting = false; inputs.cancel(); inputs.cancelPreview() }
    }

    private var modes: [CaptureMode] {
        recorder.choice.mode == .camera ? CaptureMode.allCases : [.screen, .window, .area]
    }

    private func close() {
        model.preparingRecording = false
    }

    @ViewBuilder
    private var preview: some View {
        if let image = inputs.image {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .accessibilityLabel("Snapshot of the selected recording source")
        } else {
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: recorder.choice.mode.symbol).font(.system(size: 30))
                Text(inputs.sourceStatus).textStyle(.body).multilineTextAlignment(.center)
                if recorder.choice.mode.recordsScreen {
                    Button("Refresh preview") { Task { await inputs.preview(recorder.choice) } }
                        .buttonStyle(.secondary)
                        .disabled(starting)
                }
            }
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
    }

    /// Microphone with its level, system audio, camera and the script, as
    /// one grouped card.
    private var sourceRows: some View {
        VStack(spacing: 0) {
            setupRow(icon: "mic", title: "Microphone", detail: micName) {
                Button {
                    Task {
                        if inputs.testing { await inputs.stop() } else { await inputs.testMicrophone(recorder.choice) }
                    }
                } label: {
                    LevelBars(level: inputs.level, active: inputs.testing)
                }
                .buttonStyle(.plain)
                .help(inputs.testing ? "Stop the mic test" : "Test the microphone")
                .accessibilityLabel(inputs.testing ? "Stop mic test" : "Test microphone")
                Toggle("", isOn: $recorder.choice.includeMicrophone).labelsHidden().toggleStyle(.ink)
                    .accessibilityLabel("Microphone")
                micMenu
            }
            divider
            setupRow(icon: "speaker.wave.2", title: "System audio",
                     detail: recorder.choice.includeSystemSound ? "On" : "Off") {
                Toggle("", isOn: $recorder.choice.includeSystemSound).labelsHidden().toggleStyle(.ink)
                    .accessibilityLabel("System audio")
            }
            if recorder.choice.mode.recordsScreen {
                divider
                setupRow(icon: "web.camera", title: "Camera", detail: cameraName) {
                    Toggle("", isOn: Binding(get: { devices.cameraChoice != .off },
                                                   set: { devices.cameraChoice = $0 ? .auto : .off }))
                        .labelsHidden().toggleStyle(.ink)
                        .accessibilityLabel("Camera")
                    cameraMenu
                }
                if devices.cameraChoice != .off && !model.isFixture {
                    BackgroundRow().padding(.horizontal, Theme.Space.md).padding(.bottom, Theme.Space.sm)
                }
            }
            divider
            if !model.isFixture {
                SourcesRow(devices: devices).padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                divider
            }
            scriptSection
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { showingScriptText.toggle() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text").font(.system(size: 17)).frame(width: 26)
                    Text("Script (teleprompter)").font(.custom(BundledFont.sansMedium, size: 14))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showingScriptText ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showingScriptText {
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    Text(script.text.isEmpty ? "No script yet. Add one to read from the teleprompter while you record." : script.text)
                        .font(Font(Theme.transcriptFont(size: 15)).italic())
                        .foregroundStyle(script.text.isEmpty ? Theme.textMuted : Theme.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Edit script…") { showingScript = true }
                        Toggle("Show teleprompter", isOn: $script.showsPrompter)
                        Divider()
                        Button("Script Coach…") { ScriptCoachWindowController.shared.show() }
                        Button("Rehearse…") { RehearseWindowController.shared.show() }
                    } label: {
                        Label(script.text.isEmpty ? "Add script" : "Edit script", systemImage: "pencil")
                            .font(.custom(BundledFont.sansMedium, size: 13))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                    } primaryAction: { showingScript = true }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                .padding(Theme.Space.sm + 4)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
        .padding(Theme.Space.md)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline).padding(.leading, 56)
    }

    private func setupRow<Trailing: View>(icon: String, title: String, detail: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.custom(BundledFont.sansMedium, size: 14))
                Text(detail).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.sm)
            trailing()
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 12)
    }

    private var micName: String {
        guard recorder.choice.includeMicrophone else { return "Off" }
        if model.isFixture { return "MacBook microphone" }
        return microphones.resolved(for: recorder.choice)?.name ?? "No mic found"
    }

    private var cameraName: String {
        if devices.cameraChoice == .off { return "Off" }
        if model.isFixture { return "FaceTime camera" }
        if devices.cameras.isEmpty { return "No camera found" }
        return devices.cameraToRecord()?.localizedName ?? "Automatic"
    }

    private var micMenu: some View {
        Menu {
            Button { recorder.choice.microphoneID = nil } label: { MenuCheck("Automatic", isOn: recorder.choice.microphoneID == nil) }
            Divider()
            ForEach(microphones.options) { option in
                Button { recorder.choice.microphoneID = option.id } label: {
                    MenuCheck(option.dropsHeadphonesToCallQuality ? "\(option.name) (call quality)" : option.name,
                              isOn: recorder.choice.microphoneID == option.id)
                }
            }
        } label: { chevron }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Choose microphone")
    }

    private var cameraMenu: some View {
        Menu {
            Button { devices.cameraChoice = .auto } label: { MenuCheck("Automatic", isOn: devices.cameraChoice == .auto) }
            Divider()
            ForEach(devices.pickerCameras) { camera in
                Button { devices.cameraChoice = .device(id: camera.id) } label: {
                    MenuCheck(camera.name, isOn: devices.cameraChoice == .device(id: camera.id))
                }
            }
        } label: { chevron }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Choose camera")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
    }

    private func startRecording() {
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
            close()
            await recorder.record()
        }
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

/// A row of thin bars lit up to the mic level; faint until you test.
struct LevelBars: View {
    let level: Double
    let active: Bool
    private let count = 28

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let lit = active && Double(index) / Double(count) < level
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? Theme.text : Theme.lineStrong)
                    .frame(width: 2.5, height: 12)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .accessibilityValue(active ? "\(Int(level * 100)) percent" : "Not testing")
    }
}

/// The thread beside Ready to record: what Vision One set up, and what
/// the recording will make (dashed: it hasn't happened yet).
struct RecordingThreadSummary: View {
    @ObservedObject var model: HarnessModel
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var devices = CaptureDevices.shared
    @ObservedObject private var microphones = Microphones.shared
    @ObservedObject private var script = ScriptStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                AgentReply(agent: .producer, text: "Everything is set up on the right. Check the source, audio, camera and script, then start recording.")
                VStack(spacing: 0) {
                    SuggestionRow(icon: recorder.choice.mode.symbol, title: captureTitle, detail: captureDetail,
                                  count: "", proposed: false) {}
                    rowDivider
                    SuggestionRow(icon: "mic", title: "Microphone",
                                  detail: !recorder.choice.includeMicrophone ? "Off"
                                      : model.isFixture ? "MacBook microphone"
                                      : microphones.resolved(for: recorder.choice)?.name ?? "No mic found",
                                  count: "", proposed: false) {}
                    if recorder.choice.mode.recordsScreen {
                        rowDivider
                        SuggestionRow(icon: "web.camera", title: "Camera",
                                      detail: devices.cameraChoice == .off ? "Off"
                                          : model.isFixture ? "FaceTime camera" : devices.cameraToRecord()?.localizedName ?? "Automatic",
                                      count: "", proposed: false) {}
                    }
                    rowDivider
                    SuggestionRow(icon: "doc.text", title: script.script == nil ? "No script" : "Use script",
                                  detail: script.script.map { "\($0.lines.count) lines  ·  Teleprompter \(script.showsPrompter ? "on" : "off")" }
                                      ?? "Record freely",
                                  count: "", proposed: false) {}
                }
                .padding(.vertical, 4)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                .allowsHitTesting(false)
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "film").font(.system(size: 18)).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording will create").font(.custom(BundledFont.sansMedium, size: 14))
                        Text("A new version with your screen, camera, audio, transcript, and captions. Saved on this Mac.")
                            .textStyle(.body).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dash)))
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline).padding(.leading, 56)
    }

    private var captureTitle: String {
        switch recorder.choice.mode {
        case .screen: return "Capture screen"
        case .window: return "Capture window"
        case .area: return "Capture area"
        case .camera: return "Camera only"
        }
    }

    private var captureDetail: String {
        switch recorder.choice.mode {
        case .screen: return NSScreen.main?.localizedName ?? "Main display"
        case .window: return recorder.choice.windowID == nil ? "Choose a window" : "Window selected"
        case .area: return recorder.choice.area.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Choose an area"
        case .camera: return "Just you and your mic"
        }
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
