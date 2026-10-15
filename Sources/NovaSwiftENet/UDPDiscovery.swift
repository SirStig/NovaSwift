import Foundation
import NovaSwiftNet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// UDP status queries (`NSQ1` -> `NSB1`) and LAN beacons, over plain BSD sockets so the same code runs on macOS,
// iOS, tvOS and in `swift test`. Mirrors `godot/net/LanDiscovery.gd`. Status queries (`NSQ1`) work over IPv4 and
// IPv6 (a client resolves the host with getaddrinfo, so an IPv6-only NAT64 network gets the synthesized address; a
// server answers on an extra IPv6-only socket next to its IPv4 one). LAN broadcast beacons stay IPv4: IPv6 has no
// broadcast, and Godot's LanDiscovery.gd only listens for IPv4 broadcasts.
//
// Local-network privacy: on iOS / tvOS the first LAN beacon send / receive (or a query to a private address)
// triggers the Local Network permission prompt, which needs `NSLocalNetworkUsageDescription` in Info.plist.
// See docs/MULTIPLAYER.md, "Cross-play with the Apple app".

// MARK: - Socket helpers

/// An IPv4 or IPv6 socket address of either family, family-agnostic for the query / responder paths.
struct UDPAddr {
    var storage = sockaddr_storage()
    var length = 0
    init() {}
    init<T>(_ raw: T) {
        withUnsafeMutableBytes(of: &storage) { d in withUnsafeBytes(of: raw) { d.copyMemory(from: $0) } }
        length = MemoryLayout<T>.size
    }
    init(raw: UnsafeRawPointer, length n: Int) {
        let n = min(n, MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: raw, count: n)) }
        length = n
    }
    /// From raw address bytes (4 = IPv4, 16 = IPv6); port 0.
    init(literal b: [UInt8]) {
        if b.count == 4 {
            var s = sockaddr_in()
            #if os(Windows)
            s.sin_family = ADDRESS_FAMILY(AF_INET)
            #else
            s.sin_family = sa_family_t(AF_INET)
            #endif
            withUnsafeMutableBytes(of: &s.sin_addr) { for i in 0..<4 { $0[i] = b[i] } }
            #if canImport(Darwin)
            s.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            self.init(s)
        } else {
            var s = sockaddr_in6()
            #if os(Windows)
            s.sin6_family = ADDRESS_FAMILY(AF_INET6)
            #else
            s.sin6_family = sa_family_t(AF_INET6)
            #endif
            withUnsafeMutableBytes(of: &s.sin6_addr) { for i in 0..<min(16, b.count) { $0[i] = b[i] } }
            #if canImport(Darwin)
            s.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            self.init(s)
        }
    }
    var family: Int32 { Int32(storage.ss_family) }
    var isIPv6: Bool { family == Int32(AF_INET6) }

    /// Address bytes: 4 (IPv4) or 16 (IPv6).
    var addressBytes: [UInt8] {
        withUnsafeBytes(of: storage) { raw in
            if isIPv6 {
                let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                return withUnsafeBytes(of: a) { Array($0.prefix(16)) }
            }
            let a = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            return withUnsafeBytes(of: a) { Array($0.prefix(4)) }
        }
    }
    /// Normalized text (IPv4-mapped IPv6 shows as the dotted quad).
    var host: String { IPAddressTools.format(bytes: addressBytes) }
    var port: Int {
        withUnsafeBytes(of: storage) { raw in
            Int(UInt16(bigEndian: isIPv6 ? raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_port
                                         : raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_port))
        }
    }
    func with(port p: Int) -> UDPAddr {
        var a = self
        let be = UInt16(clamping: p).bigEndian
        withUnsafeMutableBytes(of: &a.storage) { raw in
            if isIPv6 { raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_port = be }
            else { raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_port = be }
        }
        return a
    }
    func sameHost(as o: UDPAddr) -> Bool { addressBytes == o.addressBytes || host == o.host }
}

#if os(Windows)
private let sockDgram = Int32(SOCK_DGRAM)

