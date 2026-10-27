import Foundation

/// A point of a pen stroke drawn over the video, in any units where x
/// and y are to the same scale (points on screen, not 0...1 of a wide
/// frame), so a circle stays round.
public struct StrokePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: StrokePoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

/// What a pen stroke on the video means: circle something to zoom on
/// it, scribble over it to blur it, draw a line to point at it.
public enum StrokeShape: Equatable, Sendable {
    /// A loop around something: zoom on its box.
    case circle(minX: Double, minY: Double, maxX: Double, maxY: Double)
    /// Back and forth over something: blur its box.
    case scribble(minX: Double, minY: Double, maxX: Double, maxY: Double)
    /// A line: an arrow from the first point to the last.
    case line(from: StrokePoint, to: StrokePoint)

    /// Plain geometry, no templates: how straight the stroke is, how
    /// often it turns back on itself, and whether it ends near where it
    /// began. Nil for a tap or a stroke too small to mean anything.
    public static func classify(_ points: [StrokePoint], minimumSize: Double = 12) -> StrokeShape? {
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let width = maxX - minX, height = maxY - minY
        guard max(width, height) >= minimumSize else { return nil }

        let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        guard length > 0 else { return nil }
        let gap = first.distance(to: last)

        // Nearly as long as the distance it covers: a line.
        if gap / length > 0.85 { return .line(from: first, to: last) }

        // Sharp turns back on itself, counted on an evenly spaced copy so
        // the speed of the pen doesn't matter.
        let even = resample(points, count: 48, length: length)
        var sharpTurns = 0
        var turning = 0.0
        for i in 1..<(even.count - 1) {
            let ax = even[i].x - even[i - 1].x, ay = even[i].y - even[i - 1].y
            let bx = even[i + 1].x - even[i].x, by = even[i + 1].y - even[i].y
            let norms = (ax * ax + ay * ay).squareRoot() * (bx * bx + by * by).squareRoot()
            guard norms > 0 else { continue }
            let cosine = (ax * bx + ay * by) / norms
            turning += acos(min(1, max(-1, cosine)))
            if cosine < -0.5 { sharpTurns += 1 } // more than 120°
        }
        if sharpTurns >= 3 {
            return .scribble(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        // Ends near its start, or turns most of the way round: a loop.
        let size = max(width, height)
        if gap < size * 0.35 || turning > 1.5 * .pi {
            return .circle(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }
        if sharpTurns >= 2 {
            return .scribble(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }
        return nil
    }

    static func resample(_ points: [StrokePoint], count: Int, length: Double) -> [StrokePoint] {
        let step = length / Double(count - 1)
        var result = [points[0]]
        var carried = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = a.distance(to: b)
            guard segment > 0 else { continue }
            var along = step - carried
            while along <= segment {
                let f = along / segment
                result.append(StrokePoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                along += step
            }
            carried = segment - (along - step)
        }
        if result.count < count, let last = points.last { result.append(last) }
        return result
    }
}
