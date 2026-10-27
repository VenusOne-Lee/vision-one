import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The creator's own Cloudflare account, set up once to host share
/// pages: an R2 bucket for the files, a D1 database for notes and watch
/// events, and the share Worker (worker.js) on their workers.dev address.
/// Saved (without secrets) as cloudflare-share.json in Application
/// Support; the API token and the creator key live in the Keychain.
public struct CloudflareShareAccount: Codable, Equatable, Sendable {
    public var accountID: String
    /// "https://vision-one-share.lee.workers.dev"
    public var baseURL: URL
    public var bucket: String
    public var databaseID: String
    public var scriptName: String
    public var connectedAt: Date

    public init(accountID: String, baseURL: URL, bucket: String = CloudflareShareSetup.name,
                databaseID: String, scriptName: String = CloudflareShareSetup.name, connectedAt: Date = Date()) {
        self.accountID = accountID
        self.baseURL = baseURL
        self.bucket = bucket
        self.databaseID = databaseID
        self.scriptName = scriptName
        self.connectedAt = connectedAt
    }

    /// Where the pages send reactions, notes and events.
    public var apiURL: URL { baseURL.appendingPathComponent("api") }

    public func pageURL(slug: String) -> URL {
        baseURL.appendingPathComponent("v").appendingPathComponent(slug).appendingPathComponent("")
    }

    /// ~/Library/Application Support/Vision One/cloudflare-share.json
    public static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("cloudflare-share.json")
    }

    public static func load(from url: URL = standardURL) -> CloudflareShareAccount? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CloudflareShareAccount.self, from: data)
    }

    public func save(to url: URL = standardURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sharePage.encode(self).write(to: url, options: .atomic)
    }
}

/// Keychain names for the Cloudflare connection.
public enum CloudflareSecretName {
    /// The API token the creator pasted. Used only to set up and update
    /// the Worker.
    public static let apiToken = "cloudflare-api-token"
    /// The secret the Worker checks before it accepts uploads or hands
    /// out notes. Made by Vision One; never shown.
    public static let creatorKey = "cloudflare-share-key"
}

public enum CloudflareShareError: Error, Equatable, LocalizedError {
    case badToken
    case noAccount
    case r2NotEnabled
    case missingPermission(String)
    case api(String)
    case notReachableYet
    case videoTooLarge(megabytes: Int)

    public var errorDescription: String? {
        switch self {
        case .badToken: return "Cloudflare didn't accept that token. Copy it again from the token page."
        case .noAccount: return "That token can't see a Cloudflare account. Give it access to your account and try again."
        case .r2NotEnabled: return "Turn on R2 in your Cloudflare dashboard first (it's free up to 10 GB, but Cloudflare asks for a card), then try again."
        case .missingPermission(let what): return "The token needs \(what) permission. Make a new token with the Vision One template."
        case .api(let message): return "Cloudflare said: \(message)"
        case .notReachableYet: return "Your share address is new and Cloudflare is still switching it on. Try again in a minute."
        case .videoTooLarge(let mb): return "This video is \(mb) MB and share pages take up to 95 MB. Export 720p for the page."
        }
    }
}

/// Sets up the creator's account with one API token. Safe to run again:
/// what already exists is reused and the Worker is updated.
public struct CloudflareShareSetup: Sendable {
    public static let name = "vision-one-share"
    public static let compatibilityDate = "2025-06-01"
    static let api = URL(string: "https://api.cloudflare.com/client/v4")!

    /// Steps, for the progress list in the Connect sheet.
    public enum Step: String, CaseIterable, Sendable {
        case account, storage, database, worker, address, check

        public var title: String {
            switch self {
            case .account: return "Find your Cloudflare account"
            case .storage: return "Make video storage (R2)"
            case .database: return "Make the notes database (D1)"
            case .worker: return "Put the share page server on your account"
            case .address: return "Switch on your workers.dev address"
            case .check: return "Check it answers"
            }
        }
    }

    let token: String
    let http: HTTPClient
    let workerSource: String
    let schema: String

    public init(token: String, http: HTTPClient = URLSessionHTTPClient(),
                workerSource: String? = nil, schema: String? = nil) throws {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.workerSource = try workerSource ?? Self.resource("worker", "js")
        self.schema = try schema ?? Self.resource("schema", "sql")
    }

