import AVFoundation
import CoreImage
import VisionOneKit

/// One instruction for the whole export: which track is the screen and
/// what to draw on top. AVVideoCompositionCoreAnimationTool would be
/// simpler for overlays, but it only works with AVAssetExportSession, and
/// export needs AVAssetReader to control the bitrate.
final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let overlays: [ExportOverlay]
    /// The part of the frame to show, normalized with origin top left, at
    /// an output time. Clips use it to cut a 9:16 or 1:1 window out of
    /// the wide screen. nil shows the whole frame.
    let crop: (@Sendable (Double) -> NormalizedRect?)?
    /// Fills the space around a frame that doesn't match the output shape.
    let background: CIColor

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, overlays: [ExportOverlay],
         crop: (@Sendable (Double) -> NormalizedRect?)? = nil, background: CIColor = .black) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.overlays = overlays
        self.crop = crop
        self.background = background
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Scales each screen frame to the export size with Core Image (on the
/// GPU), then lets overlays draw on top with Core Graphics. The camera
/// bubble, burned-in captions and click zooms all plug in here.
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
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VisionOne.Export", code: 1))
            return
        }

        let size = request.renderContext.size
        var image = CIImage(cvPixelBuffer: source)
        if let rect = instruction.crop?(request.compositionTime.seconds) {
            image = Self.crop(image, to: rect)
        }
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Centre it. A clip's window matches the output shape; "fit"
        // clips show the whole screen on the background.
        let x = (size.width - scaled.extent.width) / 2
        let y = (size.height - scaled.extent.height) / 2
        let placed = scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: CIImage(color: instruction.background).cropped(to: CGRect(origin: .zero, size: size)))
        context.render(placed, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        if !instruction.overlays.isEmpty {
            draw(instruction.overlays, on: output, size: size, at: request.compositionTime.seconds)
        }
        request.finish(withComposedVideoFrame: output)
    }

    /// Cuts `rect` (normalized, origin top left) out of the image and
    /// moves it to the origin. Core Image's origin is bottom left.
    static func crop(_ image: CIImage, to rect: NormalizedRect) -> CIImage {
        let e = image.extent
        let r = CGRect(x: e.minX + rect.x * e.width,
                       y: e.minY + (1 - rect.y - rect.height) * e.height,
                       width: rect.width * e.width,
                       height: rect.height * e.height)
        guard r.width >= 2, r.height >= 2 else { return image }
        return image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    private func draw(_ overlays: [ExportOverlay], on buffer: CVPixelBuffer, size: CGSize, at time: Double) {
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
        for overlay in overlays {
            context.saveGState()
            overlay.draw(in: context, size: size, at: time)
            context.restoreGState()
        }
    }
}
