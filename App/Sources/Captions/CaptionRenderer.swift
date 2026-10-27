import AppKit
import CoreText
import SwiftUI
import VisionOneKit

/// Draws the caption on screen at a moment of the edited video: ink text
/// on white panels, keywords in the builder's ring colour. The editor
/// preview and the export compositor both call `draw`, so the preview is
/// exactly what ships.
///
/// `draw(in:size:at:)` matches the exporter's ExportOverlay hook (origin
/// bottom left, size in output pixels, output seconds), so burning in is
/// `extension CaptionRenderer: ExportOverlay {}` once that lands.
struct CaptionRenderer {
    var track: CaptionTrack
    /// Style, size and position, all adjustable in the editor.
    var settings: CaptionSettings
    /// The builder's ring colour as 0xRRGGBB (kept as a number so the
    /// renderer stays Sendable for the export compositor).
    var ringHex: UInt32

    init(track: CaptionTrack, settings: CaptionSettings, ringHex: UInt32 = CaptionRenderer.ringBlue) {
        self.track = track
        self.settings = settings
        self.ringHex = ringHex
    }

    var ringColor: CGColor { Self.color(hex: ringHex) }

    static func color(hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var style: CaptionStyle { settings.style }

    static let ink = CGColor(srgbRed: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
    static let paper = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// Words not said yet, in the word styles.
    static let later = CGColor(srgbRed: 0xA9 / 255.0, green: 0xA8 / 255.0, blue: 0xA3 / 255.0, alpha: 1)
    static let ringBlue: UInt32 = 0x1F3FBF

    /// Draws the cue at `outputTime`, if there is one. The context's
    /// origin is bottom left.
    func draw(in context: CGContext, size: CGSize, at outputTime: Double) {
        guard let cue = track.cue(at: outputTime), size.width > 0, size.height > 0 else { return }

        let fontSize = CGFloat(settings.relativeFontSize) * min(size.width, size.height)
        let font = Self.font(size: fontSize, weight: style.weight)
        let spoken = cue.spokenWordIndex(at: outputTime)
        let padX = fontSize * 0.45
        let padY = fontSize * 0.14
        let lineGap = fontSize * 0.3
        let radius = fontSize * 0.3

        // Build each line, remembering where its words start in the cue.
        var lines: [(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] = []
        var firstIndex = 0
        for words in cue.lines {
            let text = NSMutableAttributedString()
            for (k, word) in words.enumerated() {
                let index = firstIndex + k
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(for: word, index: index, spoken: spoken),
                ]
                text.append(NSAttributedString(string: (k == 0 ? "" : " ") + word.text, attributes: attributes))
            }
            firstIndex += words.count
            let line = CTLineCreateWithAttributedString(text as CFAttributedString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append((line, width, ascent, descent))
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity

        let bottom = CGFloat(settings.bottomInset(isVertical: size.height > size.width)) * size.height
        let center = CGPoint(x: size.width / 2, y: bottom)

        // Shrink to fit if a line would run past 92% of the frame, then
        // pop (Bold pop only) around the bottom centre.
        let widest = (lines.map(\.width).max() ?? 0) + padX * 2
        var scale = min(1, size.width * 0.92 / max(widest, 1))
        if let spoken {
            let words = cue.words
            scale *= CGFloat(style.scale(secondsSinceWordStart: outputTime - words[spoken].start))
        }
        if scale != 1 {
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -center.x, y: -center.y)
        }

        // Lines stack upwards from the bottom inset, last line lowest.
        var y = bottom
        for item in lines.reversed() {
            let height = item.ascent + item.descent + padY * 2
            let box = CGRect(x: center.x - item.width / 2 - padX, y: y, width: item.width + padX * 2, height: height)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(Self.paper)
            context.fillPath()

            context.textPosition = CGPoint(x: box.minX + padX, y: y + padY + item.descent)
            CTLineDraw(item.line, context)
            y += height + lineGap
        }
    }

    private func color(for word: CaptionWord, index: Int, spoken: Int?) -> CGColor {
        let notSaidYet = style.highlightsSpokenWord && (spoken.map { index > $0 } ?? true)
        if style.colorsKeywords && word.isKeyword {
            return notSaidYet ? (ringColor.copy(alpha: 0.45) ?? ringColor) : ringColor
        }
        return notSaidYet ? Self.later : Self.ink
    }

    /// Bricolage Grotesque when it is installed or bundled, otherwise the
    /// system font at the same weight.
    static func font(size: CGFloat, weight: CaptionStyle.Weight) -> NSFont {
        let name: String
        let systemWeight: NSFont.Weight
        switch weight {
        case .medium:
            name = "BricolageGrotesque-Medium"
            systemWeight = .medium
        case .bold:
            name = "BricolageGrotesque-Bold"
            systemWeight = .bold
        case .heavy:
            name = "BricolageGrotesque-ExtraBold"
            systemWeight = .heavy
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: systemWeight)
    }
}

/// The caption over the editor's player, drawn by the same renderer the
/// export uses. Put it in an overlay on the video view and pass the
/// playhead in output seconds. Drag up or down to move the caption; the
/// new spot is saved in `settings.position`.
struct CaptionPreview: View {
    let track: CaptionTrack
    @Binding var settings: CaptionSettings
    var ringHex: UInt32 = CaptionRenderer.ringBlue
    let time: Double

    @State private var dragStart: Double?

    var body: some View {
        let renderer = CaptionRenderer(track: track, settings: settings, ringHex: ringHex)
        GeometryReader { proxy in
            Canvas { context, size in
                context.withCGContext { cg in
                    // SwiftUI's origin is top left; the renderer's is bottom left.
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    renderer.draw(in: cg, size: size, at: time)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let height = max(proxy.size.height, 1)
                        let isVertical = proxy.size.height > proxy.size.width
                        let start = dragStart ?? settings.bottomInset(isVertical: isVertical)
                        dragStart = start
                        let moved = start - Double(value.translation.height / height)
                        settings.position = min(max(moved, CaptionSettings.positionRange.lowerBound),
                                                CaptionSettings.positionRange.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(track.cue(at: time)?.text ?? "No caption")
        .accessibilityHint("Drag up or down to move the captions")
    }
}

/// Caption controls for the editor's side panel: style, size, words at
/// a time, burn in and files. Position is set by dragging on the preview.
struct CaptionControls: View {
    @Binding var settings: CaptionSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Toggle("Captions", isOn: $settings.isOn)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Picker("Style", selection: $settings.style) {
                    ForEach(CaptionStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Size").foregroundStyle(Theme.textMuted)
                    Slider(value: $settings.sizeScale, in: CaptionSettings.sizeRange)
                }

                if settings.style != .subtitle {
                    Stepper(
                        "Words at a time: \(settings.wordsAtATime ?? settings.style.layout.maxWordsPerCue ?? 4)",
                        value: Binding(
                            get: { settings.wordsAtATime ?? settings.style.layout.maxWordsPerCue ?? 4 },
                            set: { settings.wordsAtATime = $0 }
                        ),
                        in: CaptionSettings.wordsRange
                    )
                }

                HStack {
                    Text(settings.position == nil ? "Drag the caption to move it" : "Moved by you")
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    if settings.position != nil {
                        Button("Reset position") { settings.position = nil }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }

                Toggle("Burn into the video", isOn: $settings.burnIn)
                Toggle("Also save .srt and .vtt", isOn: $settings.writeFiles)
            }
            .disabled(!settings.isOn)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
    }
}
