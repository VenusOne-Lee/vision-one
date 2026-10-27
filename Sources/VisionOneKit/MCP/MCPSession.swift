import Foundation

/// The agent on the other end: Claude Code, Codex, Cursor. Named from the
/// clientInfo it sends when it connects.
public struct MCPClient: Equatable, Hashable, Sendable {
    /// What the client calls itself ("claude-code").
    public var id: String
    /// What the user sees ("Claude Code").
    public var displayName: String
    public var version: String?

    public init(name: String?, title: String? = nil, version: String? = nil) {
        let raw = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        id = raw.isEmpty ? "agent" : raw
        let titled = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = titled.isEmpty ? Self.friendlyName(raw) : titled
        self.version = version
    }

    /// Before an agent says who it is.
    public static let unknown = MCPClient(name: nil)

    /// "claude-code" → "Claude Code", "codex-mcp-client" → "Codex".
    public static func friendlyName(_ raw: String) -> String {
        let name = raw.lowercased()
        if name.isEmpty { return "An agent" }
        if name.contains("claude-code") || name == "claude code" { return "Claude Code" }
        if name.hasPrefix("codex") { return "Codex" }
        if name.contains("cursor") { return "Cursor" }
        if name.contains("claude") { return "Claude" }
        if name.contains("vscode") || name.contains("copilot") { return "VS Code" }
        if name.contains("zed") { return "Zed" }
        if name.contains("windsurf") { return "Windsurf" }
        return raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A tool as `tools/list` shows it. The hints tell clients what a tool
/// does; the server checks every call itself and doesn't rely on them.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    /// Reaches past the Mac (a post).
    public var openWorld: Bool

    public init(_ name: String, title: String, description: String, input: JSONValue = .object([:]),
                required: [String] = [], readOnly: Bool = false, destructive: Bool = false,
                idempotent: Bool = false, openWorld: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        var schema: [String: JSONValue] = ["type": "object", "properties": input]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        schema["additionalProperties"] = false
        inputSchema = .object(schema)
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }

    public var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": .bool(openWorld),
            ],
        ]
    }
}

/// What a tool call hands back. `text` is what the model reads first;
/// `data` follows it as JSON and also goes out as structured content.
public struct MCPToolResult: Equatable, Sendable {
    public var text: String
    public var data: JSONValue?
    public var isError: Bool

    public init(text: String, data: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.data = data
        self.isError = isError
    }

    public static func done(_ text: String, _ data: JSONValue? = nil) -> MCPToolResult {
        MCPToolResult(text: text, data: data)
    }

    /// A failure the model can read and act on, not a protocol error.
    public static func failed(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }

    public var json: JSONValue {
        var shown = text
        if let data { shown += "\n\n" + data.pretty() }
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(shown)]],
            "isError": .bool(isError),
        ]
        if let data, case .object = data { result["structuredContent"] = data }
        return .object(result)
    }
}

/// A JSON-RPC error.
public struct MCPError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func invalidParams(_ message: String) -> MCPError { MCPError(code: -32602, message: message) }
    public static func notFound(_ message: String) -> MCPError { MCPError(code: -32002, message: message) }
    public static func unknownMethod(_ method: String) -> MCPError {
        MCPError(code: -32601, message: "Vision One doesn't handle \(method).")
    }
}

/// One connected agent. Reads JSON-RPC messages (one per line) and
/// answers them. Calls may overlap: a long tool call doesn't hold up a
/// ping or a list, because the actor lets other messages in while a tool
/// waits.
public actor MCPSession {
    /// Newest first. A client asking for one of these gets it back;
    /// anything else gets the newest.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let server: VisionOneMCP
    public private(set) var client: MCPClient = .unknown
    public private(set) var protocolVersion: String?

    public init(server: VisionOneMCP) {
        self.server = server
    }

    /// The reply to one line, or nil when there's nothing to send (a
    /// notification).
    public func handle(_ line: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            return Self.error(id: .null, MCPError(code: -32700, message: "That wasn't valid JSON.")).encodedLine()
        }
        if case let .array(batch) = message {
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await reply(to: item) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : JSONValue.array(replies).encodedLine()
        }
        return await reply(to: message)?.encodedLine()
    }

    func reply(to message: JSONValue) async -> JSONValue? {
        guard case .object = message else {
            return Self.error(id: .null, MCPError(code: -32600, message: "Expected a JSON-RPC message."))
        }
        // A reply to a request of ours. The server doesn't send any.
        guard let method = message["method"]?.stringValue else { return nil }
        let params = message["params"] ?? .object([:])
        guard let id = message["id"], !id.isNull else {
            return nil // notifications/initialized, notifications/cancelled
        }
        do {
            return Self.result(id: id, try await call(method, params))
        } catch let error as MCPError {
            return Self.error(id: id, error)
        } catch {
            return Self.error(id: id, MCPError(code: -32603, message: error.localizedDescription))
        }
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            protocolVersion = version
            let info = params["clientInfo"]
            client = MCPClient(name: info?["name"]?.stringValue, title: info?["title"]?.stringValue,
                               version: info?["version"]?.stringValue)
            await server.host.connected(client)
            return [
                "protocolVersion": .string(version),
                "capabilities": Self.capabilities,
                "serverInfo": server.info,
                "instructions": .string(VisionOneMCP.instructions),
            ]
        case "server/discover":
            // Newer clients probe with this. Listing only versions that
            // start with initialize makes them fall back to it.
            return [
                "supportedVersions": .array(Self.protocolVersions.map { .string($0) }),
                "capabilities": Self.capabilities,
                "serverInfo": server.info,
                "instructions": .string(VisionOneMCP.instructions),
            ]
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(VisionOneMCP.tools.map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                throw MCPError.invalidParams("Say which tool to call.")
            }
            guard VisionOneMCP.tools.contains(where: { $0.name == name }) else {
                throw MCPError.invalidParams("Vision One has no tool called \(name).")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            return await server.call(name, arguments: arguments, client: client).json
        case "resources/list":
            return ["resources": .array(await server.resources().map(\.json))]
        case "resources/templates/list":
            return ["resourceTemplates": .array(VisionOneMCP.resourceTemplates.map(\.json))]
        case "resources/read":
            guard let uri = params["uri"]?.stringValue else {
                throw MCPError.invalidParams("Say which resource to read.")
            }
            return ["contents": [try await server.read(uri).json]]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw MCPError.unknownMethod(method)
        }
    }

    static let capabilities: JSONValue = [
        "tools": ["listChanged": false],
        "resources": ["subscribe": false, "listChanged": false],
    ]

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, _ error: MCPError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
    }
}
