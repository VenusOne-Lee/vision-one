import Foundation

/// One spoken word with its timing. `id` never changes once the
/// transcript is written, so features can point at words by id. Saved
/// cuts should use times, which survive a re-transcribe.
public struct TranscriptWord: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    /// The word as shown, with any punctuation the model attached
    /// ("Hello," or "it's."). Words are joined with single spaces.
    public var text: String
    /// Seconds from the take's first video frame, the same clock as
    /// events.json and screen.mov.
    public var start: Double
    public var end: Double
    /// 0...1 from the model, or nil when the engine doesn't give one.
    public var confidence: Double?
    /// Who said it ("S1", "S2"), or nil when there is one voice or no
    /// diarization ran. Solo takes leave it out.
    public var speaker: String?

    public init(id: Int, text: String, start: Double, end: Double,
                confidence: Double? = nil, speaker: String? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
    }

    public var duration: Double { end - start }

    /// The word without punctuation, lowercased, for matching fillers
    /// ("Um," becomes "um") and searching.
    public var normalized: String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

/// A run of words the engine treated as one sentence or phrase. The
/// editor shows each segment as a paragraph; captions may split it.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var words: [TranscriptWord]

    public init(words: [TranscriptWord]) {
        self.words = words
    }

    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }
    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// A silence between two words, found from the word timings.
public struct TranscriptGap: Equatable, Sendable {
    /// The word before the gap, or nil for silence at the start.
    public let afterWordID: Int?
    /// The word after the gap, or nil for silence at the end.
    public let beforeWordID: Int?
    public let start: Double
    public let end: Double

    public init(afterWordID: Int?, beforeWordID: Int?, start: Double, end: Double) {
        self.afterWordID = afterWordID
        self.beforeWordID = beforeWordID
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// The transcript.json file in a take folder. Written once, after the
/// take is recorded, and never changed by editing: edits live in their
/// own files (edits.json). See docs/TRANSCRIPT.md.
public struct Transcript: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Transcript.currentVersion
    /// BCP 47 code of the spoken language, such as "en" or "af".
    public var language: String
    /// Which model wrote this, such as "parakeet-tdt-0.6b-v2" or
    /// "whisper-large-v3-turbo". Shown in the editor and useful for
    /// re-running with a better model later.
    public var engine: String
    /// The audio track it was made from: "mic" or "system".
    public var audioTrack: String
    /// Length of the audio in seconds.
    public var duration: Double
    public var createdAt: Date
    public var segments: [TranscriptSegment]

    public init(
        language: String,
        engine: String,
        audioTrack: String = "mic",
        duration: Double,
        createdAt: Date = Date(),
        segments: [TranscriptSegment]
    ) {
        self.language = language
        self.engine = engine
        self.audioTrack = audioTrack
        self.duration = duration
        self.createdAt = createdAt
        self.segments = segments
    }

    /// Every word in order.
    public var words: [TranscriptWord] { segments.flatMap(\.words) }

    public var text: String { segments.map(\.text).joined(separator: "\n") }

    public var isEmpty: Bool { segments.allSatisfy { $0.words.isEmpty } }

    public func word(id: Int) -> TranscriptWord? {
        words.first { $0.id == id }
    }

    /// The word being spoken at `time`, for highlighting during playback.
    public func word(at time: Double) -> TranscriptWord? {
        words.first { $0.start <= time && time < $0.end }
    }

    /// Words that overlap `start..<end`.
    public func words(from start: Double, to end: Double) -> [TranscriptWord] {
        words.filter { $0.end > start && $0.start < end }
    }

    /// Silences at least `minimum` seconds long, including any before
    /// the first word and after the last one.
    public func gaps(minimum: Double) -> [TranscriptGap] {
        let all = words
        var gaps: [TranscriptGap] = []
        var cursor = 0.0
        var previous: TranscriptWord?
        for word in all {
            if word.start - cursor >= minimum {
                gaps.append(TranscriptGap(afterWordID: previous?.id, beforeWordID: word.id,
                                          start: cursor, end: word.start))
            }
            cursor = max(cursor, word.end)
            previous = word
        }
        if duration - cursor >= minimum {
            gaps.append(TranscriptGap(afterWordID: previous?.id, beforeWordID: nil,
                                      start: cursor, end: duration))
        }
        return gaps
    }

    /// Problems that would break the editor: ids must be unique, every
    /// word must end after it starts, words must be in time order and
    /// inside the audio. Engines run this before writing.
    public func validate() throws {
        var seen = Set<Int>()
        var lastStart = -Double.infinity
        for word in words {
            guard seen.insert(word.id).inserted else { throw TranscriptError.duplicateID(word.id) }
            guard word.end > word.start, word.start >= 0, word.end <= duration + 0.05 else {
                throw TranscriptError.badTiming(word.id)
            }
            guard word.start >= lastStart else { throw TranscriptError.outOfOrder(word.id) }
            lastStart = word.start
        }
    }

    public func write(to url: URL) throws {
        try validate()
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Transcript {
        let transcript = try decoder.decode(Transcript.self, from: Data(contentsOf: url))
        guard transcript.version <= currentVersion else {
            throw TranscriptError.newerVersion(transcript.version)
        }
        return transcript
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum TranscriptError: Error, Equatable {
    case duplicateID(Int)
    case badTiming(Int)
    case outOfOrder(Int)
    /// Written by a newer Vision One; this one can't read it safely.
    case newerVersion(Int)
}
