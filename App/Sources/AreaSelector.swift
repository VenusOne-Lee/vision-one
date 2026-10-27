import AppKit
import SwiftUI
import VisionOneKit

/// Full-screen overlay for dragging the area to record. The area is
/// dashed while you're still choosing, the app's mark for "proposed".
/// Return accepts, Esc cancels. Vision One's own windows are never
/// recorded, so the overlay stays out of the take.
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
        panel.appearance = NSAppearance(named: .aqua)
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
            default:
                return event
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
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

@MainActor
private final class AreaSelection: ObservableObject {
    @Published var rect: CGRect?

    init(rect: CGRect?) {
        self.rect = rect
    }

    var isBigEnough: Bool {
        guard let rect else { return false }
        return CaptureRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height).isBigEnough
    }
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
                            model.rect = CGRect(
                                x: min(drag.startLocation.x, drag.location.x),
                                y: min(drag.startLocation.y, drag.location.y),
                                width: abs(drag.location.x - drag.startLocation.x),
                                height: abs(drag.location.y - drag.startLocation.y)
                            )
                        }
                )

                if let rect = model.rect {
                    Rectangle()
                        .strokeBorder(Theme.paper, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)

                    controls(for: rect, in: geometry.size)
                } else {
                    hint
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light) // light only, always
    }

    private var hint: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Drag to choose the area to record.")
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
        .offset(x: max(Theme.Space.sm, min(rect.minX, size.width - 360)), y: y)
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
