import Foundation

/// A note a viewer left on one line of a share page. Notes go to the
/// creator only; the page never shows one viewer's note to another.
public struct ViewerNote: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// What the viewer typed as their name, or nil.
    public var name: String?
    public var text: String
    /// Seconds into the video.
    public var at: Double
    /// The line it's pinned to, as the page showed it.
    public var quote: String?
    public var createdAt: Date
    /// The creator marked it handled.
    public var done: Bool

    public init(id: String = UUID().uuidString, name: String? = nil, text: String, at: Double,
                quote: String? = nil, createdAt: Date = Date(), done: Bool = false) {
        self.id = id
        self.name = name
        self.text = text
        self.at = at
        self.quote = quote
        self.createdAt = createdAt
        self.done = done
    }

    public var who: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "A viewer" : trimmed
    }

    /// The note as a task in the Agent Desk, under "Needs you". The
    /// Editor reads `ask` if the user presses "Ask the Editor to fix".
    public func job(for take: Take) -> AgentJob {
        let short = text.count > 60 ? String(text.prefix(57)) + "…" : text
        var job = AgentJob(agent: .editor, title: "Viewer note: \(short)", take: take,
                           ask: editorAsk, createdAt: createdAt)
        job.state = .needsReview
        job.receipt = "\(who) at \(Timecode.short(from: at))\(quote.map { " on “\($0)”" } ?? "")"
        return job
    }

    /// "A viewer said at 0:33, on “You see the price up front”: Is the
    /// price per person or per car?"
    public var editorAsk: String {
        "\(who) said at \(Timecode.short(from: at))\(quote.map { ", on “\($0)”" } ?? ""): \(text)"
    }
}

/// What came back from a share page: notes and events, saved per take
/// as viewers.json so the Viewers panel opens instantly and works
/// offline. New pulls are merged in; nothing is ever sent back.
public struct ViewerInbox: Codable, Equatable, Sendable {
    public var notes: [ViewerNote]
    public var events: [ViewerEvent]
    /// The last pull; the next one asks only for what's newer.
    public var pulledAt: Date?
    /// The host's id for the last event pulled, so none come twice.
    public var eventCursor: Int?
    /// Notes already filed as Desk asks, so each is filed once.
    public var filedNoteIDs: [String]?

    public init(notes: [ViewerNote] = [], events: [ViewerEvent] = [], pulledAt: Date? = nil, eventCursor: Int? = nil) {
        self.notes = notes
        self.events = events
        self.pulledAt = pulledAt
        self.eventCursor = eventCursor
    }

    /// Notes not yet filed on the Desk, oldest first. Call `markFiled`
    /// once each is.
    public var unfiledNotes: [ViewerNote] {
        let filed = Set(filedNoteIDs ?? [])
        return notes.filter { !filed.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    public mutating func markFiled(_ id: String) {
        var filed = filedNoteIDs ?? []
        if !filed.contains(id) { filed.append(id) }
        filedNoteIDs = filed
    }

    /// Notes the creator hasn't handled, newest first.
    public var openNotes: [ViewerNote] {
        notes.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Adds what a pull returned. Notes already here keep their `done`.
    public mutating func merge(notes new: [ViewerNote], events newEvents: [ViewerEvent], at time: Date = Date()) {
        let known = Set(notes.map(\.id))
        notes += new.filter { !known.contains($0.id) }
        let seen = Set(events.map(Self.key))
        events += newEvents.filter { !seen.contains(Self.key($0)) }
        pulledAt = time
    }

    public mutating func markDone(_ id: String, _ done: Bool = true) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].done = done
    }

    private static func key(_ event: ViewerEvent) -> String {
        "\(event.visit)|\(event.kind.rawValue)|\(event.at ?? -1)|\(event.emoji ?? "")|\(event.text ?? "")|\(event.time.timeIntervalSince1970)"
    }

    public static func load(for take: Take) -> ViewerInbox {
        guard let data = try? Data(contentsOf: take.viewersURL) else { return ViewerInbox() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ViewerInbox.self, from: data)) ?? ViewerInbox()
    }

    public func save(for take: Take) throws {
        try JSONEncoder.sharePage.encode(self).write(to: take.viewersURL, options: .atomic)
    }
}