enum UDP {
    // Winsock is started once per process (ENet starts it too; the calls are reference counted).
    private static let winsock: Bool = {
        var d = WSADATA()
        return WSAStartup(0x0202, &d) == 0
    }()

    static func addr(_ networkOrder: UInt32) -> in_addr { var a = in_addr(); a.S_un.S_addr = networkOrder; return a }
    static func raw(_ a: in_addr) -> UInt32 { a.S_un.S_addr }
    static func closeSocket(_ fd: Int32) { _ = closesocket(SOCKET(UInt32(bitPattern: fd))) }

    /// libdispatch has no socket read sources on Windows, so poll the socket on a short timer instead.
    static func makeReadSource(_ fd: Int32, queue: DispatchQueue, handler: @escaping () -> Void) -> DispatchSourceProtocol {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02)
        t.setEventHandler { if waitReadable(fd, seconds: 0) { handler() } }
        return t
    }

    static func resolveIPv4(_ host: String) -> in_addr? {
        _ = winsock
        var a = in_addr()
        if inet_pton(AF_INET, host, &a) == 1 { return a }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = sockDgram
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    static func sockaddr(_ ip: in_addr, port: Int) -> sockaddr_in {
        var s = sockaddr_in()
        s.sin_family = ADDRESS_FAMILY(AF_INET)
        s.sin_port = UInt16(clamping: port).bigEndian
        s.sin_addr = ip
        return s
    }

    static func string(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: 32)
        inet_ntop(AF_INET, &a, &buf, buf.count)
        return String(cString: buf)
    }

    static func makeSocket(bindPort: Int?, broadcast: Bool, shared: Bool, loopbackOnly: Bool = false, family: Int32 = AF_INET) -> Int32? {
        _ = winsock
        let s = socket(family, sockDgram, 0)
        guard s != INVALID_SOCKET else { return nil }
        if family == AF_INET6 {
            // IPv6-only: leaves the IPv4 socket on the same port alone (Windows defaults V6ONLY to on, but be explicit).
            var on: Int32 = 1
            withUnsafePointer(to: &on) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                    _ = setsockopt(s, Int32(IPPROTO_IPV6.rawValue), IPV6_V6ONLY, $0, Int32(MemoryLayout<Int32>.size))
                }
            }
        }
        var one: Int32 = 1
        func opt(_ name: Int32) {
            withUnsafePointer(to: &one) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                    _ = setsockopt(s, SOL_SOCKET, name, $0, Int32(MemoryLayout<Int32>.size))
                }
            }
        }
        if shared { opt(SO_REUSEADDR) }
        if broadcast { opt(SO_BROADCAST) }
        var nonBlocking: u_long = 1
        _ = ioctlsocket(s, Int32(bitPattern: 0x8004667E), &nonBlocking)   // FIONBIO
        if let bindPort {
            var ok: Int32
            if family == AF_INET6 {
                var a = sockaddr_in6()
                a.sin6_family = ADDRESS_FAMILY(AF_INET6)
                a.sin6_port = UInt16(clamping: bindPort).bigEndian          // sin6_addr zero = in6addr_any
                ok = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { bind(s, $0, Int32(MemoryLayout<sockaddr_in6>.size)) }
                }
            } else {
                var a = sockaddr(addr(loopbackOnly ? UInt32(0x7f000001).bigEndian : 0), port: bindPort)
                ok = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if ok != 0 { _ = closesocket(s); return nil }
        }
        return Int32(truncatingIfNeeded: s)    // Winsock handles are 32-bit significant
    }

    static func send(_ fd: Int32, _ data: Data, to dest: sockaddr_in) {
        var dest = dest
        let s = SOCKET(UInt32(bitPattern: fd))
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { sa in
                    _ = sendto(s, base, Int32(buf.count), 0, sa, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func send(_ fd: Int32, _ data: Data, to dest: UDPAddr) {
        var dest = dest
        let s = SOCKET(UInt32(bitPattern: fd))
        let len = Int32(dest.length)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            withUnsafePointer(to: &dest.storage) {
                $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { sa in
                    _ = sendto(s, base, Int32(buf.count), 0, sa, len)
                }
            }
        }
    }

    static func receive(_ fd: Int32) -> (data: Data, from: UDPAddr)? {
        var buf = [CChar](repeating: 0, count: 2048)
        var from = UDPAddr()
        var len = Int32(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from.storage) {
            $0.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) {
                recvfrom(SOCKET(UInt32(bitPattern: fd)), &buf, Int32(buf.count), 0, $0, &len)
            }
        }
        guard n >= 0 else { return nil }
        from.length = Int(len)
        return (Data(buf[0..<Int(n)].map { UInt8(bitPattern: $0) }), from)
    }

    /// Resolve with getaddrinfo (any family). `AI_ADDRCONFIG` isn't requested on Windows.
    static func resolve(_ host: String) -> UDPAddr? {
        _ = winsock
        if let lit = IPAddressTools.bytes(host), lit.count == 16 || IPAddressTools.isLoopback(host) {
            return UDPAddr(literal: lit)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockDgram
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
            defer { freeaddrinfo(res) }
            if let sa = first.pointee.ai_addr { return UDPAddr(raw: UnsafeRawPointer(sa), length: Int(first.pointee.ai_addrlen)) }
        }
        if let lit = IPAddressTools.bytes(host) { return UDPAddr(literal: lit) }
        return nil
    }

    static func waitReadable(_ fd: Int32, seconds: Double) -> Bool {
        var p = WSAPOLLFD(fd: SOCKET(UInt32(bitPattern: fd)), events: 0x0100, revents: 0)   // POLLRDNORM
        return WSAPoll(&p, 1, Int32(max(0, seconds * 1000))) > 0 && (p.revents & 0x0100) != 0
    }

    /// This machine's IPv4 addresses (from its host name; loopback excluded). Per-interface subnet broadcast
    /// addresses aren't enumerated on Windows: the limited broadcast (255.255.255.255) is always sent.
    static func interfaces() -> (local: Set<String>, broadcast: [in_addr]) {
        _ = winsock
        var local = Set<String>()
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, Int32(name.count)) == 0 else { return (local, []) }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let head = res else { return (local, []) }
        defer { freeaddrinfo(res) }
        var cur: UnsafeMutablePointer<addrinfo>? = head
        while let p = cur {
            defer { cur = p.pointee.ai_next }
            guard let sa = p.pointee.ai_addr else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if UDP.raw(ip) != UInt32(0x7f000001).bigEndian { local.insert(string(ip)) }
        }
        return (local, [])
    }
}

