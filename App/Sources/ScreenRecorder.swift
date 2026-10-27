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
        switch phase {
        case .idle, .failed: await start()
        case .recording: await stop()
        case .preparing, .finishing: break
        }
    }

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
            let sink = CaptureSink(writer: writer) { [weak cursor] firstFrame in
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
            if thenRecord { Task { await self.start() } }
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
        guard phase.isLive, let stream, let sink, let take else { return }
        phase = .finishing
        do {
            try await stream.stopCapture()
        } catch {
            // Keep going: whatever was written is still worth finishing.
        }
        await deviceTracks.stop()
        await CameraBubble.shared.stopRecording()
        cursor?.stop(writingTo: take.eventsURL)
        let saved = await sink.finish()
        if saved {
            // Remember what it's for now, so a later pick on Home
            // doesn't change what this take is.
            try? TakePlan.stamp(take, purposeID: UserDefaults.standard.string(forKey: "ai.nextPurpose"))
            lastTake = take
            Transcriber.shared.transcribe(take)
            phase = .idle
            // Straight to review. The editor waits for the transcript.
            EditorWindowController.shared.open(take)
        } else {
            phase = .failed(message: sink.writerError?.localizedDescription
                ?? "Nothing was recorded. Try again, and check Screen Recording access.")
        }
        reset()
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
/// writer, which is only ever touched on that queue.
final class CaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: TakeWriter
    private let queue = DispatchQueue(label: "za.co.versionone.visionone.writer")
    private let onFirstFrame: @Sendable (CMTime) -> Void
    private var sentFirstFrame = false

    init(writer: TakeWriter, onFirstFrame: @escaping @Sendable (CMTime) -> Void) {
        self.writer = writer
        self.onFirstFrame = onFirstFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        queue.sync {
            writer.append(sampleBuffer, of: type)
            if !sentFirstFrame, let first = writer.firstFrameTime {
                sentFirstFrame = true
                onFirstFrame(first)
            }
        }
    }

    func finish() async -> Bool {
        // Wait for any buffer still being appended, then finish.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        return await writer.finish()
    }

    var writerError: Error? { queue.sync { writer.error } }
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
