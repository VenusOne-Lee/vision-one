import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VisionOneKit

/// Answers like Cloudflare, and remembers what was asked.
private final class FakeCloudflare: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let answer: (URLRequest) -> (Int, String)

    init(answer: @escaping (URLRequest) -> (Int, String)) {
        self.answer = answer
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    var paths: [String] {
        lock.withLock { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }
    }
}

private func ok(_ result: String) -> (Int, String) {
    (200, #"{"success":true,"errors":[],"result":\#(result)}"#)
}

final class CloudflareShareSetupTests: XCTestCase {
    private let schema = """
    -- comment
    CREATE TABLE a (x TEXT);
    CREATE INDEX i ON a (x);
    """

    func testSchemaSplitsIntoStatements() throws {
        XCTAssertEqual(CloudflareShareSetup.statements(in: schema), ["CREATE TABLE a (x TEXT)", "CREATE INDEX i ON a (x)"])
        let shipped = try CloudflareShareSetup.resource("schema", "sql")
        XCTAssertEqual(CloudflareShareSetup.statements(in: shipped).count, 5)
        XCTAssertTrue(try CloudflareShareSetup.resource("worker", "js").contains("export default"))
    }

    func testSetsUpEverythingWithOneToken() async throws {
        let fake = FakeCloudflare { request in
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            switch (method, path) {
            case ("GET", "/client/v4/accounts"): return ok(#"[{"id":"acc123456789","name":"Lee"}]"#)
            case ("POST", "/client/v4/accounts/acc123456789/r2/buckets"):
                return (409, #"{"success":false,"errors":[{"code":10004,"message":"The bucket you tried to create already exists."}]}"#)
            case ("GET", "/client/v4/accounts/acc123456789/d1/database"): return ok("[]")
            case ("POST", "/client/v4/accounts/acc123456789/d1/database"): return ok(#"{"uuid":"db-1","name":"vision-one-share"}"#)
            case ("GET", "/client/v4/accounts/acc123456789/workers/subdomain"): return ok(#"{"subdomain":"lee"}"#)
            default: return ok("{}")
            }
        }
        let setup = try CloudflareShareSetup(token: " tok \n", http: fake, workerSource: "export default {}", schema: schema)
        let account = try await setup.run(creatorKey: "secret-key")

        XCTAssertEqual(account.baseURL.absoluteString, "https://vision-one-share.lee.workers.dev")
        XCTAssertEqual(account.databaseID, "db-1")
        XCTAssertEqual(account.apiURL.absoluteString, "https://vision-one-share.lee.workers.dev/api")
        XCTAssertEqual(account.pageURL(slug: "demo-ab12").absoluteString, "https://vision-one-share.lee.workers.dev/v/demo-ab12/")
        XCTAssertEqual(fake.paths.filter { $0.hasSuffix("/query") }.count, 2)
        XCTAssertTrue(fake.paths.contains("PUT /client/v4/accounts/acc123456789/workers/scripts/vision-one-share"))
        XCTAssertTrue(fake.paths.contains("POST /client/v4/accounts/acc123456789/workers/scripts/vision-one-share/subdomain"))
        XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })

        let upload = try XCTUnwrap(fake.requests.first { $0.httpMethod == "PUT" && $0.url!.path.hasSuffix("/scripts/vision-one-share") })
        let body = String(decoding: upload.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""main_module":"worker.js""#))
        XCTAssertTrue(body.contains(#""bucket_name":"vision-one-share""#))
        XCTAssertTrue(body.contains(#""text":"secret-key""#))
        XCTAssertTrue(body.contains("application/javascript+module"))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
    }

    func testExplainsCloudflareErrors() {
        XCTAssertEqual(CloudflareShareSetup.error(status: 403, body: ["errors": [["code": 10042, "message": "Please enable R2 through the Cloudflare Dashboard."]]]), .r2NotEnabled)
        XCTAssertEqual(CloudflareShareSetup.error(status: 401, body: nil), .badToken)
        XCTAssertEqual(CloudflareShareSetup.error(status: 403, body: ["errors": [["code": 9109, "message": "Unauthorized to access requested resource"]]]),
                       .missingPermission("Unauthorized to access requested resource"))
        XCTAssertEqual(CloudflareShareSetup.error(status: 500, body: nil), .api("HTTP 500"))
    }

    func testCreatorKeysAreLongAndDifferent() {
        let a = CloudflareShareSetup.makeCreatorKey(), b = CloudflareShareSetup.makeCreatorKey()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
    }
}

final class CloudflareShareHostTests: XCTestCase {
    private let account = CloudflareShareAccount(accountID: "acc", baseURL: URL(string: "https://vision-one-share.lee.workers.dev")!,
                                                 databaseID: "db")

    func testPublishesVideoFirstAndThePageLast() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["index.html", "page.json", "video.mp4", "captions.vtt"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let fake = FakeCloudflare { _ in (200, #"{"ok":true}"#) }
        let host = CloudflareShareHost(account: account, creatorKey: "k", http: fake)
        let url = try await host.publish(bundle: folder, slug: "demo-ab12")

        XCTAssertEqual(url.absoluteString, "https://vision-one-share.lee.workers.dev/v/demo-ab12/")
        XCTAssertEqual(fake.paths, [
            "PUT /api/pages/demo-ab12/video.mp4", "PUT /api/pages/demo-ab12/captions.vtt",
            "PUT /api/pages/demo-ab12/page.json", "PUT /api/pages/demo-ab12/index.html",
        ])
        XCTAssertEqual(fake.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testPullsNotesAndEventsOnce() async throws {
        let fake = FakeCloudflare { _ in
            (200, """
            {"notes":[{"id":"n1","name":"Thandi","text":"Per person?","at":6,"quote":"Price","createdAt":"2026-10-27T16:00:34Z","done":false}],
             "events":[{"visit":"abc123","kind":"progress","at":5,"time":"2026-10-27T16:00:33Z"}],
             "after":42,"now":"2026-10-27T16:01:00Z"}
            """)
        }
        let host = CloudflareShareHost(account: account, creatorKey: "k", http: fake)
        var inbox = try await host.pull(slug: "demo-ab12", into: ViewerInbox())
        XCTAssertEqual(inbox.notes.map(\.who), ["Thandi"])
        XCTAssertEqual(inbox.events.count, 1)
        XCTAssertEqual(inbox.eventCursor, 42)
        XCTAssertEqual(inbox.unfiledNotes.map(\.id), ["n1"])
        inbox.markFiled("n1")
        XCTAssertEqual(inbox.unfiledNotes, [])

        inbox = try await host.pull(slug: "demo-ab12", into: inbox)
        XCTAssertEqual(inbox.notes.count, 1, "the same note isn't added twice")
        let query = fake.requests.last?.url?.query ?? ""
        XCTAssertTrue(query.contains("after=42"), query)
        XCTAssertTrue(query.contains("since="), query)
    }

    func testWrongKeyIsReported() async {
        let fake = FakeCloudflare { _ in (401, #"{"error":"no"}"#) }
        let host = CloudflareShareHost(account: account, creatorKey: "k", http: fake)
        do {
            try await host.checkHealth()
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? CloudflareShareError, .badToken)
        }
    }
}