#else
#if canImport(Darwin)
private let sockDgram = SOCK_DGRAM
#else
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
#endif

enum UDP {
    static func addr(_ networkOrder: UInt32) -> in_addr { in_addr(s_addr: networkOrder) }
    static func raw(_ a: in_addr) -> UInt32 { a.s_addr }
    static func closeSocket(_ fd: Int32) { close(fd) }
    /// Calls `handler` on `queue` whenever `fd` has data.
    static func makeReadSource(_ fd: Int32, queue: DispatchQueue, handler: @escaping () -> Void) -> DispatchSourceProtocol {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler(handler: handler)
        return src
    }
    static func resolveIPv4(_ host: String) -> in_addr? {
        var a = in_addr()
        if inet_pton(AF_INET, host, &a) == 1 { return a }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = sockDgram
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    static func sockaddr(_ ip: in_addr, port: Int) -> sockaddr_in {
        var s = sockaddr_in()
        s.sin_family = sa_family_t(AF_INET)
        s.sin_port = UInt16(clamping: port).bigEndian
        s.sin_addr = ip
        #if canImport(Darwin)
        s.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        return s
    }

    static func string(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// A non-blocking UDP socket. `bindPort` nil = ephemeral. `shared` allows several processes (Godot + this app)
    /// to listen on the beacon port.
    static func makeSocket(bindPort: Int?, broadcast: Bool, shared: Bool, loopbackOnly: Bool = false, family: Int32 = AF_INET) -> Int32? {
        let fd = socket(family, sockDgram, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        if family == AF_INET6 {
            // IPv6-only: the IPv4 socket bound to the same port keeps its own traffic.
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if shared {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) }
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if let bindPort {
            var ok: Int32
            if family == AF_INET6 {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = UInt16(clamping: bindPort).bigEndian          // sin6_addr zero = in6addr_any
                #if canImport(Darwin)
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                #endif
                ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            } else {
                var addr = sockaddr(in_addr(s_addr: loopbackOnly ? UInt32(0x7f000001).bigEndian : INADDR_ANY.bigEndian), port: bindPort)
                ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if ok != 0 { close(fd); return nil }
        }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data, to dest: sockaddr_in) {
        var dest = dest
        _ = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func send(_ fd: Int32, _ data: Data, to dest: UDPAddr) {
        var dest = dest
        let len = socklen_t(dest.length)
        _ = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &dest.storage) {
                $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, len)
                }
            }
        }
    }

    /// One pending datagram (from an IPv4 or IPv6 sender) or nil.
    static func receive(_ fd: Int32) -> (data: Data, from: UDPAddr)? {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = UDPAddr()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from.storage) {
            $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &len)
            }
        }
        guard n >= 0 else { return nil }
        from.length = Int(len)
        return (Data(buf[0..<n]), from)
    }

    /// Resolve with getaddrinfo (any family). On Apple platforms `AI_DEFAULT` makes an IPv6-only NAT64 network
    /// synthesize a `64:ff9b::` address for an IPv4 literal or an A-only host name; the first result (the system's own
    /// ordering) wins. Loopback / IPv6 literals skip the resolver; a routable IPv4 literal falls back to itself.
    static func resolve(_ host: String) -> UDPAddr? {
        if let lit = IPAddressTools.bytes(host), lit.count == 16 || IPAddressTools.isLoopback(host) { return UDPAddr(literal: lit) }
        for pass in 0..<2 {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = sockDgram
            if pass == 0 {
                #if canImport(Darwin)
                hints.ai_flags = AI_DEFAULT
                #else
                hints.ai_flags = AI_ADDRCONFIG
                #endif
            }
            var res: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
                defer { freeaddrinfo(res) }
                if let sa = first.pointee.ai_addr { return UDPAddr(raw: UnsafeRawPointer(sa), length: Int(first.pointee.ai_addrlen)) }
            }
        }
        if let lit = IPAddressTools.bytes(host) { return UDPAddr(literal: lit) }
        return nil
    }

    /// Wait up to `seconds` for the socket to become readable.
    static func waitReadable(_ fd: Int32, seconds: Double) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, Int32(max(0, seconds * 1000))) > 0 && (p.revents & Int16(POLLIN)) != 0
    }

    /// IPv4 addresses of this machine (loopback excluded) and the subnet broadcast address of each up interface.
    static func interfaces() -> (local: Set<String>, broadcast: [in_addr]) {
        var local = Set<String>(); var bcast: [in_addr] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return (local, bcast) }
        defer { freeifaddrs(list) }
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let flags = Int(p.pointee.ifa_flags)
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET), flags & Int(IFF_UP) != 0 else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            local.insert(string(ip))
            #if canImport(Darwin)
            let broadcastAddr = p.pointee.ifa_dstaddr
            #else
            let broadcastAddr = p.pointee.ifa_ifu.ifu_broadaddr
            #endif
            if flags & Int(IFF_BROADCAST) != 0, flags & Int(IFF_LOOPBACK) == 0, let b = broadcastAddr {
                bcast.append(b.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
            }
        }
        return (local, bcast)
    }
}

