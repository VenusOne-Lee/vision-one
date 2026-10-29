import AVFoundation
import CoreImage
import ImageIO
import Vision
import VisionOneKit

/// Puts a `CameraBackground` behind the person in camera frames, all on
/// this Mac: Apple Vision cuts the person out, Core Image draws the room.
/// The bubble's live preview and export use the same renderer, so what
/// you see while recording is what the video gets.
///
/// Back to front: the room's layers (shifted for "Move with me", blurred
/// by distance), the person's soft shadow, film grain, then the person,
/// colour matched to the room with the room's light wrapped onto their
/// edges. Off and Blur skip the room.
final class BackgroundRenderer: @unchecked Sendable {
    let background: CameraBackground

    // Everything below is used under `lock`: export can ask from more
    // than one thread.
    private let lock = NSLock()
    private let segmentation: VNGeneratePersonSegmentationRequest
    private let faces = VNDetectFaceRectanglesRequest()
    // One handler for every frame keeps the mask steady from frame to
    // frame instead of shimmering round the hair.
    private let sequence = VNSequenceRequestHandler()
    private var follower = HeadFollower()
    private var backdrop: Backdrop?
    private var gains = LightMatch.RGB.one
    private var frameCount = 0
    private let reader = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private let picture: CGImage?

    /// A room drawn at one frame size, with its average colour.
    private struct Backdrop {
        let size: CGSize
        let layers: [(image: CIImage, depth: Double)]
        let lightFrom: LightSide
        var average: LightMatch.RGB?
    }

