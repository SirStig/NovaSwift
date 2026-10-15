import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// The few blocking IPv4 TCP/UDP socket calls the admin HTTP server and the UPnP probe need, behind one API so the
/// BSD-socket (macOS, Linux) and Winsock (Windows) differences live in a single file. A socket is an `Int32`
/// everywhere (Winsock handles are 32-bit significant, so the narrowing is lossless).
enum Sock {
    enum BindResult: Equatable { case ok(port: Int), invalidAddress, inUse, failed(String) }

    // MARK: Shared

    static func tcp() -> Int32? { make(stream: true) }
    static func udp() -> Int32? { make(stream: false) }

    #if os(Windows)

    private static let winsock: Bool = {
        var d = WSADATA()
        return WSAStartup(0x0202, &d) == 0
    }()

    private static func s(_ fd: Int32) -> SOCKET { SOCKET(UInt32(bitPattern: fd)) }

    private static func make(stream: Bool) -> Int32? {
        _ = winsock
        let h = socket(AF_INET, stream ? Int32(SOCK_STREAM) : Int32(SOCK_DGRAM), 0)
        return h == INVALID_SOCKET ? nil : Int32(truncatingIfNeeded: h)
    }

    private static func opt(_ fd: Int32, _ name: Int32, _ value: Int32) {
        var v = value
        withUnsafePointer(to: &v) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                _ = setsockopt(s(fd), SOL_SOCKET, name, $0, Int32(MemoryLayout<Int32>.size))
            }
        }
    }

    /// Winsock takes SO_RCVTIMEO / SO_SNDTIMEO as milliseconds in a DWORD.
    static func setTimeouts(_ fd: Int32, seconds: Double) {
        opt(fd, SO_RCVTIMEO, Int32(seconds * 1000))
        opt(fd, SO_SNDTIMEO, Int32(seconds * 1000))
    }
    static func setReceiveTimeout(_ fd: Int32, seconds: Double) { opt(fd, SO_RCVTIMEO, Int32(seconds * 1000)) }

    static func bindIPv4(_ fd: Int32, address: String, port: Int) -> BindResult {
        opt(fd, SO_REUSEADDR, 0)   // Windows SO_REUSEADDR lets a second process steal the port; leave it off so EADDRINUSE works
        var a = sockaddr_in()
        a.sin_family = ADDRESS_FAMILY(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &a.sin_addr) == 1 else { return .invalidAddress }
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { WinSDK.bind(s(fd), $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = WSAGetLastError()
            return e == WSAEADDRINUSE ? .inUse : .failed("Winsock error \(e)")
        }
        var bound = sockaddr_in(); var len = Int32(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { getsockname(s(fd), $0, &len) } }
        return .ok(port: Int(UInt16(bigEndian: bound.sin_port)))
    }

    static func listen(_ fd: Int32, backlog: Int32) -> Bool { WinSDK.listen(s(fd), backlog) == 0 }

    /// nil = the listener is closed or failed; otherwise the connection and the peer's dotted address.
    static func accept(_ fd: Int32) -> (fd: Int32, ip: String)? {
        var peer = sockaddr_in(); var len = Int32(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { WinSDK.accept(s(fd), $0, &len) } }
        guard c != INVALID_SOCKET else { return nil }
        var buf = [CChar](repeating: 0, count: 32)
        var a = peer.sin_addr
        inet_ntop(AF_INET, &a, &buf, buf.count)
        return (Int32(truncatingIfNeeded: c), String(cString: buf))
    }

    static func recv(_ fd: Int32, _ buf: inout [UInt8], max: Int) -> Int {
        let n = min(max, buf.count)
        return buf.withUnsafeMutableBytes { raw in
            Int(WinSDK.recv(s(fd), raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(n), 0))
        }
    }

    static func send(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int) -> Int {
        Int(WinSDK.send(s(fd), p.assumingMemoryBound(to: CChar.self), Int32(count), 0))
    }

    static func sendTo(_ fd: Int32, _ text: String, ip: String, port: Int) {
        var dest = sockaddr_in()
        dest.sin_family = ADDRESS_FAMILY(AF_INET)
        dest.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, ip, &dest.sin_addr)
        _ = text.withCString { c in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) {
                    WinSDK.sendto(s(fd), c, Int32(strlen(c)), 0, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// This machine's non-loopback IPv4 addresses, from the addresses its host name resolves to.
    static func localIPv4() -> [String] {
        _ = winsock
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, Int32(name.count)) == 0 else { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let head = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = head
        while let p = cur {
            defer { cur = p.pointee.ai_next }
            guard let sa = p.pointee.ai_addr else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: 32)
            inet_ntop(AF_INET, &a, &buf, buf.count)
            let ip = String(cString: buf)
            if !ip.hasPrefix("127.") { out.append(ip) }
        }
        return out
    }

    static func shutdown(_ fd: Int32) { _ = WinSDK.shutdown(s(fd), 2) }   // SD_BOTH
    static func close(_ fd: Int32) { _ = closesocket(s(fd)) }

    #else

    private static func make(stream: Bool) -> Int32? {
        #if canImport(Darwin)
        let type = stream ? SOCK_STREAM : SOCK_DGRAM
        #else
        let type = Int32((stream ? SOCK_STREAM : SOCK_DGRAM).rawValue)
        #endif
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    private static func timeval(_ seconds: Double) -> timeval {
        Foundation.timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    }

    static func setTimeouts(_ fd: Int32, seconds: Double) {
        var tv = timeval(seconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<Foundation.timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<Foundation.timeval>.size))
    }
    static func setReceiveTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(seconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<Foundation.timeval>.size))
    }

    static func bindIPv4(_ fd: Int32, address: String, port: Int) -> BindResult {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &a.sin_addr) == 1 else { return .invalidAddress }
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = errno
            return e == EADDRINUSE ? .inUse : .failed(String(cString: strerror(e)))
        }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return .ok(port: Int(UInt16(bigEndian: bound.sin_port)))
    }

    static func listen(_ fd: Int32, backlog: Int32) -> Bool {
        return sysListen(fd, backlog) == 0
    }

    static func accept(_ fd: Int32) -> (fd: Int32, ip: String)? {
        while true {
            var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysAccept(fd, $0, &len) } }
            if c < 0 { if errno == EINTR { continue }; return nil }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = peer.sin_addr
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            return (c, String(cString: buf))
        }
    }

    static func recv(_ fd: Int32, _ buf: inout [UInt8], max: Int) -> Int { sysRecv(fd, &buf, Swift.min(max, buf.count), 0) }

    static func send(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        return sysSend(fd, p, count, Int32(MSG_NOSIGNAL))
        #else
        return sysSend(fd, p, count, 0)
        #endif
    }

    static func sendTo(_ fd: Int32, _ text: String, ip: String, port: Int) {
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, ip, &dest.sin_addr)
        _ = text.withCString { c in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, c, strlen(c), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    static func shutdown(_ fd: Int32) { _ = sysShutdown(fd, Int32(SHUT_RDWR)) }
    static func close(_ fd: Int32) { _ = sysClose(fd) }

    #endif
}

#if !os(Windows)
// File-level wrappers: inside `Sock`, the static methods named send/recv/close/... would shadow the C functions.
private func sysBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { bind(fd, a, l) }
private func sysAccept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>, _ l: UnsafeMutablePointer<socklen_t>) -> Int32 { accept(fd, a, l) }
private func sysRecv(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int, _ f: Int32) -> Int { recv(fd, b, n, f) }
private func sysSend(_ fd: Int32, _ b: UnsafeRawPointer, _ n: Int, _ f: Int32) -> Int { send(fd, b, n, f) }
private func sysShutdown(_ fd: Int32, _ how: Int32) -> Int32 { shutdown(fd, how) }
private func sysClose(_ fd: Int32) -> Int32 { close(fd) }

private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
#endif
