import Foundation

/// A multipart/form-data body, for uploads: ElevenLabs audio and the
/// share page's Cloudflare worker.
public struct MultipartForm: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "vision-one-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func add(name: String, filename: String? = nil, contentType: String, data: Data) {
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
        if let filename { head += "; filename=\"\(filename)\"" }
        head += "\r\nContent-Type: \(contentType)\r\n\r\n"
        body.append(Data(head.utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        add(name: name, filename: fileName, contentType: mimeType, data: data)
    }

    public var finished: Data { body + Data("--\(boundary)--\r\n".utf8) }
    public var data: Data { finished }

    public func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = finished
        return request
    }
}
