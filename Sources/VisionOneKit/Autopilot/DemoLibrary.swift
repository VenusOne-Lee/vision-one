import Foundation

/// A demo file on disk.
public struct DemoFile: Equatable, Sendable, Identifiable {
    public let url: URL
    public var demo: DemoScript

    public init(url: URL, demo: DemoScript) {
        self.url = url
        self.demo = demo
    }

    public var id: URL { url }
}

/// Where demos live: Vision One's own Demos folder, plus any repo folders
/// the person linked (each repo keeps its demos in `.visionone/demos/`).
/// Plain JSON files, so they diff and review like code.
public struct DemoLibrary: Sendable {
    /// `~/Library/Application Support/Vision One/Demos`
    public let folder: URL
    /// Repo roots or demo folders added by the person.
    public var linked: [URL]

    public init(folder: URL, linked: [URL] = []) {
        self.folder = folder
        self.linked = linked
    }

    public static var supportFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vision One", isDirectory: true)
    }

    public static func standard(linked: [URL] = []) -> DemoLibrary {
        DemoLibrary(folder: supportFolder.appendingPathComponent("Demos", isDirectory: true), linked: linked)
    }

    /// The folder demos sit in for a linked path: the path itself when it
    /// already holds demos, else its `.visionone/demos`.
    public static func demosFolder(for linked: URL) -> URL {
        let nested = linked.appendingPathComponent(".visionone/demos", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue { return nested }
        return linked
    }

    public var folders: [URL] { [folder] + linked.map(Self.demosFolder(for:)) }

    /// Every demo that reads, sorted by name. Files that don't read are
    /// skipped (a typo shouldn't hide the rest).
    public func all() -> [DemoFile] {
        var seen = Set<URL>()
        var files: [DemoFile] = []
        for dir in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" && !seen.contains(url.standardizedFileURL) {
                seen.insert(url.standardizedFileURL)
                if let demo = try? DemoScript.load(from: url) { files.append(DemoFile(url: url, demo: demo)) }
            }
        }
        return files.sorted { $0.demo.name.localizedCaseInsensitiveCompare($1.demo.name) == .orderedAscending }
    }

    /// A demo by name or slug, ignoring case.
    public func find(_ name: String) -> DemoFile? {
        let wanted = DemoScript.slug(name)
        return all().first { $0.demo.slug == wanted || $0.url.deletingPathExtension().lastPathComponent == wanted }
    }

    /// Where a new demo is saved: `<slug>.json`, numbered if taken.
    public func newURL(for name: String) -> URL {
        let slug = DemoScript.slug(name)
        var url = folder.appendingPathComponent("\(slug).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(slug)-\(n).json")
            n += 1
        }
        return url
    }
}

/// What Vision One remembers per demo between runs, in
/// `Autopilot/state.json`: the last release it recorded, the take, and
/// which version of the steps the person said may run on its own.
public struct AutopilotState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var lastRelease: String?
        public var lastTakeFolder: URL?
        /// `DemoFingerprint` the person approved for unattended runs.
        /// When the steps or apps change, it asks again.
        public var approvedFingerprint: String?

        public init(lastRelease: String? = nil, lastTakeFolder: URL? = nil, approvedFingerprint: String? = nil) {
            self.lastRelease = lastRelease
            self.lastTakeFolder = lastTakeFolder
            self.approvedFingerprint = approvedFingerprint
        }
    }

    public var demos: [String: Entry]

    public init(demos: [String: Entry] = [:]) {
        self.demos = demos
    }

    public static var standardURL: URL {
        DemoLibrary.supportFolder.appendingPathComponent("Autopilot/state.json")
    }

    public static func load(from url: URL = standardURL) -> AutopilotState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AutopilotState.self, from: data) else { return AutopilotState() }
        return state
    }

    public func write(to url: URL = standardURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public subscript(_ demo: DemoScript) -> Entry {
        get { demos[demo.slug] ?? Entry() }
        set { demos[demo.slug] = newValue }
    }

    /// Whether `demo` may run without the person watching: they said yes
    /// to these exact steps and apps before.
    public func mayRunAlone(_ demo: DemoScript) -> Bool {
        self[demo].approvedFingerprint == DemoFingerprint.of(demo)
    }

    public mutating func approve(_ demo: DemoScript) {
        self[demo].approvedFingerprint = DemoFingerprint.of(demo)
    }

    public mutating func recorded(_ demo: DemoScript, release: String?, take: Take) {
        var entry = self[demo]
        if let release { entry.lastRelease = release }
        entry.lastTakeFolder = take.folder
        self[demo] = entry
    }
}
