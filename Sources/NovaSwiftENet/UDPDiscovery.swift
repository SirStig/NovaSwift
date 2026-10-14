import Foundation
import NovaSwiftNet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// UDP status queries (`NSQ1` -> `NSB1`) and LAN beacons, over plain BSD sockets so the same code runs on macOS,
// iOS, tvOS and in `swift test`. Mirrors `godot/net/LanDiscovery.gd`. IPv4 only, like ENet 1.3.
//
// Local-network privacy: on iOS / tvOS the first LAN beacon send / receive (or a query to a private address)
// triggers the Local Network permission prompt, which needs `NSLocalNetworkUsageDescription` in Info.plist.
// See docs/MULTIPLAYER.md, "Cross-play with the Apple app".

// MARK: - Socket helpers

#if canImport(Darwin)
private let sockDgram = SOCK_DGRAM
#else
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
#endif

enum UDP {
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
    static func makeSocket(bindPort: Int?, broadcast: Bool, shared: Bool, loopbackOnly: Bool = false) -> Int32? {
        let fd = socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
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
            var addr = sockaddr(in_addr(s_addr: loopbackOnly ? UInt32(0x7f000001).bigEndian : INADDR_ANY.bigEndian), port: bindPort)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
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

    /// One pending datagram or nil.
    static func receive(_ fd: Int32) -> (data: Data, from: sockaddr_in)? {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: Foundation.sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &len)
            }
        }
        guard n >= 0 else { return nil }
        return (Data(buf[0..<n]), from)
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
        guard let ip = UDP.resolveIPv4(host) else { return nil }
        return query(ip: ip, queryPort: CrossPlayProtocol.queryPort(forGamePort: gamePort), timeout: timeout)
    }

    static func query(ip: in_addr, queryPort: Int, timeout: TimeInterval) -> Result? {
        guard let fd = UDP.makeSocket(bindPort: nil, broadcast: false, shared: false) else { return nil }
        defer { close(fd) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        UDP.send(fd, ServerBeacon.queryPacket, to: UDP.sockaddr(ip, port: queryPort))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, UDP.waitReadable(fd, seconds: left) else { return nil }
            while let (data, from) = UDP.receive(fd) {
                guard from.sin_addr.s_addr == ip.s_addr, let b = ServerBeacon.decode(data) else { continue }
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
        queue.qualityOfService = .userInitiated
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
    private var listenSource: DispatchSourceRead?
    private var txFD: Int32 = -1
    private var querySource: DispatchSourceRead?
    private var queryFD: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var provider: (() -> ServerBeacon)?
    private var gamePort = CrossPlayProtocol.defaultPort
    private var seen: [String: (server: LANServer, at: Date)] = [:]
    private var lastPublished: [LANServer] = []
    private var broadcastTargets: [in_addr] = []
    private var localIPs = Set<String>()
    private var announceDue = Date.distantPast

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
                    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
                    src.setEventHandler { [weak self] in self?.drain(fd, takeBeacons: false) }
                    src.resume(); querySource = src
                } else {
                    lastError = "Server pinging is off (UDP \(qport) is busy)."
                    ok = false
                }
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
            if queryFD >= 0 { close(queryFD); queryFD = -1 }
            if txFD >= 0 { close(txFD); txFD = -1 }
        }
    }

    public func stop() {
        stopAnnouncing()
        q.sync {
            timer?.cancel(); timer = nil
            listenSource?.cancel(); listenSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
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
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in self?.drain(fd, takeBeacons: true) }
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
            UDP.send(txFD, pkt, to: UDP.sockaddr(in_addr(s_addr: INADDR_BROADCAST.bigEndian), port: listenPort))
            for b in broadcastTargets { UDP.send(txFD, pkt, to: UDP.sockaddr(b, port: listenPort)) }
        }
        let before = seen.count
        seen = seen.filter { now.timeIntervalSince($0.value.at) <= Self.expireAfter }
        if seen.count != before { publish() }
    }

    private func drain(_ fd: Int32, takeBeacons: Bool) {
        while let (data, from) = UDP.receive(fd) {
            if ServerBeacon.isQuery(data) {
                if let provider {
                    UDP.send(fd, provider().encode(), to: from)
                }
            } else if takeBeacons, let b = ServerBeacon.decode(data) {
                let ip = UDP.string(from.sin_addr)
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
