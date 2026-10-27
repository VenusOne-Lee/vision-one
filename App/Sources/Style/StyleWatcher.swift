import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import VisionOneKit
import WebKit

/// "Watch it play" for links on video sites. The link opens in a Vision
/// One window and plays; ScreenCaptureKit watches only the video's part of
/// that window, four times a second, and the same measuring as a file
/// runs on each frame in memory. Nothing is downloaded or saved.
@MainActor
final class StyleWatcher: NSObject, WKNavigationDelegate {
    enum Failure: LocalizedError {
        case noVideo
        case noAccess
        case tooShort

        var errorDescription: String? {
            switch self {
            case .noVideo: return "Vision One couldn't find a video on that page. If it needs you to sign in, sign in inside the window, then press Read again."
            case .noAccess: return "Vision One needs Screen Recording access to read a playing video. Turn it on in Access."
            case .tooShort: return "Not enough of the video played to read its style."
            }
        }
    }

    private let url: URL
    private let onProgress: (Double, StyleInput) -> Void
    private let onFinish: (Result<StyleInput, Error>) -> Void

    private var window: NSWindow?
    private var webView: WKWebView?
    private var stream: SCStream?
    private let sink = WatchSink()
    private var probeTimer: Timer?
    private var progress = StyleWatch.Progress()
    private var started = Date()
    private var lastPictureRect: CGRect?
    private var finished = false

    init(url: URL, onProgress: @escaping (Double, StyleInput) -> Void,
         onFinish: @escaping (Result<StyleInput, Error>) -> Void) {
        self.url = url
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        // Plays with sound straight away, so music is heard too.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Reading the style. Press play if it doesn't start."
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameAutosaveName("VisionOneStyleWatchWindow")
        window.center()
        // The window must be seen by ScreenCaptureKit.
        window.sharingType = .readOnly
        window.delegate = self
        self.window = window
        self.webView = webView
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: url))
        started = Date()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.probe() }
        }
    }

    /// Stops reading. `useWhatWasRead` hands on the frames so far (the
    /// Stop button); otherwise it just closes.
    func stop(useWhatWasRead: Bool) {
        guard !finished else { return }
        if useWhatWasRead {
            Task { await finish() }
        } else {
            finished = true
            tearDown()
        }
    }

    // MARK: - Page

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            _ = try? await webView.evaluateJavaScript(StyleWatch.playScript)
        }
    }

    private var noVideoChecks = 0
    private var playNudges = 0
    private var probes = 0

    private var probing = false

    private func probe() async {
        guard !finished, !probing, let webView else { return }
        probing = true
        defer { probing = false }
        let state = StyleWatch.VideoState.parse(try? await webView.evaluateJavaScript(StyleWatch.probeScript))
        guard state.found else {
            noVideoChecks += 1
            // A minute and a half to sign in or click through a cookie banner.
            if noVideoChecks > 360, sink.frameCount == 0 { fail(Failure.noVideo) }
            return
        }
        if !state.playing, sink.frameCount == 0, playNudges < 3, Date().timeIntervalSince(started) > Double(playNudges + 1) * 3 {
            playNudges += 1
            _ = try? await webView.evaluateJavaScript(StyleWatch.playScript)
        }
        await follow(state)
        sink.update(videoTime: state.time, playing: state.playing)
        let done = progress.update(state)
        probes += 1
        // The live numbers every two seconds is plenty.
        if probes % 8 == 0 {
            onProgress(progress.fraction, sink.input(duration: max(progress.furthest, 0.1), width: state.width, height: state.height))
        }
        if done { await finish() }
    }

    /// Starts capture once a video shows, and keeps the crop on the
    /// picture when the page moves it.
    private func follow(_ state: StyleWatch.VideoState) async {
        guard let window, let webView else { return }
        let picture = state.pictureRect
        guard picture.width > 40, picture.height > 40 else { return }
        // Page points (top left) to the web view's own space, then to the
        // window (bottom left), then to ScreenCaptureKit's window space
        // (top left of the whole window, title bar included).
        let y = webView.isFlipped ? picture.y : Double(webView.bounds.height) - picture.y - picture.height
        let inWindow = webView.convert(NSRect(x: picture.x, y: y, width: picture.width, height: picture.height), to: nil)
        let rect = CGRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY,
                          width: inWindow.width, height: inWindow.height).integral
        if let last = lastPictureRect, abs(last.minX - rect.minX) < 2, abs(last.minY - rect.minY) < 2,
           abs(last.width - rect.width) < 2, abs(last.height - rect.height) < 2 { return }
        lastPictureRect = rect
        if let stream {
            try? await stream.updateConfiguration(configuration(for: rect))
        } else {
            await startCapture(rect)
        }
    }

    private func configuration(for rect: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        let scale = min(1, 720 / max(rect.width, rect.height))
        config.width = max(2, Int(rect.width * scale) & ~1)
        config.height = max(2, Int(rect.height * scale) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(StyleMeasure.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        config.capturesAudio = true
        config.sampleRate = Int(StyleSampler.soundRate)
        config.channelCount = 1
        return config
    }

    private func startCapture(_ rect: CGRect) async {
        guard CGPreflightScreenCaptureAccess() else {
            fail(Failure.noAccess)
            return
        }
        guard let window,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target),
                              configuration: configuration(for: rect), delegate: nil)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            self.stream = stream
            sink.startSampling()
        } catch {
            fail(error)
        }
    }

    // MARK: - Finish

    private func finish() async {
        guard !finished else { return }
        finished = true
        let width = Double(lastPictureRect?.width ?? 0), height = Double(lastPictureRect?.height ?? 0)
        let videoSize = await videoSize()
        tearDown()
        let input = await sink.finish(duration: progress.furthest,
                                      width: videoSize?.width ?? width, height: videoSize?.height ?? height)
        if input.frames.count < 8 {
            onFinish(.failure(Failure.tooShort))
        } else {
            onFinish(.success(input))
        }
    }

    private func videoSize() async -> (width: Double, height: Double)? {
        guard let webView else { return nil }
        let state = StyleWatch.VideoState.parse(try? await webView.evaluateJavaScript(StyleWatch.probeScript))
        return state.width > 0 && state.height > 0 ? (state.width, state.height) : nil
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        tearDown()
        onFinish(.failure(error))
    }

    private func tearDown() {
        probeTimer?.invalidate()
        probeTimer = nil
        sink.stopSampling()
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        if let webView {
            webView.evaluateJavaScript(StyleWatch.pauseScript, completionHandler: nil)
        }
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }
}

