import AppKit
import CoreText
import ImageIO
import VisionOneKit

/// An intro or outro, drawn full frame by the export compositor. Draws in
/// output pixels, origin bottom left, at seconds into the card.
protocol CardSource: Sendable {
    func draw(in context: CGContext, size: CGSize, at cardTime: Double)
}

/// The cards one export opens and closes with.
struct BrandCardSet: Sendable {
    var intro: (any CardSource)?
    var outro: (any CardSource)?

    static let empty = BrandCardSet(intro: nil, outro: nil)
}

/// Frames of an HTML card, rendered by WebKit ahead of the export and
/// kept as PNG data. Frames that repeat (once the animation settles) are
/// stored once.
struct RenderedCard: CardSource {
    let frameRate: Int
    /// Unique frames as PNG.
    let frames: [Data]
    /// For each frame time, which entry of `frames` to show.
    let order: [Int]

    func draw(in context: CGContext, size: CGSize, at cardTime: Double) {
        guard !order.isEmpty else { return }
        let index = order[min(max(0, Int(cardTime * Double(frameRate))), order.count - 1)]
        guard let source = CGImageSourceCreateWithData(frames[index] as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }
}

/// The built-in brand card drawn with Core Graphics. Used when WebKit
/// can't render the HTML card, so an export never fails over its intro.
struct NativeCard: CardSource, @unchecked Sendable {
    enum Kind { case intro, outro }

    let kind: Kind
    let brand: BrandKit
    /// The logo, already decoded. CGImage is immutable, so sharing it
    /// with the compositor's threads is safe.
    let logo: CGImage?
    /// A personalised version's two lines ("Made for Thandi", "Joburg
    /// Taxi Association"), drawn instead of the name and tagline.
    var headline: String?
    var subline: String?

    func draw(in context: CGContext, size: CGSize, at cardTime: Double) {
        let short = min(size.width, size.height)
        let paper = CaptionRenderer.color(hex: brand.paperHex)
        let ink = CaptionRenderer.color(hex: brand.inkHex)
        let ring = CaptionRenderer.color(hex: brand.ring.hex)

        context.setFillColor(paper)
        context.fill(CGRect(origin: .zero, size: size))

        // The ring grows in over the first 0.6 s, text follows.
        let ringIn = ease(cardTime / 0.6)
        let textIn = ease((cardTime - 0.25) / 0.6)
        let left = size.width * 0.08
        let diameter = short * 0.18
        let lineWidth = short * 0.022

        let name = headline ?? (brand.name.isEmpty ? "Vision One" : brand.name)
        let second = headline != nil ? (subline ?? "") : (kind == .intro ? brand.tagline : brand.cta)
        let third = kind == .outro ? brand.displaySite : ""

        let nameLine = line(name, font: font(brand.fonts.display, size: short * 0.09, bold: true), color: ink)
        let secondLine = second.isEmpty ? nil : line(second, font: font(brand.fonts.body, size: short * 0.04, bold: false),
                                                     color: ink.copy(alpha: 0.72) ?? ink)
        let thirdLine = third.isEmpty ? nil : line(third, font: CTFontCreateWithName("Menlo" as CFString, short * 0.03, nil), color: ink)

        // Stack ring, name and lines, centred vertically.
        let gap = short * 0.03
        var heights: [CGFloat] = [diameter, nameLine.height]
        if let secondLine { heights.append(secondLine.height) }
        if let thirdLine { heights.append(thirdLine.height + gap) }
        let total = heights.reduce(0, +) + gap * CGFloat(heights.count - 1)
        var top = (size.height + total) / 2

        // Ring
        context.saveGState()
        let ringRect = CGRect(x: left, y: top - diameter, width: diameter, height: diameter)
        let scale = 0.6 + 0.4 * ringIn
        context.translateBy(x: ringRect.midX, y: ringRect.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -ringRect.midX, y: -ringRect.midY)
        context.setAlpha(ringIn)
        context.setStrokeColor(ring)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: ringRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        if let logo {
            let inner = ringRect.insetBy(dx: diameter * 0.18, dy: diameter * 0.18)
            context.draw(logo, in: fit(CGSize(width: logo.width, height: logo.height), in: inner))
        } else {
            let letter = line(brand.initial, font: font(brand.fonts.display, size: diameter * 0.42, bold: true), color: ink)
            draw(letter, in: context, x: ringRect.midX - letter.width / 2, baseline: ringRect.midY - (letter.ascent - letter.descent) / 2)
        }
        context.restoreGState()
        top -= diameter + gap

        // Text rises a little as it fades in.
        let rise = (1 - textIn) * short * 0.03
        context.saveGState()
        context.setAlpha(textIn)
        draw(nameLine, in: context, x: left, baseline: top - nameLine.ascent - rise)
        top -= nameLine.height + gap
        if let secondLine {
            draw(secondLine, in: context, x: left, baseline: top - secondLine.ascent - rise)
            top -= secondLine.height + gap
        }
        if let thirdLine {
            context.setStrokeColor(ring)
            context.setLineWidth(short * 0.006)
            context.move(to: CGPoint(x: left, y: top - rise))
            context.addLine(to: CGPoint(x: left + max(thirdLine.width, short * 0.2), y: top - rise))
            context.strokePath()
            draw(thirdLine, in: context, x: left, baseline: top - gap - thirdLine.ascent - rise)
        }
        context.restoreGState()
    }

    // MARK: - Text

    private struct Line {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        var height: CGFloat { ascent + descent }
    }

    private func line(_ text: String, font: CTFont, color: CGColor) -> Line {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return Line(line: line, width: width, ascent: ascent, descent: descent)
    }

    private func draw(_ line: Line, in context: CGContext, x: CGFloat, baseline: CGFloat) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line.line, context)
    }

    /// The named font, or the system font when it isn't installed.
    private func font(_ name: String, size: CGFloat, bold: Bool) -> CTFont {
        if let named = NSFont(name: name, size: size) {
            let font = named as CTFont
            guard bold else { return font }
            return CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .heavy : .regular) as CTFont
    }

    private func fit(_ image: CGSize, in rect: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = min(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func ease(_ x: Double) -> CGFloat {
        let t = min(max(x, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }
}

/// The brand logo on every frame of the video (not the cards), where the
/// person dragged it in Settings · Brand.
struct WatermarkOverlay: ExportOverlay, @unchecked Sendable {
    let logo: CGImage
    let watermark: BrandWatermark

    func draw(in context: CGContext, size: CGSize, at outputTime: Double) {
        let width = min(size.width, size.height) * CGFloat(min(max(watermark.size, 0.02), 0.5))
        let aspect = logo.width > 0 ? CGFloat(logo.height) / CGFloat(logo.width) : 1
        let height = width * aspect
        // Settings measure from the top left; the context's origin is bottom left.
        let centre = CGPoint(x: size.width * CGFloat(watermark.centerX), y: size.height * CGFloat(1 - watermark.centerY))
        var rect = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
        rect.origin.x = min(max(rect.origin.x, 0), size.width - width)
        rect.origin.y = min(max(rect.origin.y, 0), size.height - height)
        context.setAlpha(CGFloat(min(max(watermark.opacity, 0), 1)))
        context.interpolationQuality = .high
        context.draw(logo, in: rect)
    }
}
