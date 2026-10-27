import Foundation

/// "Try in a copy": a take's cut can have copies, each its own edit list
/// on top of the same recording. The main cut is always edits.json, so
/// everything that reads a take keeps working; Make main swaps files.
public struct TakeVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// The edit list's file name in the take folder.
    public var file: String
    public var createdAt: Date
    /// Exported versions are locked, so a shared link always matches.
    public var locked: Bool

    public init(id: UUID = UUID(), name: String, file: String, createdAt: Date = Date(), locked: Bool = false) {
        self.id = id
        self.name = name
        self.file = file
        self.createdAt = createdAt
        self.locked = locked
    }

    public var isMain: Bool { file == TakeVersions.mainFile }
}

public enum TakeVersionError: Error, Equatable, Sendable {
    case notFound
    case locked(String)
    case cantRemoveMain
}

/// versions.json in the take folder.
public struct TakeVersions: Codable, Equatable, Sendable {
    public static let mainFile = "edits.json"

    public var version = 1
    public var versions: [TakeVersion]

    public init(versions: [TakeVersion] = [TakeVersion(name: "Main cut", file: TakeVersions.mainFile)]) {
        self.versions = versions
    }

    public var main: TakeVersion { versions.first { $0.isMain } ?? TakeVersion(name: "Main cut", file: Self.mainFile) }
    public var copies: [TakeVersion] { versions.filter { !$0.isMain } }

    public func version(_ id: UUID) -> TakeVersion? { versions.first { $0.id == id } }

    public static func url(of version: TakeVersion, in take: Take) -> URL {
        take.folder.appendingPathComponent(version.file)
    }

    /// A copy of `source` (the main cut by default), named "Copy 1", "Copy 2"…
    @discardableResult
    public mutating func makeCopy(of source: UUID? = nil, name: String? = nil, in take: Take,
                                  fileManager: FileManager = .default) throws -> TakeVersion {
        let from = try source.map { id -> TakeVersion in
            guard let v = version(id) else { throw TakeVersionError.notFound }
            return v
        } ?? main
        var n = copies.count + 1
        while versions.contains(where: { $0.file == "edits-copy-\(n).json" }) { n += 1 }
        let copy = TakeVersion(name: name ?? "Copy \(n)", file: "edits-copy-\(n).json")
        let src = Self.url(of: from, in: take)
        let dst = Self.url(of: copy, in: take)
        if fileManager.fileExists(atPath: dst.path) { try fileManager.removeItem(at: dst) }
        if fileManager.fileExists(atPath: src.path) { try fileManager.copyItem(at: src, to: dst) }
        versions.append(copy)
        return copy
    }

    /// Makes a copy the main cut. The old main becomes a copy under its
    /// own name, so nothing is lost.
    public mutating func makeMain(_ id: UUID, in take: Take, fileManager: FileManager = .default) throws {
        guard let i = versions.firstIndex(where: { $0.id == id }) else { throw TakeVersionError.notFound }
        guard !versions[i].isMain else { return }
        guard let m = versions.firstIndex(where: { $0.isMain }) else {
            versions[i].file = Self.mainFile
            return
        }
        let mainURL = take.folder.appendingPathComponent(Self.mainFile)
        let copyURL = take.folder.appendingPathComponent(versions[i].file)
        let spare = take.folder.appendingPathComponent(".swap-\(UUID().uuidString).json")
        let hasMain = fileManager.fileExists(atPath: mainURL.path)
        let hasCopy = fileManager.fileExists(atPath: copyURL.path)
        if hasMain { try fileManager.moveItem(at: mainURL, to: spare) }
        if hasCopy { try fileManager.moveItem(at: copyURL, to: mainURL) }
        if hasMain { try fileManager.moveItem(at: spare, to: copyURL) }
        let copyFile = versions[i].file
        versions[i].file = Self.mainFile
        versions[m].file = copyFile
        if versions[m].name == "Main cut" { versions[m].name = "Earlier main cut" }
    }

    /// Called on export: this version can't be changed any more.
    public mutating func lock(_ id: UUID) {
        guard let i = versions.firstIndex(where: { $0.id == id }) else { return }
        versions[i].locked = true
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = versions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { versions[i].name = trimmed }
    }

    public mutating func remove(_ id: UUID, in take: Take, fileManager: FileManager = .default) throws {
        guard let v = version(id) else { throw TakeVersionError.notFound }
        guard !v.isMain else { throw TakeVersionError.cantRemoveMain }
        guard !v.locked else { throw TakeVersionError.locked(v.name) }
        try? fileManager.removeItem(at: Self.url(of: v, in: take))
        versions.removeAll { $0.id == id }
    }

    // MARK: File

    public static func load(for take: Take) -> TakeVersions {
        guard let data = try? Data(contentsOf: take.versionsURL),
              let saved = try? JSONDecoder().decode(TakeVersions.self, from: data) else { return TakeVersions() }
        return saved
    }

    public func write(for take: Take) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: take.versionsURL, options: .atomic)
    }
}

extension Take {
    /// The main cut and its copies (TakeVersions).
    public var versionsURL: URL { folder.appendingPathComponent("versions.json") }
}
