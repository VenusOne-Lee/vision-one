import AppKit
import AVFoundation
import ScreenCaptureKit
import VisionOneKit

/// Records a display, a window or an area into a take folder: screen video, system
/// sound and mic as separate tracks in a fragmented screen.mov, plus the
/// cursor log. Uses SCStream + AVAssetWriter rather than SCRecordingOutput
/// so the editor gets each source on its own track (see the research doc
/// linked in docs/RECORDER.md). Vision One's own windows are left out.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var lastTake: Take?
    /// Why an extra track (like a plugged-in iPhone's screen) is missing
    /// from the current take. The screen recording carries on without it.
    @Published private(set) var trackNotes: [String] = []
    /// Pauses in the current take, on the host clock. Nothing is written
    /// while paused; at stop they become accepted cuts in edits.json.
    @Published private(set) var pauses = PauseLog()
    /// True from pressing record until the countdown ends.
    @Published private(set) var isCountingDown = false
    /// Screen, window or area, and which sound to record. Saved so ⌘⇧R
    /// records the same way next launch.
    @Published var choice: CaptureChoice {
        didSet { UserDefaults.standard.set(try? choice.encoded(), forKey: Self.choiceKey) }
    }
    private static let choiceKey = "captureChoice"

    let library = TakeLibrary.standard

    private let captureQueue = DispatchQueue(label: "za.co.versionone.visionone.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var cursor: CursorLogger?
    private var take: Take?
    private let deviceTracks = DeviceTracks()
    /// Camera only: open from just before the countdown until the take
    /// ends, so the preview is live while counting down.
    private var cameraCapture: CameraOnlyCapture?
    private var cameraCaptureHasMic = false

    private override init() {
        choice = CaptureChoice.decoded(from: UserDefaults.standard.data(forKey: Self.choiceKey))
        super.init()
        lastTake = library.takes().first
    }

    /// The take being recorded, while live.
    var currentTake: Take? { phase.isLive ? take : nil }

    func toggle() async {
        if Countdown.shared.isRunning {
            // Pressing record again during the countdown starts at once.
            Countdown.shared.skip()
            return
        }
        switch phase {
        case .idle, .failed: await record()
        case .recording: await stop()
        case .preparing, .finishing: break
        }
    }

    /// What the record buttons and ⌘⇧R do: step Vision One's window aside,
    /// count down, then start. Cancelling the countdown brings the window
    /// back.
    func record() async {
        guard !phase.isBusy, !phase.isLive, !isCountingDown else { return }
        if choice.missingStep == .dragArea {
            chooseArea(thenRecord: true)
            return
        }
        if choice.missingStep == .pickWindow {
            phase = .failed(message: RecorderError.noWindowPicked.localizedDescription)
            return
        }
        // Without access there's nothing to count down to.
        let access = AccessCenter.shared
        access.refresh()
        if case .failed = phase { phase = .idle }
        if choice.mode == .camera {
            // Camera only needs no Screen Recording: open the camera now,
            // so you can frame yourself during the countdown.
            guard await openCameraOnly(choice) else { return }
        } else {
            guard access.checklist.canRecord else {
                SetupWindowController.shared.show()
                return
            }
        }
        MainWindowStepAside.hide()
        // The script shows during the countdown, so the first line is
        // ready to read.
        Teleprompter.shared.prepare(on: recordedScreen())
        isCountingDown = true
        let go = await Countdown.shared.run(on: recordedScreen())
        isCountingDown = false
        guard go else {
            Teleprompter.shared.hide()
            closeCameraOnly()
            MainWindowStepAside.restore()
            return
        }
        await start()
        if !phase.isLive {
            Teleprompter.shared.hide()
            closeCameraOnly()
            MainWindowStepAside.restore()
        }
    }

    /// Starts recording straight away, without the countdown. `override`
    /// records something else this once (an agent's app window) without
    /// changing the saved choice.
    func start(choosing override: CaptureChoice? = nil) async {
        guard !phase.isBusy, !phase.isLive else { return }
        let choice = override ?? self.choice

        if choice.mode == .camera {
            await startCameraOnly(choice)
            return
        }

        // Area mode with no area yet: drag one first, then record.
        if choice.missingStep == .dragArea {
            chooseArea(thenRecord: true)
            return
        }
        if choice.missingStep == .pickWindow {
            phase = .failed(message: RecorderError.noWindowPicked.localizedDescription)
            return
        }
        phase = .preparing

        // No dead end: without access, open the setup window instead.
        let access = AccessCenter.shared
        access.refresh()
        guard access.checklist.canRecord else {
            phase = .idle
            SetupWindowController.shared.show()
            return
        }
        // Ask for the mic the first time it's wanted, so the first take
        // isn't silently voiceless.
        if choice.includeMicrophone, access.checklist.state(of: .microphone) == .notAsked {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            access.refresh()
        }
        let withMicrophone = choice.includeMicrophone && access.checklist.state(of: .microphone) == .granted
        var notes: [String] = []
        if choice.includeMicrophone, !withMicrophone {
            notes.append("Recording without your voice. Turn on Microphone in Access.")
        }
        let withSystemSound = choice.includeSystemSound

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let target = try CaptureTarget.resolve(choice, in: content)

            let config = SCStreamConfiguration()
            config.width = target.width
            config.height = target.height
            if let sourceRect = target.sourceRect {
                config.sourceRect = sourceRect
            }
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6
            // v0.1 keeps the real cursor in the video and logs it too. When
            // smooth cursor and zooms land, we hide it and draw it at export.
            config.showsCursor = true
            config.capturesAudio = withSystemSound
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = withMicrophone
            // Never the default input blindly: if that's a Bluetooth headset,
            // recording from it drops the headphones to call quality, and
            // what you're listening to goes mono and muffled.
            if withMicrophone {
                let microphones = Microphones.shared
                microphones.refresh()
                config.microphoneCaptureDeviceID = microphones.resolved(for: choice)?.id
            }

            let take = try library.newTake()
            let writer = try TakeWriter(url: take.screenURL, width: target.width, height: target.height,
                                        includeSystemAudio: withSystemSound, includeMicrophone: withMicrophone)
            let cursor = CursorLogger(captureFrame: target.captureFrame)
            let sink = CaptureSink(writer: writer, meterMicrophone: withMicrophone) { [weak cursor] firstFrame in
                Task { @MainActor in
                    cursor?.setOrigin(firstFrame.seconds)
                    AgentSession.shared.setOrigin(firstFrame.seconds)
                    CameraBubble.shared.screenStarted(at: firstFrame.seconds)
                }
            }

            let stream = SCStream(filter: target.filter, configuration: config, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
            if withSystemSound {
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: captureQueue)
            }
            if withMicrophone {
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: captureQueue)
            }
            // The camera starts first, so it's ready when the screen's
            // first frame arrives and camera.json can line the two up.
            let cameraNote = CameraBubble.shared.startRecording(for: take, captureFrame: target.captureFrame)
            try await stream.startCapture()
            // Only once capture is running, so a failed start doesn't
            // leave the global mouse monitor behind.
            cursor.start()
            // Recording an agent: mark its clicks and typing too.
            AgentSession.shared.begin(captureFrame: target.captureFrame)
            let deviceNotes = await deviceTracks.start(for: take, devices: .shared)
            trackNotes = notes + deviceNotes
            if let cameraNote { trackNotes.append(cameraNote) }

            self.stream = stream
            self.sink = sink
            self.cursor = cursor
            self.take = take
            if choice.mode == .area {
                RegionOutline.shared.show(around: target.captureFrame)
            }
            pauses = PauseLog()
            MicMonitor.shared.begin(withMicrophone: withMicrophone)
            // Recorded from a script: keep it with the take, so the best
            // attempt at each line can be picked after transcription.
            if Teleprompter.shared.isShowing, let script = ScriptStore.shared.script {
                try? script.write(to: take.scriptURL)
                Teleprompter.shared.begin(withMicrophone: withMicrophone)
            }
            phase = .recording(startedAt: Date())
        } catch {
            fail(error)
        }
    }

    // MARK: Camera only

    /// Asks for the camera (and mic) the first time, starts the camera and
    /// shows the stage. False, with the reason in `phase`, when it can't.
    private func openCameraOnly(_ choice: CaptureChoice) async -> Bool {
        if cameraCapture != nil { return true }
        let access = AccessCenter.shared
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            CaptureDevices.shared.refresh()
        }
        if choice.includeMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        access.refresh()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            phase = .failed(message: CameraOnlyError.noAccess.localizedDescription)
            return false
        }
        guard let camera = CaptureDevices.shared.cameraForCameraOnly() else {
            phase = .failed(message: CameraOnlyError.noCamera.localizedDescription)
            return false
        }
        var microphone: AVCaptureDevice?
        if choice.includeMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let microphones = Microphones.shared
            microphones.refresh()
            microphone = microphones.resolved(for: choice).flatMap { AVCaptureDevice(uniqueID: $0.id) }
                ?? AVCaptureDevice.default(for: .audio)
        }
        // The bubble lets go of the camera first.
        CameraBubble.shared.setSuppressed(true)
        let capture = CameraOnlyCapture()
        do {
            try await capture.open(camera: camera, microphone: microphone)
        } catch {
            CameraBubble.shared.setSuppressed(false)
            phase = .failed(message: error.localizedDescription)
            return false
        }
        cameraCapture = capture
        cameraCaptureHasMic = microphone != nil
        CameraStage.shared.show(capture.previewLayer, on: recordedScreen())
        return true
    }

    /// Stops the camera and hides the stage. Safe to call when it's closed.
    private func closeCameraOnly() {
        guard let cameraCapture else { return }
        cameraCapture.close()
        self.cameraCapture = nil
        CameraStage.shared.hide()
        CameraBubble.shared.setSuppressed(false)
    }

    /// Records the camera and mic into screen.mov. No ScreenCaptureKit,
    /// no cursor log, no system sound.
    private func startCameraOnly(_ choice: CaptureChoice) async {
        phase = .preparing
        guard await openCameraOnly(choice), let capture = cameraCapture else {
            if case .preparing = phase { phase = .idle }
            return
        }
        var notes: [String] = []
        if choice.includeMicrophone, !cameraCaptureHasMic {
            notes.append("Recording without your voice. Turn on Microphone in Access.")
        }
        do {
            let take = try library.newTake()
            capture.startWriting(to: take.screenURL, withMicrophone: cameraCaptureHasMic) { _ in }
            self.take = take
            trackNotes = notes
            pauses = PauseLog()
            MicMonitor.shared.begin(withMicrophone: cameraCaptureHasMic)
            if Teleprompter.shared.isShowing, let script = ScriptStore.shared.script {
                try? script.write(to: take.scriptURL)
                Teleprompter.shared.begin(withMicrophone: cameraCaptureHasMic)
            }
            CameraStage.shared.isLive = true
            phase = .recording(startedAt: Date())
        } catch {
            fail(error)
        }
    }

    /// Opens the full-screen overlay to drag an area. With `thenRecord`,
    /// recording starts as soon as the area is accepted.
    func chooseArea(thenRecord: Bool = false) {
        guard !phase.isBusy, !phase.isLive else { return }
        AreaSelector.shared.show(displayID: choice.displayID, current: choice.area,
                                 acceptTitle: thenRecord ? "Record this area" : "Use this area") { [weak self] displayID, area in
            guard let self else { return }
            self.choice.displayID = displayID
            self.choice.area = area
            self.choice.mode = .area
            if thenRecord { Task { await self.record() } }
        }
    }

    /// Normal app windows that can be recorded, for the picker. Empty
    /// without Screen Recording access.
    func pickableWindows() async -> [WindowCandidate] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return []
        }
        let windows = content.windows.map { window in
            WindowCandidate(
                id: window.windowID,
                appName: window.owningApplication?.applicationName ?? "",
                bundleID: window.owningApplication?.bundleIdentifier,
                title: window.title,
                width: window.frame.width,
                height: window.frame.height,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        }
        return WindowCandidate.pickable(windows, excludingBundleID: Bundle.main.bundleIdentifier)
    }

    func stop() async {
        guard let ended = await endCapture() else { return }
        let (take, saved, firstFrame, writerError) = ended
        if saved {
            writePauseCuts(for: take, firstFrame: firstFrame)
            // Remember what it's for now, so a later pick on Home
            // doesn't change what this take is.
            try? TakePlan.stamp(take, from: .standard)
            lastTake = take
            Transcriber.shared.transcribe(take)
            phase = .idle
            MainWindowStepAside.forget()
            // Ready to share (or the editor, if that's the builder's
            // pick). Both wait for the transcript.
            ReadyToShareWindowController.shared.afterStop(take)
        } else {
            phase = .failed(message: writerError?.localizedDescription
                ?? (choice.mode == .camera
                    ? "Nothing was recorded. Try again, and check the camera is connected."
                    : "Nothing was recorded. Try again, and check Screen Recording access."))
            MainWindowStepAside.restore()
        }
        pauses = PauseLog()
    }

    // MARK: Pause, restart, delete

    /// Seconds recorded so far, leaving out pauses, for the REC bar.
    func recordedTime(at date: Date = Date()) -> TimeInterval {
        guard let elapsed = phase.elapsed(at: date) else { return 0 }
        return max(0, elapsed - pauses.pausedDuration(at: HostClock.now))
    }

    var isPaused: Bool { phase.isLive && pauses.isPaused }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    /// Stops writing screen, sound, mic and camera until resumed. Clocks
    /// keep running, so nothing needs lining up again afterwards.
    func pause() {
        guard phase.isLive, !pauses.isPaused, sink != nil || cameraCapture != nil else { return }
        pauses.pause(at: HostClock.now)
        sink?.setPaused(true)
        cameraCapture?.setPaused(true)
        CameraBubble.shared.setPaused(true)
    }

    func resume() {
        guard phase.isLive, pauses.isPaused, sink != nil || cameraCapture != nil else { return }
        pauses.resume(at: HostClock.now)
        sink?.setPaused(false)
        cameraCapture?.setPaused(false)
        CameraBubble.shared.setPaused(false)
        MicMonitor.shared.restartSilenceTimer()
    }

    /// Throws this take away (to the Bin, so it can be fished out) and
    /// counts down again with the same choices.
    func restart() async {
        guard await discard() else { return }
        await record()
    }

    /// Throws this take away and goes back to where you were. The editor
    /// doesn't open.
    func deleteTake() async {
        guard await discard() else { return }
        MainWindowStepAside.restore()
    }

    private func discard() async -> Bool {
        guard let ended = await endCapture() else { return false }
        try? FileManager.default.trashItem(at: ended.take.folder, resultingItemURL: nil)
        pauses = PauseLog()
        phase = .idle
        return true
    }

    /// Stops every track of the live take and finishes its files.
    private func endCapture() async -> (take: Take, saved: Bool, firstFrame: Double?, error: Error?)? {
        guard phase.isLive, let take, stream != nil || cameraCapture != nil else { return nil }
        phase = .finishing
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // Keep going: whatever was written is still worth finishing.
            }
        }
        await deviceTracks.stop()
        CameraBubble.shared.setPaused(false)
        await CameraBubble.shared.stopRecording()
        cursor?.stop(writingTo: take.eventsURL)
        AgentSession.shared.end(writingTo: take)
        MicMonitor.shared.end()
        Teleprompter.shared.hide()
        let result: (saved: Bool, firstFrame: Double?, error: Error?)
        if let cameraCapture {
            result = await cameraCapture.finishWriting()
            closeCameraOnly()
        } else if let sink {
            let saved = await sink.finish()
            result = (saved, sink.firstFrameSeconds, sink.writerError)
        } else {
            result = (false, nil, nil)
        }
        reset()
        return (take, result.saved, result.firstFrame, result.error)
    }

    /// The take's pauses as accepted cuts, so the editor and export play
    /// straight through them.
    private func writePauseCuts(for take: Take, firstFrame: Double?) {
        guard let firstFrame else { return }
        let end = HostClock.now
        let cuts = pauses.cuts(firstFrame: firstFrame, end: end)
        guard !cuts.isEmpty else { return }
        do {
            var edits = try EditList.load(from: take.editsURL, sourceDuration: end - firstFrame)
            for cut in cuts { edits.add(cut) }
            try edits.write(to: take.editsURL)
        } catch {
            trackNotes.append("Couldn't mark the paused parts as cuts: \(error.localizedDescription)")
        }
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        if let lastTake {
            NSWorkspace.shared.activateFileViewerSelecting([lastTake.screenURL])
        } else {
            NSWorkspace.shared.open(library.folder)
        }
    }

    func openSetup() {
        SetupWindowController.shared.show()
    }

    private func fail(_ error: Error) {
        if let take { cursor?.stop(writingTo: take.eventsURL) }
        AgentSession.shared.cancel()
        MicMonitor.shared.end()
        Teleprompter.shared.hide()
        pauses = PauseLog()
        MainWindowStepAside.restore()
        if let sink { Task { _ = await sink.finish() } }
        if let cameraCapture { Task { _ = await cameraCapture.finishWriting() } }
        closeCameraOnly()
        Task {
            await deviceTracks.stop()
            await CameraBubble.shared.stopRecording()
        }
        reset()
        phase = .failed(message: RecorderError.describe(error))
    }

    private func reset() {
        RegionOutline.shared.hide()
        stream = nil
        sink = nil
        cursor = nil
        take = nil
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.phase.isLive else { return }
            self.fail(error)
        }
    }
}

