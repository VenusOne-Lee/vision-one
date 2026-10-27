import AppKit
import AVFoundation
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision
import VisionOneKit

/// Grabs and measures frames for thumbnails, and draws the finished
/// thumbnail: the frame, a shade so the title reads, the title, and the
/// camera in the builder's ring. Plain Core Graphics, so what the editor
/// previews is exactly what gets saved.
struct ThumbnailRenderer: Sendable {
    let take: Take

    /// Where the title and the face ended up, normalized over the image
    /// (origin top left), so the editor can put drag handles on them.
    struct Layout: Equatable, Sendable {
        var title: NormalizedRect
        var face: NormalizedRect?
    }

    enum Failure: LocalizedError {
        case noFrame
        case write(URL)

        var errorDescription: String? {
            switch self {
            case .noFrame: return "Couldn't read a frame from this take."
            case let .write(url): return "Couldn't save \(url.lastPathComponent)."
            }
        }
    }

    // MARK: Frames

    /// The frame at `time` (seconds of the take) from screen.mov, at most
    /// `maxSize` on its long edge (0 for full size).
    func screenFrame(at time: Double, maxSize: CGFloat = 0) async throws -> CGImage {
        try await frame(of: take.screenURL, at: time, maxSize: maxSize)
    }

    /// The camera frame at `time`, or nil when the take has no camera.
    func cameraFrame(at time: Double, maxSize: CGFloat = 0) async -> CGImage? {
        guard FileManager.default.fileExists(atPath: take.cameraURL.path) else { return nil }
        return try? await frame(of: take.cameraURL, at: time, maxSize: maxSize)
    }