#endif

// MARK: - Status query (ping)

/// Asks a server for its beacon with a one-shot UDP `NSQ1` datagram (no connection): live players / version /
/// password / latency for the Public, Saved and Join-by-address lists.
public enum ServerStatusQuery {
    public struct Result: Equatable, Sendable {
        public var beacon: ServerBeacon
        public var rttMilliseconds: Int
    }

    /// Blocking (up to `timeout`); call off the main thread. nil = no answer (offline, firewalled, wrong port).
    public static func query(host: String, gamePort: Int, timeout: TimeInterval = 3) -> Result? {
        guard let ip = UDP.resolve(host) else { return nil }
        return query(ip: ip, queryPort: CrossPlayProtocol.queryPort(forGamePort: gamePort), timeout: timeout)
    }

    static func query(ip: UDPAddr, queryPort: Int, timeout: TimeInterval) -> Result? {
        // A socket of the target's family: IPv6 targets (including NAT64-synthesized ones) need an AF_INET6 socket.
        guard let fd = UDP.makeSocket(bindPort: nil, broadcast: false, shared: false, family: ip.family) else { return nil }
        defer { UDP.closeSocket(fd) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let dest = ip.with(port: queryPort)
        // The padded request (a server never answers it with more bytes than it received). Servers older than this
        // build only know the bare 4-byte query, so if nothing came back after a third of the timeout we try that too.
        UDP.send(fd, ServerBeacon.queryPacket, to: dest)
        let deadline = Date().addingTimeInterval(timeout)
        let legacyAt = Date().addingTimeInterval(max(0.6, timeout / 3))
        var sentLegacy = false
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            let wait = sentLegacy ? left : min(left, max(0, legacyAt.timeIntervalSinceNow))
            if !UDP.waitReadable(fd, seconds: wait) {
                if !sentLegacy, Date() >= legacyAt { UDP.send(fd, ServerBeacon.legacyQueryPacket, to: dest); sentLegacy = true; continue }
                if sentLegacy || Date() >= deadline { return nil }
                continue
            }
            while let (data, from) = UDP.receive(fd) {
                guard from.sameHost(as: ip), let b = ServerBeacon.decode(data) else { continue }
                let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                return Result(beacon: b, rttMilliseconds: Swift.max(1, ms))
            }
        }
    }
}

