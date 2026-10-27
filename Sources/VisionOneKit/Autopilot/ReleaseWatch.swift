import Foundation

/// A GitHub release, reduced to what Autopilot needs. Decodes the
/// `GET /repos/{owner}/{repo}/releases/latest` reply.
public struct GitHubRelease: Codable, Equatable, Sendable {
    public var tagName: String
    public var name: String?
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: Date?
    public var htmlURL: URL?

    public init(tagName: String, name: String? = nil, draft: Bool = false, prerelease: Bool = false,
                publishedAt: Date? = nil, htmlURL: URL? = nil) {
        self.tagName = tagName
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, draft, prerelease, publishedAt = "published_at", htmlURL = "html_url"
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// The API address for a repo's latest release, or nil when `repo`
    /// isn't "owner/name".
    public static func latestURL(for repo: String) -> URL? {
        let parts = repo.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
    }
}

/// One demo to record again, and why.
public struct RerecordPlan: Equatable, Sendable {
    public var demo: DemoFile
    public var release: String
    /// The person hasn't approved these steps for running alone, so the
    /// run waits in Needs you instead of starting.
    public var needsApproval: Bool
    /// Last take's voice can be lined up with the new clicks.
    public var reuseVoice: Bool

    public init(demo: DemoFile, release: String, needsApproval: Bool, reuseVoice: Bool) {
        self.demo = demo
        self.release = release
        self.needsApproval = needsApproval
        self.reuseVoice = reuseVoice
    }
}

/// Decides which demos to re-record when releases come in.
public enum ReleaseWatch {
    /// How often to check while Vision One is open.
    public static let interval: TimeInterval = 3600

    /// The repos worth asking GitHub about: those with a demo that
    /// re-records on release.
    public static func repos(in demos: [DemoFile]) -> [String] {
        var repos: [String] = []
        for file in demos where file.demo.rerecordOnRelease {
            if let repo = file.demo.repo, GitHubRelease.latestURL(for: repo) != nil, !repos.contains(repo) {
                repos.append(repo)
            }
        }
        return repos
    }

    /// Marks the current release as the starting point for demos that
    /// have none yet, so only the *next* release re-records them.
    public static func baseline(_ demos: [DemoFile], latest: [String: GitHubRelease],
                                state: AutopilotState) -> AutopilotState {
        var state = state
        for file in demos {
            guard let repo = file.demo.repo, let release = latest[repo], !release.draft, !release.prerelease,
                  state[file.demo].lastRelease == nil else { continue }
            state[file.demo].lastRelease = release.tagName
        }
        return state
    }

    /// Demos due a new take: their repo has a published, non-draft,
    /// non-prerelease release they weren't recorded for. A demo never
    /// recorded before isn't due (the first take is the person's call).
    public static func due(_ demos: [DemoFile], latest: [String: GitHubRelease], state: AutopilotState,
                           lastRuns: [String: AutopilotRun] = [:]) -> [RerecordPlan] {
        demos.compactMap { file in
            let demo = file.demo
            guard demo.rerecordOnRelease, let repo = demo.repo, let release = latest[repo],
                  !release.draft, !release.prerelease else { return nil }
            let entry = state[demo]
            guard let last = entry.lastRelease, last != release.tagName else { return nil }
            let reuse = lastRuns[demo.slug]?.voiceFits(demo) ?? false
            return RerecordPlan(demo: file, release: release.tagName,
                                needsApproval: !state.mayRunAlone(demo), reuseVoice: reuse)
        }
    }
}

/// A request to re-record, from a link (`visionone://demo/rerecord?…`),
/// the GitHub Action, or the MCP server.
public struct RerecordRequest: Equatable, Sendable {
    public var name: String
    public var release: String?
    /// Set by the GitHub Action, so it can follow the run's status file.
    public var id: UUID
    public var requestedBy: String?

    public init(name: String, release: String? = nil, id: UUID = UUID(), requestedBy: String? = nil) {
        self.name = name
        self.release = release
        self.id = id
        self.requestedBy = requestedBy
    }

    /// `visionone://demo/rerecord?name=Checkout%20demo&release=v1.4.0&request=<uuid>&from=GitHub`
    public init?(url: URL) {
        guard url.scheme == "visionone", url.host == "demo", url.path == "/rerecord",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let name = items.first(where: { $0.name == "name" })?.value, !name.isEmpty else { return nil }
        self.name = name
        release = items.first { $0.name == "release" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        id = items.first { $0.name == "request" }?.value.flatMap(UUID.init(uuidString:)) ?? UUID()
        requestedBy = items.first { $0.name == "from" }?.value
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "visionone"
        c.host = "demo"
        c.path = "/rerecord"
        var items = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "request", value: id.uuidString)]
        if let release { items.append(URLQueryItem(name: "release", value: release)) }
        if let requestedBy { items.append(URLQueryItem(name: "from", value: requestedBy)) }
        c.queryItems = items
        return c.url!
    }
}

/// Where a request stands, written to `Autopilot/requests/<id>.json` so a
/// script (the GitHub Action) can wait for it.
public struct RerecordStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Waiting for the person to say yes in Vision One.
        case waiting
        case running
        /// Every step recorded; the take waits in Needs you.
        case recorded
        /// A step failed or it was stopped; see `receipt`.
        case stopped
        /// No demo by that name.
        case unknownDemo
    }

    public var id: UUID
    public var demo: String
    public var release: String?
    public var state: State
    public var receipt: String?
    public var takeFolder: String?
    public var updatedAt: Date

    public init(id: UUID, demo: String, release: String?, state: State, receipt: String? = nil,
                takeFolder: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.demo = demo
        self.release = release
        self.state = state
        self.receipt = receipt
        self.takeFolder = takeFolder
        self.updatedAt = updatedAt
    }

    public var isFinal: Bool { state == .recorded || state == .stopped || state == .unknownDemo }

    public static func url(for id: UUID, in support: URL = DemoLibrary.supportFolder) -> URL {
        support.appendingPathComponent("Autopilot/requests/\(id.uuidString).json")
    }

    public func write(in support: URL = DemoLibrary.supportFolder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = Self.url(for: id, in: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(_ id: UUID, in support: URL = DemoLibrary.supportFolder) -> RerecordStatus? {
        guard let data = try? Data(contentsOf: url(for: id, in: support)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RerecordStatus.self, from: data)
    }
}
