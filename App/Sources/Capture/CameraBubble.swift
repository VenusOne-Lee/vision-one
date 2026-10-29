import AppKit
import AVFoundation
import Combine
import VisionOneKit

/// The camera bubble: a round live preview in the builder's ring that
/// floats over everything while the camera is on. Drag it anywhere, pull
/// the grip to resize, or right-click for sizes. It remembers where it was
/// left. While recording it also writes camera.mov and camera.json; the
/// bubble itself never lands in screen.mov, because Vision One's windows
/// are left out of the capture, so export can draw the camera instead.
@MainActor
final class CameraBubble {
    static let shared = CameraBubble()

    private let feed = CameraFeed()
    private var panel: BubblePanel?
    private var view: BubbleView?
    private var cancellables: Set<AnyCancellable> = []
    private var feedCameraID: String?
    private var placement: BubblePlacement?
    private static let placementKey = "cameraBubblePlacement"

    /// Set while a take is recording the camera.
    private var recording: Recording?
    private struct Recording {
        let take: Take
        let cameraName: String
        /// What screen.mov records, in Core Graphics global points.
        let captureFrame: CGRect
        var screenStart: Double?
        /// Host clock seconds and the bubble's frame (CG global) each time
        /// it moved.
        var moves: [(time: Double, frame: CGRect)] = []
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.placementKey) {
            placement = try? JSONDecoder().decode(BubblePlacement.self, from: data)
        }
    }

    /// Call once at launch. The bubble then follows the camera choice.
    func start() {
        let devices = CaptureDevices.shared
        devices.$cameraChoice.map { _ in () }
            .merge(with: devices.$cameras.map { _ in () }, devices.$systemPreferredCameraID.map { _ in () })
            // @Published sends before the value is stored; read it after.
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        BrandStore.shared.$kit.map(\.ring).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] ring in self?.view?.ringColour = Self.colour(ring) }
            .store(in: &cancellables)
    }

    var isShown: Bool { panel?.isVisible == true }

    /// Hidden while Camera only records: the camera is already the whole
    /// picture, and the stage has the camera to itself.
    private var suppressed = false

    func setSuppressed(_ suppressed: Bool) {
        guard self.suppressed != suppressed else { return }
        self.suppressed = suppressed
        update()
    }

    // MARK: Recording

    /// Starts camera.mov for a take. Returns why the camera is missing,
    /// when it was chosen but can't record; the screen carries on.
    func startRecording(for take: Take, captureFrame: CGRect) -> String? {
        let devices = CaptureDevices.shared
        guard devices.cameraChoice != .off else { return nil }
        guard devices.hasVideoAccess else {
            return "Recording without the camera: turn on Camera access for Vision One in System Settings → Privacy & Security → Camera."
        }
        guard let device = devices.cameraToRecord() else {
            return "Recording without the camera: it isn't connected."
        }
        if feedCameraID != device.uniqueID { useCamera(device) }
        show()
        feed.startWriting(to: take.cameraURL)
        var recording = Recording(take: take, cameraName: device.localizedName, captureFrame: captureFrame)
        if let frame = panel?.frame { recording.moves.append((Self.hostNow(), Self.globalFrame(frame))) }
        self.recording = recording
        view?.isLive = true
        return nil
    }

    /// While paused no camera frames are written. camera.json's offset and
    /// placements keep the host clock, and the paused cuts in edits.json
    /// cover the same stretch, so export lines up without changes here.
    func setPaused(_ paused: Bool) {
        guard recording != nil else { return }
        feed.setPaused(paused)
    }

    /// screen.mov's first frame, on the host clock, so camera.json can
    /// line the two files up.
    func screenStarted(at seconds: Double) {
        recording?.screenStart = seconds
    }

    /// Finishes camera.mov and writes camera.json. Safe to call when the
    /// camera wasn't recording.
    func stopRecording() async {
        guard let recording else { return }
        self.recording = nil
        view?.isLive = false
        let result = await feed.finishWriting()
        guard let cameraStart = result.firstFrame else {
            try? FileManager.default.removeItem(at: recording.take.cameraURL)
            return
        }
        let screenStart = recording.screenStart ?? cameraStart
        var track = CameraTrack(cameraName: recording.cameraName, startOffset: cameraStart - screenStart)
        let recorded = Self.rect(recording.captureFrame)
        for move in recording.moves {
            if let placement = CameraTrack.Placement(t: max(0, move.time - screenStart),
                                                     bubble: Self.rect(move.frame), recorded: recorded) {
                track.record(placement)
            }
        }
        try? track.write(to: recording.take.cameraInfoURL)
        update()
    }

    // MARK: Showing

    private func update() {
        guard recording == nil else { return }  // Choices are locked mid-take.
        let devices = CaptureDevices.shared
        guard !suppressed, devices.cameraChoice != .off, devices.hasVideoAccess, let device = devices.cameraToRecord() else {
            hide()
            return
        }
        if feedCameraID != device.uniqueID { useCamera(device) }
        show()
    }

    private func useCamera(_ device: AVCaptureDevice) {
        feedCameraID = device.uniqueID
        feed.use(device)
    }

    private func show() {
        if panel == nil { makePanel() }
        guard let panel else { return }
        let screen = screen(for: placement)
        let bounds = Self.rect(screen.visibleFrame)
        let resolved = placement ?? BubblePlacement.standard(on: bounds, displayID: screen.displayID)
        panel.setFrame(Self.cgRect(resolved.frame(on: bounds)), display: true)
        view?.layoutBubble()
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        if feedCameraID != nil {
            feed.stop()
            feedCameraID = nil
        }
    }

    private func makePanel() {
        let panel = BubblePanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let view = BubbleView(previewLayer: feed.previewLayer)
        view.ringColour = Self.colour(BrandStore.shared.kit.ring)
        view.onDrag = { [weak self] frame, done in self?.dragged(to: frame, done: done) }
        view.onSize = { [weak self] size in self?.resize(to: size) }
        view.onTurnOff = { CaptureDevices.shared.cameraChoice = .off }
        panel.contentView = view
        self.panel = panel
        self.view = view
    }

    /// Keeps the bubble whole on the screen under the mouse while it's
    /// dragged, and saves the spot when the drag ends.
    private func dragged(to frame: CGRect, done: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        let bounds = Self.rect(screen.visibleFrame)
        let moved = BubblePlacement(frame: Self.rect(frame), on: bounds, displayID: screen.displayID)
        let kept = Self.cgRect(moved.frame(on: bounds))
        panel.setFrame(kept, display: true)
        view?.layoutBubble()
        recording?.moves.append((Self.hostNow(), Self.globalFrame(kept)))
        if done { save(moved) }
    }

    private func resize(to size: BubblePlacement.Size) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let bounds = Self.rect(screen.visibleFrame)
        let current = BubblePlacement(frame: Self.rect(panel.frame), on: bounds, displayID: screen.displayID)
        let resized = current.resized(to: size.diameter, on: bounds)
        let frame = Self.cgRect(resized.frame(on: bounds))
        panel.setFrame(frame, display: true)
        view?.layoutBubble()
        recording?.moves.append((Self.hostNow(), Self.globalFrame(frame)))
        save(resized)
    }

    private func save(_ placement: BubblePlacement) {
        self.placement = placement
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: Self.placementKey)
        }
    }

    private func screen(for placement: BubblePlacement?) -> NSScreen {
        if let id = placement?.displayID, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Helpers

    private static func colour(_ ring: RingColour) -> NSColor {
        NSColor(srgbRed: CGFloat((ring.hex >> 16) & 0xFF) / 255, green: CGFloat((ring.hex >> 8) & 0xFF) / 255,
                blue: CGFloat(ring.hex & 0xFF) / 255, alpha: 1)
    }

    private static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// AppKit screen frame (origin bottom left of the main display) to
    /// Core Graphics global points (origin top left), like the capture
    /// frame and events.json.
    private static func globalFrame(_ frame: CGRect) -> CGRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func rect(_ r: CGRect) -> CaptureRect {
        CaptureRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    private static func cgRect(_ r: CaptureRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}

/// Floats without taking focus from the app being recorded.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The round preview, the ring, the resize grip (on hover) and, while
/// recording, the orange tally dot.
private final class BubbleView: NSView {
    var onDrag: ((CGRect, Bool) -> Void)?
    var onSize: ((BubblePlacement.Size) -> Void)?
    var onTurnOff: (() -> Void)?

    var ringColour: NSColor = .black {
        didSet { ring.strokeColor = ringColour.cgColor }
    }
    var isLive = false {
        didSet { tally.isHidden = !isLive }
    }

    private let previewLayer: AVCaptureVideoPreviewLayer
    private let ring = CAShapeLayer()
    private let grip = CALayer()
    private let tally = CALayer()
    private static let ringWidth: CGFloat = 4
    private static let gripSide: CGFloat = 22

    private var dragStart: CGPoint = .zero
    private var frameAtStart: CGRect = .zero
    private var resizing = false

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        wantsLayer = true
        let paper = NSColor.white.cgColor
        let ink = NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1).cgColor

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF1 / 255, alpha: 1).cgColor
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)

        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        layer?.addSublayer(ring)

        grip.backgroundColor = paper
        grip.borderColor = ink
        grip.borderWidth = 1.5
        grip.isHidden = true
        layer?.addSublayer(grip)

        tally.backgroundColor = NSColor(srgbRed: 1, green: 0x5A / 255, blue: 0x1F / 255, alpha: 1).cgColor
        tally.borderColor = paper
        tally.borderWidth = 2
        tally.isHidden = true
        layer?.addSublayer(tally)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Camera bubble. Drag to move, drag the corner handle to resize.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutBubble()
    }

    func layoutBubble() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let circle = bounds.insetBy(dx: Self.ringWidth / 2, dy: Self.ringWidth / 2)
        previewLayer.frame = bounds.insetBy(dx: Self.ringWidth, dy: Self.ringWidth)
        previewLayer.cornerRadius = previewLayer.frame.width / 2
        ring.path = CGPath(ellipseIn: circle, transform: nil)
        // On the circle's edge at the bottom right, and the tally at the
        // top right, both at 45 degrees from the centre.
        let r = bounds.width / 2
        let edge = r * 0.707
        let side = Self.gripSide
        grip.frame = CGRect(x: r + edge - side / 2, y: r - edge - side / 2, width: side, height: side)
        grip.cornerRadius = side / 2
        tally.frame = CGRect(x: r + edge - 8, y: r + edge - 8, width: 16, height: 16)
        tally.cornerRadius = 8
        CATransaction.commit()
    }

    // Clicks outside the circle fall through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(local.x - centre.x, local.y - centre.y) <= bounds.width / 2 || inGrip(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { grip.isHidden = false }
    override func mouseExited(with event: NSEvent) { if !resizing { grip.isHidden = true } }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        frameAtStart = window?.frame ?? .zero
        resizing = inGrip(convert(event.locationInWindow, from: nil))
        (resizing ? NSCursor.crosshair : NSCursor.closedHand).push()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(draggedFrame(), false)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDrag?(draggedFrame(), true)
        resizing = false
    }

    /// Moving keeps the size; the grip keeps the top left corner still
    /// and grows towards the mouse.
    private func draggedFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStart.x, dy = mouse.y - dragStart.y
        guard resizing else { return frameAtStart.offsetBy(dx: dx, dy: dy) }
        let side = max(BubblePlacement.minimumDiameter, frameAtStart.width + (dx - dy) / 2)
        return CGRect(x: frameAtStart.minX, y: frameAtStart.maxY - side, width: side, height: side)
    }

    private func inGrip(_ point: CGPoint) -> Bool {
        grip.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for size in BubblePlacement.Size.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Turn camera off", action: isLive ? nil : #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        return menu
    }

    @objc private func pickSize(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let size = BubblePlacement.Size(rawValue: raw) {
            onSize?(size)
        }
    }

    @objc private func turnOff() { onTurnOff?() }
}

