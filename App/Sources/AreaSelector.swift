import AppKit
import SwiftUI
import VisionOneKit

/// Full-screen overlay for choosing the area to record. Draw it, then
/// move it or resize it from any of its eight handles, or pick a shape
/// (16:9, 9:16, 1:1) and it keeps that shape. It's dashed while you're
/// still choosing, the app's mark for "proposed". Return accepts, Esc
/// cancels, arrow keys nudge (Shift for ten points). Click a window to take
/// its frame; while drawing or resizing, edges near a window's edge snap
/// onto it. Vision One's own windows are never recorded, so the overlay
/// stays out of the take.
@MainActor
final class AreaSelector {
    static let shared = AreaSelector()
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func show(displayID: UInt32?, current: CaptureRect?, acceptTitle: String,
              onAccept: @escaping @MainActor (UInt32, CaptureRect) -> Void) {
        close()
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main ?? NSScreen.screens[0]
        guard let screenID = screen.displayID else { return }
        // Start from the last area when it was on this screen.
        let start = screenID == displayID ? current : nil

        let model = AreaSelection(rect: start.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
        model.windows = Self.windows(on: screenID)
        let view = AreaSelectView(model: model, acceptTitle: acceptTitle) { [weak self] rect in
            self?.close()
            onAccept(screenID, CaptureRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        } cancel: { [weak self] in
            self?.close()
        }

        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(screen.frame, display: true)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                MainActor.assumeIsolated { view.cancel() }
                return nil
            case 36, 76: // Return, Enter
                MainActor.assumeIsolated {
                    if let rect = model.rect, model.isBigEnough { view.accept(rect) }
                }
                return nil
            case 123, 124, 125, 126: // Left, Right, Down, Up
                let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
                let dx: Double = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
                let dy: Double = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
                MainActor.assumeIsolated { model.nudge(dx: dx, dy: dy) }
                return nil
            default:
                return event
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Other apps' normal windows on this display, front to back, in the
    /// display's points from its top left. Only frames are read, which
    /// needs no permission.
    static func windows(on displayID: UInt32) -> [CaptureRect] {
        let origin = CGDisplayBounds(displayID).origin
        let size = CGDisplayBounds(displayID).size
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 40, frame.height >= 40 else { return nil }
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
                .intersection(CGRect(origin: .zero, size: size))
            guard !local.isNull, local.width >= 40, local.height >= 40 else { return nil }
            return CaptureRect(x: local.minX, y: local.minY, width: local.width, height: local.height)
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A borderless panel that can still take key presses.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The area being chosen. Drag inside it to move it, drag a handle to
/// resize it, or drag anywhere else to draw a new one.
@MainActor
private final class AreaSelection: ObservableObject {
    @Published var rect: CGRect?
    /// Other apps' windows, front to back, for clicking and snapping.
    var windows: [CaptureRect] = []
    /// The window under the pointer before an area is chosen.
    @Published var hovered: CGRect?
    /// Free, or a shape the area keeps while you draw and resize it.
    @Published private(set) var shape: AreaShape
    private static let shapeKey = "areaShape"
    /// The screen in points, so the area can't leave it.
    var bounds = CaptureRect(x: 0, y: 0, width: 0, height: 0)
    private var drag: Drag?

    private enum Drag {
        case draw
        case move(from: CaptureRect)
        case resize(CaptureRect.Edges, from: CaptureRect)
    }

    /// How close to a handle a drag has to start to grab it, in points.
    static let grab: CGFloat = 10

    init(rect: CGRect?) {
        self.rect = rect
        shape = UserDefaults.standard.string(forKey: Self.shapeKey).flatMap(AreaShape.init(rawValue:)) ?? .free
        if let ratio = shape.ratio, let rect { self.rect = CaptureRect(rect).fitted(ratio: ratio).cgRect }
    }

    /// Picking a shape snaps the area to the biggest box of that shape
    /// inside it. Remembered for next time.
    func setShape(_ shape: AreaShape) {
        self.shape = shape
        UserDefaults.standard.set(shape.rawValue, forKey: Self.shapeKey)
        if let ratio = shape.ratio, let rect {
            self.rect = CaptureRect(rect).fitted(ratio: ratio).cgRect
        }
    }

    func nudge(dx: Double, dy: Double) {
        guard let rect else { return }
        self.rect = CaptureRect(rect).moved(dx: dx, dy: dy, within: bounds).cgRect
    }

    var isBigEnough: Bool {
        guard let rect else { return false }
        return CaptureRect(rect).isBigEnough
    }

    func dragChanged(start: CGPoint, location: CGPoint) {
        if drag == nil { drag = beginDrag(at: start) }
        let dx = location.x - start.x
        let dy = location.y - start.y
        switch drag {
        case .draw:
            var drawn = CaptureRect.between(start.x, start.y, location.x, location.y)
            if let ratio = shape.ratio {
                // Grow from the start point in the drag's direction.
                let width = max(abs(dx), abs(dy) * ratio)
                let height = width / ratio
                drawn = CaptureRect(x: dx < 0 ? start.x - width : start.x, y: dy < 0 ? start.y - height : start.y,
                                    width: width, height: height)
            }
            let kept = drawn.clamped(to: bounds) ?? drawn
            rect = snapped(kept, edges: [.left, .right, .top, .bottom]).cgRect
            hovered = nil
        case let .move(from):
            rect = from.moved(dx: dx, dy: dy, within: bounds).cgRect
        case let .resize(edges, from):
            if let ratio = shape.ratio {
                rect = from.resized(edges, dx: dx, dy: dy, within: bounds, keeping: ratio).cgRect
            } else {
                rect = snapped(from.resized(edges, dx: dx, dy: dy, within: bounds), edges: edges).cgRect
            }
        case nil:
            break
        }
    }

    func dragEnded() {
        drag = nil
    }

    /// Before an area is chosen, the window under the pointer lights up.
    func hover(at point: CGPoint?) {
        guard rect == nil, let point else {
            if hovered != nil { hovered = nil }
            return
        }
        hovered = WindowSnap.window(at: (Double(point.x), Double(point.y)), in: windows)?.cgRect
    }

    /// A click with no area yet takes the window under it, kept to the
    /// chosen shape.
    func click(at point: CGPoint) {
        guard rect == nil, let window = WindowSnap.window(at: (Double(point.x), Double(point.y)), in: windows) else { return }
        var picked = window.clamped(to: bounds) ?? window
        if let ratio = shape.ratio { picked = picked.fitted(ratio: ratio) }
        rect = picked.cgRect
        hovered = nil
    }

    /// Edges near a window's edge (or the screen's) jump onto it. Shapes
    /// with a fixed ratio don't snap, so they keep their shape.
    private func snapped(_ area: CaptureRect, edges: CaptureRect.Edges) -> CaptureRect {
        guard shape.ratio == nil else { return area }
        return WindowSnap.snap(area, edges: edges, to: windows + [bounds])
    }

    private func beginDrag(at point: CGPoint) -> Drag {
        guard let rect else { return .draw }
        let edges = Self.edges(near: point, of: rect)
        if !edges.isEmpty { return .resize(edges, from: CaptureRect(rect)) }
        if rect.contains(point) { return .move(from: CaptureRect(rect)) }
        return .draw
    }

    /// The edges whose handles sit under `point`, if any.
    static func edges(near point: CGPoint, of rect: CGRect) -> CaptureRect.Edges {
        guard rect.insetBy(dx: -grab, dy: -grab).contains(point) else { return [] }
        var edges: CaptureRect.Edges = []
        if abs(point.x - rect.minX) <= grab { edges.insert(.left) }
        if abs(point.x - rect.maxX) <= grab { edges.insert(.right) }
        if abs(point.y - rect.minY) <= grab { edges.insert(.top) }
        if abs(point.y - rect.maxY) <= grab { edges.insert(.bottom) }
        return edges
    }
}

private extension CaptureRect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct AreaSelectView: View {
    @ObservedObject var model: AreaSelection
    let acceptTitle: String
    let accept: (CGRect) -> Void
    let cancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Dim everything except the chosen area.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    if let rect = model.rect { path.addRect(rect) }
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            model.dragChanged(start: drag.startLocation, location: drag.location)
                        }
                        .onEnded { _ in model.dragEnded() }
                )
                .onTapGesture { location in model.click(at: location) }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): model.hover(at: location)
                    case .ended: model.hover(at: nil)
                    }
                }
                .onAppear {
                    model.bounds = CaptureRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
                }