/// Queries many servers concurrently (at most `concurrency` at a time, 60 entries per cycle like the Godot
/// browser) and reports each answer as it lands. `onResult` runs on `callbackQueue`.
public final class ServerStatusProber {
    public static let maxPerCycle = 60
    private let queue = OperationQueue()
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0

    public init(concurrency: Int = 12, callbackQueue: DispatchQueue = .main) {
        queue.maxConcurrentOperationCount = concurrency
        #if os(Linux)
        // An elevated QoS makes libdispatch raise worker-thread priority, which unprivileged services are refused
        // ("Failed to set thread priority ... errno=13" in the log). Default QoS needs no privilege.
        queue.qualityOfService = .default
        #else
        queue.qualityOfService = .userInitiated
        #endif
        self.callbackQueue = callbackQueue
    }

    /// Start a cycle for `addresses` (replaces any running one; stale answers are dropped).
    public func probe(_ addresses: [CrossPlayAddress], timeout: TimeInterval = 3,
                      onResult: @escaping (CrossPlayAddress, ServerStatusQuery.Result?) -> Void) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        queue.cancelAllOperations()
        for a in addresses.prefix(Self.maxPerCycle) {
            queue.addOperation { [weak self] in
                guard let self else { return }
                let r = ServerStatusQuery.query(host: a.host, gamePort: a.port, timeout: timeout)
                self.lock.lock(); let current = gen == self.generation; self.lock.unlock()
                guard current else { return }
                self.callbackQueue.async { onResult(a, r) }
            }
        }
    }

    public func cancel() {
        lock.lock(); generation += 1; lock.unlock()
        queue.cancelAllOperations()
    }
}

// MARK: - LAN beacons

/// A game seen on the LAN: the beacon plus the sender's IP.
public struct LANServer: Identifiable, Equatable, Sendable {
    public var ip: String
    public var beacon: ServerBeacon
    public var id: String { "\(ip):\(beacon.port)" }
    public var address: CrossPlayAddress { CrossPlayAddress(host: ip, port: beacon.port) }
}

