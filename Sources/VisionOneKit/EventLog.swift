import Foundation

/// What happened under the cursor while recording. Logged from v0.1 so
/// v0.2 can zoom on clicks and redraw a smooth cursor without the user
/// recording again.
public struct InputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, leftDown, leftUp, rightDown, rightUp
    }

    public let kind: Kind
    /// Seconds from the take's first video frame.
    public let t: Double
    /// Position in display points, origin top left.
    public let x: Double
    public let y: Double

    public init(kind: Kind, t: Double, x: Double, y: Double) {
        self.kind = kind
        self.t = t
        self.x = x
        self.y = y
    }
}

/// The events.json file in a take folder.
public struct EventLog: Codable, Equatable, Sendable {
    public var version = 1
    /// Display size in points, so positions can be mapped onto the video.
    public var displayWidth: Double
    public var displayHeight: Double
    public var events: [InputEvent]

    public init(displayWidth: Double, displayHeight: Double, events: [InputEvent] = []) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.events = events
    }

    /// Adds an event, skipping moves closer than `minMoveInterval` to the
    /// last one so a long take doesn't log thousands of moves a minute.
    /// Clicks are always kept. Events from before the first frame are
    /// dropped.
    public mutating func append(_ event: InputEvent, minMoveInterval: Double = 1.0 / 60) {
        guard event.t >= 0 else { return }
        if event.kind == .move, let last = events.last, last.kind == .move,
           event.t - last.t < minMoveInterval {
            return
        }
        events.append(event)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
