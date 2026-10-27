import Foundation

/// Where your own presets live: one Markdown file each in
/// ~/Library/Application Support/Vision One/Presets. Built-in presets are
/// listed first and never written to disk; saving one makes your copy.
public struct PresetLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static var standard: PresetLibrary {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return PresetLibrary(folder: support
            .appendingPathComponent("Vision One", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true))
    }

    /// Your presets, sorted by name. Unreadable files are skipped.
    public func load(fileManager: FileManager = .default) -> [PromptPreset] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return PromptPreset(markdown: text, fallbackName: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Built-in presets first, then yours. One of yours with the same name
    /// as a built-in replaces it.
    public func all(fileManager: FileManager = .default) -> [PromptPreset] {
        let mine = load(fileManager: fileManager)
        let names = Set(mine.map { $0.name.lowercased() })
        return PromptPreset.builtIn.filter { !names.contains($0.name.lowercased()) } + mine
    }

    /// Writes a preset to its file and returns where it went. Saving a
    /// built-in writes your own copy.
    @discardableResult
    public func save(_ preset: PromptPreset, fileManager: FileManager = .default) throws -> URL {
        var preset = preset
        preset.isBuiltIn = false
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(preset.fileName)
        try preset.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Removes your file for a preset. Built-ins can't be deleted.
    public func delete(_ preset: PromptPreset, fileManager: FileManager = .default) throws {
        let url = folder.appendingPathComponent(preset.fileName)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    /// A name that isn't taken yet: "Mzansi warm copy", "Mzansi warm copy 2".
    public func uniqueName(startingFrom name: String, among presets: [PromptPreset]) -> String {
        let taken = Set(presets.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var candidate = "\(name) copy"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) copy \(n)"
            n += 1
        }
        return candidate
    }
}
