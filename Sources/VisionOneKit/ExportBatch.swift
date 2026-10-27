import Foundation

/// A video's shape as people say it: "16:9", "16:10", "9:16". Shapes
/// that aren't close to a common one read as "1.54:1".
public enum AspectRatio {
    /// Common shapes, landscape first. A shape within 2% of one of these
    /// takes its name.
    static let common: [(width: Int, height: Int)] = [
        (16, 9), (16, 10), (3, 2), (4, 3), (21, 9), (1, 1),
        (9, 16), (10, 16), (2, 3), (3, 4), (4, 5),
    ]
    static let tolerance = 0.02

    public static func label(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        let ratio = Double(width) / Double(height)
        func distance(_ shape: (width: Int, height: Int)) -> Double {
            abs(Double(shape.width) / Double(shape.height) / ratio - 1)
        }
        if let best = common.min(by: { distance($0) < distance($1) }), distance(best) <= tolerance {
            return "\(best.width):\(best.height)"
        }
        return String(format: "%.2f:1", ratio)
    }
}

/// What a preset will make of a take before it's exported: its shape,
/// length and a rough size, for the line under each format in the
/// export sheet.
public struct ExportEstimate: Equatable, Sendable {
    /// Output size in pixels (the source's when no plan could be made).
    public let width: Int
    public let height: Int
    /// "16:9"
    public let ratio: String
    /// Seconds of video, cards included.
    public let duration: Double
    /// Rough file size, or nil when no plan could be made.
    public let bytes: Int64?
    /// Why the preset can't export this take, in plain words.
    public let problem: String?
    /// The same, short enough for the line under the format.
    public let shortProblem: String?

    public init(preset: ExportPreset, source: ExportSource, duration: Double) {
        self.duration = max(0, duration)
        do {
            let settings = try ExportPlanner.settings(for: preset, source: source, duration: duration)
            width = settings.width
            height = settings.height
            var estimate = settings.estimatedBytes(duration: duration)
            // Size-limited exports go again lower if they overshoot, so
            // the file never ends up over the limit.
            if let limit = preset.sizeLimitBytes { estimate = min(estimate, limit) }
            bytes = estimate
            problem = nil
            shortProblem = nil
        } catch let error as ExportPlanError {
            width = source.width
            height = source.height
            bytes = nil
            problem = ExportPhase.message(for: error)
            switch error {
            case .tooLongForSizeLimit: shortProblem = "too long"
            case .emptyVideo: shortProblem = "all cut"
            }
        } catch {
            width = source.width
            height = source.height
            bytes = nil
            problem = error.localizedDescription
            shortProblem = "can't plan"
        }
        ratio = AspectRatio.label(width: width, height: height)
    }

    /// "16:9 · 2:41 · ~38 MB"
    public var detail: String {
        var parts = [ratio, Timecode.short(from: duration)].filter { !$0.isEmpty }
        if let bytes {
            parts.append(Self.size(bytes))
        } else if let shortProblem {
            parts.append(shortProblem)
        }
        return parts.joined(separator: " · ")
    }

    /// "~38 MB", or "~4.2 MB" under 10 MB. Decimal megabytes like Finder.
    public static func size(_ bytes: Int64) -> String {
        let megabytes = Double(max(0, bytes)) / 1_000_000
        return megabytes < 10 ? String(format: "~%.1f MB", megabytes) : String(format: "~%.0f MB", megabytes)
    }
}

