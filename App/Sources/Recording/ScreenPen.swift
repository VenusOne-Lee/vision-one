import AppKit
import Combine
import CoreImage
import SwiftUI
import VisionOneKit

/// The pen on the REC bar: draw on the screen while recording. The marks
/// show on screen as you draw, and are saved with the take (drawings.json)
/// so the preview and every export draw them in. Vision One's windows are
/// kept out of screen.mov, so the overlay itself is never recorded.
///
/// Esc or the pen again puts it down. Each stroke holds for a few seconds,
/// then fades, the same on screen and in the export.
@MainActor
final class ScreenPen: ObservableObject {
    static let shared = ScreenPen()

    /// True while the pen is down and clicks draw instead of reaching apps.
    @Published private(set) var isDrawing = false
    /// True while a screen, window or area take is recording.
    @Published private(set) var isAvailable = false
    /// Strokes so far, on the recording's clock, for the overlay to show.
    @Published fileprivate private(set) var strokes: [ScreenDrawing.Stroke] = []
    @Published fileprivate private(set) var current: [ScreenDrawing.Point] = []

    private var captureFrame: CGRect = .zero
    /// screen.mov's first frame on the host clock.
    private var origin: Double?
    private var panel: ScreenPenPanel?

    private init() {}

    // MARK: Recording

    /// `captureFrame` is in Core Graphics global points (origin top left).
    func begin(captureFrame: CGRect) {
        cancel()
        guard captureFrame.width > 0, captureFrame.height > 0 else { return }
        self.captureFrame = captureFrame
        isAvailable = true
    }

    func setOrigin(_ seconds: Double) {
        origin = seconds
    }

    /// Saves the strokes with the take, if there are any, and puts the pen away.
    func end(writingTo take: Take) {
        finishStroke()
        let drawing = ScreenDrawing(strokes: strokes)
        if !drawing.isEmpty {
            try? drawing.write(to: take.drawingsURL)
        }
        cancel()
    }

    func cancel() {
        panel?.orderOut(nil)
        panel = nil
        isDrawing = false
        isAvailable = false
        strokes = []
        current = []
        origin = nil
    }

    // MARK: Pen

    func toggle() {
        isDrawing ? putDown() : pickUp()
    }

