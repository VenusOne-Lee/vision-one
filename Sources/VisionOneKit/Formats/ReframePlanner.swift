import Foundation

/// How a recording is fitted into a shape it wasn't recorded in.
public enum ReframeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Crop the frame and follow the cursor (or face).
    case follow
    /// Show the whole frame, scaled down on paper, with room for captions.
    case fit
    /// Screen in the top part, camera in the ring below.
    case split

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .follow: return "Follow"
        case .fit: return "Fit"
        case .split: return "Split"
        }
    }
}

/// Something worth keeping in frame, in source seconds and 0...1 of the
/// source frame (origin top left): a cursor position, a click, a face.
public struct FocusPoint: Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

/// A stretch where the person dragged the crop window themselves. Their
/// framing wins over following.
public struct ReframePin: Codable, Equatable, Sendable {
    /// Source seconds.
    public var start: Double
    public var end: Double
    public var centerX: Double
    public var centerY: Double

    public init(start: Double, end: Double, centerX: Double, centerY: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
        self.centerX = centerX
        self.centerY = centerY
    }

    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Which part of the source to show at every moment for one format.
/// Saved with the take per format, so each shape keeps its own framing.
/// Times are source seconds (the events.json and transcript clock).
public struct ReframePlan: Codable, Equatable, Sendable {
    /// Where the crop is centred at a moment, 0...1 of the source frame.
    public struct Keyframe: Codable, Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    /// In split mode, the share of the output's height that shows the
    /// screen. The camera takes the rest.
    public static let splitScreenShare = 0.6

    public var format: VideoFormat
    public var mode: ReframeMode
    /// Size of the crop as a share of the source frame.
    public var cropWidth: Double
    public var cropHeight: Double
    public var keyframes: [Keyframe]
    public var pins: [ReframePin]

    public init(format: VideoFormat, mode: ReframeMode, cropWidth: Double, cropHeight: Double,
                keyframes: [Keyframe], pins: [ReframePin] = []) {
        self.format = format
        self.mode = mode
        self.cropWidth = min(max(cropWidth, 0), 1)
        self.cropHeight = min(max(cropHeight, 0), 1)
        self.keyframes = keyframes.sorted { $0.t < $1.t }
        self.pins = pins
    }

    /// The part of the source frame to show at a source time.
    public func crop(at t: Double) -> NormalisedRect {
        if mode == .fit { return .full }
        if let pin = pins.last(where: { $0.contains(t) }) {
            return NormalisedRect(centerX: pin.centerX, centerY: pin.centerY, width: cropWidth, height: cropHeight)
        }
        let centre = centre(at: t)
        return NormalisedRect(centerX: centre.x, centerY: centre.y, width: cropWidth, height: cropHeight)
    }

    /// Pins the crop's centre over a stretch, replacing any pins it
    /// overlaps. Pass the whole take to pin it everywhere.
    public mutating func pin(centerX: Double, centerY: Double, from start: Double, to end: Double) {
        let pin = ReframePin(start: start, end: end, centerX: centerX, centerY: centerY)
        pins.removeAll { $0.start < pin.end && pin.start < $0.end }
        pins.append(pin)
        pins.sort { $0.start < $1.start }
    }

    /// Goes back to following wherever a pin covers `t`.
    public mutating func unpin(at t: Double) {
        pins.removeAll { $0.contains(t) }
    }

    private func centre(at t: Double) -> (x: Double, y: Double) {
        guard let first = keyframes.first, let last = keyframes.last else { return (0.5, 0.5) }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        // Binary search for the keyframe at or before t.
        var low = 0
        var high = keyframes.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if keyframes[mid].t <= t { low = mid } else { high = mid }
        }
        let a = keyframes[low]
        let b = keyframes[high]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }
}

/// Plans the crop for a format from what should stay in frame. Export
/// isn't live, so the planner can look ahead: the frame starts moving
/// just before the cursor does, instead of chasing it. A dead zone keeps
/// it still while the cursor wanders a little, a speed limit stops whip
/// pans, and smoothing runs forwards and backwards so it never lags.
public enum ReframePlanner {
    public struct Options: Equatable, Sendable {
        /// Seconds of look-ahead.
        public var lookAhead: Double = 0.4
        /// How far the focus can drift from the centre, as a share of the
        /// crop's size, before the frame moves.
        public var deadZone: Double = 0.12
        /// Fastest pan, in crop widths per second.
        public var maxSpeed: Double = 1.5
        /// Smoothing time constant in seconds.
        public var smoothing: Double = 0.3
        /// Keyframes per second.
        public var sampleRate: Double = 10
        /// How much of the source the crop covers along its long side.
        /// 1 uses the full height (or width); smaller zooms in.
        public var zoom: Double = 1

        public init() {}
    }

