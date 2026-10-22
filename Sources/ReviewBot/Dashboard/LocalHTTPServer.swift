import Foundation
#if os(Windows)
import WinSDK
#else
import Darwin
#endif

/// One parsed HTTP request, as much of it as the dashboard needs.
struct HTTPRequest {
    var method: String
    /// The path without its query string, e.g. `/api/state`.
    var path: String
    var query: [String: String]
    /// Header names lower-cased, so lookups do not depend on how the client spelled them.
    var headers: [String: String]
    var body: Data

    /// The path split on `/`, empty segments dropped: `/api/keys/Claude` → `["api", "keys", "Claude"]`.
    var pathSegments: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func html(_ markup: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(markup.utf8)
        )
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func empty(_ status: Int = 204) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: Data())
    }

    private static let reasons: [Int: String] = [
        200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
        403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        413: "Payload Too Large", 500: "Internal Server Error",
    ]

    /// The bytes that go on the wire. Every response closes the connection: the dashboard
    /// polls with short independent requests, and one-request-per-connection keeps the server
    /// free of keep-alive bookkeeping.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        // Nothing the dashboard serves may be framed by another site, and the API answers only
        // its own page — there is no CORS header, so a cross-origin script cannot read it.
        all["X-Frame-Options"] = "DENY"
        all["X-Content-Type-Options"] = "nosniff"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Parses the request head and body, independent of any socket so it can be unit-tested on the
/// bytes alone.
enum HTTPRequestParser {
    /// Largest request accepted, head and body together. The biggest thing the dashboard sends
    /// is a configuration with a custom prompt; a megabyte is far beyond it.
    static let maximumSize = 1_048_576

    enum Outcome {
        /// More bytes are needed before the request is complete.
        case incomplete
        case complete(HTTPRequest)
        case invalid(String)
    }

    static func parse(_ data: Data) -> Outcome {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumSize ? .invalid("request head too large") : .incomplete
        }
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return .invalid("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid("malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= maximumSize else {
            return .invalid("body too large")
        }
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + contentLength)]

        let target = String(requestLine[1])
        let path: String
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            for pair in target[target.index(after: questionMark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                query[key] = value
            }
        } else {
            path = target
        }

        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: Data(body)
        ))
    }
}

/// A loopback-only HTTP server: the transport under the Windows dashboard.
///
/// Sockets rather than a framework because no HTTP server library targets both macOS and
/// Windows from one Swift package, and the need is small — a handful of JSON routes and one
/// page, on 127.0.0.1, for a single user. The socket calls are the one place the shared core
/// touches an OS API directly; they are confined to this file behind `#if os(Windows)`.
///
/// Binding is to the loopback address only and to an ephemeral port, so nothing on the network
/// can reach it and two instances never collide. That the *page* is reachable by anything on
/// this machine is fine; the API behind it is not, and `DashboardAPI` gates it with a per-launch
/// bearer token that only the tray hands out.
final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let handler: Handler
    private var listener: SocketHandle = invalidSocket
    private var acceptThread: Thread?
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Binds, listens, and starts accepting on a background thread. Returns the port.
    @discardableResult
    func start() throws -> UInt16 {
        try Self.initializeNetworking()

        let socket = Self.openSocket()
        guard socket != invalidSocket else { throw ServerError.socket("socket()") }

        var address = sockaddr_in()
        #if os(Windows)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        #else
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        #endif
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(socket, generic, SocketLength(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            closeSocket(socket)
            throw ServerError.socket("bind()")
        }
        guard listen(socket, 16) == 0 else {
            closeSocket(socket)
            throw ServerError.socket("listen()")
        }

        var boundAddress = sockaddr_in()
        var length = SocketLength(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(socket, generic, &length)
            }
        }
        guard named == 0 else {
            closeSocket(socket)
            throw ServerError.socket("getsockname()")
        }

        listener = socket
        port = UInt16(bigEndian: boundAddress.sin_port)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "review-bot-dashboard"
        acceptThread = thread
        thread.start()
        return port
    }

    func stop() {
        guard listener != invalidSocket else { return }
        closeSocket(listener)
        listener = invalidSocket
    }

    deinit { stop() }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection != invalidSocket else { return }
            let thread = Thread { [handler] in
                Self.serve(connection, handler: handler)
            }
            thread.start()
        }
    }

    /// One connection, start to finish, on its own thread: the blocking read and write stay off
    /// the cooperative pool, and the handler — which may hop to the main actor — runs as a task
    /// the thread waits on.
    private static func serve(_ connection: SocketHandle, handler: @escaping Handler) {
        defer { closeSocket(connection) }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var request: HTTPRequest?
        while request == nil {
            let count = receive(connection, into: &buffer)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
            switch HTTPRequestParser.parse(received) {
            case .incomplete:
                continue
            case let .complete(parsed):
                request = parsed
            case let .invalid(reason):
                write(HTTPResponse.error(400, reason).serialized(), to: connection)
                return
            }
        }
        guard let request else { return }

        let finished = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.response = await handler(request)
            finished.signal()
        }
        finished.wait()
        write((box.response ?? .error(500, "no response")).serialized(), to: connection)
    }

    private final class ResponseBox: @unchecked Sendable {
        var response: HTTPResponse?
    }

    private static func write(_ data: Data, to connection: SocketHandle) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = transmit(connection, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    enum ServerError: LocalizedError {
        case socket(String)

        var errorDescription: String? {
            switch self {
            case let .socket(call): "The dashboard server could not start: \(call) failed."
            }
        }
    }

    // MARK: - Platform socket calls

    #if os(Windows)
    private typealias SocketHandle = SOCKET
    private typealias SocketLength = Int32
    private static let invalidSocket: SocketHandle = INVALID_SOCKET

    private static func initializeNetworking() throws {
        var data = WSADATA()
        // Version 2.2. WSAStartup is reference-counted, so calling it once per server is fine.
        guard WSAStartup(0x0202, &data) == 0 else { throw ServerError.socket("WSAStartup()") }
    }

    private static func openSocket() -> SocketHandle {
        WinSDK.socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
    }

    private static func closeSocket(_ socket: SocketHandle) {
        _ = closesocket(socket)
    }

    private static func receive(_ socket: SocketHandle, into buffer: inout [UInt8]) -> Int {
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) {
                recv(socket, $0, Int32(pointer.count), 0)
            }
        }
        return Int(count)
    }

    private static func transmit(_ socket: SocketHandle, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        Int(send(socket, bytes.assumingMemoryBound(to: CChar.self), Int32(count), 0))
    }
    #else
    private typealias SocketHandle = Int32
    private typealias SocketLength = socklen_t
    private static let invalidSocket: SocketHandle = -1

    private static func initializeNetworking() throws {}

    private static func openSocket() -> SocketHandle {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { return invalidSocket }
        // A client that goes away mid-response must not take the server down with SIGPIPE.
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return socket
    }

    private static func closeSocket(_ socket: SocketHandle) {
        _ = close(socket)
    }

    private static func receive(_ socket: SocketHandle, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
    }

    private static func transmit(_ socket: SocketHandle, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        send(socket, bytes, count, 0)
    }
    #endif

    // Instance-level aliases so the accept loop and `stop` read naturally.
    private var invalidSocket: SocketHandle { Self.invalidSocket }
    private func closeSocket(_ socket: SocketHandle) { Self.closeSocket(socket) }
}
