import Foundation

/// The attempts at each script line in a take, and which one to keep.
/// Written as script-takes.json; the losers become proposed "repeat"
/// cuts in edits.json, so they show in Changes with the other retakes
/// and can be flipped to keep a different attempt.
public struct ScriptTakes: Codable, Equatable, Sendable {
    public var version = 1
    public var lines: [Line]

    public struct Line: Codable, Equatable, Sendable {
        public let line: Int
        public var attempts: [Attempt]
        /// Index into `attempts` of the one kept, or nil if never said.
        public var kept: Int?
    }

    public struct Attempt: Codable, Equatable, Sendable {
        /// Seconds from the first video frame, first word to last.
        public var start: Double
        public var end: Double
        /// Share of the line's words said, 0...1.
        public var coverage: Double
        /// Words in the attempt that aren't in the script (ums, asides).
        public var strays: Int

        public var span: TimeSpan { TimeSpan(start: start, end: end) }
    }

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Lines said more than once.
    public var retakenLines: [Line] { lines.filter { $0.attempts.count > 1 } }

    // MARK: Finding attempts

    /// Matches the transcript to the script in order. A jump back to an
    /// earlier word (saying a line again) or on to another line starts a
    /// new attempt. Words that match nothing count against the attempt
    /// they fall in.
    public static func find(script: Script, words: [TranscriptWord]) -> ScriptTakes {
        var follower = ScriptFollower(script: script)
        let scriptWords = follower.words

        struct Building {
            var line: Int
            var start: Double
            var end: Double
            var said: Set<Int> = []
            var strays = 0
            var lastIndex: Int
        }
        var finished: [Building] = []
        var current: Building?

        for word in words {
            guard let index = follower.hear(word.text) else {
                current?.strays += 1
                continue
            }
            let line = scriptWords[index].line
            if var open = current, open.line == line, index > open.lastIndex {
                open.end = word.end
                open.said.insert(scriptWords[index].index)
                open.lastIndex = index
                current = open
            } else {
                if let open = current { finished.append(open) }
                current = Building(line: line, start: word.start, end: word.end,
                                   said: [scriptWords[index].index], lastIndex: index)
            }
        }
        if let open = current { finished.append(open) }

        let result = script.lines.map { line -> Line in
            let attempts = finished.filter { $0.line == line.id }.map { building -> Attempt in
                // Strays after the last script word don't stretch the
                // attempt; a losing attempt's cut runs past them anyway.
                Attempt(start: building.start, end: building.end,
                        coverage: line.words.isEmpty ? 0 : Double(building.said.count) / Double(line.words.count),
                        strays: building.strays)
            }
            return Line(line: line.id, attempts: attempts, kept: best(of: attempts))
        }
        return ScriptTakes(lines: result)
    }

    /// The most complete attempt; then the one with fewer strays; then the
    /// later one, since people say a line again to fix it.
    static func best(of attempts: [Attempt]) -> Int? {
        guard !attempts.isEmpty else { return nil }
        var bestIndex = 0
        for (i, attempt) in attempts.enumerated().dropFirst() {
            let best = attempts[bestIndex]
            if attempt.coverage > best.coverage + 0.001 { bestIndex = i; continue }
            if attempt.coverage < best.coverage - 0.001 { continue }
            if attempt.strays <= best.strays { bestIndex = i }
        }
        return bestIndex
    }

    // MARK: Cuts

    /// A proposed cut for every attempt not kept, running to the start of
    /// whatever was said next so the pause after a fluff goes too. Never
    /// reaches into a kept attempt.
    public func cuts(endOfTake: Double) -> [Cut] {
        let all = lines.flatMap { line in line.attempts.enumerated().map { (line: line, index: $0.offset, attempt: $0.element) } }
            .sorted { $0.attempt.start < $1.attempt.start }
        var result: [Cut] = []
        for (i, item) in all.enumerated() where item.index != item.line.kept {
            let nextStart = i + 1 < all.count ? all[i + 1].attempt.start : min(endOfTake, item.attempt.end)
            let end = max(item.attempt.end, nextStart)
            guard end > item.attempt.start else { continue }
            result.append(Cut(span: TimeSpan(start: item.attempt.start, end: end),
                              reason: Cut.Reason.`repeat`, state: .proposed))
        }
        return result
    }

    // MARK: File

    public static func read(from url: URL) throws -> ScriptTakes {
        try JSONDecoder().decode(ScriptTakes.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Runs after transcription for takes recorded from a script: finds the
/// attempts per line, writes script-takes.json and proposes cutting the
/// losers. Run before auto-clean, so its own retake guesses don't overlap.
public enum ScriptRetakes {
    @discardableResult
    public static func run(on take: Take, transcript: Transcript, sourceDuration: Double) throws -> ScriptTakes? {
        guard FileManager.default.fileExists(atPath: take.scriptURL.path) else { return nil }
        let script = try Script.read(from: take.scriptURL)
        let takes = ScriptTakes.find(script: script, words: transcript.words)
        try takes.write(to: take.scriptTakesURL)
        let cuts = takes.cuts(endOfTake: sourceDuration)
        if !cuts.isEmpty {
            var list = try EditList.load(from: take.editsURL, sourceDuration: sourceDuration)
            list.propose(cuts)
            try list.write(to: take.editsURL)
        }
        return takes
    }
}
