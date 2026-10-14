import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data
    /// Large bodies (plug-in uploads) are spooled to this temp file instead of memory.
    public var bodyFile: URL?
    public var remoteIP: String

    public var cookies: [String: String] {
        var out: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data(), bodyFile: URL? = nil, remoteIP: String = "127.0.0.1") {
        self.method = method; self.path = path; self.query = query; self.headers = headers
        self.body = body; self.bodyFile = bodyFile; self.remoteIP = remoteIP
    }

    public var isLoopback: Bool { remoteIP == "127.0.0.1" || remoteIP == "::1" }
    public func json() -> [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
}

public struct HTTPResponse: Error {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let d = (try? JSONSerialization.data(withJSONObject: clean(obj), options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: d)
    }

    /// Turn Swift optionals (`nil` boxed in `Any`) into JSON null, recursively.
    static func clean(_ v: Any) -> Any {
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional { return m.children.first.map { clean($0.value) } ?? NSNull() }
        if let d = v as? [String: Any] { return d.mapValues { clean($0) } }
        if let a = v as? [Any] { return a.map { clean($0) } }
        return v
    }
    public static func text(_ s: String, type: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
    }
    public static func error(_ message: String, status: Int = 400) -> HTTPResponse { json(["error": message], status: status) }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 204: return "No Content"; case 302: return "Found"; case 400: return "Bad Request"
        case 401: return "Unauthorized"; case 403: return "Forbidden"; case 404: return "Not Found"; case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"; case 413: return "Payload Too Large"; case 421: return "Misdirected Request"; case 429: return "Too Many Requests"; case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"; default: return "OK"
        }
    }
}