    private func pickUp() {
        guard isAvailable else { return }
        if panel == nil { makePanel() }
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        isDrawing = true
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func putDown() {
        finishStroke()
        isDrawing = false
        // The panel stays, letting go of the mouse, so strokes still fade out.
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        // Hand the keyboard back to the app being recorded.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Seconds into the recording now, or nil before the first frame.
    private var now: Double? {
        origin.map { HostClock.now - $0 }
    }

    /// `point` in the overlay's own points, from its top left.
    fileprivate func draw(at point: CGPoint) {
        guard isDrawing, let t = now else { return }
        let x = min(max(point.x / captureFrame.width, 0), 1)
        let y = min(max(point.y / captureFrame.height, 0), 1)
        current.append(ScreenDrawing.Point(t: t, x: x, y: y))
    }

    fileprivate func finishStroke() {
        guard !current.isEmpty else { return }
        strokes.append(ScreenDrawing.Stroke(points: current))
        current = []
    }

    /// What the overlay shows now: finished strokes as they fade, and the
    /// stroke being drawn.
    fileprivate func visible() -> [ScreenDrawing.Visible] {
        guard let t = now else { return [] }
        var shown = ScreenDrawing(strokes: strokes).visible(atSource: t)
        if !current.isEmpty { shown.append(ScreenDrawing.Visible(points: current, opacity: 1)) }
        return shown
    }

    private func makePanel() {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = CGRect(x: captureFrame.minX, y: mainHeight - captureFrame.maxY,
                           width: captureFrame.width, height: captureFrame.height)
        let panel = ScreenPenPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        // Above the apps being recorded, just under the REC bar (floating),
        // so the pen button there can still put the pen down.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.putDown() }
        panel.contentView = PenHostingView(rootView: ScreenPenView(pen: self).themed())
        self.panel = panel
    }
}

/// A borderless panel that takes Esc without bringing Vision One forward.
private final class ScreenPenPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The first click draws, rather than only focusing the panel.
private final class PenHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ScreenPenView: View {
    @ObservedObject var pen: ScreenPen

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let shown = pen.visible()
                Canvas { context, size in
                    for stroke in shown {
                        ScreenPenView.draw(stroke, in: &context, size: size)
                    }
                }
            }
            if pen.isDrawing {
                // Clicks need something to land on; this is all but clear.
                Color.white.opacity(0.001)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { pen.draw(at: $0.location) }
                            .onEnded { _ in pen.finishStroke() }
                    )
                Text("Drawing · Esc to stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)))
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(pen.isDrawing ? "Drawing on the screen" : "Screen drawings")
    }

    nonisolated static func draw(_ stroke: ScreenDrawing.Visible, in context: inout GraphicsContext, size: CGSize) {
        guard let first = stroke.points.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for point in stroke.points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
        }
        if stroke.points.count == 1 {
            path.addLine(to: CGPoint(x: first.x * size.width + 0.1, y: first.y * size.height))
        }
        let width = ScreenInk.lineWidth(for: size)
        context.opacity = stroke.opacity
        context.stroke(path, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: width * 1.8, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// Screen drawings in the export and preview, drawn onto the recorded
/// screen at its own size before zooms and crops, so they stay on what
/// they marked. Ink with a white edge, so they show on light and dark.
struct ScreenInk: @unchecked Sendable {
    let drawing: ScreenDrawing
    /// The recording's moment for an output time (follows the cuts).
    let sourceTime: @Sendable (Double) -> Double?

    static func lineWidth(for size: CGSize) -> CGFloat {
        max(3, min(size.width, size.height) * 0.006)
    }

    /// The take's drawings, or nil when nothing was drawn.
    static func make(for take: Take, timeline: ExportTimeline) -> ScreenInk? {
        guard let drawing = ScreenDrawing.read(from: take.drawingsURL) else { return nil }
        return ScreenInk(drawing: drawing) { timeline.sourceTime(forOutput: $0) }
    }

    /// `image` with this moment's strokes on it. The image's origin is
    /// bottom left; stroke points are measured from the top left.
    func apply(to image: CIImage, atOutput t: Double) -> CIImage {
        guard let source = sourceTime(t) else { return image }
        let shown = drawing.visible(atSource: source)
        guard !shown.isEmpty else { return image }
        let e = image.extent
        let width = Self.lineWidth(for: e.size)
        // Only the strokes' box is drawn, so a 5K frame doesn't need a 5K bitmap.
        let points = shown.flatMap(\.points)
        let pad = width * 2
        let box = CGRect(x: points.map(\.x).min()! * e.width - pad,
                         y: (1 - points.map(\.y).max()!) * e.height - pad,
                         width: (points.map(\.x).max()! - points.map(\.x).min()!) * e.width + pad * 2,
                         height: (points.map(\.y).max()! - points.map(\.y).min()!) * e.height + pad * 2)
            .integral
            .intersection(CGRect(origin: .zero, size: e.size))
        guard box.width >= 1, box.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in shown {
            guard let first = stroke.points.first else { continue }
            let path = CGMutablePath()
            let place = { (p: ScreenDrawing.Point) in CGPoint(x: p.x * e.width, y: (1 - p.y) * e.height) }
            path.move(to: place(first))
            for point in stroke.points.dropFirst() { path.addLine(to: place(point)) }
            if stroke.points.count == 1 { path.addLine(to: place(first).applying(.init(translationX: 0.1, y: 0))) }
            context.setAlpha(CGFloat(stroke.opacity))
            context.addPath(path)
            context.setLineWidth(width * 1.8)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            context.strokePath()
            context.addPath(path)
            context.setLineWidth(width)
            context.setStrokeColor(CGColor(srgbRed: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1))
            context.strokePath()
        }
        guard let drawn = context.makeImage() else { return image }
        let ink = CIImage(cgImage: drawn).transformed(by: CGAffineTransform(translationX: e.minX + box.minX,
                                                                              y: e.minY + box.minY))
        return ink.composited(over: image).cropped(to: e)
    }
}
