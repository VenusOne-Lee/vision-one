import AppKit
import Foundation
import Network
import VisionOneKit

/// Sign in with ChatGPT: opens the system browser, waits for OpenAI to send
/// the browser back to http://127.0.0.1:<port>/auth/callback, then trades
/// the code for tokens. The listener only accepts connections from this Mac
/// and stops after one callback or five minutes.
@MainActor
final class ChatGPTSignIn: ObservableObject {
    static let shared = ChatGPTSignIn()

    enum Phase: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?

    func start() {
        stop()
        let session = AIServices.shared.chatGPT
        // 1455 is the port OpenAI's examples use; try a few after it if busy.
        for port in UInt16(1455)...UInt16(1460) {
            guard let listener = makeListener(port: port) else { continue }
            self.listener = listener
            phase = .waiting
            Task {
                let attempt = await session.newAttempt(port: port)
                let url = await session.authorizationURL(for: attempt)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.handle(connection, attempt: attempt) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        Task { @MainActor in self?.fail("Port \(port) is busy. Quit other apps signing in to ChatGPT and try again.") }
                    }
                }
                listener.start(queue: .main)
                NSWorkspace.shared.open(url)
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.fail("Sign-in timed out. Try again.")
            }
            return
        }
        fail("Couldn't open a port for the sign-in callback. Quit other apps signing in to ChatGPT and try again.")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        timeout?.cancel()
        timeout = nil
        if phase == .waiting { phase = .idle }
    }

    private func makeListener(port: UInt16) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        return try? NWListener(using: parameters)
    }

    private func handle(_ connection: NWConnection, attempt: ChatGPTAuth.Attempt) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /auth/callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix(ChatGPTAuth.callbackPath),
                  let url = URL(string: "http://127.0.0.1" + target) else {
                Self.reply(connection, status: "404 Not Found", body: "Not found")
                return
            }
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await AIServices.shared.chatGPT.finish(callback: url, attempt: attempt)
                    Self.reply(connection, status: "200 OK",
                               body: "Signed in. You can close this tab and go back to Vision One.")
                    self.stop()
                    self.phase = .idle
                    await AIServices.shared.refresh()
                    NSApp.activate()
                } catch ChatGPTAuth.AuthError.noPlanAccess {
                    Self.reply(connection, status: "200 OK", body: "Signed in, but plan usage wasn't allowed. Go back to Vision One.")
                    self.fail("Signed in, but ChatGPT didn't allow plan usage. Plan usage needs Go, Plus or Pro, and the box ticked when you approve.")
                } catch {
                    Self.reply(connection, status: "200 OK", body: "Sign-in didn't finish. Go back to Vision One and try again.")
                    self.fail("Sign-in didn't finish: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    nonisolated private static func reply(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Vision One</title><body style=\"font:16px -apple-system;padding:48px;color:#121212;background:#F4F4F1\"><p>\(body)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
