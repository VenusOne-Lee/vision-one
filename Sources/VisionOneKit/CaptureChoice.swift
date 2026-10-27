import Foundation

/// What a take records: the whole screen, one window, or an area you drag.
public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case screen, window, area

    public var title: String {
        switch self {
        case .screen: return "Screen"
        case .window: return "Window"
        case .area: return "Area"
        }
    }
}

/// A rectangle in display points, origin top left of the display. That's
/// the space ScreenCaptureKit's `sourceRect` and the cursor log use.
public struct CaptureRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Smallest area worth recording, in points.
    public static let minimumSide = 64.0

    /// The rectangle between two drag points, whichever way you dragged.
    public static func between(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> CaptureRect {
        CaptureRect(x: min(ax, bx), y: min(ay, by), width: abs(bx - ax), height: abs(by - ay))
    }

    /// The part of this rectangle that lies inside `bounds`, or nil when
    /// they don't overlap.
    public func clamped(to bounds: CaptureRect) -> CaptureRect? {
        let minX = max(x, bounds.x)
        let minY = max(y, bounds.y)
        let maxX = min(x + width, bounds.x + bounds.width)
        let maxY = min(y + height, bounds.y + bounds.height)
        guard maxX > minX, maxY > minY else { return nil }
        return CaptureRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var isBigEnough: Bool {
        width >= Self.minimumSide && height >= Self.minimumSide
    }

    /// Video size in pixels. HEVC needs even sides, so odd sizes round down.
    public func pixelSize(scale: Double) -> (width: Int, height: Int) {
        func even(_ points: Double) -> Int {
            let pixels = Int((points * scale).rounded(.down))
            return max(2, pixels - pixels % 2)
        }
        return (even(width), even(height))
    }
}

/// The choices in the menu bar panel. Saved between launches, so ⌘⇧R
/// records the same way as last time.
public struct CaptureChoice: Codable, Equatable, Sendable {
    public var mode: CaptureMode
    /// Core Graphics display ID; nil means the main display.
    public var displayID: UInt32?
    /// ScreenCaptureKit window ID, for Window mode.
    public var windowID: UInt32?
    /// The dragged area on `displayID`, for Area mode.
    public var area: CaptureRect?
    public var includeMicrophone: Bool
    public var includeSystemSound: Bool

    public init(
        mode: CaptureMode = .screen,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        area: CaptureRect? = nil,
        includeMicrophone: Bool = true,
        includeSystemSound: Bool = true
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowID = windowID
        self.area = area
        self.includeMicrophone = includeMicrophone
        self.includeSystemSound = includeSystemSound
    }

    /// What's still missing before this choice can record, if anything.
    public var missingStep: MissingStep? {
        switch mode {
        case .screen: return nil
        case .window: return windowID == nil ? .pickWindow : nil
        case .area: return area?.isBigEnough == true ? nil : .dragArea
        }
    }

    public enum MissingStep: Equatable, Sendable {
        case pickWindow, dragArea
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// The saved choice, or the default when nothing valid was saved.
    public static func decoded(from data: Data?) -> CaptureChoice {
        guard let data, let choice = try? JSONDecoder().decode(CaptureChoice.self, from: data) else {
            return CaptureChoice()
        }
        return choice
    }
}

/// A window as ScreenCaptureKit lists it, reduced to what the picker needs.
public struct WindowCandidate: Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let appName: String
    public let bundleID: String?
    public let title: String?
    public let width: Double
    public let height: Double
    /// Window layer; 0 is normal app windows. Menus, the Dock and
    /// overlays sit on other layers.
    public let layer: Int
    public let isOnScreen: Bool

    public init(id: UInt32, appName: String, bundleID: String?, title: String?,
                width: Double, height: Double, layer: Int, isOnScreen: Bool) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
        self.layer = layer
        self.isOnScreen = isOnScreen
    }

    /// "Safari: Version One" or just "Safari" when the window has no title.
    public var label: String {
        guard let title, !title.isEmpty, title != appName else { return appName }
        return "\(appName): \(title)"
    }

    /// Normal, visible app windows worth recording, sorted by app then
    /// title. Leaves out Vision One's own windows.
    public static func pickable(_ windows: [WindowCandidate], excludingBundleID ownBundleID: String?) -> [WindowCandidate] {
        windows
            .filter { window in
                window.isOnScreen
                    && window.layer == 0
                    && window.width >= CaptureRect.minimumSide
                    && window.height >= CaptureRect.minimumSide
                    && !window.appName.isEmpty
                    && (ownBundleID == nil || window.bundleID != ownBundleID)
            }
            .sorted { ($0.appName.lowercased(), $0.label.lowercased()) < ($1.appName.lowercased(), $1.label.lowercased()) }
    }
}
