import Foundation

/// Choosing an area against the windows on screen: click a window to
/// take its frame, and while drawing or resizing, edges near a window's
/// edge jump onto it. Rects are in one screen's points, origin top left.
public enum WindowSnap {
    /// How near an edge has to be to snap, in points.
    public static let tolerance = 8.0

    /// The front-most window under `point`. `windows` are front to back.
    public static func window(at point: (x: Double, y: Double), in windows: [CaptureRect]) -> CaptureRect? {
        windows.first { w in
            point.x >= w.x && point.x <= w.x + w.width && point.y >= w.y && point.y <= w.y + w.height
        }
    }

    /// `rect` with each of `edges` moved onto the nearest window edge (or
    /// the screen's, through `windows`) within `tolerance`. Edges that
    /// would cross each other are left alone.
    public static func snap(_ rect: CaptureRect, edges: CaptureRect.Edges, to windows: [CaptureRect],
                            tolerance: Double = tolerance) -> CaptureRect {
        let xs = windows.flatMap { [$0.x, $0.x + $0.width] }
        let ys = windows.flatMap { [$0.y, $0.y + $0.height] }
        func nearest(_ value: Double, in lines: [Double]) -> Double {
            var best = value
            var distance = tolerance
            for line in lines where abs(line - value) <= distance {
                distance = abs(line - value)
                best = line
            }
            return best
        }
        var left = rect.x, right = rect.x + rect.width
        var top = rect.y, bottom = rect.y + rect.height
        if edges.contains(.left) { left = nearest(left, in: xs) }
        if edges.contains(.right) { right = nearest(right, in: xs) }
        if edges.contains(.top) { top = nearest(top, in: ys) }
        if edges.contains(.bottom) { bottom = nearest(bottom, in: ys) }
        guard right - left >= 1, bottom - top >= 1 else { return rect }
        return CaptureRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