    static func resource(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SharePageBundle.BundleError.missingTemplate
        }
        return text
    }

    /// A strong random key for the Worker.
    public static func makeCreatorKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func run(creatorKey: String, progress: @Sendable (Step) -> Void = { _ in }) async throws -> CloudflareShareAccount {
        progress(.account)
        let accountID = try await findAccount()

        progress(.storage)
        try await makeBucket(accountID)

        progress(.database)
        let databaseID = try await findOrMakeDatabase(accountID)
        for statement in Self.statements(in: schema) {
            _ = try await call("POST", "accounts/\(accountID)/d1/database/\(databaseID)/query", json: ["sql": statement])
        }

        progress(.worker)
        try await uploadWorker(accountID, databaseID: databaseID, creatorKey: creatorKey)

        progress(.address)
        let subdomain = try await workersSubdomain(accountID)
        _ = try await call("POST", "accounts/\(accountID)/workers/scripts/\(Self.name)/subdomain",
                           json: ["enabled": true, "previews_enabled": false])

        let base = URL(string: "https://\(Self.name).\(subdomain).workers.dev")!
        // The caller saves this, then runs `.check` with CloudflareShareHost.checkHealth:
        // a brand-new workers.dev address can take a minute to answer.
        return CloudflareShareAccount(accountID: accountID, baseURL: base, databaseID: databaseID)
    }

    func findAccount() async throws -> String {
        let result = try await call("GET", "accounts")
        guard let list = result as? [[String: Any]], let id = list.first?["id"] as? String else {
            throw CloudflareShareError.noAccount
        }
        return id
    }

    func makeBucket(_ accountID: String) async throws {
        do {
            _ = try await call("POST", "accounts/\(accountID)/r2/buckets", json: ["name": Self.name])
        } catch CloudflareShareError.api(let message) where message.localizedCaseInsensitiveContains("already exists") {
            return
        }
    }

    func findOrMakeDatabase(_ accountID: String) async throws -> String {
        let found = try await call("GET", "accounts/\(accountID)/d1/database?name=\(Self.name)")
        if let list = found as? [[String: Any]],
           let match = list.first(where: { ($0["name"] as? String) == Self.name }),
           let id = match["uuid"] as? String {
            return id
        }
        let made = try await call("POST", "accounts/\(accountID)/d1/database", json: ["name": Self.name])
        guard let id = (made as? [String: Any])?["uuid"] as? String else {
            throw CloudflareShareError.api("No database id came back.")
        }
        return id
    }

    func uploadWorker(_ accountID: String, databaseID: String, creatorKey: String) async throws {
        let metadata: [String: Any] = [
            "main_module": "worker.js",
            "compatibility_date": Self.compatibilityDate,
            "bindings": [
                ["type": "r2_bucket", "name": "FILES", "bucket_name": Self.name],
                ["type": "d1", "name": "DB", "id": databaseID],
                ["type": "secret_text", "name": "CREATOR_KEY", "text": creatorKey],
            ],
        ]
        var form = MultipartForm()
        form.add(name: "metadata", contentType: "application/json",
                 data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
        form.add(name: "worker.js", filename: "worker.js", contentType: "application/javascript+module",
                 data: Data(workerSource.utf8))
        var request = URLRequest(url: Self.api.appendingPathComponent("accounts/\(accountID)/workers/scripts/\(Self.name)"))
        request.httpMethod = "PUT"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished
        _ = try await send(request)
    }

    /// The account's workers.dev name, made from the account id if it
    /// has none yet.
    func workersSubdomain(_ accountID: String) async throws -> String {
        if let result = try? await call("GET", "accounts/\(accountID)/workers/subdomain"),
           let name = (result as? [String: Any])?["subdomain"] as? String, !name.isEmpty {
            return name
        }
        let wanted = "vision-one-" + accountID.prefix(8).lowercased()
        let made = try await call("PUT", "accounts/\(accountID)/workers/subdomain", json: ["subdomain": wanted])
        return ((made as? [String: Any])?["subdomain"] as? String) ?? wanted
    }

    /// Statements in schema.sql, one at a time, without comments.
    static func statements(in sql: String) -> [String] {
        sql.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Calls

    func call(_ method: String, _ path: String, json body: [String: Any]? = nil) async throws -> Any? {
        // `path` may carry a query string, so build the URL from text.
        var request = URLRequest(url: URL(string: Self.api.absoluteString + "/" + path)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> Any? {
        var request = request
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(request)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if (200..<300).contains(response.statusCode), (object?["success"] as? Bool) != false {
            return object?["result"]
        }
        throw Self.error(status: response.statusCode, body: object)
    }

    static func error(status: Int, body: [String: Any]?) -> CloudflareShareError {
        let errors = (body?["errors"] as? [[String: Any]]) ?? []
        let codes = errors.compactMap { $0["code"] as? Int }
        let message = errors.compactMap { $0["message"] as? String }.joined(separator: " ")
        if codes.contains(10042) || message.localizedCaseInsensitiveContains("enable r2") { return .r2NotEnabled }
        if status == 401 || codes.contains(1000) || (codes.contains(10000) && message.localizedCaseInsensitiveContains("authentication")) {
            return .badToken
        }
        if status == 403 { return .missingPermission(message.isEmpty ? "more" : message) }
        return .api(message.isEmpty ? "HTTP \(status)" : message)
    }
}

/// Publishing to, and reading back from, a connected account's Worker.
public struct CloudflareShareHost: Sendable {
    public static let maxUploadBytes = 95 * 1024 * 1024

    public let account: CloudflareShareAccount
    let creatorKey: String
    let http: HTTPClient

    public init(account: CloudflareShareAccount, creatorKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.account = account
        self.creatorKey = creatorKey
        self.http = http
    }

    public func checkHealth() async throws {
        var request = URLRequest(url: account.apiURL.appendingPathComponent("health"))
        request.timeoutInterval = 20
        do {
            _ = try await send(request)
        } catch let error as URLError where [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut].contains(error.code) {
            throw CloudflareShareError.notReachableYet
        }
    }

    /// Uploads a bundle folder (from `SharePageBundle.write`) and returns
    /// the page's link. The video goes first and index.html last, so the
    /// page never points at a file that isn't there yet.
    public func publish(bundle folder: URL, slug: String, fileManager: FileManager = .default) async throws -> URL {
        let video = folder.appendingPathComponent("video.mp4")
        let size = (try? fileManager.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        guard size <= Self.maxUploadBytes else {
            throw CloudflareShareError.videoTooLarge(megabytes: Int((Double(size) / 1_048_576).rounded()))
        }
        for name in ["video.mp4", "poster.jpg", "captions.vtt", "page.json", "index.html"] {
            let file = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            var request = URLRequest(url: account.apiURL.appendingPathComponent("pages/\(slug)/\(name)"))
            request.httpMethod = "PUT"
            request.timeoutInterval = name == "video.mp4" ? 600 : 60
            request.httpBody = try Data(contentsOf: file, options: .mappedIfSafe)
            _ = try await send(request)
        }
        return account.pageURL(slug: slug)
    }

    public func takeDown(slug: String) async throws {
        var request = URLRequest(url: account.apiURL.appendingPathComponent("pages/\(slug)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// New notes and events for a page, merged into `inbox`.
    public func pull(slug: String, into inbox: ViewerInbox) async throws -> ViewerInbox {
        var parts = URLComponents(url: account.apiURL.appendingPathComponent("inbox"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "page", value: slug), URLQueryItem(name: "after", value: String(inbox.eventCursor ?? 0))]
        if let since = inbox.pulledAt {
            // A minute back, so a note saved as the last pull ran isn't missed.
            query.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since.addingTimeInterval(-60))))
        }
        parts.queryItems = query
        let data = try await send(URLRequest(url: parts.url!))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = try decoder.decode(InboxPage.self, from: data)
        var inbox = inbox
        inbox.merge(notes: page.notes, events: page.events, at: page.now)
        inbox.eventCursor = page.after
        return inbox
    }

    struct InboxPage: Decodable {
        var notes: [ViewerNote]
        var events: [ViewerEvent]
        var after: Int
        var now: Date
    }

    @discardableResult
    func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(creatorKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw CloudflareShareError.badToken }
            throw CloudflareShareError.api(errorMessage(from: data))
        }
        return data
    }
}

/// multipart/form-data, for the Worker upload.
struct MultipartForm {
    let boundary = "vision-one-" + UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(name: String, filename: String? = nil, contentType: String, data: Data) {
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
        if let filename { head += "; filename=\"\(filename)\"" }
        head += "\r\nContent-Type: \(contentType)\r\n\r\n"
        body.append(Data(head.utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    var finished: Data { body + Data("--\(boundary)--\r\n".utf8) }
}
