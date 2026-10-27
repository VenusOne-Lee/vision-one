import Foundation

/// What the transcriber is doing. Shown as one muted line in the menu.
/// Never orange: only a live recording is orange.
public enum TranscriptionPhase: Equatable, Sendable {
    case idle
    /// First run only: the speech model is downloading. Progress 0...1.
    case downloadingModel(progress: Double?)
    case transcribing(takeName: String)
    case failed(takeName: String, message: String)

    public var isWorking: Bool {
        switch self {
        case .downloadingModel, .transcribing: return true
        case .idle, .failed: return false
        }
    }

    /// The menu line, or nil when there is nothing to say.
    public var statusText: String? {
        switch self {
        case .idle:
            return nil
        case let .downloadingModel(progress):
            guard let progress else { return "Getting the speech model…" }
            return "Getting the speech model… \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        case .transcribing:
            return "Writing the transcript…"
        case let .failed(_, message):
            return "No transcript yet. \(message)"
        }
    }
}

/// Collects decoded audio into one continuous run of samples, placing
/// each buffer at its timestamp. Gaps (a mic that dropped out) become
/// silence and overlaps are dropped, so sample n is always at n / rate
/// seconds from the take's first frame, and word times line up with the
/// video.
public struct SampleTimeline: Sendable {
    public let sampleRate: Double
    public private(set) var samples: [Float] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public var duration: Double { Double(samples.count) / sampleRate }

    public mutating func append(_ buffer: [Float], at seconds: Double) {
        let position = Int((max(0, seconds) * sampleRate).rounded())
        if position > samples.count {
            samples.append(contentsOf: repeatElement(0, count: position - samples.count))
        }
        let skip = samples.count - position
        guard skip < buffer.count else { return }
        samples.append(contentsOf: buffer.dropFirst(skip))
    }
}
