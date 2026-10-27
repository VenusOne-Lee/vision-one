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

    private override init() {
        choice = CaptureChoice.decoded(from: UserDefaults.standard.data(forKey: Self.choiceKey))
        super.init()
        lastTake = library.takes().first
    }

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
        guard access.checklist.canRecord else {
            SetupWindowController.shared.show()
            return
        }
        if case .failed = phase { phase = .idle }
        MainWindowStepAside.hide()
        isCountingDown = true
        let go = await Countdown.shared.run(on: recordedScreen())
        isCountingDown = false
        guard go else {
            MainWindowStepAside.restore()
            return
        }
        await start()
        if !phase.isLive { MainWindowStepAside.restore() }
    }

    /// Starts recording straight away, without the countdown.
    func start() async {
        guard !phase.isBusy, !phase.isLive else { return }

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
        let (take, sink, saved) = ended
        if saved {
            writePauseCuts(for: take, firstFrame: sink.firstFrameSeconds)
            // Remember what it's for now, so a later pick on Home
            // doesn't change what this take is.
            try? TakePlan.stamp(take, purposeID: UserDefaults.standard.string(forKey: "ai.nextPurpose"))
            lastTake = take
            Transcriber.shared.transcribe(take)
            phase = .idle
            MainWindowStepAside.forget()
            // Straight to review. The editor waits for the transcript.
            EditorWindowController.shared.open(take)
        } else {
            phase = .failed(message: sink.writerError?.localizedDescription
                ?? "Nothing was recorded. Try again, and check Screen Recording access.")
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
        guard phase.isLive, !pauses.isPaused, let sink else { return }
        pauses.pause(at: HostClock.now)
        sink.setPaused(true)
        CameraBubble.shared.setPaused(true)
    }

    func resume() {
        guard phase.isLive, pauses.isPaused, let sink else { return }
        pauses.resume(at: HostClock.now)
        sink.setPaused(false)
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
    private func endCapture() async -> (take: Take, sink: CaptureSink, saved: Bool)? {
        guard phase.isLive, let stream, let sink, let take else { return nil }
        phase = .finishing
        do {
            try await stream.stopCapture()
        } catch {
            // Keep going: whatever was written is still worth finishing.
        }
        await deviceTracks.stop()
        CameraBubble.shared.setPaused(false)
        await CameraBubble.shared.stopRecording()
        cursor?.stop(writingTo: take.eventsURL)
        MicMonitor.shared.end()
        let saved = await sink.finish()
        reset()
        return (take, sink, saved)
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
        MicMonitor.shared.end()
        pauses = PauseLog()
        MainWindowStepAside.restore()
        if let sink { Task { _ = await sink.finish() } }
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
