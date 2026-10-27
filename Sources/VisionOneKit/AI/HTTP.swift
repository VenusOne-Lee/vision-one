import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. Providers take this so tests can answer for
/// the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension URLRequest {
    static func json(_ url: URL, body: Any, headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// Server-sent events, read from a whole response body.
public enum ServerSentEvents {
    public struct Event: Equatable, Sendable {
        public var name: String?
        public var data: String
    }

    public static func parse(_ text: String) -> [Event] {
        var events: [Event] = []
        var name: String?
        var data: [String] = []
        func flush() {
            if !data.isEmpty { events.append(Event(name: name, data: data.joined(separator: "\n"))) }
            name = nil
            data = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                data.append(value)
            }
        }
        flush()
        return events
    }
}

/// Error text from a JSON error body ({"error": {"message": ...}}), or the
/// body itself.
func errorMessage(from data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["message"] as? String { return message }
    }
    return String(decoding: data.prefix(300), as: UTF8.self)
}