                // The window a click would take, before an area is chosen.
                if model.rect == nil, let window = model.hovered {
                    Rectangle()
                        .strokeBorder(Theme.paper, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: window.width, height: window.height)
                        .offset(x: window.minX, y: window.minY)
                        .allowsHitTesting(false)
                }

                if let rect = model.rect {
                    Rectangle()
                        .strokeBorder(Theme.paper, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)

                    handles(for: rect)

                    controls(for: rect, in: geometry.size)
                } else {
                    hint
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .themed()
    }

    /// Eight white handles with an ink ring: corners and side middles.
    /// They only show the grab points; the drag itself is handled above.
    private func handles(for rect: CGRect) -> some View {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        let size: CGFloat = 10
        return ForEach(points.indices, id: \.self) { index in
            Circle()
                .fill(Theme.paper)
                .overlay(Circle().strokeBorder(Theme.text, lineWidth: 1.5))
                .frame(width: size, height: size)
                .offset(x: points[index].x - size / 2, y: points[index].y - size / 2)
                .allowsHitTesting(false)
        }
    }

    private var shapePicker: some View {
        Picker("Shape", selection: Binding(get: { model.shape }, set: { model.setShape($0) })) {
            ForEach(AreaShape.allCases, id: \.self) { shape in
                Text(shape.title).tag(shape)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Keep the area to a shape: 16:9 for YouTube, 9:16 for Reels and Status, 1:1 for posts")
    }

    private var hint: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Click a window, or drag to choose the area to record. Move or resize it after.")
            shapePicker
            Button("Cancel", action: cancel)
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.paper, in: Capsule())
    }

