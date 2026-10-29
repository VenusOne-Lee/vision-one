import AppKit
import AVFoundation
import VisionOneKit

/// Camera only: records the camera and mic straight into screen.mov, so
/// the transcript, editor, captions and export treat it like any take.
/// No ScreenCaptureKit, so no Screen Recording access. One capture
/// session feeds the stage's mirrored preview and the writer; the file
/// itself isn't mirrored, so text behind you reads the right way.
final class CameraOnlyCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "za.co.versionone.visionone.camera-only-session")
    /// Video and audio both arrive here, so the writer needs no locking.
    private let queue = DispatchQueue(label: "za.co.versionone.visionone.camera-only", qos: .userInitiated)

    // Touched only on `queue`.
    private var url: URL?
    private var withMicrophone = false
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var mic: AVAssetWriterInput?
    private var firstFrame: CMTime?
    private var paused = false
    private var lastMeterPost = 0.0
    private var sentFirstFrame = false
    private var onFirstFrame: (@Sendable (Double) -> Void)?

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        // Mono float at 48 kHz, like the mic track in screen recordings.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: queue)
    }

    /// Starts the camera (and mic) so the preview is live during the
    /// countdown. Nothing is written until `startWriting`.
    func open(camera: AVCaptureDevice, microphone: AVCaptureDevice?) async throws {
        // Devices aren't Sendable, so the session queue looks them up again.
        let cameraID = camera.uniqueID
        let microphoneID = microphone?.uniqueID
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                guard let camera = AVCaptureDevice(uniqueID: cameraID),
                      let cameraInput = try? AVCaptureDeviceInput(device: camera), session.canAddInput(cameraInput) else {
                    session.commitConfiguration()
                    done.resume(throwing: CameraOnlyError.cameraUnavailable)
                    return
                }
                session.addInput(cameraInput)
                if let microphoneID, let microphone = AVCaptureDevice(uniqueID: microphoneID),
                   let micInput = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
                if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
                // 1080p when the camera has it, else 720p.
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                } else if session.canSetSessionPreset(.hd1280x720) {
                    session.sessionPreset = .hd1280x720
                }
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async { [self] in
                    if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
                done.resume()
            }
        }
    }

    /// Stops the camera, so its light goes off.
    func close() {
        sessionQueue.async { [self] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }

    /// Writes screen.mov from the next camera frame on. `onFirstFrame`
    /// gets that frame's host time, like the screen recorder's.
    func startWriting(to url: URL, withMicrophone: Bool, onFirstFrame: @escaping @Sendable (Double) -> Void) {
        queue.sync {
            self.url = url
            self.withMicrophone = withMicrophone
            self.onFirstFrame = onFirstFrame
            writer = nil
            video = nil
            mic = nil
            firstFrame = nil
            paused = false
            sentFirstFrame = false
        }
        // The transcriber reads this to find the mic.
        let take = Take(folder: url.deletingLastPathComponent())
        try? TakeAudioTracks(tracks: withMicrophone ? [.mic] : []).write(to: take.audioTracksURL)
    }

    /// While paused, camera frames are dropped and sound is written as
    /// silence, like screen recordings, so pause cuts line up.
    func setPaused(_ paused: Bool) {
        queue.sync { self.paused = paused }
    }

    /// Finishes screen.mov. False when no frame ever arrived.
    func finishWriting() async -> (saved: Bool, firstFrame: Double?, error: Error?) {
        let taken: (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, CMTime?) = await withCheckedContinuation { done in
            queue.async { [self] in
                let result = (self.writer, self.video, self.mic, self.firstFrame)
                self.url = nil
                self.writer = nil
                self.video = nil
                self.mic = nil
                self.firstFrame = nil
                done.resume(returning: result)
            }
        }
        let (finishing, videoInput, micInput, first) = taken
        guard let finishing, finishing.status == .writing else { return (false, nil, finishing?.error) }
        videoInput?.markAsFinished()
        micInput?.markAsFinished()
        await finishing.finishWriting()
        return (finishing.status == .completed, first.map { hostSeconds($0) }, finishing.error)
    }

    var firstFrameSeconds: Double? { queue.sync { firstFrame.map { hostSeconds($0) } } }

    // MARK: Capture

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard buffer.isValid else { return }
        if output === videoOutput {
            appendVideo(buffer)
        } else if output === audioOutput, withMicrophone {
            appendAudio(buffer)
        }
    }

    private func appendVideo(_ buffer: CMSampleBuffer) {
        guard url != nil, !paused else { return }
        if writer == nil, !makeWriter(for: buffer) { return }
        if let video, video.isReadyForMoreMediaData { video.append(buffer) }
        if !sentFirstFrame, let firstFrame {
            sentFirstFrame = true
            let seconds = hostSeconds(firstFrame)
            onFirstFrame?(seconds)
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer) {
        guard let firstFrame, let mic, buffer.presentationTimeStamp >= firstFrame else { return }
        if paused {
            guard AudioSamples.silence(buffer) else { return }
        } else {
            meter(buffer)
            ScriptVoice.shared.append(buffer)
        }
        if mic.isReadyForMoreMediaData { mic.append(buffer) }
    }

    private func makeWriter(for buffer: CMSampleBuffer) -> Bool {
        guard let url, let format = buffer.formatDescription else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            self.url = nil
            return false
        }
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else {
            self.url = nil
            return false
        }
        writer.add(video)
        if withMicrophone {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            mic.expectsMediaDataInRealTime = true
            if writer.canAdd(mic) {
                writer.add(mic)
                self.mic = mic
            }
        }
        guard writer.startWriting() else {
            self.url = nil
            return false
        }
        let time = buffer.presentationTimeStamp
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.video = video
        firstFrame = time
        return true
    }

    private func meter(_ buffer: CMSampleBuffer) {
        let time = hostSeconds(buffer.presentationTimeStamp)
        guard time - lastMeterPost >= 1.0 / 15, let peak = AudioSamples.peak(of: buffer) else { return }
        lastMeterPost = time
        Task { @MainActor in MicMonitor.shared.feed(peak: peak, at: time) }
    }

    /// The session's clock is the host clock on Macs; convert anyway so
    /// pauses on the host clock line up if it ever isn't.
    private func hostSeconds(_ time: CMTime) -> Double {
        guard let clock = session.synchronizationClock else { return time.seconds }
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()).seconds
    }
}

