import Foundation

/// The editor timeline's maths: where ruler ticks go at any zoom, what
/// they say, and how zooming keeps a moment under the pointer. Plain, so
/// the ruler and zoom can be tested without drawing anything.
public enum TimelineScale {
    /// Labelled tick spacings in seconds, shortest first.
    public static let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    /// The shortest labelled step that leaves at least `minSpacing`
    /// points between labels.
    public static func step(pointsPerSecond: Double, minSpacing: Double = 72) -> Double {
        guard pointsPerSecond > 0 else { return steps.last! }
        return steps.first { $0 * pointsPerSecond >= minSpacing } ?? steps.last!
    }

    /// Unlabelled ticks between two labels.
    public static func minorDivisions(for step: Double) -> Int {
        switch step {
        case 0.1: return 2
        case 2, 120, 3600: return 4
        case 15, 900: return 3
        case 30, 1800: return 6
        default: return 5
        }
    }

    /// The label at `seconds`: "0:12", "1:02:03", or "0:03.5" once the
    /// labels are less than a second apart.
    public static func label(_ seconds: Double, step: Double) -> String {
        let t = max(0, seconds)
        if step < 1 {
            let whole = Int(t.rounded(.down))
            let tenths = Int(((t - Double(whole)) * 100).rounded()) / 10
            let tail = step < 0.5 ? String(format: ".%02d", Int(((t - Double(whole)) * 100).rounded())) : ".\(tenths)"
            return "\(Timecode.short(from: Double(whole)))\(tail)"
        }
        return Timecode.short(from: t.rounded())
    }

    /// Labelled tick times from `start` to `end`.
    public static func ticks(from start: Double, to end: Double, step: Double) -> [Double] {
        guard step > 0, end >= start else { return [] }
        var out: [Double] = []
        var i = (max(0, start) / step).rounded(.down)
        while i * step <= end + 1e-9 {
            out.append(i * step)
            i += 1
        }
        return out
    }

    // MARK: Zoom

    /// Most points per second the timeline zooms to: about a frame every
    /// 7 points at 30 fps.
    public static let maxPointsPerSecond = 200.0

    /// Widest the zoomed timeline gets, so a long take stays light to draw.
    public static let maxContentWidth = 20_000.0

    /// `zoom` kept between showing the whole take (1) and the closest
    /// zoom, for a timeline `width` points wide.
    public static func clampZoom(_ zoom: Double, duration: Double, width: Double) -> Double {
        guard duration > 0, width > 0 else { return 1 }
        let most = max(1, min(duration * maxPointsPerSecond, maxContentWidth) / width)
        return min(most, max(1, zoom.isFinite ? zoom : 1))
    }

    /// Scroll offset that puts moment `t` at `viewX` points from the
    /// timeline's left edge, clamped so the take never scrolls off.
    public static func offset(keeping t: Double, atViewX viewX: Double, zoom: Double,
                              duration: Double, width: Double) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        let content = width * zoom
        let x = t / duration * content - viewX
        return min(max(0, content - width), max(0, x))
    }
}

extension Timecode {
    /// "00:00:12.10": hours, minutes, seconds and the frame, for the
    /// transport. Frames count from 00 at `fps`.
    public static func precise(from seconds: TimeInterval, fps: Double = 30) -> String {
        let t = max(0, seconds)
        let frames = max(1, Int(fps.rounded()))
        var whole = Int(t.rounded(.down))
        var frame = Int(((t - Double(whole)) * Double(frames)).rounded())
        if frame >= frames {
            whole += 1
            frame = 0
        }
        return "\(string(from: Double(whole))).\(String(format: "%02d", frame))"
    }
}
