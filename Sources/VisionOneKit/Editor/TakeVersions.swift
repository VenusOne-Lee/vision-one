import Foundation

/// One version of a take's edit: its cuts, zooms, blurs and sound. The
/// video is never copied; versions are a few small JSON files each.
public struct TakeVersion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var created: Date
    /// What was asked for when the copy was made, such as "punchier, for LinkedIn".
    public var note: String?
    /// An exported version: kept as it was, so a shared link never
    /// changes under people. It can be compared but not opened to edit.
    public var locked: Bool

    public init(id: String, name: String, created: Date, note: String? = nil, locked: Bool = false) {
        self.id = id
        self.name = name
        self.created = created
        self.note = note
        self.locked = locked
    }
}

/// "Try in a copy", like a Codex worktree: big changes happen in a copy
/// while the main cut stays safe. The version open in the editor lives
/// in the take's own folder (so the editor, export and agents need no
/// changes); every other version is parked in versions/<id>/.
public struct TakeVersions: Sendable {
    /// The files that make up one version of the edit.
    public static let files = ["edits.json", "zooms.json", "blurs.json", "sound.json", "redos.json"]
    public static let mainID = "main"

    public struct Index: Codable, Equatable, Sendable {
        public var open: String
        public var main: String
        public var versions: [TakeVersion]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unknown(String)
        case locked(String)
        case inUse(String)

        public var errorDescription: String? {
            switch self {
            case let .unknown(name): return "There's no version called \(name)."
            case let .locked(name): return "\(name) was exported, so it stays as it is. Make a copy of it to change it."
            case let .inUse(name): return "\(name) is open or is the main cut, so it can't be deleted."
            }
        }
    }

    public let take: Take

    public init(take: Take) {
        self.take = take
    }

    public var folder: URL { take.folder.appendingPathComponent("versions", isDirectory: true) }
    var indexURL: URL { folder.appendingPathComponent("index.json") }

    /// The versions, oldest first. A take that was never copied has one,
    /// the main cut, open.
    public func index() -> Index {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? Self.decoder.decode(Index.self, from: data), !index.versions.isEmpty {
            return index
        }
        let created = (try? take.folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(timeIntervalSince1970: 0)
        return Index(open: Self.mainID, main: Self.mainID,
                     versions: [TakeVersion(id: Self.mainID, name: "Main cut", created: created)])
    }

    /// Where a version's files are: the take's folder for the open one.
    public func folder(for id: String, in index: Index? = nil) -> URL {
        (index ?? self.index()).open == id ? take.folder : folder.appendingPathComponent(id, isDirectory: true)
    }

    /// Parks the open version and opens a fresh copy of it, called
    /// `name`. The copy starts the same as what was open.
    @discardableResult
    public func tryCopy(named name: String, note: String? = nil, now: Date = Date()) throws -> TakeVersion {
        var index = index()
        try park(index.open)
        let version = TakeVersion(id: uniqueID(for: name, in: index), name: name, created: now, note: note)
        index.versions.append(version)
        index.open = version.id
        try save(index)
        return version
    }

    /// Copies the open version as it is now into a locked version, for
    /// an export. The open version stays open.
    @discardableResult
    public func lockSnapshot(named name: String, now: Date = Date()) throws -> TakeVersion {
        var index = index()
        let version = TakeVersion(id: uniqueID(for: name, in: index), name: name, created: now, locked: true)
        try copyFiles(from: take.folder, to: folder.appendingPathComponent(version.id, isDirectory: true))
        index.versions.append(version)
        try save(index)
        return version
    }

    /// Opens another version for editing: the open one is parked, the
    /// other's files move into the take's folder.
    public func open(_ id: String) throws {
        var index = index()
        guard id != index.open else { return }
        guard let version = index.versions.first(where: { $0.id == id }) else { throw Failure.unknown(id) }
        guard !version.locked else { throw Failure.locked(version.name) }
        try park(index.open)
        let parked = folder.appendingPathComponent(id, isDirectory: true)
        try copyFiles(from: parked, to: take.folder)
        try? FileManager.default.removeItem(at: parked)
        index.open = id
        try save(index)
    }

    /// Marks a version as the main cut, the one Home and Library show.
    public func makeMain(_ id: String) throws {
        var index = index()
        guard index.versions.contains(where: { $0.id == id }) else { throw Failure.unknown(id) }
        index.main = id
        try save(index)
    }

    public func delete(_ id: String) throws {
        var index = index()
        guard let version = index.versions.first(where: { $0.id == id }) else { throw Failure.unknown(id) }
        guard id != index.open, id != index.main else { throw Failure.inUse(version.name) }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
        index.versions.removeAll { $0.id == id }
        try save(index)
    }

    public func rename(_ id: String, to name: String) throws {
        var index = index()
        guard let i = index.versions.firstIndex(where: { $0.id == id }) else { throw Failure.unknown(id) }
        index.versions[i].name = name
        try save(index)
    }

    // MARK: Files

    /// Copies the open version's files out of the take's folder.
    private func park(_ id: String) throws {
        try copyFiles(from: take.folder, to: folder.appendingPathComponent(id, isDirectory: true))
    }

    /// Copies the version files from one folder to another. A file the
    /// source doesn't have is removed from the destination, so the
    /// destination ends up exactly like the source.
    private func copyFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in Self.files {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: to) }
        }
    }

    private func save(_ index: Index) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    func uniqueID(for name: String, in index: Index) -> String {
        let slug = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = slug.isEmpty ? "copy" : String(slug.prefix(40))
        var id = base
        var n = 2
        while index.versions.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// "Copy", "Copy 2", … for the next copy's default name.
    public func nextCopyName() -> String {
        let names = Set(index().versions.map(\.name))
        if !names.contains("Copy") { return "Copy" }
        var n = 2
        while names.contains("Copy \(n)") { n += 1 }
        return "Copy \(n)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
