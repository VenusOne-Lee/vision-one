import Foundation

/// The stretches of a take spent paused, on one clock (the host clock in
/// the app). Nothing is written while paused, so clocks never shift: the
/// gaps simply become accepted "paused" cuts in edits.json, and every
/// track (screen, camera, phone, cursor) stays lined up on its own.
public struct PauseLog: Equatable, Sendable {
    /// Finished pauses, oldest first.
    public private(set) var spans: [TimeSpan] = []
    /// When the current pause began, or nil while recording.
    public private(set) var pausedSince: Double?

    public init() {}

    public var isPaused: Bool { pausedSince != nil }

    public mutating func pause(at t: Double) {
        guard pausedSince == nil else { return }
        pausedSince = t
    }

    public mutating func resume(at t: Double) {
        guard let since = pausedSince else { return }
        pausedSince = nil
        if t > since { spans.append(TimeSpan(start: since, end: t)) }
    }

    /// Seconds spent paused up to `t`, counting a pause still running.
    public func pausedDuration(at t: Double) -> Double {
        let done = spans.reduce(0) { $0 + $1.duration }
        guard let since = pausedSince else { return done }
        return done + max(0, t - since)
    }

    /// The pauses as cuts over the take, in seconds from `firstFrame`.
    /// A pause still running at `end` is closed there. Spans before the
    /// first frame or of no length are left out.
    public func cuts(firstFrame: Double, end: Double) -> [Cut] {
        var all = spans
        if let since = pausedSince, end > since { all.append(TimeSpan(start: since, end: end)) }
        return all.compactMap { span in
            let start = max(0, span.start - firstFrame)
            let stop = span.end - firstFrame
            guard stop > start else { return nil }
            return Cut(span: TimeSpan(start: start, end: stop), reason: Cut.Reason.paused, state: .accepted)
        }
    }
}

/// How long the countdown before recording runs. Off starts at once.
public enum CountdownLength: Int, CaseIterable, Codable, Sendable {
    case off = 0
    case three = 3
    case five = 5

    public static let `default` = CountdownLength.three

    public var title: String {
        self == .off ? "Off" : "\(rawValue) s"
    }

    /// From a saved number; anything unknown falls back to the default.
    public init(saved: Int?) {
        self = saved.flatMap(CountdownLength.init(rawValue:)) ?? .default
    }
}
