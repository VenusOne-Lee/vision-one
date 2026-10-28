import Foundation

/// Every cut, zoom and blur in a take as one list of rows with short names
/// (c1, z1, b1), for agents: HyperFrames' `timeline --json` idea. Names go
/// in order of start time within each kind, so they can change after an
/// edit; agents read the timeline again before naming a row.
public struct TakeTimeline: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case cut, zoom, blur

        var letter: String {
            switch self {
            case .cut: return "c"
            case .zoom: return "z"
            case .blur: return "b"
            }
        }
    }

    public struct Row: Equatable, Sendable {
        public var ref: String
        public var kind: Kind
        public var id: UUID
        public var start: Double
        public var end: Double
        public var state: ProposalState
        /// Why it's there: "filler", "click", "OpenAI key", "2× zoom".
        public var detail: String?

        public var span: TimeSpan { TimeSpan(start: start, end: end) }
    }

    public var rows: [Row]

    public init(edits: EditList, zooms: ZoomList = ZoomList(), blurs: BlurList = BlurList()) {
        func named<T>(_ items: [T], _ kind: Kind, _ make: (T) -> (UUID, TimeSpan, ProposalState, String?)) -> [Row] {
            items.map(make)
                .sorted { $0.1.start < $1.1.start }
                .enumerated()
                .map { i, item in
                    Row(ref: "\(kind.letter)\(i + 1)", kind: kind, id: item.0, start: item.1.start, end: item.1.end,
                        state: item.2, detail: item.3)
                }
        }
        let cuts = named(edits.cuts, .cut) { ($0.id, $0.span, $0.state, $0.reason) }
        let zoomRows = named(zooms.zooms, .zoom) { zoom in
            let scale = (zoom.scale * 10).rounded() / 10
            let label = scale == scale.rounded() ? "\(Int(scale))× zoom" : "\(scale)× zoom"
            return (zoom.id, zoom.span, zoom.state, zoom.followsCursor ? label + ", follows the cursor" : label)
        }
        let blurRows = named(blurs.blurs, .blur) { ($0.id, $0.span, $0.state, $0.kind ?? $0.reason) }
        rows = (cuts + zoomRows + blurRows).sorted { ($0.start, $0.ref) < ($1.start, $1.ref) }
    }

    /// Reads edits.json, zooms.json and blurs.json. Missing files are empty lists.
    public static func load(_ take: Take, sourceDuration: Double) throws -> TakeTimeline {
        TakeTimeline(edits: try EditList.load(from: take.editsURL, sourceDuration: sourceDuration),
                     zooms: try ZoomList.load(from: take.zoomsURL),
                     blurs: try BlurList.load(from: take.blursURL))
    }

    public func row(_ ref: String) -> Row? {
        let wanted = ref.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.first { $0.ref == wanted }
    }

    // MARK: What changed

    /// What changed between an earlier look at the timeline and now, one
    /// plain line each: "Kept cut c3 (0:12–0:15, filler)". Rows are matched
    /// by id, so a renumbered row still counts as the same one.
    public func changes(since before: TakeTimeline) -> [String] {
        let old = Dictionary(before.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Set(rows.map(\.id))
        var lines: [String] = []
        for row in rows {
            guard let was = old[row.id] else {
                lines.append("Added \(Self.describe(row))\(row.state == .proposed ? ", proposed" : "")")
                continue
            }
            if was.state != row.state {
                lines.append("\(Self.verb(for: row.state)) \(Self.describe(row))")
            } else if abs(was.start - row.start) > 0.01 || abs(was.end - row.end) > 0.01 {
                lines.append("Moved \(Self.describe(row)), was \(Self.clock(was.start))–\(Self.clock(was.end))")
            }
        }
        for row in before.rows where !now.contains(row.id) {
            lines.append("Removed \(row.kind.rawValue) \(Self.clock(row.start))–\(Self.clock(row.end))\(row.detail.map { ", \($0)" } ?? "")")
        }
        return lines
    }

    static func verb(for state: ProposalState) -> String {
        switch state {
        case .accepted: return "Kept"
        case .rejected: return "Turned down"
        case .proposed: return "Put back as a proposal:"
        }
    }

    static func describe(_ row: Row) -> String {
        "\(row.kind.rawValue) \(row.ref) (\(clock(row.start))–\(clock(row.end))\(row.detail.map { ", \($0)" } ?? ""))"
    }

    /// "0:12.4": tenths, since cuts are often under a second.
    static func clock(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds * 10).rounded()))
        let whole = tenths / 10
        let base = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return base + ".\(tenths % 10)"
    }

    // MARK: For agents

    /// "c3  0:12.4–0:15.0  cut   kept      filler"
    public var lines: [String] {
        rows.map { row in
            let state: String
            switch row.state {
            case .accepted: state = "kept"
            case .proposed: state = "proposed"
            case .rejected: state = "turned down"
            }
            return [row.ref, "\(Self.clock(row.start))–\(Self.clock(row.end))", row.kind.rawValue, state, row.detail ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
        }
    }

    public var json: JSONValue {
        .array(rows.map { row in
            var object: [String: JSONValue] = [
                "ref": .string(row.ref),
                "kind": .string(row.kind.rawValue),
                "start": .number((row.start * 100).rounded() / 100),
                "end": .number((row.end * 100).rounded() / 100),
                "state": .string(row.state.rawValue),
            ]
            if let detail = row.detail { object["detail"] = .string(detail) }
            return .object(object)
        })
    }
}

/// What each agent last saw of each take's timeline, so `what_changed`
/// can tell it what moved since: HyperFrames' `history --since mine`.
/// Kept in memory; a restart of Vision One starts afresh.
public actor TimelineMemory {
    private var seen: [String: TakeTimeline] = [:]

    public init() {}

    static func key(_ client: MCPClient, _ take: Take) -> String {
        client.id + "\n" + take.name
    }

    public func remember(_ timeline: TakeTimeline, client: MCPClient, take: Take) {
        seen[Self.key(client, take)] = timeline
    }

    public func last(client: MCPClient, take: Take) -> TakeTimeline? {
        seen[Self.key(client, take)]
    }
}
