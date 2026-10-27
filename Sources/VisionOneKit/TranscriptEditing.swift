import Foundation

/// How the editor draws one word, from the edit list.
public enum WordMark: Equatable, Sendable {
    case kept
    /// Removed by an accepted cut: grey with a line through, still visible.
    case cut
    /// Inside a proposed cut (dashed); `reason` picks the tint, such as
    /// gold for fillers.
    case proposed(reason: String?)
}

extension EditList {
    /// The mark for each span in `spans`. A word counts as cut when an
    /// accepted cut covers its middle, so a cut that clips a word's edge
    /// by a few milliseconds doesn't strike the whole word through.
    public func marks(for spans: [TimeSpan]) -> [WordMark] {
        let removed = removedSpans
        let proposed = cuts.filter { $0.state == .proposed }
        return spans.map { span in
            let middle = (span.start + span.end) / 2
            if removed.contains(where: { $0.contains(middle) }) { return .cut }
            if let cut = proposed.first(where: { $0.span.contains(middle) }) {
                return .proposed(reason: cut.reason)
            }
            return .kept
        }
    }

    /// The span to cut when words `range` of `words` (in time order) are
    /// deleted. It reaches halfway into the silence on each side, so the
    /// words around it keep their breath and no syllable is clipped; the
    /// gap left behind is about as long as the ones it replaced. At the
    /// start or end of the take it runs to the edge.
    public static func span(deleting range: ClosedRange<Int>, of words: [TimeSpan], sourceDuration: Double) -> TimeSpan? {
        guard range.lowerBound >= 0, range.upperBound < words.count else { return nil }
        let first = words[range.lowerBound]
        let last = words[range.upperBound]

        let start: Double
        if range.lowerBound == 0 {
            start = 0
        } else {
            let before = words[range.lowerBound - 1].end
            start = min(first.start, before + max(0, first.start - before) / 2)
        }

        let end: Double
        if range.upperBound == words.count - 1 {
            end = sourceDuration
        } else {
            let after = words[range.upperBound + 1].start
            end = max(last.end, last.end + max(0, after - last.end) / 2)
        }
        return TimeSpan(start: max(0, start), end: min(sourceDuration, max(end, start)))
    }

    /// The nearest moment at or after `t` that plays in the edited
    /// video, for seeking: clicking a cut word lands just after the cut.
    public func nearestKeptSource(_ t: Double) -> Double {
        if outputTime(forSource: t) != nil { return t }
        return keptSpans.first { $0.start >= t }?.start ?? keptSpans.last?.end ?? 0
    }
}

extension TranscriptWord {
    public var span: TimeSpan { TimeSpan(start: start, end: end) }
}
