import Foundation

/// A stretch of the take, in seconds from the first video frame: the
/// same clock as events.json and the transcript.
public struct TimeSpan: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    public func contains(_ t: Double) -> Bool { t >= start && t < end }

    public func overlaps(_ other: TimeSpan) -> Bool {
        start < other.end && other.start < end
    }
}

/// One piece of the take to leave out. Cuts are never applied to the
/// recording itself, so every edit can be undone.
public struct Cut: Codable, Hashable, Identifiable, Sendable {
    /// Dashed = proposed, solid = accepted, the app's one grammar.
    /// Rejected proposals stay in the list so auto-clean doesn't suggest
    /// them again.
    public enum State: String, Codable, Sendable {
        case proposed, accepted, rejected
    }

    /// Why a cut exists. Free text in the file so new kinds don't break
    /// old builds; these are the ones the app writes today.
    public enum Reason {
        public static let word = "word"         // deleted in the transcript
        public static let filler = "filler"     // um, uh, like
        public static let `repeat` = "repeat"   // a retake; the last try wins
        public static let pause = "pause"       // a long pause, shortened
        public static let deadAir = "deadAir"   // silence at the start or end
    }

    public let id: UUID
    public var start: Double
    public var end: Double
    public var reason: String?
    public var state: State

    public init(id: UUID = UUID(), span: TimeSpan, reason: String? = Reason.word, state: State = .accepted) {
        self.id = id
        self.start = span.start
        self.end = span.end
        self.reason = reason
        self.state = state
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
}

/// The edits.json file in a take folder: a non-destructive list of cuts
/// over screen.mov. The editor, auto-clean, captions and export all read
/// this one file. Only accepted cuts change the video.
public struct EditList: Codable, Equatable, Sendable {
    public var version = 1
    /// Length of screen.mov in seconds.
    public var sourceDuration: Double
    public var cuts: [Cut]

    public init(sourceDuration: Double, cuts: [Cut] = []) {
        self.sourceDuration = max(0, sourceDuration)
        self.cuts = cuts
    }

    // MARK: Changing cuts

    /// Adds a cut, clamped to the take. Empty cuts are ignored.
    @discardableResult
    public mutating func add(_ cut: Cut) -> Cut? {
        var cut = cut
        cut.start = min(max(0, cut.start), sourceDuration)
        cut.end = min(max(0, cut.end), sourceDuration)
        guard cut.end > cut.start else { return nil }
        cuts.append(cut)
        return cut
    }

    /// Adds auto-clean proposals, skipping any that overlap a cut already
    /// in the list (proposed, accepted or rejected), so running auto-clean
    /// again never repeats itself or brings back what the user turned down.
    /// Returns the ones that were added.
    @discardableResult
    public mutating func propose(_ proposals: [Cut]) -> [Cut] {
        var added: [Cut] = []
        for var proposal in proposals {
            proposal.state = .proposed
            guard !cuts.contains(where: { $0.span.overlaps(proposal.span) }) else { continue }
            if let cut = add(proposal) { added.append(cut) }
        }
        return added
    }

    public mutating func remove(id: UUID) {
        cuts.removeAll { $0.id == id }
    }

    public mutating func setState(_ state: Cut.State, for id: UUID) {
        guard let i = cuts.firstIndex(where: { $0.id == id }) else { return }
        cuts[i].state = state
    }

    /// "Accept all" in the changes list.
    public mutating func acceptAllProposed() {
        for i in cuts.indices where cuts[i].state == .proposed {
            cuts[i].state = .accepted
        }
    }

    /// Brings back everything in `span`: accepted cuts inside it are
    /// removed, and ones that cross its edges are trimmed or split.
    /// Proposals and rejections are left alone.
    public mutating func restore(_ span: TimeSpan) {
        var result: [Cut] = []
        for cut in cuts {
            guard cut.state == .accepted, cut.span.overlaps(span) else {
                result.append(cut)
                continue
            }
            let keepsStart = cut.start < span.start
            if keepsStart {
                var before = cut
                before.end = span.start
                result.append(before)
            }
            if cut.end > span.end {
                // A split needs a second id; a trim keeps the cut's own.
                result.append(Cut(id: keepsStart ? UUID() : cut.id,
                                  span: TimeSpan(start: span.end, end: cut.end),
                                  reason: cut.reason, state: cut.state))
            }
        }
        cuts = result
    }

    // MARK: Reading the edit

    /// Accepted cuts merged into sorted, non-overlapping spans.
    public var removedSpans: [TimeSpan] {
        let spans = cuts
            .filter { $0.state == .accepted }
            .map(\.span)
            .sorted { $0.start < $1.start }
        var merged: [TimeSpan] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// What export renders and the preview plays, in order.
    public var keptSpans: [TimeSpan] {
        var kept: [TimeSpan] = []
        var cursor = 0.0
        for removed in removedSpans {
            if removed.start > cursor { kept.append(TimeSpan(start: cursor, end: removed.start)) }
            cursor = max(cursor, removed.end)
        }
        if sourceDuration > cursor { kept.append(TimeSpan(start: cursor, end: sourceDuration)) }
        return kept
    }

    public var outputDuration: Double {
        keptSpans.reduce(0) { $0 + $1.duration }
    }

    /// True when `t` falls inside an accepted cut.
    public func isRemoved(_ t: Double) -> Bool {
        removedSpans.contains { $0.contains(t) }
    }

    /// Where a moment of the take lands in the edited video, or nil if it
    /// was cut.
    public func outputTime(forSource t: Double) -> Double? {
        var output = 0.0
        for span in keptSpans {
            if t < span.start { return nil }
            if t < span.end || (t == span.end && span.end == sourceDuration) {
                return output + (t - span.start)
            }
            output += span.duration
        }
        return nil
    }

    /// The moment of the take shown at `t` in the edited video. Times
    /// past the end map to the end of the last kept span.
    public func sourceTime(forOutput t: Double) -> Double {
        var remaining = max(0, t)
        let kept = keptSpans
        for span in kept {
            if remaining < span.duration { return span.start + remaining }
            remaining -= span.duration
        }
        return kept.last?.end ?? 0
    }

    // MARK: File

    public static func read(from url: URL) throws -> EditList {
        try JSONDecoder().decode(EditList.self, from: Data(contentsOf: url))
    }

    /// Reads edits.json, or starts an empty list when the take has none.
    public static func load(from url: URL, sourceDuration: Double) throws -> EditList {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EditList(sourceDuration: sourceDuration)
        }
        var list = try read(from: url)
        if list.sourceDuration <= 0 { list.sourceDuration = sourceDuration }
        return list
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
