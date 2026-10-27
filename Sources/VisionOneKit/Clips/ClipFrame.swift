import Foundation

/// The window a clip shows of the wide screen, in normalized frame space
/// (0...1, origin top left). Plain geometry, so it's tested without
/// AVFoundation. Export crops each frame to this rect, then scales it to
/// the format's size.
public enum ClipFrame {
    /// The largest window of `format`'s shape that fits a frame of
    /// `sourceAspect` (width over height), centred on `centerX`/`centerY`
    /// and slid back inside the frame where it would spill over. `fit`
    /// framing and same-shape formats get the whole frame.
    public static func rect(format: ClipFormat, sourceAspect: Double, framing: ClipFraming) -> NormalisedRect {
        guard framing.mode != .fit, sourceAspect > 0 else { return .full }
        let target = format.aspect
        var width = 1.0
        var height = 1.0
        if target < sourceAspect {
            width = target / sourceAspect
        } else {
            height = sourceAspect / target
        }
        guard width < 0.999 || height < 0.999 else { return .full }
        let x = min(max(framing.centerX - width / 2, 0), 1 - width)
        let y = min(max(framing.centerY - height / 2, 0), 1 - height)
        return NormalisedRect(x: x, y: y, width: width, height: height)
    }

    /// Where the window starts for `follow` framing: centred on where the
    /// cursor spent the clip (the median position, so one fling across
    /// the screen doesn't drag it). Clicks count three times, because
    /// that's where the action is. Without cursor events in the clip, the
    /// centre of the screen.
    ///
    /// This picks one steady window per clip. Moving with the cursor
    /// during the clip comes from the shared reframe planner.
    public static func followCenter(events: EventLog, span: TimeSpan) -> (x: Double, y: Double) {
        guard events.displayWidth > 0, events.displayHeight > 0 else { return (0.5, 0.5) }
        var xs: [Double] = []
        var ys: [Double] = []
        for event in events.events where span.contains(event.t) {
            let weight = event.kind == .move ? 1 : 3
            for _ in 0..<weight {
                xs.append(event.x / events.displayWidth)
                ys.append(event.y / events.displayHeight)
            }
        }
        guard !xs.isEmpty else { return (0.5, 0.5) }
        return (min(max(median(xs), 0), 1), min(max(median(ys), 0), 1))
    }

    /// The framing export uses: `follow` resolved to a centre from the
    /// cursor, anything else as saved.
    public static func resolved(_ clip: Clip, events: EventLog?) -> ClipFraming {
        guard clip.framing.mode == .follow, let events else { return clip.framing }
        let center = followCenter(events: events, span: clip.span)
        return ClipFraming(mode: .fixed, centerX: center.x, centerY: center.y)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