enum CameraOnlyError: LocalizedError {
    case noAccess
    case noCamera
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "Camera only needs the camera. Turn on Camera for Vision One in System Settings → Privacy & Security → Camera, then try again."
        case .noCamera:
            return "No camera found. Plug one in, or bring your iPhone close for Continuity Camera."
        case .cameraUnavailable:
            return "The camera is busy or was unplugged. Close other apps using it, then try again."
        }
    }
}

/// The big mirrored preview while recording Camera only: 16:9, in the
/// builder's ring colour, centred the first time and then where it was
/// left. Drag it anywhere, resize it from any edge. Never takes focus.
@MainActor
final class CameraStage {
    static let shared = CameraStage()

    private var panel: StagePanel?
    private var view: StageView?
    private static let frameKey = "cameraStageFrame"

    private init() {}

    func show(_ previewLayer: AVCaptureVideoPreviewLayer, on screen: NSScreen) {
        if panel == nil { makePanel() }
        guard let panel, let view else { return }
        view.attach(previewLayer)
        view.ringColour = Self.colour(BrandStore.shared.kit.ring)
        view.isLive = false
        panel.setFrame(savedFrame() ?? Self.standardFrame(on: screen), display: true)
        panel.orderFrontRegardless()
    }

    var isLive: Bool {
        get { view?.isLive ?? false }
        set { view?.isLive = newValue }
    }

    func hide() {
        if let panel, panel.isVisible {
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        }
        panel?.orderOut(nil)
        view?.detach()
    }

    private func makePanel() {
        let panel = StagePanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                               styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = CGSize(width: 16, height: 9)
        panel.contentMinSize = CGSize(width: 320, height: 180)
        let view = StageView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        panel.contentView = view
        self.panel = panel
        self.view = view
    }

    /// The saved spot, if it's still on a screen.
    private func savedFrame() -> CGRect? {
        guard let saved = UserDefaults.standard.string(forKey: Self.frameKey) else { return nil }
        let frame = NSRectFromString(saved)
        guard frame.width >= 320, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    /// Centred, two thirds of the screen's width, a little above the
    /// middle so the REC bar fits underneath.
    private static func standardFrame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = (visible.width * 2 / 3).rounded()
        let height = (width * 9 / 16).rounded()
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2 + visible.height * 0.04,
                      width: width, height: height)
    }

    private static func colour(_ ring: RingColour) -> NSColor {
        NSColor(srgbRed: CGFloat((ring.hex >> 16) & 0xFF) / 255, green: CGFloat((ring.hex >> 8) & 0xFF) / 255,
                blue: CGFloat(ring.hex & 0xFF) / 255, alpha: 1)
    }
}

/// Floats without taking focus.
private final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The rounded preview, the ring and, while live, the orange tally dot.
private final class StageView: NSView {
    var ringColour: NSColor = .black {
        didSet { layer?.borderColor = ringColour.cgColor }
    }
    var isLive = false {
        didSet { tally.isHidden = !isLive }
    }

    private weak var preview: AVCaptureVideoPreviewLayer?
    private let tally = CALayer()
    private static let radius: CGFloat = 14
    private static let ringWidth: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        layer?.borderWidth = Self.ringWidth
        layer?.backgroundColor = NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF1 / 255, alpha: 1).cgColor
        tally.backgroundColor = NSColor(srgbRed: 1, green: 0x5A / 255, blue: 0x1F / 255, alpha: 1).cgColor
        tally.borderColor = NSColor.white.cgColor
        tally.borderWidth = 2
        tally.cornerRadius = 8
        tally.isHidden = true
        tally.zPosition = 1
        layer?.addSublayer(tally)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Camera preview. Drag to move, drag an edge to resize.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ previewLayer: AVCaptureVideoPreviewLayer) {
        guard preview !== previewLayer else { return }
        preview?.removeFromSuperlayer()
        layer?.insertSublayer(previewLayer, at: 0)
        preview = previewLayer
        needsLayout = true
    }

    func detach() {
        preview?.removeFromSuperlayer()
        preview = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        tally.frame = CGRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 16, height: 16)
        CATransaction.commit()
    }
}
