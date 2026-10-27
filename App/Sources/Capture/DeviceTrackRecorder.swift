import AVFoundation

/// Records one capture device (a camera, or a plugged-in iPhone's screen
/// and sound) to its own movie file in the take, next to screen.mov.
/// Uses AVCaptureMovieFileOutput because these tracks need no per-frame
/// work; export draws them later.
final class DeviceTrackRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let url: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "za.co.versionone.visionone.device-track")
    private let lock = NSLock()
    private var started: CheckedContinuation<Error?, Never>?
    private var finished: CheckedContinuation<Error?, Never>?

    init(device: AVCaptureDevice, url: URL) throws {
        self.url = url
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if device.hasMediaType(.video), session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw DeviceTrackError.cantUse(device.localizedName)
        }
        session.addInput(input)
        session.addOutput(output)
        // Same crash safety as screen.mov: a few seconds lost at most.
        output.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    }

    func start() async throws {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.session.startRunning()
                done.resume()
            }
        }
        let error: Error? = await withCheckedContinuation { continuation in
            lock.withLock { started = continuation }
            output.startRecording(to: url, recordingDelegate: self)
        }
        if let error { throw error }
    }

    /// Stops and waits for the file to be finished. Returns the error, if
    /// the recording failed.
    func stop() async -> Error? {
        var error: Error?
        if output.isRecording {
            error = await withCheckedContinuation { continuation in
                lock.withLock { finished = continuation }
                output.stopRecording()
            }
        }
        sessionQueue.async { self.session.stopRunning() }
        return error
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        lock.withLock { started.take() }?.resume(returning: nil)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation reports some clean finishes (disk nearly full, a
        // max duration) as errors with this flag set.
        let succeeded = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let result: Error? = succeeded ? nil : error
        let (start, finish) = lock.withLock { (started.take(), finished.take()) }
        start?.resume(returning: result ?? DeviceTrackError.stoppedEarly)
        finish?.resume(returning: result)
    }
}

enum DeviceTrackError: LocalizedError {
    case cantUse(String)
    case stoppedEarly

    var errorDescription: String? {
        switch self {
        case .cantUse(let name): return "\(name) is busy or can't be recorded. Close other apps using it and try again."
        case .stoppedEarly: return "The device stopped before recording began. Check it's still connected."
        }
    }
}