    /// Size, then Cancel and accept, under the area (or above it when
    /// the area reaches the bottom of the screen).
    private func controls(for rect: CGRect, in size: CGSize) -> some View {
        let height: CGFloat = 40
        let below = rect.maxY + Theme.Space.sm + height <= size.height
        let y = below ? rect.maxY + Theme.Space.sm : max(Theme.Space.sm, rect.minY - Theme.Space.sm - height)
        return HStack(spacing: Theme.Space.sm) {
            Text("\(Int(rect.width)) × \(Int(rect.height))")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            shapePicker
            Button("Cancel", action: cancel)
                .buttonStyle(PillButtonStyle(kind: .secondary))
            Button(acceptTitle) { accept(rect) }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!model.isBigEnough)
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(height: height)
        .background(Theme.paper, in: Capsule())
        .fixedSize()
        .offset(x: max(Theme.Space.sm, min(rect.minX, size.width - 560)), y: y)
    }
}

/// A thin orange frame around the area while it's being recorded, so you
/// can see what's in the take. Orange because recording is live. It
/// ignores the mouse and, like every Vision One window, isn't recorded.
@MainActor
final class RegionOutline {
    static let shared = RegionOutline()
    private var panel: NSPanel?

    /// `frame` is in Core Graphics global points (origin top left).
    func show(around frame: CGRect) {
        hide()
        let border: CGFloat = 2
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let appKitFrame = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
            .insetBy(dx: -border, dy: -border)

        let panel = NSPanel(contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Rectangle().strokeBorder(Theme.tally, lineWidth: border))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

extension NSScreen {
    /// The Core Graphics display ID behind this screen.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
