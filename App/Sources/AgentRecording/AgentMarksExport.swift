import AppKit
import CoreImage
import CoreText
import VisionOneKit

/// An agent recording's marks in the export: the agent's notes as an ink
/// pill at the top left (this overlay), and a ring where each click
/// landed (`AgentClickRings`, drawn on the screen before zooms and crops
/// so it stays on what was clicked).
struct AgentStepsOverlay: ExportOverlay {
    let steps: [AgentMarks.Step]

    static let ink = CGColor(srgbRed: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 0.92)
    static let paper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// The steps for a take, or nil when it isn't an agent recording or
    /// the agent sent no notes.
    static func make(for take: Take, timeline: ExportTimeline) -> AgentStepsOverlay? {
        guard let log = AgentActionLog.load(for: take),
              let marks = AgentMarks(log: log, recordedWidth: nil, recordedHeight: nil) else { return nil }
        let steps = marks.steps(on: timeline)
        return steps.isEmpty ? nil : AgentStepsOverlay(steps: steps)
    }

    func draw(in context: CGContext, size: CGSize, at outputTime: Double) {
        guard let step = steps.first(where: { $0.start <= outputTime && outputTime < $0.end }),
              size.width > 0, size.height > 0 else { return }
        let fontSize = min(size.width, size.height) * 0.034
        let font = CaptionRenderer.font(size: fontSize, weight: .medium)
        let text = NSAttributedString(string: step.text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.paper,
        ])
        var line = CTLineCreateWithAttributedString(text as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = fontSize * 0.7, padY = fontSize * 0.4
        let margin = min(size.width, size.height) * 0.04
        // Long notes end in an ellipsis rather than running off the frame.
        let widest = size.width * 0.7 - padX * 2
        if width > widest, let truncated = CTLineCreateTruncatedLine(
            line, Double(widest), .end,
            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.paper,
            ]) as CFAttributedString)) {
            line = truncated
            width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        }
        let height = ascent + descent + padY * 2
        // Origin is bottom left, so the top left is at the frame's height.
        let box = CGRect(x: margin, y: size.height - margin - height, width: width + padX * 2, height: height)
        // A short fade in and out.
        let fade = min(1, (outputTime - step.start) / 0.2, (step.end - outputTime) / 0.2)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(max(0, fade)))
        context.addPath(CGPath(roundedRect: box, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(Self.ink)
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: box.minX + padX, y: box.minY + padY + descent)
        CTLineDraw(line, context)
    }
}

/// Rings where an agent clicked, drawn onto the recorded screen at its own
/// size, so zooms and crops keep them on what was clicked.
struct AgentClickRings: @unchecked Sendable {
    let marks: AgentMarks
    /// The recording's moment for an output time (follows the cuts).
    let sourceTime: @Sendable (Double) -> Double?

    /// The click marks for a take, or nil when it has no placed clicks.
    static func make(for take: Take, timeline: ExportTimeline) -> AgentClickRings? {
        guard let log = AgentActionLog.load(for: take) else { return nil }
        let events = try? EventLog.read(from: take.eventsURL)
        guard let marks = AgentMarks(log: log, recordedWidth: events?.displayWidth, recordedHeight: events?.displayHeight),
              !marks.clicks.isEmpty else { return nil }
        return AgentClickRings(marks: marks) { timeline.sourceTime(forOutput: $0) }
    }

    /// `image` with this moment's rings on it. The image's origin is
    /// bottom left; click spots are measured from the top left.
    func apply(to image: CIImage, atOutput t: Double) -> CIImage {
        guard let source = sourceTime(t) else { return image }
        let rings = marks.rings(atSource: source)
        guard !rings.isEmpty else { return image }
        let e = image.extent
        let base = min(e.width, e.height) * 0.028
        var result = image
        for ring in rings {
            let centre = CGPoint(x: e.minX + ring.x * e.width, y: e.minY + (1 - ring.y) * e.height)
            let radius = base * (1 + 0.8 * ring.progress)
            let width = max(2, base * 0.28)
            let alpha = 1 - ring.progress
            // Ink inside, a white edge outside, so it shows on light and dark.
            result = Self.ring(at: centre, radius: radius + width, width: width,
                               colour: CIColor(red: 1, green: 1, blue: 1, alpha: alpha * 0.9))
                .composited(over: result)
            result = Self.ring(at: centre, radius: radius, width: width,
                               colour: CIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: alpha))
                .composited(over: result)
        }
        return result.cropped(to: e)
    }

    /// A ring between `radius - width` and `radius`.
    static func ring(at centre: CGPoint, radius: CGFloat, width: CGFloat, colour: CIColor) -> CIImage {
        let inner = max(0, radius - width)
        let bounds = CGRect(x: centre.x - radius - 1, y: centre.y - radius - 1, width: radius * 2 + 2, height: radius * 2 + 2)
        // Colour outside the inner edge…
        let outside = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: centre.x, y: centre.y),
            "inputRadius0": inner,
            "inputRadius1": inner + 1,
            "inputColor0": CIColor.clear,
            "inputColor1": colour,
        ])?.outputImage?.cropped(to: bounds)
        // …kept only inside the outer edge.
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: centre.x, y: centre.y),
            "inputRadius0": radius,
            "inputRadius1": radius + 1,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear,
        ])?.outputImage?.cropped(to: bounds)
        guard let outside, let disc else { return CIImage.empty() }
        return outside.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: disc,
        ])
    }
}
