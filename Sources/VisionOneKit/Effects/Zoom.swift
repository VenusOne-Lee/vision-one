import Foundation

/// One zoom: from `start` to `end` (seconds of the take, the same clock as
/// events.json and edits.json) the camera eases in to `scale` around a
/// point, holds, and eases back out. Kept against the take's own clock so
/// zooms survive cuts and undo.
public struct Zoom: Codable, Hashable, Identifiable, Sendable {
    public enum Reason {
        public static let click = "click"     // proposed from clicks in events.json
        public static let manual = "manual"   // added in the editor
    }

    public let id: UUID
    public var start: Double
    public var end: Double
    /// 1 is no zoom, 2 shows half the width. Kept between 1 and 4.
    public var scale: Double
    /// Where the camera looks, in 0...1 of the frame, origin top left.
    public var centerX: Double
    public var centerY: Double
    /// Pan with the cursor while zoomed, instead of holding still.
    public var followsCursor: Bool
    /// Seconds to ease in and out. nil uses the default.
    public var ramp: Double?
    public var reason: String?
    public var state: ProposalState

    public static let defaultRamp = 0.6
    public static let scaleRange: ClosedRange<Double> = 1...4

    public init(id: UUID = UUID(), span: TimeSpan, scale: Double, centerX: Double, centerY: Double,
                followsCursor: Bool = false, ramp: Double? = nil,
                reason: String? = Reason.manual, state: ProposalState = .accepted) {
        self.id = id
        self.start = span.start
        self.end = span.end
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        self.centerX = min(max(centerX, 0), 1)
        self.centerY = min(max(centerY, 0), 1)
        self.followsCursor = followsCursor
        self.ramp = ramp
        self.reason = reason
        self.state = state
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
    public var duration: Double { end - start }

    /// Ease time, never more than half the zoom so it always reaches full.
    public var easeTime: Double { min(max(ramp ?? Self.defaultRamp, 0.05), duration / 2) }

    /// The part of the frame showing when fully zoomed on a point.
    public func viewport(centeredOn x: Double, _ y: Double) -> FrameRect {
        FrameRect.centered(x: x, y: y, width: 1 / scale, height: 1 / scale)
    }

    /// The part of the frame showing when fully zoomed, held still.
    public var target: FrameRect { viewport(centeredOn: centerX, centerY) }

    /// The box as the user drags it in the editor: moving it moves the
    /// centre, resizing it changes the scale. Keeps the frame's shape.
    public mutating func setViewport(_ rect: FrameRect) {
        let size = max(rect.width, rect.height)
        scale = min(max(1 / max(size, 0.0001), Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let fitted = FrameRect.centered(x: rect.midX, y: rect.midY, width: 1 / scale, height: 1 / scale)
        centerX = fitted.midX
        centerY = fitted.midY
    }
}

/// A cursor position in 0...1 of the frame, origin top left.
public struct CursorPoint: Equatable, Sendable {
    public let t: Double
    public let x: Double
    public let y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

extension EventLog {
    /// Every logged position, divided by the display size, in time order.
    public var cursorPath: [CursorPoint] {
        guard displayWidth > 0, displayHeight > 0 else { return [] }
        return events
            .map { CursorPoint(t: $0.t, x: min(max($0.x / displayWidth, 0), 1), y: min(max($0.y / displayHeight, 0), 1)) }
            .sorted { $0.t < $1.t }
    }

    /// Mouse-downs (left and right), divided by the display size.
    public var clicks: [CursorPoint] {
        guard displayWidth > 0, displayHeight > 0 else { return [] }
        return events
            .filter { $0.kind == .leftDown || $0.kind == .rightDown }
            .map { CursorPoint(t: $0.t, x: min(max($0.x / displayWidth, 0), 1), y: min(max($0.y / displayHeight, 0), 1)) }
            .sorted { $0.t < $1.t }
    }

    public static func read(from url: URL) throws -> EventLog {
        try JSONDecoder().decode(EventLog.self, from: Data(contentsOf: url))
    }
}

// MARK: - Planning zooms from clicks

/// How eager auto zoom is. Set by the Energy dial (Calm, Lively, Viral).
public enum ZoomEnergy: String, Codable, CaseIterable, Sendable {
    case calm, lively, viral

    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .lively: return "Lively"
        case .viral: return "Viral"
        }
    }
}

public struct ZoomStyle: Codable, Equatable, Sendable {
    /// How far in each zoom goes.
    public var scale: Double
    /// Seconds before the first click the zoom starts, so it has landed
    /// by the time the click happens.
    public var lead: Double
    /// Seconds the zoom stays after the last click.
    public var hold: Double
    /// Clicks closer together than this (seconds) share one zoom.
    public var mergeGap: Double
    /// Seconds to ease in and out.
    public var ramp: Double
    public var followsCursor: Bool

    public init(scale: Double, lead: Double, hold: Double, mergeGap: Double, ramp: Double, followsCursor: Bool) {
        self.scale = scale
        self.lead = lead
        self.hold = hold
        self.mergeGap = mergeGap
        self.ramp = ramp
        self.followsCursor = followsCursor
    }

    public static func energy(_ energy: ZoomEnergy) -> ZoomStyle {
        switch energy {
        case .calm:
            return ZoomStyle(scale: 1.5, lead: 0.8, hold: 1.8, mergeGap: 3.0, ramp: 0.7, followsCursor: false)
        case .lively:
            return ZoomStyle(scale: 2.0, lead: 0.65, hold: 1.4, mergeGap: 2.5, ramp: 0.55, followsCursor: true)
        case .viral:
            return ZoomStyle(scale: 2.6, lead: 0.5, hold: 1.0, mergeGap: 1.8, ramp: 0.4, followsCursor: true)
        }
    }
}

/// Turns the click log into proposed zooms, the way Screen Studio, Cap
/// and Tella do a first pass: clicks close in time and place become one
/// zoom that lands just before the first click and lets go after the
/// last. Everything comes back proposed (dashed) for the user to accept.
public enum ZoomPlanner {
    /// - Parameters:
    ///   - removed: spans already cut; clicks in them don't zoom.
    public static func propose(from log: EventLog, style: ZoomStyle, sourceDuration: Double,
                               removed: [TimeSpan] = []) -> [Zoom] {
        let clicks = log.clicks.filter { click in !removed.contains { $0.contains(click.t) } }
        guard !clicks.isEmpty, sourceDuration > 0 else { return [] }

        // Group clicks: same group while they keep coming and stay inside
        // what the zoomed camera could show.
        let reach = 0.75 / max(style.scale, 1)
        var groups: [[CursorPoint]] = []
        for click in clicks {
            if var group = groups.last, let last = group.last, click.t - last.t <= style.mergeGap {
                let cx = group.map(\.x).reduce(0, +) / Double(group.count)
                let cy = group.map(\.y).reduce(0, +) / Double(group.count)
                if hypot(click.x - cx, click.y - cy) <= reach {
                    group.append(click)
                    groups[groups.count - 1] = group
                    continue
                }
            }
            groups.append([click])
        }

        let minDuration = 2 * style.ramp + 0.5
        var zooms: [Zoom] = groups.map { group in
            let start = max(0, group[0].t - style.lead)
            var end = min(sourceDuration, group[group.count - 1].t + style.hold)
            if end - start < minDuration { end = min(sourceDuration, start + minDuration) }
            let cx = group.map(\.x).reduce(0, +) / Double(group.count)
            let cy = group.map(\.y).reduce(0, +) / Double(group.count)
            return Zoom(span: TimeSpan(start: start, end: end), scale: style.scale, centerX: cx, centerY: cy,
                        followsCursor: style.followsCursor, ramp: style.ramp,
                        reason: Zoom.Reason.click, state: .proposed)
        }

        // Neighbours that overlap hand over at the next one's start, so
        // the camera pans across instead of zooming out and back in. Two
        // that would leave a stub too short to ease are merged.
        var resolved: [Zoom] = []
        for zoom in zooms.sorted(by: { $0.start < $1.start }) {
            guard var previous = resolved.last, zoom.start < previous.end else {
                resolved.append(zoom)
                continue
            }
            if zoom.start - previous.start < minDuration {
                previous.end = max(previous.end, zoom.end)
                previous.centerX = (previous.centerX + zoom.centerX) / 2
                previous.centerY = (previous.centerY + zoom.centerY) / 2
                resolved[resolved.count - 1] = previous
            } else {
                previous.end = zoom.start
                resolved[resolved.count - 1] = previous
                resolved.append(zoom)
            }
        }
        zooms = resolved

        // Leave out zooms that are almost all inside cuts.
        return zooms.filter { zoom in
            let cut = removed.reduce(0.0) { sum, span in
                sum + max(0, min(span.end, zoom.end) - max(span.start, zoom.start))
            }
            return zoom.duration - cut >= 0.5
        }
    }
}

// MARK: - Playing zooms back

/// The camera path export and the preview both follow: for any moment of
/// the take, which part of the frame is showing. Only accepted zooms move
/// the camera.
public struct ZoomTrack: Sendable {
    public let zooms: [Zoom]
    public let cursor: [CursorPoint]
    /// Seconds of cursor history averaged when following, so the camera
    /// glides instead of shaking with the hand.
    public var followWindow = 0.5
    /// Zooms this close together hand over with a pan instead of easing
    /// out and back in.
    public var chainGap = 0.35

    public init(zooms: [Zoom], cursor: [CursorPoint] = []) {
        // Sorted and never overlapping: a later zoom starts where the
        // earlier one ends.
        var cleaned: [Zoom] = []
        for var zoom in zooms.filter({ $0.state == .accepted && $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = cleaned.last, zoom.start < last.end { zoom.start = last.end }
            if zoom.duration > 0.05 { cleaned.append(zoom) }
        }
        self.zooms = cleaned
        self.cursor = cursor.sorted { $0.t < $1.t }
    }

    public var isEmpty: Bool { zooms.isEmpty }

    /// The part of the frame on screen at `t` (seconds of the take).
    public func viewport(atSource t: Double) -> FrameRect {
        guard !zooms.isEmpty else { return .full }
        // Last zoom starting at or before t.
        var lo = 0, hi = zooms.count - 1, k = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if zooms[mid].start <= t { k = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard k >= 0 else { return .full }
        let zoom = zooms[k]
        let next = k + 1 < zooms.count ? zooms[k + 1] : nil
        let chainsToNext = next.map { $0.start - zoom.end <= chainGap } ?? false

        if t >= zoom.end {
            // Between two chained zooms, hold where the first one ended.
            return chainsToNext ? target(of: zoom, at: zoom.end) : .full
        }

        let ease = zoom.easeTime
        let here = target(of: zoom, at: t)
        let sinceStart = t - zoom.start
        let untilEnd = zoom.end - t
        if sinceStart < ease && sinceStart <= untilEnd {
            let previous = k > 0 ? zooms[k - 1] : nil
            let from: FrameRect
            if let previous, zoom.start - previous.end <= chainGap {
                from = target(of: previous, at: previous.end)
            } else {
                from = .full
            }
            return from.lerp(to: here, Self.easeInOut(sinceStart / ease))
        }
        if untilEnd < ease && !chainsToNext {
            return FrameRect.full.lerp(to: here, Self.easeInOut(untilEnd / ease))
        }
        return here
    }

    /// Where a zoom looks at `t`: its fixed point, or the smoothed cursor.
    func target(of zoom: Zoom, at t: Double) -> FrameRect {
        guard zoom.followsCursor, let point = smoothedCursor(at: t) else { return zoom.target }
        return zoom.viewport(centeredOn: point.x, point.y)
    }

    /// Mean cursor position over the last `followWindow` seconds, or the
    /// last known position when it hasn't moved.
    func smoothedCursor(at t: Double) -> (x: Double, y: Double)? {
        guard !cursor.isEmpty else { return nil }
        // First point after t.
        var lo = 0, hi = cursor.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cursor[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return (cursor[0].x, cursor[0].y) }
        var sumX = 0.0, sumY = 0.0, n = 0.0
        var i = lo - 1
        while i >= 0, cursor[i].t >= t - followWindow {
            sumX += cursor[i].x
            sumY += cursor[i].y
            n += 1
            i -= 1
        }
        if n == 0 { return (cursor[lo - 1].x, cursor[lo - 1].y) }
        return (sumX / n, sumY / n)
    }

    /// Cubic ease in and out, 0...1.
    public static func easeInOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

// MARK: - zooms.json

/// The zooms.json file in a take folder. Like edits.json it never changes
/// the recording, and rejected proposals stay so auto zoom doesn't offer
/// them again.
public struct ZoomList: Codable, Equatable, Sendable {
    public var version = 1
    public var energy: ZoomEnergy = .lively
    public var zooms: [Zoom] = []

    public init(energy: ZoomEnergy = .lively, zooms: [Zoom] = []) {
        self.energy = energy
        self.zooms = zooms
    }

    /// Adds proposals that don't overlap a zoom already in the list
    /// (proposed, accepted or rejected). Returns the ones added.
    @discardableResult
    public mutating func propose(_ proposals: [Zoom]) -> [Zoom] {
        var added: [Zoom] = []
        for var proposal in proposals {
            proposal.state = .proposed
            guard !zooms.contains(where: { $0.span.overlaps(proposal.span) }) else { continue }
            zooms.append(proposal)
            added.append(proposal)
        }
        return added
    }

    /// Drops proposals nobody has answered yet, e.g. before re-planning at
    /// a new energy. Accepted and rejected zooms stay.
    public mutating func clearProposals() {
        zooms.removeAll { $0.state == .proposed }
    }

    public mutating func setState(_ state: ProposalState, for id: UUID) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].state = state
    }

    public mutating func acceptAllProposed() {
        for i in zooms.indices where zooms[i].state == .proposed { zooms[i].state = .accepted }
    }

    public mutating func update(_ zoom: Zoom) {
        guard let i = zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        zooms[i] = zoom
    }

    public mutating func remove(id: UUID) {
        zooms.removeAll { $0.id == id }
    }

    /// The zoom that is on screen at `t`, if any (any state but rejected).
    public func zoom(at t: Double) -> Zoom? {
        zooms.first { $0.state != .rejected && $0.span.contains(t) }
    }

    public func track(cursor: [CursorPoint]) -> ZoomTrack {
        ZoomTrack(zooms: zooms, cursor: cursor)
    }

    public var proposedCount: Int { zooms.filter { $0.state == .proposed }.count }

    public static func read(from url: URL) throws -> ZoomList {
        try JSONDecoder().decode(ZoomList.self, from: Data(contentsOf: url))
    }

    /// Reads zooms.json, or starts an empty list when the take has none.
    public static func load(from url: URL) throws -> ZoomList {
        guard FileManager.default.fileExists(atPath: url.path) else { return ZoomList() }
        return try read(from: url)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension Take {
    public var zoomsURL: URL { folder.appendingPathComponent("zooms.json") }
    public var blursURL: URL { folder.appendingPathComponent("blurs.json") }
}