/// One capture session for the camera: it feeds the bubble's preview and,
/// while recording, camera.mov through AVAssetWriter, so the first
/// frame's time is known on the host clock that screen.mov uses.
private final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "za.co.versionone.visionone.camera-session")
    private let frameQueue = DispatchQueue(label: "za.co.versionone.visionone.camera-frames", qos: .userInitiated)

    // Touched only on frameQueue.
    private var pendingURL: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstFrame: Double?
    private var paused = false

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    func use(_ device: AVCaptureDevice) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            // The bubble reads like a mirror; camera.mov stays unmirrored.
            DispatchQueue.main.async { [self] in
                if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }

    /// Stops the camera, so its light goes off.
    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }

    func startWriting(to url: URL) {
        frameQueue.async { [self] in
            pendingURL = url
            writer = nil
            input = nil
            firstFrame = nil
            paused = false
        }
    }

    /// Drops frames while paused. The writer and its first frame stay as
    /// they are, so camera.json's start offset is still right.
    func setPaused(_ paused: Bool) {
        frameQueue.async { [self] in self.paused = paused }
    }

    /// Finishes camera.mov. `firstFrame` is its first frame on the host
    /// clock, or nil when no frame arrived.
    func finishWriting() async -> (firstFrame: Double?, error: Error?) {
        let taken: (AVAssetWriter?, AVAssetWriterInput?, Double?) = await withCheckedContinuation { done in
            frameQueue.async { [self] in
                let result = (self.writer, self.input, self.firstFrame)
                pendingURL = nil
                self.writer = nil
                self.input = nil
                firstFrame = nil
                done.resume(returning: result)
            }
        }
        let (writer, input, first) = taken
        guard let writer, writer.status == .writing else { return (nil, writer?.error) }
        input?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? (first, nil) : (nil, writer.error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let url = pendingURL, !paused else { return }
        let time = sampleBuffer.presentationTimeStamp
        if writer == nil {
            guard let format = sampleBuffer.formatDescription else { return }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                pendingURL = nil
                return
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                pendingURL = nil
                return
            }
            writer.add(input)
            // Same crash safety as screen.mov: a few seconds lost at most.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            guard writer.startWriting() else {
                pendingURL = nil
                return
            }
            writer.startSession(atSourceTime: time)
            self.writer = writer
            self.input = input
            firstFrame = hostSeconds(time)
        }
        if let input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// The capture session's clock is the host clock on Macs, but convert
    /// anyway so the offset to screen.mov is right if it ever isn't.
    private func hostSeconds(_ time: CMTime) -> Double {
        guard let clock = session.synchronizationClock else { return time.seconds }
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()).seconds
    }
}