/// Receives sample buffers on the capture queue and hands them to the
/// writer, which is only ever touched on that queue. While paused, screen
/// frames are dropped and sound is written as silence, so nothing from
/// the pause is kept but the audio tracks have no holes.
final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: TakeWriter
    private let queue = DispatchQueue(label: "za.co.versionone.visionone.writer")
    private let onFirstFrame: @Sendable (CMTime) -> Void
    private let meterMicrophone: Bool
    private var sentFirstFrame = false
    // Touched only on `queue`.
    private var paused = false
    private var lastMeterPost = 0.0

    init(writer: TakeWriter, meterMicrophone: Bool, onFirstFrame: @escaping @Sendable (CMTime) -> Void) {
        self.writer = writer
        self.meterMicrophone = meterMicrophone
        self.onFirstFrame = onFirstFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        queue.sync {
            if paused {
                guard type != .screen, sampleBuffer.isValid, AudioSamples.silence(sampleBuffer) else { return }
            } else if type == .microphone, meterMicrophone {
                meter(sampleBuffer)
                // The teleprompter follows the same voice, on device.
                ScriptVoice.shared.append(sampleBuffer)
            }
            writer.append(sampleBuffer, of: type)
            if !sentFirstFrame, let first = writer.firstFrameTime {
                sentFirstFrame = true
                onFirstFrame(first)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.sync { self.paused = paused }
    }

    /// About fifteen readings a second is plenty for the meter.
    private func meter(_ buffer: CMSampleBuffer) {
        let time = buffer.presentationTimeStamp.seconds
        guard time - lastMeterPost >= 1.0 / 15, let peak = AudioSamples.peak(of: buffer) else { return }
        lastMeterPost = time
        Task { @MainActor in MicMonitor.shared.feed(peak: peak, at: time) }
    }

    func finish() async -> Bool {
        // Wait for any buffer still being appended, then finish.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        return await writer.finish()
    }

    var writerError: Error? { queue.sync { writer.error } }

    /// screen.mov's first frame on the host clock, or nil before one.
    var firstFrameSeconds: Double? { queue.sync { writer.firstFrameTime?.seconds } }
}

enum RecorderError: LocalizedError {
    case noDisplay
    case noWindowPicked
    case windowGone
    case areaOffScreen

    static let screenAccessMessage = "Vision One needs Screen Recording access. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .noWindowPicked: return "Pick a window to record in the Vision One menu."
        case .windowGone: return "That window has closed. Pick another one in the Vision One menu."
        case .areaOffScreen: return "That area is no longer on a screen. Choose the area again."
        }
    }

    /// Errors say how to fix, per the design system.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return screenAccessMessage
        }
        return error.localizedDescription
    }
}

