import AppKit
import ImageIO
import Network
import VisionOneKit
import WebKit

/// Native WebKit checks using only an ephemeral loopback server and local
/// fixture cards. The control uses the same file-origin subresource request
/// as production, so zero blocked requests cannot pass on an unreachable server.
@MainActor
enum CardVerification {
    static func run(in root: URL) async throws {
        _ = try await CardRenderer.offlineRules()
        let folder = root.appendingPathComponent("card-safety")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = CardLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let card = folder.appendingPathComponent("network.html")
        let html = """
        <html><head><style>html,body{margin:0;width:100%;height:100%;background:#ffff00}
        #mark{width:40%;height:100%;background:#0000ff}img{position:absolute;opacity:0}</style></head>
        <body><div id="mark"></div><img src="http://127.0.0.1:\(port)/probe.svg"></body></html>
        """
        try Data(html.utf8).write(to: card)
        try await CardControlLoad().load(card, readAccess: folder)
        let baseline = server.connectionCount
        try MediaVerification.require(baseline > 0, "Unprotected file-origin WebKit control did not reach loopback")
        _ = try await CardRenderer().render(card: card, readAccess: folder, variables: CardVariables(brand: BrandKit()),
                                             size: CGSize(width: 240, height: 160), frameRate: 1, duration: 1)
        try await Task.sleep(for: .milliseconds(200))
        try MediaVerification.require(server.connectionCount == baseline, "Offline card reached the loopback server")

        let fade = folder.appendingPathComponent("fade.html")
        try Data("""
        <html><head><style>html,body{margin:0;width:100%;height:100%;background:#ffff00}
        #mark{width:40%;height:100%;background:#0000ff;animation:fade .5s linear forwards}
        @keyframes fade{from{opacity:1}to{opacity:0}}</style></head><body><div id="mark"></div></body></html>
        """.utf8).write(to: fade)
        let rendered = try await CardRenderer().render(card: fade, readAccess: folder,
            variables: CardVariables(brand: BrandKit()), size: CGSize(width: 240, height: 160),
            frameRate: 4, duration: 1)
        guard let firstIndex = rendered.order.first, let lastIndex = rendered.order.last else {
            throw MediaVerification.Failure(message: "Animated card produced no frames")
        }
        let first = rendered.frames[firstIndex], last = rendered.frames[lastIndex]
        try first.write(to: folder.appendingPathComponent("painted-first.png"))
        try last.write(to: folder.appendingPathComponent("flat-last.png"))
        var firstPaint = CardPaintEvidence()
        firstPaint.observe(try pixels(first))
        var lastPaint = CardPaintEvidence()
        lastPaint.observe(try pixels(last))
        try MediaVerification.require(firstPaint.hasPaint, "Animated card's first frame did not paint")
        try MediaVerification.require(!lastPaint.hasPaint, "Animated card did not end on a flat frame")
        let report: [String: Any] = ["compiledOfflineRules": true, "unprotectedConnections": baseline,
                                    "protectedConnections": server.connectionCount - baseline,
                                    "paintedFirstFrame": true, "flatFinalFrameRetained": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("card-safety.json"))
        print("Native card offline enforcement and painted-to-flat checks passed")
    }

    private static func pixels(_ png: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaVerification.Failure(message: "Could not decode card verification frame")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw MediaVerification.Failure(message: "Card pixels missing") }
        return Data(bytes: data, count: context.bytesPerRow * image.height)
    }
}

private final class CardLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VisionOne.CardLoopbackVerification")
    private let lock = NSLock()
    private var accepted = 0
    private var listener: NWListener?
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return accepted }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var pending: CheckedContinuation<UInt16, Error>? = continuation
            listener.stateUpdateHandler = { state in
                guard let current = pending else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    pending = nil
                    current.resume(returning: port.rawValue)
                case let .failed(error):
                    pending = nil
                    current.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.accepted += 1; self.lock.unlock()
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    let body = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'><rect width='1' height='1' fill='red'/></svg>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard let current = pending else { return }
                pending = nil
                current.resume(throwing: MediaVerification.Failure(message: "Loopback listener timed out"))
            }
        }
    }

    func stop() { listener?.cancel() }
}

@MainActor
private final class CardControlLoad: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?

    func load(_ card: URL, readAccess: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 160), configuration: configuration)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = web
        window.orderBack(nil)
        defer { web.navigationDelegate = nil; window.orderOut(nil); window.contentView = nil; window.close() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            web.loadFileURL(card, allowingReadAccessTo: readAccess)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finish(.failure(MediaVerification.Failure(message: "Unprotected WebKit control timed out")))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(with: result)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(.success(())) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
}
