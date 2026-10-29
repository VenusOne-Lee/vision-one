import AVFoundation
import CoreImage
import VisionOneKit

/// One stretch of the export: either the recording (which track is the
/// screen and what to draw on top) or a brand card drawn full frame.
/// AVVideoCompositionCoreAnimationTool would be simpler for overlays, but
/// it only works with AVAssetExportSession, and export needs
/// AVAssetReader to control the bitrate.
final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let overlays: [ExportOverlay]
    /// Subtracted from the export time before overlays draw, so captions
    /// keep the edited video's clock after an intro.
    let overlayTimeOffset: Double
    /// Blurs and zooms, applied to the screen frame before it's scaled.
    let effects: FrameEffects?
    /// Set for an intro or outro; the recording isn't read then.
    let card: (any CardSource)?
    /// The part of the frame to show, normalized with origin top left, at
    /// an output time. Clips use it to cut a 9:16 or 1:1 window out of
    /// the wide screen. nil shows the whole frame.
    let crop: (@Sendable (Double) -> NormalisedRect?)?
    /// Fills the space around a frame that doesn't match the output shape.
    let background: CIColor
    /// camera.mov's track and where to draw it, when the take has one.
    let camera: CameraLayer?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, overlays: [ExportOverlay], overlayTimeOffset: Double = 0,
         effects: FrameEffects? = nil,
         crop: (@Sendable (Double) -> NormalisedRect?)? = nil, background: CIColor = .black,
         camera: CameraLayer? = nil) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.overlays = overlays
        self.overlayTimeOffset = overlayTimeOffset
        self.effects = effects
        self.crop = crop
        self.background = background
        self.camera = camera
        card = nil
        requiredSourceTrackIDs = [NSNumber(value: trackID)] + (camera.map { [NSNumber(value: $0.trackID)] } ?? [])
    }

    init(timeRange: CMTimeRange, card: any CardSource) {
        self.timeRange = timeRange
        trackID = kCMPersistentTrackID_Invalid
        overlays = []
        overlayTimeOffset = 0
        effects = nil
        crop = nil
        background = .white
        camera = nil
        self.card = card
        requiredSourceTrackIDs = []
    }
}

/// Per frame: secret blurs, then the zoom viewport (`FrameEffects`), then
/// scaled to the export size with Core Image (on the GPU), then overlays
/// drawn on top with Core Graphics (captions, the camera bubble). Blurring
/// first means a secret can't slip out through a zoom or a clip's crop.
/// The editor's preview plays through this compositor too.
final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VisionOne.Export", code: 1))
            return
        }
        let size = request.renderContext.size

        if let card = instruction.card {
            let cardTime = request.compositionTime.seconds - instruction.timeRange.start.seconds
            drawCard(card, on: output, size: size, at: cardTime)
            request.finish(withComposedVideoFrame: output)
            return
        }

        guard let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            // A frame time a hair past the last recorded frame (rounding at
            // a card's edge). Paper is better than failing the export.
            drawCard(BlankCard(), on: output, size: size, at: 0)
            request.finish(withComposedVideoFrame: output)
            return
        }

        var image = CIImage(cvPixelBuffer: source)
        if let effects = instruction.effects, !effects.isEmpty {
            // Effects run on the edited video's clock, like overlays.
            image = FrameEffectRenderer.apply(effects, to: image,
                                              atOutput: request.compositionTime.seconds - instruction.overlayTimeOffset)
        }
        // A clip's 9:16 or 1:1 window, inside whatever the zoom showed.
        if let rect = instruction.crop?(request.compositionTime.seconds - instruction.overlayTimeOffset) {
            image = Self.crop(image, to: rect)
        }
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Centre it; the shape matches in v0.1, so this only matters once
        // reframing to 9:16 and 1:1 arrives.
        let x = (size.width - scaled.extent.width) / 2
        let y = (size.height - scaled.extent.height) / 2
        var placed = scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: CIImage(color: instruction.background).cropped(to: CGRect(origin: .zero, size: size)))

        // The camera bubble, where it sat over the recording. A frame with
        // no camera (it started late, or a gap) just shows the screen.
        let outputTime = request.compositionTime.seconds - instruction.overlayTimeOffset
        var ring: (rect: CGRect, layer: CameraLayer)?
        if let camera = instruction.camera, let frame = request.sourceFrame(byTrackID: camera.trackID),
           let placement = camera.track.placement(atOutput: outputTime, timeline: camera.timeline) {
            let screen = CaptureRect(x: x, y: y, width: scaled.extent.width, height: scaled.extent.height)
            let r = CameraTrack.outputRect(for: placement, in: screen)
            let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            // The room behind the person, when the take has one.
            let face = camera.background?.render(frame, at: outputTime) ?? CIImage(cvPixelBuffer: frame)
            placed = Self.bubble(face, in: rect).composited(over: placed)
            ring = (rect, camera)
        }
        context.render(placed, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        if ring != nil || !instruction.overlays.isEmpty {
            draw(instruction.overlays, ring: ring, on: output, size: size, at: outputTime)
        }
        request.finish(withComposedVideoFrame: output)
    }

    /// The middle square of a camera frame, filling `rect`, cut to a circle.
    static func bubble(_ camera: CIImage, in rect: CGRect) -> CIImage {
        let e = camera.extent
        let side = min(e.width, e.height)
        guard side > 0, rect.width > 0 else { return CIImage.empty() }
        let square = camera
            .cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        let scale = rect.width / side
        let fitted = square
            .transformed(by: CGAffineTransform(translationX: -square.extent.minX, y: -square.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let radius = rect.width / 2
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": max(0, radius - 1),
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: rect) ?? CIImage.empty()
        return fitted.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Cuts `rect` (normalized, origin top left) out of the image and
    /// moves it to the origin. Core Image's origin is bottom left.
    static func crop(_ image: CIImage, to rect: NormalisedRect) -> CIImage {
        let e = image.extent
        let r = CGRect(x: e.minX + rect.x * e.width,
                       y: e.minY + (1 - rect.y - rect.height) * e.height,
                       width: rect.width * e.width,
                       height: rect.height * e.height)
        guard r.width >= 2, r.height >= 2 else { return image }
        return image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    private func drawCard(_ card: any CardSource, on buffer: CVPixelBuffer, size: CGSize, at time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Paper first, so a card that draws nothing still isn't black.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        card.draw(in: context, size: size, at: max(0, time))
    }

    private func draw(_ overlays: [ExportOverlay], ring: (rect: CGRect, layer: CameraLayer)?,
                      on buffer: CVPixelBuffer, size: CGSize, at time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // The builder's ring around the camera, under captions.
        if let ring {
            let width = max(3, ring.rect.width * 0.03)
            context.setStrokeColor(ring.layer.ringColour)
            context.setLineWidth(width)
            context.strokeEllipse(in: ring.rect.insetBy(dx: width / 2, dy: width / 2))
        }
        for overlay in overlays {
            context.saveGState()
            overlay.draw(in: context, size: size, at: time)
            context.restoreGState()
        }
    }
}

/// camera.mov in the export: its track in the composition, where the
/// bubble sat (camera.json), the cuts to follow, and the ring colour.
struct CameraLayer: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let track: CameraTrack
    let timeline: ExportTimeline
    let ringColour: CGColor
    /// Draws background.json's room behind the person; nil for none.
    var background: BackgroundRenderer?
}

/// Draws nothing; the compositor's paper shows.
private struct BlankCard: CardSource {
    func draw(in context: CGContext, size: CGSize, at cardTime: Double) {}
}