/// What to hand ScreenCaptureKit for a choice: the filter, the video
/// size, and where it sits on screen for the cursor log.
struct CaptureTarget {
    let filter: SCContentFilter
    /// The dragged area within the display, in Area mode.
    let sourceRect: CGRect?
    let width: Int
    let height: Int
    /// What's recorded, in Core Graphics global points.
    let captureFrame: CGRect

    static func resolve(_ choice: CaptureChoice, in content: SCShareableContent) throws -> CaptureTarget {
        switch choice.mode {
        case .camera:
            // Camera only never goes through ScreenCaptureKit.
            throw RecorderError.noDisplay
        case .window:
            guard let id = choice.windowID,
                  let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.windowGone
            }
            // Follows the window even when it's covered or moved.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = CaptureRect(x: 0, y: 0, width: filter.contentRect.width, height: filter.contentRect.height)
                .pixelSize(scale: Double(filter.pointPixelScale))
            return CaptureTarget(filter: filter, sourceRect: nil, width: size.width, height: size.height,
                                 captureFrame: window.frame)

        case .screen, .area:
            let wanted = choice.displayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == wanted })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                throw RecorderError.noDisplay
            }
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let scale = Double(filter.pointPixelScale)
            let bounds = CaptureRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height)

            guard choice.mode == .area else {
                let size = bounds.pixelSize(scale: scale)
                return CaptureTarget(filter: filter, sourceRect: nil, width: size.width, height: size.height,
                                     captureFrame: display.frame)
            }
            guard display.displayID == wanted,
                  let area = choice.area?.clamped(to: bounds), area.isBigEnough else {
                throw RecorderError.areaOffScreen
            }
            let size = area.pixelSize(scale: scale)
            let rect = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
            return CaptureTarget(filter: filter, sourceRect: rect, width: size.width, height: size.height,
                                 captureFrame: rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY))
        }
    }
}
