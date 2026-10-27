import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A place the Producer reads for what's new: a GitHub repo's releases or
/// a Linear team's finished issues. Saved on the project.
public struct ScriptSourceRef: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case github, linear
    }

    public var kind: Kind
    /// "owner/repo" for GitHub, the team key ("ENG") for Linear.
    public var id: String
    public var enabled: Bool

    public init(_ kind: Kind, _ id: String, enabled: Bool = true) {
        self.kind = kind
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.enabled = enabled
    }

    public var title: String {
        switch kind {
        case .github: return "GitHub · \(id)"
        case .linear: return "Linear · \(id)"
        }
    }
}

/// One thing that happened: a release or a finished issue.
public struct ScriptSourceItem: Codable, Equatable, Sendable {
    public var source: ScriptSourceRef
    public var title: String
    public var body: String
    public var url: String?
    public var date: Date?

    public init(source: ScriptSourceRef, title: String, body: String, url: String? = nil, date: Date? = nil) {
        self.source = source
        self.title = title
        self.body = body
        self.url = url
        self.date = date
    }
}

public enum ScriptSourceError: Error, Equatable, Sendable {
    case needsKey(ScriptSourceRef.Kind)
    case http(ScriptSourceRef.Kind, Int, String)
    case badRepo(String)
}

/// Reads releases and issues. Only names go out (the repo, the team);
/// nothing from a take is sent. Keys live in the Keychain.
public struct ScriptSources: Sendable {
    public static let githubTokenName = "github-token"
    public static let linearKeyName = "linear-api-key"

    let http: any HTTPClient
    let secrets: any AISecretStore

    public init(http: any HTTPClient = URLSessionHTTPClient(), secrets: any AISecretStore) {
        self.http = http
        self.secrets = secrets
    }

    /// Everything new from the enabled sources, newest first. A source
    /// that fails is skipped; its error comes back in `failures`.
    public func fetch(_ refs: [ScriptSourceRef], since: Date? = nil, limit: Int = 10) async
        -> (items: [ScriptSourceItem], failures: [ScriptSourceRef: String]) {
        var items: [ScriptSourceItem] = []
        var failures: [ScriptSourceRef: String] = [:]
        for ref in refs where ref.enabled {
            do {
                switch ref.kind {
                case .github: items += try await releases(ref, limit: limit)
                case .linear: items += try await issues(ref, since: since, limit: limit)
                }
            } catch {
                failures[ref] = Self.describe(error)
            }
        }
        let filtered = since.map { cutoff in items.filter { ($0.date ?? .distantFuture) >= cutoff } } ?? items
        return (filtered.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, failures)
    }

    // MARK: GitHub

    static func releasesRequest(_ ref: ScriptSourceRef, token: String?, limit: Int) throws -> URLRequest {
        let parts = ref.id.split(separator: "/")
        guard parts.count == 2, let url = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases?per_page=\(limit)")
        else { throw ScriptSourceError.badRepo(ref.id) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Vision One", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    struct Release: Decodable {
        var name: String?
        var tag_name: String
        var body: String?
        var html_url: String?
        var published_at: Date?
        var draft: Bool?
    }

    func releases(_ ref: ScriptSourceRef, limit: Int) async throws -> [ScriptSourceItem] {
        let request = try Self.releasesRequest(ref, token: secrets.string(Self.githubTokenName), limit: limit)
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else { throw ScriptSourceError.http(.github, response.statusCode, errorMessage(from: data)) }
        return try Self.parseReleases(data, ref: ref)
    }

    static func parseReleases(_ data: Data, ref: ScriptSourceRef) throws -> [ScriptSourceItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data).filter { $0.draft != true }.map {
            ScriptSourceItem(source: ref, title: ($0.name?.isEmpty == false ? $0.name! : $0.tag_name),
                             body: String(($0.body ?? "").prefix(4000)), url: $0.html_url, date: $0.published_at)
        }
    }

    // MARK: Linear

    static let linearQuery = """
    query($team: String!, $since: DateTimeOrDuration!, $first: Int!) {
      issues(first: $first, orderBy: updatedAt, filter: { team: { key: { eq: $team } }, completedAt: { gt: $since } }) {
        nodes { identifier title description url completedAt }
      }
    }
    """

