import Foundation

/// The cursor's glide from one spot to the next, so an Autopilot demo
/// reads like a person: it eases in and out, arcs slightly instead of
/// running a ruler line, and takes longer for longer trips.
public struct CursorPath: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public let from: Point
    public let to: Point
    public let duration: Double

    /// `speed` is points per second; the trip takes at least 0.25 s and
    /// at most 1.2 s, however far it goes.
    public init(from: Point, to: Point, speed: Double) {
        self.from = from
        self.to = to
        let distance = ((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y)).squareRoot()
        duration = distance < 1 ? 0 : min(max(distance / max(speed, 1), 0.25), 1.2)
    }

    /// Where the cursor is `t` seconds in.
    public func point(at t: Double) -> Point {
        guard duration > 0 else { return to }
        let u = Self.ease(min(max(t / duration, 0), 1))
        // A gentle bow: the control point sits off the midpoint by a
        // tenth of the trip, to the side.
        let mx = (from.x + to.x) / 2, my = (from.y + to.y) / 2
        let dx = to.x - from.x, dy = to.y - from.y
        let cx = mx - dy * 0.1, cy = my + dx * 0.1
        let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
        return Point(x: a * from.x + b * cx + c * to.x, y: a * from.y + b * cy + c * to.y)
    }

    /// The points to post, one per frame at `fps`, ending exactly on `to`.
    public func frames(fps: Double = 60) -> [Point] {
        guard duration > 0 else { return [to] }
        let count = max(Int((duration * fps).rounded(.up)), 1)
        return (1...count).map { point(at: Double($0) / Double(count) * duration) }
    }

    /// Ease in and out (smootherstep).
    static func ease(_ u: Double) -> Double {
        u * u * u * (u * (u * 6 - 15) + 10)
    }
}
