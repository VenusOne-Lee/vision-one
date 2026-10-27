import Foundation

/// One box to hide from `start` to `end` (seconds of the take). The
/// secret itself is never written down: only what kind of thing it was.
public struct Blur: Codable, Hashable, Identifiable, Sendable {
    public enum Reason {
        public static let secret = "secret"   // found on screen by text detection
        public static let manual = "manual"   // drawn in the editor
    }

    public let id: UUID
    public var start: Double
    public var end: Double
    /// In 0...1 of the frame, origin top left.
    public var rect: FrameRect
    /// "OpenAI key", "Password", or nil for a box the user drew.
    public var kind: String?
    public var reason: String?
    public var state: ProposalState

    public init(id: UUID = UUID(), span: TimeSpan, rect: FrameRect, kind: String? = nil,
                reason: String? = Reason.manual, state: ProposalState = .accepted) {
        self.id = id
        self.start = span.start
        self.end = span.end
        self.rect = rect.clamped
        self.kind = kind
        self.reason = reason
        self.state = state
    }

    public var span: TimeSpan { TimeSpan(start: start, end: end) }

    /// Blurs hide from the moment they're found. A proposed blur is drawn
    /// dashed in the editor but still blurs the export: leaking a key
    /// because nobody clicked Accept is the worse mistake. Only a blur the
    /// user turned down lets the frame through.
    public var hides: Bool { state != .rejected }
}

/// A run of OCR frames, as the app's text scan hands them over.
public struct SecretSample: Sendable {
    public struct Hit: Sendable {
        public let kind: String
        public let rect: FrameRect
        /// Something that tells the same secret apart from another one in
        /// the next frame (a hash of the text). Kept in memory only.
        public let fingerprint: Int

        public init(kind: String, rect: FrameRect, fingerprint: Int) {
            self.kind = kind
            self.rect = rect
            self.fingerprint = fingerprint
        }
    }

    public let t: Double
    public let hits: [Hit]

    public init(t: Double, hits: [Hit]) {
        self.t = t
        self.hits = hits
    }
}

/// Joins secrets seen frame after frame into blurs. The scan only looks
/// at a few frames a second, so every blur reaches half way to the frames
/// on either side that weren't looked at, and a little further: better a
/// beat too long than a frame of key.
public enum BlurPlanner {
    /// - Parameters:
    ///   - interval: seconds between scanned frames.
    ///   - sourceDuration: length of the take.
    public static func propose(from samples: [SecretSample], interval: Double, sourceDuration: Double) -> [Blur] {
        struct Run {
            var kind: String
            var fingerprint: Int
            var first: Double
            var last: Double
            var rect: FrameRect
            var lastRect: FrameRect
        }
        var open: [Run] = []
        var closed: [Run] = []
        let sorted = samples.sorted { $0.t < $1.t }

        for sample in sorted {
            var stillOpen: [Run] = []
            var used = Set<Int>()
            for var run in open {
                // The same secret in about the same place carries on.
                let match = sample.hits.indices.first { i in
                    !used.contains(i)
                        && sample.hits[i].fingerprint == run.fingerprint
                        && sample.hits[i].rect.iou(run.lastRect) > 0.3
                }
                if let match, sample.t - run.last <= interval * 2.5 {
                    used.insert(match)
                    run.last = sample.t
                    run.lastRect = sample.hits[match].rect
                    run.rect = run.rect.union(sample.hits[match].rect)
                    stillOpen.append(run)
                } else {
                    closed.append(run)
                }
            }
            for (i, hit) in sample.hits.enumerated() where !used.contains(i) {
                stillOpen.append(Run(kind: hit.kind, fingerprint: hit.fingerprint,
                                     first: sample.t, last: sample.t, rect: hit.rect, lastRect: hit.rect))
            }
            open = stillOpen
        }
        closed += open

        let reach = interval * 0.75
        return closed
            .sorted { $0.first < $1.first }
            .map { run in
                let start = max(0, run.first - reach)
                let end = min(max(sourceDuration, run.last), run.last + reach)
                return Blur(span: TimeSpan(start: start, end: end), rect: padded(run.rect),
                            kind: run.kind, reason: Blur.Reason.secret, state: .proposed)
            }
    }

    /// OCR boxes hug the glyphs; pad so no edge of a letter shows.
    static func padded(_ rect: FrameRect) -> FrameRect {
        let dy = max(rect.height * 0.35, 0.004)
        let dx = max(rect.height * 0.5, 0.004)
        return rect.insetBy(dx: -dx, dy: -dy)
    }
}

/// The boxes export and preview hide at a moment of the take.
public struct BlurTrack: Sendable {
    public let blurs: [Blur]

    public init(blurs: [Blur]) {
        self.blurs = blurs.filter(\.hides).sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { blurs.isEmpty }

    public func rects(atSource t: Double) -> [FrameRect] {
        blurs.compactMap { $0.span.contains(t) || t == $0.end ? $0.rect : nil }
    }
}

/// The blurs.json file in a take folder.
public struct BlurList: Codable, Equatable, Sendable {
    public var version = 1
    public var blurs: [Blur] = []

    public init(blurs: [Blur] = []) {
        self.blurs = blurs
    }

    /// Adds proposals that don't repeat a blur already in the list over
    /// the same place and time (in any state, so a rejected one stays
    /// rejected). Returns the ones added.
    @discardableResult
    public mutating func propose(_ proposals: [Blur]) -> [Blur] {
        var added: [Blur] = []
        for var proposal in proposals {
            proposal.state = .proposed
            let repeats = blurs.contains { existing in
                existing.span.overlaps(proposal.span) && existing.rect.iou(proposal.rect) > 0.3
            }
            guard !repeats else { continue }
            blurs.append(proposal)
            added.append(proposal)
        }
        return added
    }

    public mutating func add(_ blur: Blur) {
        blurs.append(blur)
    }

    public mutating func setState(_ state: ProposalState, for id: UUID) {
        guard let i = blurs.firstIndex(where: { $0.id == id }) else { return }
        blurs[i].state = state
    }

    public mutating func acceptAllProposed() {
        for i in blurs.indices where blurs[i].state == .proposed { blurs[i].state = .accepted }
    }

    public mutating func update(_ blur: Blur) {
        guard let i = blurs.firstIndex(where: { $0.id == blur.id }) else { return }
        blurs[i] = blur
    }

    public mutating func remove(id: UUID) {
        blurs.removeAll { $0.id == id }
    }

    /// Blurs on screen at `t`, rejected ones included so the editor can
    /// still show them (faded) and bring them back.
    public func blurs(at t: Double) -> [Blur] {
        blurs.filter { $0.span.contains(t) }
    }

    public var track: BlurTrack { BlurTrack(blurs: blurs) }

    public var proposedCount: Int { blurs.filter { $0.state == .proposed }.count }

    public static func read(from url: URL) throws -> BlurList {
        try JSONDecoder().decode(BlurList.self, from: Data(contentsOf: url))
    }

    public static func load(from url: URL) throws -> BlurList {
        guard FileManager.default.fileExists(atPath: url.path) else { return BlurList() }
        return try read(from: url)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
