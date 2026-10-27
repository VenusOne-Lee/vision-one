import Foundation

/// What happened in one Autopilot run, saved as autopilot.json in the take
/// so the editor can line a voice up with the steps and the next release
/// knows what changed.
public struct AutopilotRun: Codable, Equatable, Sendable {
    public struct StepResult: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case pending, running, done, failed, skipped
        }

        public var stepID: UUID
        /// The step as a plain line, as it was when it ran.
        public var line: String
        public var state: State
        /// Seconds from the take's first frame when the step started and ended.
        public var start: Double?
        public var end: Double?
        /// The fallback used: it clicked a position, not a named thing.
        public var usedPosition: Bool
        /// When it failed: a likely replacement, offered dashed.
        public var suggestion: UITarget?
        public var note: String?

        public init(stepID: UUID, line: String, state: State = .pending) {
            self.stepID = stepID
            self.line = line
            self.state = state
            self.usedPosition = false
        }
    }

    public var demoName: String
    /// The release it was recorded for, like "v1.4.0".
    public var release: String?
    /// Who asked: "you", "release", or an MCP client like "Claude Code".
    public var requestedBy: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var steps: [StepResult]
    public var stopped: StopReason?
    /// The demo's script when it ran, so a later run can tell whether the
    /// last voice still fits.
    public var script: String
    /// `DemoFingerprint` of the steps, to tell whether the demo changed.
    public var fingerprint: String

    public init(demo: DemoScript, release: String? = nil, requestedBy: String? = nil, startedAt: Date = Date()) {
        demoName = demo.name
        self.release = release
        self.requestedBy = requestedBy
        self.startedAt = startedAt
        steps = demo.steps.map { StepResult(stepID: $0.id, line: StepWords.line(for: $0)) }
        script = demo.script
        fingerprint = DemoFingerprint.of(demo)
    }

    public static func url(in take: Take) -> URL { take.folder.appendingPathComponent("autopilot.json") }

    public static func load(for take: Take) -> AutopilotRun? {
        guard let data = try? Data(contentsOf: url(in: take)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AutopilotRun.self, from: data)
    }

    public func write(for take: Take) throws {
        try write(to: Self.url(in: take))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Progress

    public mutating func begin(_ index: Int, at t: Double) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = .running
        steps[index].start = t
    }

    public mutating func finish(_ index: Int, at t: Double, usedPosition: Bool = false) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = .done
        steps[index].end = t
        steps[index].usedPosition = usedPosition
    }

    public mutating func fail(_ index: Int, at t: Double, reason: StopReason, suggestion: UITarget? = nil) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = .failed
        steps[index].end = t
        steps[index].note = reason.message
        steps[index].suggestion = suggestion
        stopped = reason
        for i in steps.indices where i > index && steps[i].state == .pending { steps[i].state = .skipped }
    }

    public mutating func stop(_ reason: StopReason, at date: Date = Date()) {
        if stopped == nil { stopped = reason }
        for i in steps.indices where steps[i].state == .pending || steps[i].state == .running {
            steps[i].state = .skipped
        }
        finishedAt = date
    }

    public var doneCount: Int { steps.filter { $0.state == .done }.count }
    public var failedIndex: Int? { steps.firstIndex { $0.state == .failed } }
    public var finishedAll: Bool { !steps.isEmpty && doneCount == steps.count }

    /// One line for the task: "Recorded 7 of 8 steps in 0:39. Step 8
    /// couldn't find “Pay with SnapScan”."
    public var receipt: String {
        let length = steps.compactMap(\.end).max().map { " in \(Timecode.short(from: $0))" } ?? ""
        if finishedAll { return "Recorded all \(steps.count) steps\(length)." }
        var line = "Recorded \(doneCount) of \(steps.count) steps\(length)."
        if let i = failedIndex, let note = steps[i].note {
            line += " Step \(i + 1): \(note)"
        } else if let stopped {
            line += " \(stopped.message)"
        }
        return line
    }

    /// Step markers for the timeline and auto zoom: where each step began.
    public var markers: [(start: Double, line: String)] {
        steps.compactMap { s in s.start.map { ($0, s.line) } }
    }

    /// Whether last time's voice can be reused for a run of `demo`: the
    /// script is word for word the same.
    public func voiceFits(_ demo: DemoScript) -> Bool {
        !script.isEmpty && script == demo.script
    }
}

/// A short, stable hash of what a demo does (apps and steps, not its
/// name or script), so Vision One can tell when it changed and ask again.
public enum DemoFingerprint {
    public static func of(_ demo: DemoScript) -> String {
        var text = demo.appsInPlay.sorted().joined(separator: ",") + "|" + (demo.app.open ?? "")
        for step in demo.steps { text += "\n" + StepWords.line(for: step) }
        // FNV-1a, 64-bit: stable across launches, unlike hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