extension StyleWatcher: NSWindowDelegate {
    /// Closing the window uses what has been read so far.
    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        stop(useWhatWasRead: true)
    }
}

/// Gets frames and sound from ScreenCaptureKit on its own queue. A timer
/// on the same queue measures the latest frame four times a second while
/// the video plays, stamped with the video's own clock.
private final class WatchSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "za.co.versionone.visionone.stylewatch")
    private let images = CIContext(options: [.cacheIntermediates: false])
    private var latest: CGImage?
    private var frames: [StyleFrame] = []
    private var samples: [Float] = []
    private var videoTime = 0.0
    private var probedAt = Date()
    private var playing = false
    private var sampled = 0
    private var timer: DispatchSourceTimer?

    var frameCount: Int { queue.sync { frames.count } }

    func update(videoTime: Double, playing: Bool) {
        queue.async {
            self.videoTime = videoTime
            self.probedAt = Date()
            self.playing = playing
        }
    }

    func startSampling() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1 / StyleMeasure.framesPerSecond)
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
            self.timer = timer
        }
    }

    func stopSampling() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func sample() {
        guard playing, let image = latest else { return }
        let time = videoTime + min(0.5, Date().timeIntervalSince(probedAt))
        if let last = frames.last, time <= last.time + 0.05 { return }
        let (signature, colours) = StyleSampler.measure(image)
        guard !signature.isEmpty else { return }
        var frame = StyleFrame(time: time, signature: signature, colours: colours)
        if StyleMeasure.readsVision(at: sampled) {
            let seen = StyleSampler.vision(image)
            frame.faces = seen.faces
            frame.text = seen.text
        }
        sampled += 1
        frames.append(frame)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: pixels)
            latest = images.createCGImage(image, from: image.extent)
        case .audio:
            // Only while it plays, so the sound lines up with the video's clock.
            guard playing, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples += floats }
        default:
            break
        }
    }

    /// What has been read so far, without sound (for the live numbers).
    func input(duration: Double, width: Double, height: Double) -> StyleInput {
        let frames = queue.sync { self.frames }
        return StyleInput(duration: duration, width: width, height: height, frames: frames)
    }

    /// Everything read, with sound labelled. Silent sound (a page whose
    /// audio ScreenCaptureKit couldn't hear) is left out rather than read
    /// as "no music".
    func finish(duration: Double, width: Double, height: Double) async -> StyleInput {
        let (frames, samples) = queue.sync { (self.frames, self.samples) }
        let heard = samples.contains { abs($0) > 0.001 }
        let sound: (windows: [StyleSoundWindow], envelope: [Double]) = heard ? StyleSampler.sound(from: samples) : (windows: [], envelope: [])
        let length = max(duration, frames.last?.time ?? 0)
        return StyleInput(duration: length, width: width, height: height, frames: frames,
                          sound: sound.windows, envelope: sound.envelope, envelopeRate: StyleMeasure.envelopeRate)
    }
}
