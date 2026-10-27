import Foundation

/// The shape a clip is exported in. Social apps want fixed sizes, so
/// these don't follow the recording's size the way export presets do.
public enum ClipFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 9:16 for Shorts, Reels, TikTok and WhatsApp Status.
    case vertical
    /// 1:1 for LinkedIn and X feeds.
    case square
    /// 16:9, the recording's own shape, for YouTube, Slack and GitHub.
    case landscape

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .landscape: return "16:9"
        }
    }

    public var detail: String {
        switch self {
        case .vertical: return "Shorts, Reels, TikTok"
        case .square: return "LinkedIn, X"
        case .landscape: return "YouTube, Slack"
        }
    }

    /// Width over height.
    public var aspect: Double {
        switch self {
        case .vertical: return 9.0 / 16.0
        case .square: return 1
        case .landscape: return 16.0 / 9.0
        }
    }

    /// Output size in pixels.
    public var size: (width: Int, height: Int) {
        switch self {
        case .vertical: return (1080, 1920)
        case .square: return (1080, 1080)
        case .landscape: return (1920, 1080)
        }
    }

    /// Appended to the take's name for the exported file.
    public var fileSuffix: String {
        switch self {
        case .vertical: return "vertical"
        case .square: return "square"
        case .landscape: return "wide"
        }
    }
}

/// Where the clip's window sits on the wide screen.
public struct ClipFraming: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Follow the cursor and clicks from events.json.
        case follow
        /// Stay where the user dragged it.
        case fixed
        /// Show the whole screen, letterboxed on paper.
        case fit
    }

    public var mode: Mode
    /// Centre of the window, 0...1 across and down the screen (origin top
    /// left). Used by `fixed`, and as the starting point for `follow`.
    public var centerX: Double
    public var centerY: Double

    public init(mode: Mode = .follow, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.mode = mode
        self.centerX = min(max(centerX, 0), 1)
        self.centerY = min(max(centerY, 0), 1)
    }

    public static let follow = ClipFraming(mode: .follow)
}

/// A rectangle in normalized frame space: 0...1, origin top left. The
/// same space the zoom and reframe code use.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// One short clip cut from a take. Its span is in seconds of the take
/// (the same clock as edits.json), so cuts made in the editor also leave
/// the clip, and the clip survives later edits.
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    /// Dashed = proposed, solid = accepted, the app's one grammar.
    /// Rejected clips stay in the file so they aren't suggested again.
    public enum State: String, Codable, Sendable {
        case proposed, accepted, rejected
    }

    /// Who suggested it. Free text so new sources don't break old builds.
    public enum Origin {
        public static let auto = "auto"     // ClipFinder, on the Mac
        public static let agent = "agent"   // the Clipper agent
        public static let user = "user"     // made by hand
    }

    public let id: UUID
    public var title: String
    /// The opening line, shown under the title.
    public var hook: String?
    public var start: Double
    public var end: Double
    /// 0...1, higher is a better clip. Hand-made clips have 1.
    public var score: Double
    /// Why it was picked, in a few words.
    public var reason: String?
    public var origin: String
    public var state: State
    public var format: ClipFormat
    public var framing: ClipFraming

    public init(id: UUID = UUID(), title: String, hook: String? = nil, span: TimeSpan,
                score: Double = 1, reason: String? = nil, origin: String = Origin.user,
                state: State = .proposed, format: ClipFormat = .vertical,
                framing: ClipFraming = .follow) {
        self.id = id
        self.title = title
        self.hook = hook
        self.start = span.start
        self.end = span.end
        self.score = min(max(score, 0), 1)
        self.reason = reason
        self.origin = origin
        self.state = state
        self.format = format
        self.framing = framing
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }

    /// The parts of the clip that play, after the editor's cuts.
    public func keptSpans(in edits: EditList) -> [TimeSpan] {
        edits.keptSpans.compactMap { kept in
            let lower = max(kept.start, start)
            let upper = min(kept.end, end)
            return upper > lower ? TimeSpan(start: lower, end: upper) : nil
        }
    }

    /// Length of the clip once the editor's cuts are left out.
    public func duration(in edits: EditList) -> Double {
        keptSpans(in: edits).reduce(0) { $0 + $1.duration }
    }
}