    /// Nil when there's nothing to draw (Off, or a picture that's gone).
    init?(background: CameraBackground) {
        guard background.isOn else { return nil }
        if background.style == .picture {
            guard let url = background.pictureURL, let image = Self.loadImage(url) else { return nil }
            picture = image
        } else {
            picture = nil
        }
        self.background = background
        segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// The frame with the background drawn in, `scale` times the buffer's
    /// size, origin at zero. Returns the frame untouched if Vision fails.
    func render(_ buffer: CVPixelBuffer, scale: CGFloat = 1, at time: Double) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        var frame = CIImage(cvPixelBuffer: buffer)
        if scale != 1 { frame = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let extent = frame.extent
        guard extent.width >= 16, extent.height >= 16 else { return frame }

        let following = background.replacesRoom && background.moveWithMe
        do {
            try sequence.perform(following ? [segmentation, faces] : [segmentation], on: buffer)
        } catch {
            return frame
        }
        guard let maskBuffer = segmentation.results?.first?.pixelBuffer else { return frame }
        let mask = Self.grey(CIImage(cvPixelBuffer: maskBuffer))
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(CVPixelBufferGetWidth(maskBuffer)),
                                               y: extent.height / CGFloat(CVPixelBufferGetHeight(maskBuffer))))
            // A pixel or two of feather so the edge isn't a hard cut.
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(1, extent.width / 900))
            .cropped(to: extent)

        if background.style == .blur {
            let room = frame.clampedToExtent().applyingGaussianBlur(sigma: extent.width * 0.018).cropped(to: extent)
            return Self.blend(frame, over: room, mask: mask)
        }

        if following {
            let face = faces.results?.max { $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height }
            follower.update(face: face.map { (x: Double($0.boundingBox.midX), y: Double($0.boundingBox.midY)) },
                            at: time)
        }
        var backdrop = self.backdrop?.size == extent.size ? self.backdrop! : makeBackdrop(size: extent.size)
        let w = extent.width, h = extent.height
        let match = background.matchLight

        // The room, far to near.
        var room = CIImage(color: CIColor(red: 0.93, green: 0.92, blue: 0.9)).cropped(to: extent)
        for layer in backdrop.layers {
            var image = layer.image
            if following {
                let o = follower.offset(depth: layer.depth)
                image = image.transformed(by: CGAffineTransform(translationX: o.dx * w, y: o.dy * h))
            }
            // A webcam focused on a face can't see the far wall sharp.
            let sigma = match ? w * 0.0045 * (1 - layer.depth) : 0
            if sigma > 0.4 {
                image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
            }
            room = image.composited(over: room)
        }
        room = room.cropped(to: extent)

        guard match else {
            self.backdrop = backdrop
            return Self.blend(frame, over: room, mask: mask)
        }

        if backdrop.average == nil { backdrop.average = average(room, in: extent) }
        self.backdrop = backdrop

        // The person's soft shadow, thrown away from the room's light.
        let plan = ShadowPlan(lightFrom: backdrop.lightFrom)
        let shadow = mask.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: plan.dx * w, y: plan.dy * h))
            .applyingGaussianBlur(sigma: plan.softness * w)
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: Self.scale(plan.opacity))
        room = Self.blend(CIImage(color: CIColor(red: 0.12, green: 0.09, blue: 0.06)).cropped(to: extent),
                          over: room, mask: shadow)

        // The same grain the webcam puts on the face, so both share a camera.
        if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let a = 0.05
            let shift = CGAffineTransform(translationX: CGFloat.random(in: 0..<512), y: CGFloat.random(in: 0..<512))
            let grain = noise.transformed(by: shift).cropped(to: extent).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -a / 2, y: -a / 2, z: -a / 2, w: 0),
            ])
            room = grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: room])
                .cropped(to: extent)
        }

        // Tint and brighten the person toward the room's light. Measured
        // every half second or so; light doesn't change faster than that.
        if frameCount % 15 == 0, let roomAverage = backdrop.average, let person = personAverage(frame, mask: mask) {
            gains = LightMatch.gains(person: person, room: roomAverage)
        }
        frameCount += 1
        var person = frame.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains.r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains.g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains.b, w: 0),
        ])

        // Light wrap: a soft band of the room's colour just inside the
        // person's edge, as if its light spilled round them.
        let wide = room.clampedToExtent().applyingGaussianBlur(sigma: w * 0.03).cropped(to: extent)
        let soft = mask.clampedToExtent().applyingGaussianBlur(sigma: w * 0.012).cropped(to: extent)
        let edge = soft.applyingFilter("CIColorInvert")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            .applyingFilter("CIColorMatrix", parameters: Self.scale(1.2))
        person = Self.blend(wide, over: person, mask: edge)

        return Self.blend(person, over: room, mask: mask)
    }

    // MARK: Room

    private func makeBackdrop(size: CGSize) -> Backdrop {
        let over = HeadFollower.overscan
        let big = CGSize(width: (size.width * over).rounded(), height: (size.height * over).rounded())
        // Drawn bigger than the frame and centred on it, so a shifted
        // layer never shows its edge.
        let centre = CGAffineTransform(translationX: -(big.width - size.width) / 2,
                                       y: -(big.height - size.height) / 2)
        if let id = background.room {
            let scene = id.scene
            let layers = scene.layers.compactMap { layer -> (image: CIImage, depth: Double)? in
                guard let image = RoomDrawer.image(of: layer, size: big) else { return nil }
                return (CIImage(cgImage: image).transformed(by: centre), layer.depth)
            }
            return Backdrop(size: size, layers: layers, lightFrom: scene.lightFrom)
        }
        guard let picture else { return Backdrop(size: size, layers: [], lightFrom: .front) }
        let filled = Self.aspectFill(CIImage(cgImage: picture), to: big).transformed(by: centre)
        var layers: [(image: CIImage, depth: Double)] = [(filled, DepthLayers.depths[0])]
        // Nearer parts of the picture as their own layers, when the depth
        // model is on this Mac. Without it the picture moves as one.
        if background.moveWithMe, let depth = DepthEstimator.shared.depth(of: picture, key: background.picture ?? "") {
            let map = Self.aspectFill(depth.map, to: big).transformed(by: centre)
            for (cut, layerDepth) in zip(depth.cuts, DepthLayers.depths.dropFirst()) {
                let m = DepthLayers.maskMatrix(threshold: cut, min: depth.min, max: depth.max)
                let s = CGFloat(m.scale), b = CGFloat(m.bias)
                let mask = map.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: s, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: s, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: b, y: b, z: b, w: 1),
                ]).applyingFilter("CIColorClamp")
                let cutOut = filled.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: filled.extent)
                layers.append((cutOut, layerDepth))
            }
        }
        return Backdrop(size: size, layers: layers, lightFrom: .front)
    }

    // MARK: Measuring

    /// Average colour of `image` over `rect`, 0...1.
    private func average(_ image: CIImage, in rect: CGRect) -> LightMatch.RGB? {
        guard let out = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect),
        ])?.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        reader.render(out, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                      format: .RGBAf, colorSpace: nil)
        return LightMatch.RGB(r: Double(pixel[0]), g: Double(pixel[1]), b: Double(pixel[2]))
    }

    /// Average colour of the person alone: the masked frame's average
    /// over how much of the frame the mask covers.
    private func personAverage(_ frame: CIImage, mask: CIImage) -> LightMatch.RGB? {
        let extent = frame.extent
        let masked = Self.blend(frame, over: CIImage(color: .black).cropped(to: extent), mask: mask)
        guard let sum = average(masked, in: extent), let cover = average(mask, in: extent), cover.r > 0.02 else {
            return nil
        }
        return LightMatch.RGB(r: sum.r / cover.r, g: sum.g / cover.r, b: sum.b / cover.r)
    }

    // MARK: Helpers

    private static func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bottom,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: bottom.extent)
    }

    /// Red copied into green and blue, so a one-channel mask or depth
    /// map reads the same whichever channel a filter looks at.
    static func grey(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Colour matrix parameters that multiply a grey mask by `k`.
    private static func scale(_ k: Double) -> [String: Any] {
        [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ]
    }

    /// Scaled to cover `size` and centred, cropped to it, origin at zero.
    static func aspectFill(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = max(size.width / e.width, size.height / e.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Big enough for a 4K frame, small enough to keep memory sane.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Draws one layer of a `RoomScene` with Core Graphics.
enum RoomDrawer {
    static func image(of layer: RoomScene.Layer, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for shape in layer.shapes {
            context.saveGState()
            draw(shape, in: context, size: size)
            context.restoreGState()
        }
        return context.makeImage()
    }

    private static func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func draw(_ shape: RoomScene.Shape, in context: CGContext, size: CGSize) {
        let r = shape.rect
        // Shapes are top-left origin; Core Graphics is bottom left.
        let rect = CGRect(x: r.x * size.width, y: (1 - r.y - r.height) * size.height,
                          width: r.width * size.width, height: r.height * size.height)
        context.setAlpha(CGFloat(shape.opacity))
        let fill = colour(shape.colour)
        switch shape.kind {
        case .rect:
            context.setFillColor(fill)
            context.fill(rect)
        case let .rounded(share):
            let radius = min(rect.width, rect.height) * CGFloat(min(max(share, 0), 0.5))
            context.setFillColor(fill)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .ellipse:
            context.setFillColor(fill)
            context.fillEllipse(in: rect)
        case .gradient:
            guard let gradient = CGGradient(colorsSpace: nil,
                                            colors: [fill, colour(shape.colour2 ?? shape.colour)] as CFArray,
                                            locations: [0, 1]) else { return }
            context.clip(to: rect)
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        case .glow:
            guard rect.width > 0, rect.height > 0,
                  let gradient = CGGradient(colorsSpace: nil,
                                            colors: [fill, colour(shape.colour, alpha: 0)] as CFArray,
                                            locations: [0, 1]) else { return }
            // A circle squashed to the rect's shape.
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: 1, y: rect.height / rect.width)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: rect.width / 2, options: [])
        case let .frame(share):
            let line = CGFloat(share) * size.width
            context.setStrokeColor(fill)
            context.setLineWidth(line)
            context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
        }
    }
}