    private func frame(of url: URL, at time: Double, maxSize: CGFloat) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if maxSize > 0 { generator.maximumSize = CGSize(width: maxSize, height: maxSize) }
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        do {
            return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        } catch {
            throw Failure.noFrame
        }
    }

    /// Measures the frames the picker asks for. Sharpness is relative to
    /// the sharpest frame of the take, so one blurry take still gets
    /// a fair pick.
    func candidates(edits: EditList, events: EventLog?, picker: ThumbnailPicker) async -> [(ThumbnailPicker.Metrics, CGImage)] {
        var measured: [(ThumbnailPicker.Metrics, CGImage)] = []
        for time in picker.sampleTimes(edits: edits) {
            guard !Task.isCancelled, let image = try? await screenFrame(at: time, maxSize: 640) else { continue }
            let face = await cameraFrame(at: time, maxSize: 480).flatMap(Self.faceQuality) ?? Self.faceQuality(image)
            let metrics = ThumbnailPicker.Metrics(
                time: time,
                sharpness: Self.edgeEnergy(image),
                faceQuality: face,
                brightness: Self.brightness(image),
                cursorSpeed: events.map { ThumbnailPicker.cursorSpeed(at: time, events: $0) } ?? 0,
                distanceFromCut: picker.distanceFromCut(time, edits: edits))
            measured.append((metrics, image))
        }
        let sharpest = measured.map(\.0.sharpness).max() ?? 0
        if sharpest > 0 {
            for i in measured.indices { measured[i].0.sharpness /= sharpest }
        }
        let ranked = picker.rank(measured.map(\.0))
        return ranked.compactMap { pick in measured.first { $0.0.time == pick.time } }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Mean of the edge image: busy, crisp frames score high, motion
    /// blur and fades score low.
    static func edgeEnergy(_ image: CGImage) -> Double {
        let edges = CIImage(cgImage: image).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
        return average(edges, extent: CIImage(cgImage: image).extent)
    }

    static func brightness(_ image: CGImage) -> Double {
        let ci = CIImage(cgImage: image)
        return average(ci, extent: ci.extent)
    }

    private static func average(_ image: CIImage, extent: CGRect) -> Double {
        let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(mean, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    /// Vision's face capture quality (sharp, open eyes, facing the
    /// camera), or nil without a face.
    static func faceQuality(_ image: CGImage) -> Double? {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let quality = request.results?.compactMap({ $0.faceCaptureQuality.map { Double(truncating: $0 as NSNumber) } }).max()
        else { return nil }
        return quality
    }

    // MARK: Drawing

    /// Draws the thumbnail at `size`. `frame` is the screen frame and
    /// `camera` the camera frame, if any.
    static func compose(frame: CGImage, camera: CGImage?, design: ThumbnailDesign,
                        size: ThumbnailSize, scale: CGFloat = 1) -> (CGImage, Layout)? {
        let width = Int(CGFloat(size.pixels.width) * scale)
        let height = Int(CGFloat(size.pixels.height) * scale)
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high

        // The frame fills the image, cropped to its shape around the
        // middle.
        ctx.setFillColor(color(design.style.shadeHex, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(frame, in: fill(CGSize(width: frame.width, height: frame.height), into: CGRect(x: 0, y: 0, width: w, height: h)))

        // Shade the lower part so white type reads on any screen.
        let shade = color(design.style.shadeHex, alpha: 0.85)
        let clear = color(design.style.shadeHex, alpha: 0)
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: [shade, clear] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h * 0.6), options: [])
        }

        // Camera bubble in the builder's ring.
        var faceRect: NormalizedRect?
        if design.showFace, let camera {
            let d = CGFloat(design.faceSize) * min(w, h)
            let center = CGPoint(x: CGFloat(design.faceX) * w, y: h - CGFloat(design.faceY) * h)
            let circle = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            ctx.saveGState()
            ctx.addEllipse(in: circle)
            ctx.clip()
            ctx.draw(camera, in: fill(CGSize(width: camera.width, height: camera.height), into: circle))
            ctx.restoreGState()
            let ring = d * 0.05
            ctx.setStrokeColor(color(design.style.ringHex, alpha: 1))
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
            faceRect = NormalizedRect(x: Double(circle.minX / w), y: Double((h - circle.maxY) / h),
                                      width: Double(d / w), height: Double(d / h))
        }

        // Title, as big as fits the box in at most three lines.
        let boxWidth = CGFloat(design.titleWidth) * w
        let maxHeight = h * 0.42
        let text = design.title.trimmingCharacters(in: .whitespaces)
        var titleRect = CGRect(x: CGFloat(design.titleX) * w, y: h - CGFloat(design.titleY) * h, width: boxWidth, height: 0)
        if !text.isEmpty {
            var fontSize = min(w, h) * 0.16
            var framesetter: CTFramesetter
            var fitted: CGSize
            repeat {
                framesetter = CTFramesetterCreateWithAttributedString(attributed(text, size: fontSize, style: design.style))
                fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: boxWidth, height: .greatestFiniteMagnitude), nil)
                fontSize *= 0.92
            } while (fitted.height > maxHeight || fitted.height > fontSize / 0.92 * 3.4) && fontSize > 12 * scale
            let top = h - CGFloat(design.titleY) * h
            titleRect = CGRect(x: CGFloat(design.titleX) * w, y: top - fitted.height, width: boxWidth, height: fitted.height)
            let path = CGPath(rect: titleRect.insetBy(dx: 0, dy: -2), transform: nil)
            let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(ctFrame, ctx)
        }
        let layout = Layout(
            title: NormalizedRect(x: Double(titleRect.minX / w), y: Double((h - titleRect.maxY) / h),
                                  width: Double(titleRect.width / w), height: Double(max(titleRect.height, h * 0.08) / h)),
            face: faceRect)
        guard let image = ctx.makeImage() else { return nil }
        return (image, layout)
    }

    private static func attributed(_ text: String, size: CGFloat, style: ThumbnailStyle) -> CFAttributedString {
        let font = NSFont(name: style.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 0.92
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color(style.textHex, alpha: 1)) ?? .white,
            .kern: -size * 0.02,
            .paragraphStyle: paragraph,
        ]) as CFAttributedString
    }

    /// Aspect fill: the rect to draw `image` in so it covers `box`.
    static func fill(_ image: CGSize, into box: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = max(box.width / image.width, box.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func color(_ hex: String, alpha: CGFloat) -> CGColor {
        let rgb = ThumbnailStyle.rgb(hex) ?? 0x121212
        return CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Saving

    /// Writes the image as JPEG (stepping the quality down until it fits
    /// the size's limit) or PNG.
    static func write(_ image: CGImage, size: ThumbnailSize, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if size.fileExtension == "png" {
            try encode(image, type: .png, quality: nil, to: url)
            return
        }
        for quality in [0.9, 0.8, 0.7, 0.6] {
            try encode(image, type: .jpeg, quality: quality, to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes <= (size.sizeLimitBytes ?? .max) { return }
        }
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.write(url)
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.write(url) }
    }
}