/// Listens for `NSB1` beacons on UDP 53736 (the LAN browser), and/or announces a hosted game: a beacon to
/// 255.255.255.255:53736 (plus each interface's subnet broadcast) every 2 s, and answers `NSQ1` queries on
/// game port + 1 (53736 for the default port). Best effort: a bind failure sets `lastError`, never throws.
public final class LANBeaconService {
    public static let announceEvery = 2.0
    public static let expireAfter = 7.0

    /// Fired on the service's queue whenever the table of heard servers changes.
    public var onServers: (([LANServer]) -> Void)?
    public private(set) var lastError = ""
    /// Beacons from this machine for these game ports are ignored (so a host doesn't list itself).
    public var ignoredLocalPorts: Set<Int> = []
    /// When false an announcing service still answers `NSQ1` status queries but sends no LAN broadcast beacons
    /// (a dedicated server whose admin switched "show on the local network" off).
    public var broadcastBeacons = true

    private let q: DispatchQueue
    private let listenPort: Int
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceProtocol?
    private var txFD: Int32 = -1
    private var querySource: DispatchSourceProtocol?
    private var queryFD: Int32 = -1
    /// IPv6-only twin of the IPv4 query responder (same port), so `NSQ1` status queries also work over IPv6.
    private var query6FD: Int32 = -1
    private var query6Source: DispatchSourceProtocol?
    private var timer: DispatchSourceTimer?
    private var provider: (() -> ServerBeacon)?
    private var gamePort = CrossPlayProtocol.defaultPort
    private var seen: [String: (server: LANServer, at: Date)] = [:]
    private var lastPublished: [LANServer] = []
    private var broadcastTargets: [in_addr] = []
    private var localIPs = Set<String>()
    private var announceDue = Date.distantPast
    /// Rate limits and size rules for `NSQ1` status queries (see `QueryGuard`).
    public let queryGuard = QueryGuard()

    /// `listenPort` is overridable so tests can run on a private port instead of the real 53736.
    public init(listenPort: Int = CrossPlayProtocol.lanPort, queue: DispatchQueue = DispatchQueue(label: "novaswift.lan")) {
        self.listenPort = listenPort
        self.q = queue
    }
    deinit { stop() }

    /// Start listening for beacons (the "Nearby" tab). Safe to call twice.
    @discardableResult
    public func startListening() -> Bool {
        q.sync {
            let ok = listenFD >= 0 || startListeningLocked()
            if ok { startTimer() }
            return ok
        }
    }

    /// Announce a hosted game. `provider` is called per beacon so player counts stay live.
    @discardableResult
    public func startAnnouncing(gamePort: Int, provider: @escaping () -> ServerBeacon, broadcastTarget: in_addr? = nil) -> Bool {
        q.sync {
            self.provider = provider
            self.gamePort = gamePort
            if txFD < 0 { txFD = UDP.makeSocket(bindPort: nil, broadcast: true, shared: false) ?? -1 }
            let (local, bcast) = UDP.interfaces()
            localIPs = local
            broadcastTargets = broadcastTarget.map { [$0] } ?? bcast
            // The query responder: game port + 1, which is the shared beacon port for the default game port.
            let qport = CrossPlayProtocol.queryPort(forGamePort: gamePort)
            var ok = true
            if qport == listenPort {
                if listenFD < 0 { ok = startListeningLocked() }
            } else if queryFD < 0 {
                if let fd = UDP.makeSocket(bindPort: qport, broadcast: false, shared: true) {
                    queryFD = fd
                    let src = UDP.makeReadSource(fd, queue: q) { [weak self] in self?.drain(fd, takeBeacons: false) }
                    src.resume(); querySource = src
                } else {
                    lastError = "Server pinging is off (UDP \(qport) is busy)."
                    ok = false
                }
            }
            if query6FD < 0, let fd6 = UDP.makeSocket(bindPort: qport, broadcast: false, shared: true, family: Int32(AF_INET6)) {
                query6FD = fd6     // best effort: no IPv6 on this machine just means no IPv6 status queries
                let src = UDP.makeReadSource(fd6, queue: q) { [weak self] in self?.drain(fd6, takeBeacons: false) }
                src.resume(); query6Source = src
            }
            announceDue = .distantPast
            startTimer()
            return ok
        }
    }

