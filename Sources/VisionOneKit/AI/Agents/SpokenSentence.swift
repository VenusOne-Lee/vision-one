import Foundation

/// A sentence still in the edit: the unit the Editor keeps or cuts and the
/// Clipper builds clips from. Words already cut are left out.
public struct SpokenSentence: Equatable, Sendable {
    public var index: Int
    public var wordIDs: [Int]
    public var text: String
    public var start: Double
    public var end: Double

    public var span: TimeSpan { TimeSpan(start: start, end: end) }
    public var duration: Double { end - start }
}

extension Transcript {
    /// Sentences made of the words that survive `edits`, split at . ? ! and
    /// at segment ends, and at pauses of `pause` seconds or more so a
    /// sentence the model never punctuated still gets broken up.
    public func sentences(keeping edits: EditList? = nil, pause: Double = 1.2) -> [SpokenSentence] {
        var result: [SpokenSentence] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            result.append(SpokenSentence(index: result.count, wordIDs: current.map(\.id),
                                         text: current.map(\.text).joined(separator: " "),
                                         start: first.start, end: last.end))
            current = []
        }
        for segment in segments {
            for word in segment.words {
                let middle = (word.start + word.end) / 2
                if let edits, edits.isRemoved(middle) { continue }
                if let previous = current.last, word.start - previous.end >= pause { flush() }
                current.append(word)
                if let last = word.text.last, ".?!".contains(last) { flush() }
            }
            flush()
        }
        return result
    }
}
