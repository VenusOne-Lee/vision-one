import Foundation

/// Shapes offered when choosing an area. Free lets you draw anything; the
/// others match where takes usually go (YouTube, Reels and Status, posts).
public enum AreaShape: String, CaseIterable, Codable, Sendable {
    case free, wide, tall, square

    public var title: String {
        switch self {
        case .free: return "Free"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .square: return "1:1"
        }
    }

    /// Width over height, or nil for free.
    public var ratio: Double? {
        switch self {
        case .free: return nil
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .square: return 1
        }
    }
}

extension CaptureRect {
    /// The biggest rectangle of `ratio` (width over height) that fits
    /// inside this one, centred on it.
    public func fitted(ratio: Double) -> CaptureRect {
        guard ratio > 0, width > 0, height > 0 else { return self }
        var w = width
        var h = w / ratio
        if h > height {
            h = height
            w = h * ratio
        }
        return CaptureRect(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }

    /// Like `resized`, but keeps `ratio`. The edge or corner opposite the
    /// handle stays put; a side handle grows the other side about its
    /// middle. The result stays inside `bounds`.
    public func resized(_ edges: Edges, dx: Double, dy: Double, within bounds: CaptureRect,
                        keeping ratio: Double) -> CaptureRect {
        guard ratio > 0 else { return resized(edges, dx: dx, dy: dy, within: bounds) }
        let free = resized(edges, dx: dx, dy: dy, within: bounds)
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)

        var w: Double
        if horizontal && vertical {
            // A corner follows whichever side moved further.
            w = max(free.width, free.height * ratio)
        } else if horizontal {
            w = free.width
        } else {
            w = free.height * ratio
        }
        let side = Self.minimumSide
        w = max(w, max(side, side * ratio))
        w = min(w, bounds.width, bounds.height * ratio)
        let h = w / ratio

        let left: Double
        if edges.contains(.left) { left = x + width - w }
        else if edges.contains(.right) { left = x }
        else { left = x + (width - w) / 2 }

        let top: Double
        if edges.contains(.top) { top = y + height - h }
        else if edges.contains(.bottom) { top = y }
        else { top = y + (height - h) / 2 }

        return CaptureRect(x: left, y: top, width: w, height: h).moved(dx: 0, dy: 0, within: bounds)
    }
}