    public func stopAnnouncing() {
        q.sync {
            provider = nil
            querySource?.cancel(); querySource = nil
            if queryFD >= 0 { UDP.closeSocket(queryFD); queryFD = -1 }
            query6Source?.cancel(); query6Source = nil
            if query6FD >= 0 { UDP.closeSocket(query6FD); query6FD = -1 }
            if txFD >= 0 { UDP.closeSocket(txFD); txFD = -1 }
        }
    }

    public func stop() {
        stopAnnouncing()
        q.sync {
            timer?.cancel(); timer = nil
            listenSource?.cancel(); listenSource = nil
            if listenFD >= 0 { UDP.closeSocket(listenFD); listenFD = -1 }
            seen.removeAll()
            lastPublished = []
        }
    }

    public var servers: [LANServer] {
        q.sync { seen.values.map(\.server).sorted { $0.beacon.name.localizedCaseInsensitiveCompare($1.beacon.name) == .orderedAscending } }
    }

    // MARK: Internals (on q)

    private func startListeningLocked() -> Bool {
        guard let fd = UDP.makeSocket(bindPort: listenPort, broadcast: true, shared: true) else {
            lastError = "Can't listen for LAN games (UDP \(listenPort) is busy)."
            return false
        }
        listenFD = fd
        let src = UDP.makeReadSource(fd, queue: q) { [weak self] in self?.drain(fd, takeBeacons: true) }
        src.resume(); listenSource = src
        return true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.25, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    private func tick() {
        let now = Date()
        if broadcastBeacons, let provider, txFD >= 0, now >= announceDue {
            announceDue = now.addingTimeInterval(Self.announceEvery)
            let pkt = provider().encode()
            UDP.send(txFD, pkt, to: UDP.sockaddr(UDP.addr(UInt32.max), port: listenPort))
            for b in broadcastTargets { UDP.send(txFD, pkt, to: UDP.sockaddr(b, port: listenPort)) }
        }
        let before = seen.count
        seen = seen.filter { now.timeIntervalSince($0.value.at) <= Self.expireAfter }
        if seen.count != before { publish() }
    }

    private func drain(_ fd: Int32, takeBeacons: Bool) {
        while let (data, from) = UDP.receive(fd) {
            if QueryGuard.classify(data) != .invalid {
                // Anti-amplification: padded requests only (plus a trickle of legacy ones), a per-address budget, and a
                // reply never larger than the request. Everything else is dropped without an answer.
                guard let provider else { continue }
                switch queryGuard.decide(data, from: IPAddressTools.groupKey(from.host)) {   /* IPv6: one budget per /64 */
                case .drop: continue
                case .upgradeNotice: UDP.send(fd, QueryGuard.upgradeNotice, to: from)
                case .reply(let maxBytes):
                    let pkt = provider().encode(maxBytes: maxBytes)
                    if !pkt.isEmpty, pkt.count <= maxBytes { UDP.send(fd, pkt, to: from) }
                }
            } else if takeBeacons, let b = ServerBeacon.decode(data) {
                let ip = from.host
                if ignoredLocalPorts.contains(b.port), localIPs.contains(ip) || ip == "127.0.0.1" { continue }
                let s = LANServer(ip: ip, beacon: b)
                let isNew = seen[s.id]?.server != s
                seen[s.id] = (s, Date())
                if isNew { publish() }
            }
        }
    }

    private func publish() {
        let list = seen.values.map(\.server).sorted { $0.beacon.name.localizedCaseInsensitiveCompare($1.beacon.name) == .orderedAscending }
        guard list != lastPublished else { return }
        lastPublished = list
        onServers?(list)
    }
}
