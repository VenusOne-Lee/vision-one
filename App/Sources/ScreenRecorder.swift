import AppKit
import ScreenCaptureKit
import VisionOneKit

/// Records the main display, system sound and the microphone straight to
/// an MP4 with ScreenCaptureKit's SCRecordingOutput (macOS 15+).
/// Vision One's own windows are left out of the recording.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var lastRecording: URL?

    let library = RecordingLibrary.standard

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var currentURL: URL?

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
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                throw RecorderError.noDisplay
            }
            let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = true
            config.captureMicrophone = true

            let url = try library.newRecordingURL()
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = url
            outputConfig.outputFileType = .mp4
            outputConfig.videoCodecType = .h264

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()

            self.stream = stream
            self.output = output
            self.currentURL = url
            phase = .recording(startedAt: Date())
        } catch {
            fail(error)
        }
    }

    func stop() async {
        guard phase.isLive, let stream else { return }
        phase = .finishing
        do {
            try await stream.stopCapture()
            if let output { try? stream.removeRecordingOutput(output) }
            lastRecording = currentURL
            phase = .idle
        } catch {
            fail(error)
        }
        self.stream = nil
        self.output = nil
        self.currentURL = nil
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        if let lastRecording {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
        } else {
            NSWorkspace.shared.open(library.folder)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fail(_ error: Error) {
        stream = nil
        output = nil
        currentURL = nil
        phase = .failed(message: RecorderError.describe(error))
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
}

enum RecorderError: LocalizedError {
    case noDisplay

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
            return "Vision One needs Screen Recording access. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
        return error.localizedDescription
    }
}