/// A deliberately small HTTP/1.1 server: one request per connection, thread per connection, bodies by Content-Length.
/// Enough for an admin panel; not a general web server.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    public let port: Int
    public let bind: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private var active = 0
    private var running = false
    private let maxConnections = 48
    /// Most simultaneous connections from one address (the panel is used by one person).
    public var maxConnectionsPerIP = 8
    private var perIP: [String: Int] = [:]
    /// Seconds a client gets to send a complete request head (slow-loris defence) / a non-upload body.
    public var headTimeout: TimeInterval = 10
    public var bodyTimeout: TimeInterval = 30
    /// Largest body held in memory.
    public var maxMemoryBody = 4 * 1024 * 1024
    /// Largest body accepted for paths in `uploadPaths` (spooled to disk).
    public var maxUploadBody = 600 * 1024 * 1024
    public var uploadPaths: Set<String> = []
    public var tempDirectory = FileManager.default.temporaryDirectory

    public init(bind: String, port: Int, handler: @escaping Handler) {
        self.bind = bind; self.port = port; self.handler = handler
    }

    public enum StartError: Error, Equatable { case inUse(Int), failed(String) }

    /// The port actually bound (useful with port 0 in tests).
    public private(set) var boundPort = 0

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, SockType.stream, 0)
        guard fd >= 0 else { throw StartError.failed("Couldn't create a network socket.") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, bind, &addr.sin_addr) == 1 else { close(fd); throw StartError.failed("\"\(bind)\" isn't a valid address.") }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin_or_Glibc_bind(fd, $0) } }
        if rc != 0 {
            let e = errno
            close(fd)
            throw e == EADDRINUSE ? StartError.inUse(port) : StartError.failed("Couldn't open port \(port): \(String(cString: strerror(e))).")
        }
        guard listen(fd, 64) == 0 else { close(fd); throw StartError.failed("Couldn't listen on port \(port).") }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        boundPort = Int(UInt16(bigEndian: bound.sin_port))
        listenFD = fd
        running = true
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "novaswift.http.accept"
        t.stackSize = 1 << 20
        acceptThread = t
        t.start()
    }

    private func Darwin_or_Glibc_bind(_ fd: Int32, _ p: UnsafePointer<sockaddr>) -> Int32 {
        bind_(fd, p, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        if listenFD >= 0 { shutdown(listenFD, Int32(SHUT_RDWR)); close(listenFD); listenFD = -1 }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
            lock.lock(); let go = running; lock.unlock()
            if !go { if c >= 0 { close(c) }; return }
            if c < 0 { if errno == EINTR { continue }; return }
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = peer.sin_addr
            inet_ntop(AF_INET, &a, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipbuf)
            lock.lock()
            if active >= maxConnections || (perIP[ip] ?? 0) >= maxConnectionsPerIP {
                lock.unlock(); Self.write(c, HTTPResponse.error("Too many connections.", status: 503)); close(c); continue
            }
            active += 1; perIP[ip, default: 0] += 1; lock.unlock()
            // Default QoS on purpose: asking for an elevated QoS makes libdispatch try to raise thread priority, which an
            // unprivileged service (systemd, containers) is refused with a "Failed to set thread priority" log line.
            DispatchQueue.global().async { [weak self] in
                self?.serve(c, ip: ip)
                self?.lock.lock(); self?.active -= 1
                if let n = self?.perIP[ip], n > 1 { self?.perIP[ip] = n - 1 } else { self?.perIP[ip] = nil }
                self?.lock.unlock()
            }
        }
    }

    private func serve(_ fd: Int32, ip: String) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        switch readRequest(fd, ip: ip) {
        case .failure(let r): Self.write(fd, r)
        case .success(let req):
            var resp = handler(req)
            if let f = req.bodyFile { try? FileManager.default.removeItem(at: f) }
            resp.headers["Cache-Control"] = resp.headers["Cache-Control"] ?? "no-store"
            resp.headers["X-Content-Type-Options"] = "nosniff"
            resp.headers["X-Frame-Options"] = "DENY"
            resp.headers["Referrer-Policy"] = "no-referrer"
            Self.write(fd, resp)
        }
    }

    private func readRequest(_ fd: Int32, ip: String) -> Result<HTTPRequest, HTTPResponse> {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        let started = Date()
        while headerEnd == nil {
            if Date().timeIntervalSince(started) > headTimeout { return .failure(HTTPResponse.error("Request timed out.", status: 408)) }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return .failure(HTTPResponse.error("Empty request.")) }
            buf.append(chunk, count: n)
            headerEnd = buf.range(of: sep)
            if buf.count > 65536 && headerEnd == nil { return .failure(HTTPResponse.error("Request headers too large.", status: 413)) }
        }
        let headData = buf[buf.startIndex..<headerEnd!.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return .failure(HTTPResponse.error("Bad request.")) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .failure(HTTPResponse.error("Bad request line.")) }
        var headers: [String: String] = [:]
        for l in lines { if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
        let target = String(first[1])
        let (path, query) = Self.splitTarget(target)
        let length = Int(headers["content-length"] ?? "0") ?? 0
        var req = HTTPRequest(method: String(first[0]).uppercased(), path: path, query: query, headers: headers, remoteIP: ip)
        var already = buf[headerEnd!.upperBound...]
        if length <= 0 { return .success(req) }
        let isUpload = uploadPaths.contains(path)
        if length > (isUpload ? maxUploadBody : maxMemoryBody) {
            return .failure(HTTPResponse.error(isUpload ? "That file is too big (limit \(maxUploadBody / 1_000_000) MB)." : "Request too large.", status: 413))
        }
        if isUpload && length > maxMemoryBody {
            let url = tempDirectory.appendingPathComponent("upload-\(UUID().uuidString).part")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: url) else { return .failure(HTTPResponse.error("Can't write the upload.", status: 500)) }
            var got = 0
            if !already.isEmpty { try? fh.write(contentsOf: already); got = already.count }
            while got < length {
                let n = recv(fd, &chunk, min(chunk.count, length - got), 0)
                if n <= 0 { try? fh.close(); try? FileManager.default.removeItem(at: url); return .failure(HTTPResponse.error("Upload interrupted.")) }
                try? fh.write(contentsOf: Data(chunk[0..<n])); got += n
            }
            try? fh.close()
            req.bodyFile = url
            return .success(req)
        }
        var body = Data(already)
        already = Data()[...]
        while body.count < length {
            if Date().timeIntervalSince(started) > bodyTimeout { return .failure(HTTPResponse.error("Request timed out.", status: 408)) }
            let n = recv(fd, &chunk, min(chunk.count, length - body.count), 0)
            if n <= 0 { return .failure(HTTPResponse.error("Request body interrupted.")) }
            body.append(chunk, count: n)
        }
        req.body = body
        return .success(req)
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        var q: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                q[k] = v
            }
        }
        return (path, q)
    }

    static func write(_ fd: Int32, _ r: HTTPResponse) {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8); data.append(r.body)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                #if canImport(Glibc)
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                #endif
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// `bind` is shadowed by the `bind` property inside HTTPServer, so reach the C function through this alias.
private func bind_(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, addr, len)
    #else
    return Glibc.bind(fd, addr, len)
    #endif
}