/// The clips.json file in a take folder. The editor, the on-device
/// finder and the Clipper agent all read and write this one file.
public struct ClipList: Codable, Equatable, Sendable {
    public var version = 1
    public var clips: [Clip]

    public init(clips: [Clip] = []) {
        self.clips = clips
    }

    /// Shortest clip worth keeping, in seconds.
    public static let minimumDuration = 1.0

    /// Proposed and accepted clips, best first. Rejected ones are hidden.
    public var visible: [Clip] {
        clips.filter { $0.state != .rejected }
            .sorted { ($0.state == .accepted ? 1 : 0, $0.score) > ($1.state == .accepted ? 1 : 0, $1.score) }
    }

    public var accepted: [Clip] { clips.filter { $0.state == .accepted } }

    public func clip(id: UUID) -> Clip? { clips.first { $0.id == id } }

    /// Adds a clip, clamped to `0...sourceDuration`. Too-short clips are
    /// ignored.
    @discardableResult
    public mutating func add(_ clip: Clip, sourceDuration: Double) -> Clip? {
        var clip = clip
        clip.start = min(max(0, clip.start), sourceDuration)
        clip.end = min(max(0, clip.end), sourceDuration)
        guard clip.end - clip.start >= Self.minimumDuration else { return nil }
        clips.append(clip)
        return clip
    }

    /// Adds suggestions, skipping any that mostly overlap a clip already
    /// in the file (proposed, accepted or rejected), so running the
    /// finder or the agent again never repeats itself or brings back a
    /// clip the user turned down. Returns the ones added.
    @discardableResult
    public mutating func propose(_ proposals: [Clip], sourceDuration: Double) -> [Clip] {
        var added: [Clip] = []
        for var proposal in proposals {
            proposal.state = .proposed
            guard !clips.contains(where: { Self.overlapRatio($0.span, proposal.span) > 0.5 }) else { continue }
            if let clip = add(proposal, sourceDuration: sourceDuration) { added.append(clip) }
        }
        return added
    }

    public mutating func setState(_ state: Clip.State, for id: UUID) {
        update(id) { $0.state = state }
    }

    public mutating func remove(id: UUID) {
        clips.removeAll { $0.id == id }
    }

    /// Moves a clip's edges, keeping at least `minimumDuration` between
    /// them and staying inside the take.
    public mutating func trim(_ id: UUID, start: Double? = nil, end: Double? = nil, sourceDuration: Double) {
        update(id) { clip in
            var lower = start ?? clip.start
            var upper = end ?? clip.end
            lower = min(max(0, lower), sourceDuration)
            upper = min(max(0, upper), sourceDuration)
            if upper - lower < Self.minimumDuration {
                if start != nil { lower = max(0, upper - Self.minimumDuration) }
                else { upper = min(sourceDuration, lower + Self.minimumDuration) }
            }
            clip.start = lower
            clip.end = upper
        }
    }

    public mutating func update(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[i])
    }

    /// How much of the shorter span the two share, 0...1.
    static func overlapRatio(_ a: TimeSpan, _ b: TimeSpan) -> Double {
        let shared = min(a.end, b.end) - max(a.start, b.start)
        let shorter = min(a.duration, b.duration)
        guard shared > 0, shorter > 0 else { return 0 }
        return shared / shorter
    }

    // MARK: File

    public static func read(from url: URL) throws -> ClipList {
        try JSONDecoder().decode(ClipList.self, from: Data(contentsOf: url))
    }

    /// Reads clips.json, or an empty list when the take has none.
    public static func load(from url: URL) throws -> ClipList {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipList() }
        return try read(from: url)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
