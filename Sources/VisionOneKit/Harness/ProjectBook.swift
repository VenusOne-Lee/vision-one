import Foundation

/// A folder of work in the sidebar: "My videos", "RankRide launch". Each
/// take belongs to one project; a take nobody moved is in "My videos".
public struct HarnessProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Take folder names, newest added last.
    public var takes: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, takes: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.takes = takes
        self.createdAt = createdAt
    }
}

/// Every project, kept in projects.json beside jobs.json. The first one
/// is always "My videos" and can't be deleted, so a take is never lost.
public struct ProjectBook: Codable, Equatable, Sendable {
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-00000000F1D0")!
    public static let defaultName = "My videos"

    public private(set) var projects: [HarnessProject]

    public init(projects: [HarnessProject] = []) {
        self.projects = projects
        ensureDefault()
    }

    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("projects.json")
    }

    public var defaultProject: HarnessProject { projects.first { $0.id == Self.defaultID }! }

    public func project(_ id: UUID) -> HarnessProject? { projects.first { $0.id == id } }

    /// The project a take is in; "My videos" when it was never moved.
    public func projectID(for take: Take) -> UUID {
        projects.first { $0.id != Self.defaultID && $0.takes.contains(take.name) }?.id ?? Self.defaultID
    }

    /// The takes of a project, in the order the library lists them.
    public func takes(in id: UUID, from all: [Take]) -> [Take] {
        all.filter { projectID(for: $0) == id }
    }

    @discardableResult
    public mutating func add(named name: String, at date: Date = Date()) -> HarnessProject {
        let project = HarnessProject(name: Self.clean(name, fallback: "New project"), createdAt: date)
        projects.append(project)
        return project
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = Self.clean(name, fallback: projects[i].name)
    }

    /// Deleting a project keeps its takes: they go back to "My videos".
    public mutating func delete(_ id: UUID) {
        guard id != Self.defaultID else { return }
        projects.removeAll { $0.id == id }
    }

    public mutating func move(_ take: Take, to id: UUID) {
        guard project(id) != nil else { return }
        for i in projects.indices { projects[i].takes.removeAll { $0 == take.name } }
        if id != Self.defaultID, let i = projects.firstIndex(where: { $0.id == id }) {
            projects[i].takes.append(take.name)
        }
    }

    /// Reorders the sidebar, as a List's onMove hands it over; "My videos"
    /// stays first.
    public mutating func reorder(from source: IndexSet, to destination: Int) {
        let moving = source.filter { $0 > 0 && $0 < projects.count }
        let shifted = moving.filter { $0 < destination }.count
        let picked = moving.map { projects[$0] }
        var kept = projects.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        kept.insert(contentsOf: picked, at: min(max(1, destination - shifted), kept.count))
        projects = kept
    }

    // MARK: Disk

    public static func load(from url: URL = standardURL) -> ProjectBook {
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder.harness.decode(ProjectBook.self, from: data) else { return ProjectBook() }
        var fixed = book
        fixed.ensureDefault()
        return fixed
    }

    public func save(to url: URL = standardURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.harness.encode(self).write(to: url, options: .atomic)
    }

    private mutating func ensureDefault() {
        if let i = projects.firstIndex(where: { $0.id == Self.defaultID }) {
            if i != 0 { projects.insert(projects.remove(at: i), at: 0) }
        } else {
            projects.insert(HarnessProject(id: Self.defaultID, name: Self.defaultName,
                                           createdAt: Date(timeIntervalSince1970: 0)), at: 0)
        }
    }

    static func clean(_ name: String, fallback: String) -> String {
        let one = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? fallback : String(one.prefix(60))
    }
}

extension JSONEncoder {
    static var harness: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var harness: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
