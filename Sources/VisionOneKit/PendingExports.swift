import Foundation

/// Exports still to do when Vision One quits, so the next launch carries
/// on: the take, the formats not yet finished, and the kept parts it was
/// asked for. Saved in ~/Library/Application Support/Vision One.
public struct PendingExports: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var takeFolder: URL
        public var presets: [ExportPreset]
        public var keep: [Range<Double>]?

        public init(takeFolder: URL, presets: [ExportPreset], keep: [Range<Double>]? = nil) {
            self.takeFolder = takeFolder
            self.presets = presets
            self.keep = keep
        }
    }

    public var version = 1
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Leaves out entries with nothing left to export, keeping the first
    /// entry for each take.
    public var cleaned: PendingExports {
        var seen = Set<URL>()
        return PendingExports(entries: entries.filter { entry in
            guard !entry.presets.isEmpty, !seen.contains(entry.takeFolder.standardizedFileURL) else { return false }
            seen.insert(entry.takeFolder.standardizedFileURL)
            return true
        })
    }

    /// ~/Library/Application Support/Vision One/pending-exports.json
    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("pending-exports.json")
    }

    public static func load(from url: URL = standardURL) -> PendingExports {
        guard let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode(PendingExports.self, from: data) else { return PendingExports() }
        return pending.cleaned
    }

    /// Writes the list, or removes the file when there's nothing left.
    public func save(to url: URL = standardURL) throws {
        let list = cleaned
        if list.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: url, options: .atomic)
    }
}

extension ExportBatch {
    /// Formats not yet done, failed or cancelled, in export order: what a
    /// quit would leave undone.
    public var unfinished: [ExportPreset] {
        guard !isCancelled else { return [] }
        return presets.filter { statuses[$0]?.isFinished == false }
    }
}