    /// The shape the crop needs for a format and mode: the output shape
    /// for follow, the screen pane for split.
    public static func contentAspect(format: VideoFormat, mode: ReframeMode) -> Double {
        switch mode {
        case .follow, .fit: return format.aspect
        case .split: return format.aspect / ReframePlan.splitScreenShare
        }
    }

    /// Crop size, as a share of the source, for a content shape.
    public static func cropSize(sourceAspect: Double, contentAspect: Double, zoom: Double = 1) -> (width: Double, height: Double) {
        guard sourceAspect > 0, contentAspect > 0 else { return (1, 1) }
        let z = min(max(zoom, 0.2), 1)
        if contentAspect < sourceAspect {
            return (z * contentAspect / sourceAspect, z)
        } else {
            return (z, z * sourceAspect / contentAspect)
        }
    }

    public static func plan(format: VideoFormat, mode: ReframeMode,
                            sourceWidth: Int, sourceHeight: Int, duration: Double,
                            focus: [FocusPoint], options: Options = Options()) -> ReframePlan {
        guard mode != .fit, sourceWidth > 0, sourceHeight > 0 else {
            return ReframePlan(format: format, mode: mode, cropWidth: 1, cropHeight: 1,
                               keyframes: [.init(t: 0, x: 0.5, y: 0.5)])
        }
        let size = cropSize(sourceAspect: Double(sourceWidth) / Double(sourceHeight),
                            contentAspect: contentAspect(format: format, mode: mode), zoom: options.zoom)
        let points = focus.sorted { $0.t < $1.t }
        let rate = max(1, options.sampleRate)
        let dt = 1 / rate
        let count = max(1, Int((max(0, duration) * rate).rounded(.up)) + 1)
        let times = (0..<count).map { min(Double($0) * dt, max(0, duration)) }

        let raw = times.map { focusAt(points, $0 + options.lookAhead) }
        let xs = follow(raw.map { $0.x }, size: size.width, dt: dt, options: options)
        let ys = follow(raw.map { $0.y }, size: size.height, dt: dt, options: options)

        var keyframes: [ReframePlan.Keyframe] = []
        keyframes.reserveCapacity(count)
        for i in 0..<count {
            keyframes.append(.init(t: times[i], x: xs[i], y: ys[i]))
        }
        return ReframePlan(format: format, mode: mode, cropWidth: size.width, cropHeight: size.height,
                           keyframes: keyframes)
    }

    /// Cursor positions and clicks from a take's events.json, as focus
    /// points. `capture` is the recorded part of the display (0...1 of the
    /// display), for window and area recordings; the cursor outside it is
    /// ignored.
    public static func focus(from log: EventLog, capture: NormalisedRect = .full) -> [FocusPoint] {
        guard log.displayWidth > 0, log.displayHeight > 0, capture.width > 0, capture.height > 0 else { return [] }
        return log.events.compactMap { event in
            let x = (event.x / log.displayWidth - capture.x) / capture.width
            let y = (event.y / log.displayHeight - capture.y) / capture.height
            guard (0...1).contains(x), (0...1).contains(y) else { return nil }
            return FocusPoint(t: event.t, x: x, y: y)
        }
    }

    // MARK: - Path

    /// The latest focus at or before `t`; the first one before anything
    /// happens; the centre when there's nothing to follow.
    static func focusAt(_ points: [FocusPoint], _ t: Double) -> (x: Double, y: Double) {
        guard let first = points.first else { return (0.5, 0.5) }
        guard t >= first.t else { return (first.x, first.y) }
        var low = 0
        var high = points.count
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].t <= t { low = mid } else { high = mid }
        }
        return (points[low].x, points[low].y)
    }

    /// One axis: dead zone, speed limit, two-way smoothing, then kept
    /// inside the frame. `size` is the crop's size on this axis.
    static func follow(_ focus: [Double], size: Double, dt: Double, options: Options) -> [Double] {
        let half = size / 2
        func clamp(_ c: Double) -> Double { min(max(c, half), 1 - half) }
        guard size < 1, let start = focus.first else { return focus.map { _ in 0.5 } }

        let dead = max(0, options.deadZone) * size
        let maxStep = max(0, options.maxSpeed) * size * dt
        var centre = clamp(start)
        var target = centre
        var path: [Double] = []
        path.reserveCapacity(focus.count)
        for f in focus {
            if abs(f - centre) > dead { target = clamp(f) }
            let step = target - centre
            centre += min(max(step, -maxStep), maxStep)
            path.append(centre)
        }

        // Exponential smoothing forwards then backwards cancels its lag.
        if options.smoothing > 0, path.count > 1 {
            let alpha = 1 - exp(-dt / options.smoothing)
            for i in 1..<path.count { path[i] = path[i - 1] + alpha * (path[i] - path[i - 1]) }
            for i in stride(from: path.count - 2, through: 0, by: -1) { path[i] = path[i + 1] + alpha * (path[i] - path[i + 1]) }
        }
        return path.map(clamp)
    }
}
