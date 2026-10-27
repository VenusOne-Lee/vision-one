import CoreImage
import VisionOneKit

/// Draws zooms and blurs onto a screen frame with Core Image, before it's
/// scaled to the export size. Export and the editor's preview both come
/// through here, so what you see is what you get.
enum FrameEffectRenderer {
    /// Blurs first, on the whole frame, then the zoom viewport.
    static func apply(_ effects: FrameEffects, to image: CIImage, atOutput t: Double) -> CIImage {
        var image = image
        let blurs = effects.blurs(atOutput: t)
        if !blurs.isEmpty { image = hide(blurs, in: image) }
        let viewport = effects.viewport(atOutput: t)
        if viewport != .full { image = crop(image, to: viewport) }
        return image
    }

    /// A frame box in Core Image's space (origin bottom left, in pixels).
    static func pixelRect(_ rect: FrameRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.x * extent.width,
               y: extent.minY + (1 - rect.maxY) * extent.height,
               width: rect.width * extent.width,
               height: rect.height * extent.height)
    }

    /// The viewport, moved to the origin. The next step scales it to fill
    /// the output, since it has the frame's shape.
    static func crop(_ image: CIImage, to viewport: FrameRect) -> CIImage {
        let rect = pixelRect(viewport.clamped, in: image.extent)
        guard rect.width >= 2, rect.height >= 2 else { return image }
        // Clamp first so a crop on a fractional edge never pulls in
        // transparent pixels (a dark seam once scaled up).
        return image.clampedToExtent()
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Secure blur. A normal Gaussian blur or pixelation still depends on
    /// what's underneath, and tools like Depix can read text back out of
    /// it. Here the box is filled only from the pixels around it: each
    /// pixel is a weighted average of what's outside the box (normalised
    /// convolution), so two frames with different keys in the same place
    /// come out identical. It looks like frosted glass and hides like a
    /// solid bar.
    static func hide(_ rects: [FrameRect], in image: CIImage) -> CIImage {
        let extent = image.extent
        var output = image
        for rect in rects {
            let box = pixelRect(rect.clamped, in: extent).integral.intersection(extent)
            guard box.width >= 1, box.height >= 1 else { continue }
            // Wide enough that the middle of the box still reaches the
            // pixels outside it.
            let sigma = max(min(box.width, box.height) * 0.6, 6)
            let region = box.insetBy(dx: -sigma * 3, dy: -sigma * 3).intersection(extent)

            // Everything in the region except the box itself.
            let strips = [
                CGRect(x: region.minX, y: region.minY, width: box.minX - region.minX, height: region.height),
                CGRect(x: box.maxX, y: region.minY, width: region.maxX - box.maxX, height: region.height),
                CGRect(x: box.minX, y: region.minY, width: box.width, height: box.minY - region.minY),
                CGRect(x: box.minX, y: box.maxY, width: box.width, height: region.maxY - box.maxY),
            ].filter { $0.width > 0 && $0.height > 0 }

            let fill: CIImage
            if strips.isEmpty {
                // The box covers the whole frame: nothing outside to borrow.
                fill = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            } else {
                let outside = strips
                    .map { image.cropped(to: $0) }
                    .reduce(CIImage.empty()) { $1.composited(over: $0) }
                // Blur colour and coverage together, then divide one by the
                // other: an average of outside pixels only.
                fill = outside
                    .applyingGaussianBlur(sigma: sigma)
                    .applyingFilter("CIUnpremultiply")
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    ])
            }
            output = fill.cropped(to: box).composited(over: output)
        }
        return output.cropped(to: extent)
    }
}