/// Several presets exported one after another, because the exporter runs
/// one export at a time. Follows the exporter's `ExportPhase` for the
/// preset that's running, so each format can show its own ring.
public struct ExportBatch: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting
        /// Asked to start; the exporter hasn't said it's running yet.
        case starting
        case exporting(progress: Double)
        case done(url: URL, bytes: Int64)
        case failed(message: String)
        case cancelled

        /// How far along the ring is, or nil when it isn't running or done.
        public var progress: Double? {
            switch self {
            case .starting: return 0
            case let .exporting(progress): return progress
            case .done: return 1
            default: return nil
            }
        }

        public var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }

        var isRunning: Bool {
            switch self {
            case .starting, .exporting: return true
            default: return false
            }
        }
    }

    /// The presets in this batch, in the order they export.
    public let presets: [ExportPreset]
    public private(set) var statuses: [ExportPreset: Status]
    public private(set) var isCancelled = false

    /// Exports run in the presets' usual order, each once.
    public init(_ picked: [ExportPreset]) {
        presets = ExportPreset.allCases.filter { picked.contains($0) }
        statuses = Dictionary(uniqueKeysWithValues: presets.map { ($0, Status.waiting) })
    }

    public func status(of preset: ExportPreset) -> Status? { statuses[preset] }

    /// The preset that's starting or exporting.
    public var current: ExportPreset? {
        presets.first { statuses[$0]?.isRunning == true }
    }

    /// The preset to start now: the first waiting one, when nothing is
    /// running and the batch wasn't cancelled.
    public var next: ExportPreset? {
        guard !isCancelled, current == nil else { return nil }
        return presets.first { statuses[$0] == .waiting }
    }

    /// Something is still waiting or running.
    public var isRunning: Bool {
        presets.contains { statuses[$0]?.isFinished == false }
    }

    public var isFinished: Bool { !presets.isEmpty && !isRunning }

    /// Finished files, in export order.
    public var exported: [URL] {
        presets.compactMap { preset in
            if case let .done(url, _) = statuses[preset] { return url }
            return nil
        }
    }

    /// Failure messages, in export order.
    public var failures: [String] {
        presets.compactMap { preset in
            if case let .failed(message) = statuses[preset] { return message }
            return nil
        }
    }

    /// 0...1 over the whole batch. Finished presets count as whole.
    public var progress: Double {
        guard !presets.isEmpty else { return 0 }
        let total = presets.reduce(0.0) { sum, preset in
            guard let status = statuses[preset] else { return sum }
            return sum + (status.isFinished ? 1 : (status.progress ?? 0))
        }
        return total / Double(presets.count)
    }

    /// Marks `preset` as asked to start.
    public mutating func start(_ preset: ExportPreset) {
        guard statuses[preset] == .waiting else { return }
        statuses[preset] = .starting
    }

    /// `preset` couldn't start or run.
    public mutating func fail(_ preset: ExportPreset, message: String) {
        guard let status = statuses[preset], !status.isFinished else { return }
        statuses[preset] = .failed(message: message)
    }

    /// Stops the batch: nothing else starts. The running export becomes
    /// cancelled once the exporter goes back to idle.
    public mutating func cancel() {
        isCancelled = true
        for preset in presets where statuses[preset] == .waiting {
            statuses[preset] = .cancelled
        }
    }

    /// Follows the exporter. Only phases for the running preset count,
    /// and an end (done, failed, idle) only once it has been seen
    /// exporting, so a phase left over from an earlier export is ignored.
    public mutating func apply(_ phase: ExportPhase) {
        guard let current, let status = statuses[current] else { return }
        let seenExporting: Bool
        if case .exporting = status { seenExporting = true } else { seenExporting = false }

        switch phase {
        case let .exporting(preset, progress):
            guard preset == current else { return }
            let clamped = min(max(progress, 0), 1)
            // The ring only moves forward.
            statuses[current] = .exporting(progress: max(status.progress ?? 0, clamped))
        case let .done(preset, url, bytes):
            guard preset == current, seenExporting else { return }
            statuses[current] = .done(url: url, bytes: bytes)
        case let .failed(message):
            guard seenExporting else { return }
            statuses[current] = .failed(message: message)
        case .idle:
            // The exporter goes idle when an export is cancelled.
            guard seenExporting || isCancelled else { return }
            statuses[current] = .cancelled
            cancel()
        }
    }
}
