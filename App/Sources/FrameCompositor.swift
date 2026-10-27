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
    /// Blurs and zooms, applied to the screen frame before it's scaled.
    let effects: FrameEffects?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, overlays: [ExportOverlay], effects: FrameEffects? = nil) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.overlays = overlays
        self.effects = effects
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
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
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "VisionOne.Export", code: 1))
            return
        }

        let size = request.renderContext.size
        var image = CIImage(cvPixelBuffer: source)
        if let effects = instruction.effects, !effects.isEmpty {
            image = FrameEffectRenderer.apply(effects, to: image, atOutput: request.compositionTime.seconds)
        }
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Centre it; the shape matches in v0.1, so this only matters once
        // reframing to 9:16 and 1:1 arrives.
        let x = (size.width - scaled.extent.width) / 2
        let y = (size.height - scaled.extent.height) / 2
        let placed = scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        context.render(placed, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        if !instruction.overlays.isEmpty {
            draw(instruction.overlays, on: output, size: size, at: request.compositionTime.seconds)
        }
        request.finish(withComposedVideoFrame: output)
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
