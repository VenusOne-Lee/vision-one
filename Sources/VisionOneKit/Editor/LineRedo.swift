import Foundation

/// One sentence said again: the new recording plays in place of the
/// original line, in the same slot of the take, so nothing else moves
/// (cuts, captions, zooms and music keep their times). The original
/// audio is never touched, so Undo or Don't use brings it straight back.
public struct LineRedo: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The original sentence, in seconds of the take.
    public var start: Double
    public var end: Double
    public var text: String
    /// The recording, relative to the take's folder (redos/<id>.caf).
    public var file: String
    /// The part of the recording to use, after trimming silence.
    public var clipStart: Double
    public var clipEnd: Double
    /// Gain that matches the new line's level to the original's.
    public var gainDB: Double
    public var state: ProposalState

    public init(id: UUID = UUID(), slot: TimeSpan, text: String, file: String, clip: TimeSpan,
                gainDB: Double, state: ProposalState = .proposed) {
        self.id = id
        self.start = slot.start
        self.end = slot.end
        self.text = text
        self.file = file
        self.clipStart = clip.start
        self.clipEnd = clip.end
        self.gainDB = gainDB
        self.state = state
    }

    public var slot: TimeSpan { TimeSpan(start: start, end: end) }
    public var clip: TimeSpan { TimeSpan(start: clipStart, end: clipEnd) }

    /// How much the new line is sped up (above 1) or slowed down (below
    /// 1) to fill the slot exactly. Kept close to 1 so it sounds natural.
    public var rate: Double { clip.duration / max(slot.duration, 0.001) }

    /// Speeds outside this sound odd; the line is better recorded again.
    public static let rates: ClosedRange<Double> = 0.8...1.25
    /// Silence left before and after the words when trimming.
    public static let margin = 0.08
    public static let maxGainDB = 12.0

    public enum Problem: Error, Equatable, Sendable {
        case nothingHeard
        case tooLong(by: Double)
        case tooShort(by: Double)

        public var message: String {
            switch self {
            case .nothingHeard:
                return "Didn't hear anything. Check the mic and record the line again."
            case let .tooLong(by):
                return "That's \(String(format: "%.1f", by)) s longer than the original. Say it a little quicker so it fits."
            case let .tooShort(by):
                return "That's \(String(format: "%.1f", by)) s shorter than the original. Say it a little slower so it fits."
            }
        }
    }

    /// Plans a redo from a new recording: trims the silence around the
    /// words, matches the level to the original line, and checks it
    /// fits the slot.
    public static func plan(slot: TimeSpan, text: String, file: String,
                            recording: LoudnessEnvelope, original: LoudnessEnvelope?) -> Result<LineRedo, Problem> {
        let threshold = recording.adaptiveThreshold
        guard let first = recording.levels.firstIndex(where: { $0 > threshold }),
              let last = recording.levels.lastIndex(where: { $0 > threshold }), last > first
        else { return .failure(.nothingHeard) }
        let clip = TimeSpan(start: max(0, Double(first) * recording.hop - margin),
                            end: min(recording.duration, Double(last + 1) * recording.hop + margin))
        let rate = clip.duration / max(slot.duration, 0.001)
        if rate > rates.upperBound { return .failure(.tooLong(by: clip.duration - slot.duration)) }
        if rate < rates.lowerBound { return .failure(.tooShort(by: slot.duration - clip.duration)) }
        var gain = 0.0
        if let original, let was = original.speechLevel(in: slot), let now = recording.speechLevel(in: clip) {
            gain = min(maxGainDB, max(-maxGainDB, Double(was - now)))
        }
        return .success(LineRedo(slot: slot, text: text, file: file, clip: clip, gainDB: gain))
    }
}

public struct RedoList: Codable, Equatable, Sendable {
    public var version = 1
    public var redos: [LineRedo] = []

    public init(redos: [LineRedo] = []) {
        self.redos = redos
    }

    /// The redos that play: proposed ones too, so you hear them before
    /// you keep them, the way dashed cuts are skipped in the preview.
    public var playing: [LineRedo] { redos.filter { $0.state != .rejected } }

    /// Adds a redo, replacing any earlier one of the same sentence.
    public mutating func add(_ redo: LineRedo) {
        redos.removeAll { $0.slot.overlaps(redo.slot) }
        redos.append(redo)
    }

    public mutating func setState(_ state: ProposalState, for id: UUID) {
        guard let i = redos.firstIndex(where: { $0.id == id }) else { return }
        redos[i].state = state
    }

    public static func load(from url: URL) throws -> RedoList {
        guard FileManager.default.fileExists(atPath: url.path) else { return RedoList() }
        return try JSONDecoder().decode(RedoList.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension Take {
    public var redosURL: URL { folder.appendingPathComponent("redos.json") }
    public var redosFolder: URL { folder.appendingPathComponent("redos", isDirectory: true) }
}

extension LoudnessEnvelope {
    /// The median level of the speech in `span` (frames above the
    /// adaptive threshold), or nil when nothing there is speech.
    public func speechLevel(in span: TimeSpan) -> Float? {
        guard hop > 0 else { return nil }
        let threshold = adaptiveThreshold
        let first = max(0, Int(span.start / hop))
        let last = min(levels.count, Int((span.end / hop).rounded(.up)))
        guard first < last else { return nil }
        let speech = levels[first..<last].filter { $0 > threshold }.sorted()
        guard !speech.isEmpty else { return nil }
        return speech[speech.count / 2]
    }
}

extension ExportTimeline {
    /// Where a stretch of the recording plays in the export, when all of
    /// it is kept in one piece; nil when any of it was cut.
    public func outputRange(forSource span: TimeSpan) -> Range<Double>? {
        guard let segment = segments.first(where: { $0.source.contains(span.start) }),
              span.end <= segment.source.upperBound + 1e-6 else { return nil }
        let start = segment.outputStart + (span.start - segment.source.lowerBound)
        return start..<(start + span.duration)
    }
}

extension RedoList {
    /// What export uses: only the redos you kept.
    public var accepted: [LineRedo] { redos.filter { $0.state == .accepted } }
}