    static func issuesRequest(_ ref: ScriptSourceRef, key: String, since: Date, limit: Int) throws -> URLRequest {
        try URLRequest.json(URL(string: "https://api.linear.app/graphql")!,
                            body: ["query": linearQuery,
                                   "variables": ["team": ref.id, "since": ISO8601DateFormatter().string(from: since),
                                                 "first": limit]],
                            headers: ["Authorization": key])
    }

    struct LinearReply: Decodable {
        struct Payload: Decodable { var issues: Issues }
        struct Issues: Decodable { var nodes: [Issue] }
        struct Issue: Decodable {
            var identifier: String
            var title: String
            var description: String?
            var url: String?
            var completedAt: Date?
        }
        struct Problem: Decodable { var message: String }
        var data: Payload?
        var errors: [Problem]?
    }

    func issues(_ ref: ScriptSourceRef, since: Date?, limit: Int) async throws -> [ScriptSourceItem] {
        guard let key = secrets.string(Self.linearKeyName), !key.isEmpty else { throw ScriptSourceError.needsKey(.linear) }
        let from = since ?? Date().addingTimeInterval(-14 * 24 * 3600)
        let (data, response) = try await http.send(try Self.issuesRequest(ref, key: key, since: from, limit: limit))
        guard response.statusCode == 200 else { throw ScriptSourceError.http(.linear, response.statusCode, errorMessage(from: data)) }
        return try Self.parseIssues(data, ref: ref)
    }

    static func parseIssues(_ data: Data, ref: ScriptSourceRef) throws -> [ScriptSourceItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter()
            full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = full.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        let reply = try decoder.decode(LinearReply.self, from: data)
        if let problem = reply.errors?.first { throw ScriptSourceError.http(.linear, 200, problem.message) }
        return (reply.data?.issues.nodes ?? []).map {
            ScriptSourceItem(source: ref, title: "\($0.identifier) \($0.title)",
                             body: String(($0.description ?? "").prefix(1500)), url: $0.url, date: $0.completedAt)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ScriptSourceError.needsKey(.linear): return "Add a Linear API key in AI settings."
        case ScriptSourceError.needsKey(.github): return "Add a GitHub token in AI settings."
        case let ScriptSourceError.http(kind, 404, _): return "\(kind == .github ? "GitHub" : "Linear") couldn't find that. Check the name, or add a token for a private repo."
        case let ScriptSourceError.http(_, status, message): return "Said \(status): \(message)"
        case let ScriptSourceError.badRepo(id): return "\"\(id)\" isn't owner/repo."
        default: return error.localizedDescription
        }
    }
}

extension ProducerAgent {
    /// A script to record from: a hook, lines to say in order, and a call
    /// to action. Built from what's new in the project's sources.
    public struct Script: Codable, Equatable, Sendable {
        public var title: String
        public var hook: String
        public var lines: [String]
        public var cta: String

        public var text: String {
            ([hook] + lines + [cta]).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    public func script(from items: [ScriptSourceItem], brief: AgentBrief, ask: String? = nil) async throws -> Script {
        let input = items.map { item in
            "## \(item.title)\n\(item.body)"
        }.joined(separator: "\n\n")
        var lead = "You write a short script for a builder to read while screen recording what's new. Use only what the notes say. A hook, four to eight short spoken lines in the order to show them, and a call to action. Plain South African English, no hype."
        if let ask, !ask.isEmpty { lead += " They asked: \(ask)" }
        let request = AIRequest(
            task: .producerScript, summary: "Write a script from \(items.count) releases and issues",
            instructions: brief.instructions(lead, parts: ["hook", "body", "outro"]),
            input: input.isEmpty ? (ask ?? "") : input,
            format: .json(shape: #"{"title": "...", "hook": "...", "lines": ["...", "..."], "cta": "..."}"#))
        return try await ladder.complete(request).decode(Script.self)
    }
}

extension AITask {
    public static let producerScript = AITask("producer.script")
}
