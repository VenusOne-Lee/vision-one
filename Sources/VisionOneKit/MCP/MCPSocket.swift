import Foundation
#if canImport(Darwin)
import Darwin

/// Where the app listens: ~/Library/Application Support/Vision One/mcp.sock.
/// A Unix socket readable only by this Mac user; there is no network port.
public enum MCPSocketPath {
    public static var standard: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vision One", isDirectory: true).appendingPathComponent("mcp.sock").path
    }
}

public enum MCPSocketError: LocalizedError, Equatable {
    case pathTooLong
    case failed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "The folder for Vision One's agent socket has too long a path."
        case let .failed(step, code): return "Couldn't \(step) the agent socket (\(String(cString: strerror(code))))."
        }
    }
}

enum UnixSocket {
    /// A sockaddr_un for `path`, or nil when the path doesn't fit.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A connected socket, or -1.
    static func connect(to path: String) -> Int32 {
        guard var address = address(path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        noSigPipe(fd)
        return fd
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`. False when the other end has gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Splits a byte stream into lines.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            var line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[(newline + 1)...])
            if line.last == 13 { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// Serialises writes to one socket and stops them once it's closed, so a
/// late reply can't land on a reused descriptor.
final class SocketWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var open = true

    init(fd: Int32) { self.fd = fd }

    func send(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        var framed = line
        framed.append(10)
        if !UnixSocket.writeAll(fd, framed) { open = false }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        open = false
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// The app's end: listens on the socket and gives each connected bridge
/// its own `MCPSession`. Messages are one JSON object per line.
public final class MCPSocketServer: @unchecked Sendable {
    public let path: String
    private let makeSession: @Sendable () -> MCPSession
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var writers: [ObjectIdentifier: SocketWriter] = [:]
    private var running = false

    public init(path: String = MCPSocketPath.standard, makeSession: @escaping @Sendable () -> MCPSession) {
        self.path = path
        self.makeSession = makeSession
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A socket file left by a crash would stop bind.
        unlink(path)
        guard var address = UnixSocket.address(path) else { throw MCPSocketError.pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.failed("open", errno) }
        // Only this user can connect, from the moment the file exists.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw MCPSocketError.failed("open", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw MCPSocketError.failed("listen on", code)
        }
        listener = fd
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Vision One MCP"
        thread.start()
    }

    /// Closes the socket and every connection.
    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        // The accept loop notices within half a second and closes it.
        listener = -1
        let open = Array(writers.values)
        writers.removeAll()
        lock.unlock()
        for writer in open { writer.close() }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while isRunning {
            let ready = poll(&poller, 1, 500)
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            UnixSocket.noSigPipe(client)
            let writer = SocketWriter(fd: client)
            lock.lock()
            writers[ObjectIdentifier(writer)] = writer
            lock.unlock()
            let session = makeSession()
            let thread = Thread { [weak self] in self?.serve(client, writer: writer, session: session) }
            thread.name = "Vision One MCP connection"
            thread.start()
        }
        Darwin.close(fd)
    }

    private func serve(_ fd: Int32, writer: SocketWriter, session: MCPSession) {
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Requests still being answered when the agent stops sending.
        let pending = DispatchGroup()
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            for line in lines.append(Data(buffer[0..<count])) {
                pending.enter()
                Task {
                    if let reply = await session.handle(line) { writer.send(reply) }
                    pending.leave()
                }
            }
        }
        // A one-shot `printf … | Vision One --mcp` closes its side right
        // after sending: answer what it asked, then hang up.
        pending.notify(queue: .global()) { [self] in
            lock.lock()
            writers[ObjectIdentifier(writer)] = nil
            lock.unlock()
            writer.close()
        }
    }
}

/// The agent's end, run as `Vision One --mcp`: passes the agent's stdin to
/// the app's socket and the app's replies to stdout. Opens the app first
/// when it isn't running. While it can't reach the app it answers every
/// request with a plain error, so the agent shows why.
public enum MCPBridge {
    /// Returns the exit code.
    /// `openApp` returns false when it didn't open anything (Vision One is
    /// already running with agents turned off), so there's nothing to wait for.
    public static func run(socketPath: String = MCPSocketPath.standard, openApp: () -> Bool,
                           waitSeconds: Double = 8, replyWait: Double = 120) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var fd = UnixSocket.connect(to: socketPath)
        if fd < 0, openApp() {
            let deadline = Date().addingTimeInterval(waitSeconds)
            while fd < 0, Date() < deadline {
                usleep(200_000)
                fd = UnixSocket.connect(to: socketPath)
            }
        }
        guard fd >= 0 else {
            answerOffline()
            return 1
        }
        let app = fd
        let state = BridgeState()

        // App → agent, on its own thread.
        let replies = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(app, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                if !UnixSocket.writeAll(STDOUT_FILENO, Data(buffer[0..<count])) { break }
            }
            // The app hung up: it answered everything after the agent
            // finished sending, or it quit or turned agents off mid-session.
            if state.finish() { exit(0) }
        }
        replies.start()

        // Agent → app, here, until the agent closes stdin.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            if !UnixSocket.writeAll(app, Data(buffer[0..<count])) { break }
        }
        state.inputClosed()
        shutdown(app, SHUT_WR)
        // Let the replies to what was sent reach stdout before exiting.
        _ = state.done.wait(timeout: .now() + replyWait)
        return 0
    }

    private final class BridgeState: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stdinOpen = true

        func inputClosed() {
            lock.lock()
            stdinOpen = false
            lock.unlock()
        }

        /// True when the agent is still sending, so the bridge should exit now.
        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            done.signal()
            return stdinOpen
        }
    }

    static let offlineMessage = "Vision One isn't running, or \"Let coding agents use Vision One\" is off in Settings › Agents. Open Vision One and try again."

    /// Answers requests with an error until stdin closes.
    static func answerOffline() {
        FileHandle.standardError.write(Data((offlineMessage + "\n").utf8))
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            for line in lines.append(Data(buffer[0..<count])) {
                if let reply = offlineReply(to: line) {
                    var framed = reply
                    framed.append(10)
                    UnixSocket.writeAll(STDOUT_FILENO, framed)
                }
            }
        }
    }

    static func offlineReply(to line: Data) -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line),
              message["method"]?.stringValue != nil,
              let id = message["id"], !id.isNull else { return nil }
        return MCPSession.error(id: id, MCPError(code: -32000, message: offlineMessage)).encodedLine()
    }
}
#endif
