import AppKit
import ScreenCaptureKit
import VisionOneKit

/// Records the main display into a take folder: screen video, system
/// sound and mic as separate tracks in a fragmented screen.mov, plus the
/// cursor log. Uses SCStream + AVAssetWriter rather than SCRecordingOutput
/// so the editor gets each source on its own track (see the research doc
/// linked in docs/RECORDER.md). Vision One's own windows are left out.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var lastTake: Take?

    let library = TakeLibrary.standard

    private let captureQueue = DispatchQueue(label: "za.co.versionone.visionone.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var sink: CaptureSink?
    private var cursor: CursorLogger?
    private var take: Take?

    func toggle() async {
        switch phase {
        case .idle, .failed: await start()
        case .recording: await stop()
        case .preparing, .finishing: break
        }
    }

    func start() async {
        guard !phase.isBusy, !phase.isLive else { return }
        phase = .preparing

        // No dead end: without access, open the setup window instead.
        let access = AccessCenter.shared
        access.refresh()
        guard access.checklist.canRecord else {
            phase = .idle
            SetupWindowController.shared.show()
            return
        }
        let withMicrophone = access.checklist.state(of: .microphone) == .granted

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                throw RecorderError.noDisplay
            }
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

            let scale = CGFloat(filter.pointPixelScale)
            let width = Int(filter.contentRect.width * scale)
            let height = Int(filter.contentRect.height * scale)

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6
            // v0.1 keeps the real cursor in the video and logs it too. When
            // smooth cursor and zooms land, we hide it and draw it at export.
            config.showsCursor = true
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = withMicrophone

            let take = try library.newTake()
            let writer = try TakeWriter(url: take.screenURL, width: width, height: height,
                                        includeMicrophone: withMicrophone)
            let cursor = CursorLogger(displayFrame: CGDisplayBounds(display.displayID))
            let sink = CaptureSink(writer: writer) { [weak cursor] firstFrame in
                Task { @MainActor in cursor?.setOrigin(firstFrame.seconds) }
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: captureQueue)
            if withMicrophone {
                try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: captureQueue)
            }
            cursor.start()
            try await stream.startCapture()

            self.stream = stream
            self.sink = sink
            self.cursor = cursor
            self.take = take
            phase = .recording(startedAt: Date())
        } catch {
            fail(error)
        }
    }

    func stop() async {
        guard phase.isLive, let stream, let sink, let take else { return }
        phase = .finishing
        do {
            try await stream.stopCapture()
        } catch {
            // Keep going: whatever was written is still worth finishing.
        }
        cursor?.stop(writingTo: take.eventsURL)
        let saved = await sink.finish()
        if saved {
            lastTake = take
            Transcriber.shared.transcribe(take)
            phase = .idle
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
        reset()
        phase = .failed(message: RecorderError.describe(error))
    }

    private func reset() {
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

    static let screenAccessMessage = "Vision One needs Screen Recording access. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
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
