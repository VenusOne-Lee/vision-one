import Foundation

/// The AI voice tools' changes to one take, kept in voice.json next to
/// the recording. Like every edit, they never touch screen.mov: export
/// swaps them in. Each starts proposed (dashed) and is kept or undone.
public struct VoiceEdits: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The mic track after the ElevenLabs voice isolator.
    public struct CleanVoice: Codable, Equatable, Sendable {
        /// File name in the take folder.
        public var file: String
        public var kept: Bool
        public var made: Date

        public init(file: String, kept: Bool = false, made: Date = Date()) {
            self.file = file
            self.kept = kept
            self.made = made
        }
    }

    /// One word re-said in the user's own cloned voice. Always labelled:
    /// the transcript marks it "AI voice", and export can say so.
    public struct WordFix: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// The transcript word it replaces.
        public var wordID: Int
        /// Where the word sits in the recording, in take seconds.
        public var start: Double
        public var end: Double
        public var original: String
        public var replacement: String
        /// The new audio, a file in the take folder.
        public var file: String
        /// Seconds of speech in `file`, so it can be lined up.
        public var duration: Double
        public var voiceID: String
        public var kept: Bool

        public init(id: UUID = UUID(), wordID: Int, start: Double, end: Double, original: String, replacement: String,
                    file: String, duration: Double, voiceID: String, kept: Bool = false) {
            self.id = id
            self.wordID = wordID
            self.start = start
            self.end = end
            self.original = original
            self.replacement = replacement
            self.file = file
            self.duration = duration
            self.voiceID = voiceID
            self.kept = kept
        }

        public var span: TimeSpan { TimeSpan(start: start, end: end) }
    }

    public var version = VoiceEdits.currentVersion
    public var cleanVoice: CleanVoice?
    public var fixes: [WordFix] = []

    public init(cleanVoice: CleanVoice? = nil, fixes: [WordFix] = []) {
        self.cleanVoice = cleanVoice
        self.fixes = fixes
    }

    public var isEmpty: Bool { cleanVoice == nil && fixes.isEmpty }

    /// Words said by an AI copy of the user's voice, kept or proposed, so
    /// the transcript can mark every one.
    public var aiSpokenWordIDs: Set<Int> { Set(fixes.map(\.wordID)) }

    public var keptFixes: [WordFix] { fixes.filter(\.kept) }

    /// A line for the export's description when kept fixes are in it.
    public var disclosure: String? {
        let count = keptFixes.count
        guard count > 0 else { return nil }
        return count == 1
            ? "One word in this video was re-said by an AI copy of the speaker's own voice, made with their consent."
            : "\(count) words in this video were re-said by an AI copy of the speaker's own voice, made with their consent."
    }

    /// Adds a proposed fix, replacing any earlier one for the same word.
    public mutating func propose(_ fix: WordFix) {
        fixes.removeAll { $0.wordID == fix.wordID }
        fixes.append(fix)
        fixes.sort { $0.start < $1.start }
    }

    public mutating func keep(_ id: UUID) {
        if let i = fixes.firstIndex(where: { $0.id == id }) { fixes[i].kept = true }
    }

    /// Takes a fix out; returns its file so the caller can delete it.
    @discardableResult
    public mutating func undo(_ id: UUID) -> String? {
        guard let i = fixes.firstIndex(where: { $0.id == id }) else { return nil }
        return fixes.remove(at: i).file
    }

    // MARK: Export

    /// Where a kept fix plays in the edited video, and the stretch of the
    /// original mic to silence under it.
    public struct Placement: Equatable, Sendable {
        public var fix: WordFix
        /// Output seconds where the new word starts.
        public var at: Double
        /// Output span of the original word, muted on the mic track.
        public var mute: TimeSpan
    }

    /// Kept fixes whose word survived the edit, on the output clock.
    public func placements(on timeline: ExportTimeline) -> [Placement] {
        keptFixes.compactMap { fix in
            guard let start = timeline.outputTime(forSource: fix.start),
                  let end = timeline.outputTime(forSource: max(fix.start, fix.end - 0.001)) else { return nil }
            // A word split by a cut is left alone rather than half-replaced.
            guard end >= start, end - start <= fix.end - fix.start + 0.01 else { return nil }
            // Centre the new word on the old one so it lands in the same gap.
            let at = max(0, start + (end - start - fix.duration) / 2)
            return Placement(fix: fix, at: at, mute: TimeSpan(start: start, end: end))
        }
    }

    // MARK: File

    public static let fileName = "voice.json"

    public static func load(from url: URL) -> VoiceEdits {
        guard let data = try? Data(contentsOf: url) else { return VoiceEdits() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(VoiceEdits.self, from: data)) ?? VoiceEdits()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension Take {
    /// voice.json: the cleaned voice and AI word fixes.
    public var voiceURL: URL { folder.appendingPathComponent(VoiceEdits.fileName) }
}

/// Names the kind of audio file ElevenLabs sent back from its first bytes,
/// so it's saved with an extension AVFoundation will open.
public enum AudioFileKind {
    public static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 { return "wav" } // RIFF
        if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "m4a" } // ftyp
        if bytes.count >= 4, bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { return "ogg" } // OggS
        if bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return "flac" } // fLaC
        return "mp3"
    }
}
