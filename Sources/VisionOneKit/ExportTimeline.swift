import Foundation

/// The kept parts of a take, laid end to end, as export renders them.
/// Built from the edit list's kept spans (seconds from the take's first
/// frame). Edges are snapped to whole frames so a cut never lands half
/// way through a frame, and the joins are where export fades the sound
/// so cuts don't click.
public struct ExportTimeline: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Where this piece comes from in the recording.
        public let source: Range<Double>
        /// Where it lands in the exported video.
        public let outputStart: Double

        public var duration: Double { source.upperBound - source.lowerBound }
        public var output: Range<Double> { outputStart..<(outputStart + duration) }
    }

    public let segments: [Segment]

    /// Length of the exported video in seconds.
    public var duration: Double { segments.last.map { $0.output.upperBound } ?? 0 }

    /// Output times where two kept pieces meet.
    public var joins: [Double] { segments.dropFirst().map(\.outputStart) }

    /// - Parameters:
    ///   - keep: kept spans in source seconds, in any order, may overlap.
    ///     Pass nil to keep the whole recording.
    ///   - sourceDuration: length of the recording.
    ///   - frameRate: frames per second used to snap edges. 0 skips snapping.
    public init(keep: [Range<Double>]?, sourceDuration: Double, frameRate: Double) {
        let whole = 0..<max(0, sourceDuration)
        let spans = keep ?? [whole]

        func snap(_ t: Double) -> Double {
            guard frameRate > 0 else { return t }
            return (t * frameRate).rounded() / frameRate
        }

        // Clamp, snap, drop anything under one frame, then merge overlaps
        // and spans that touch.
        let minLength = frameRate > 0 ? 0.5 / frameRate : 0
        let cleaned = spans
            .map { span -> Range<Double> in
                let lower = snap(min(max(span.lowerBound, 0), whole.upperBound))
                let upper = snap(min(max(span.upperBound, 0), whole.upperBound))
                return lower..<max(lower, upper)
            }
            .filter { $0.upperBound - $0.lowerBound > minLength }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Double>] = []
        for span in cleaned {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }

        var cursor = 0.0
        segments = merged.map { span in
            defer { cursor += span.upperBound - span.lowerBound }
            return Segment(source: span, outputStart: cursor)
        }
    }

    /// Where a moment of the recording ends up in the export, or nil if
    /// it was cut.
    public func outputTime(forSource t: Double) -> Double? {
        guard let segment = segments.first(where: { $0.source.contains(t) }) else { return nil }
        return segment.outputStart + (t - segment.source.lowerBound)
    }

    /// Which moment of the recording is showing at an output time.
    public func sourceTime(forOutput t: Double) -> Double? {
        guard let segment = segments.first(where: { $0.output.contains(t) }) else { return nil }
        return segment.source.lowerBound + (t - segment.outputStart)
    }
}
