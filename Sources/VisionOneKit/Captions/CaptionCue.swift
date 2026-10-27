import Foundation

/// One spoken word as captions see it. Built from the transcript, so a
/// word fixed in the transcript is fixed in the captions too.
public struct CaptionWord: Equatable, Sendable {
    public var text: String
    /// Seconds. Source time (screen.mov clock) going into the builder,
    /// output time (the edited video) coming out of it.
    public var start: Double
    public var end: Double
    /// A number or a product name, drawn in the builder's ring colour by
    /// the Keyword and Bold pop styles.
    public var isKeyword: Bool

    public init(text: String, start: Double, end: Double, isKeyword: Bool = false) {
        self.text = text
        self.start = start
        self.end = end
        self.isKeyword = isKeyword
    }
}

/// What is on screen at once: one or two lines of words, in output time.
public struct CaptionCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var lines: [[CaptionWord]]

    public init(start: Double, end: Double, lines: [[CaptionWord]]) {
        self.start = start
        self.end = end
        self.lines = lines
    }

    public var words: [CaptionWord] { lines.flatMap { $0 } }

    /// Lines joined with a newline, words with a space.
    public var text: String {
        lines.map { line in line.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// Index into `words` of the word being said at `time`: the last word
    /// that has started, so the highlight stays put through short gaps.
    public func spokenWordIndex(at time: Double) -> Int? {
        let all = words
        guard let first = all.first, time >= first.start else { return nil }
        var index = 0
        for (i, word) in all.enumerated() where word.start <= time {
            index = i
        }
        return index
    }
}

/// All cues for a video, in order, with a fast lookup by time for the
/// preview and the export compositor.
public struct CaptionTrack: Equatable, Sendable {
    public var cues: [CaptionCue]

    public init(cues: [CaptionCue]) {
        self.cues = cues
    }

    /// The cue on screen at `time` (output seconds), if any.
    public func cue(at time: Double) -> CaptionCue? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start {
                high = mid - 1
            } else if time >= cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }
}
