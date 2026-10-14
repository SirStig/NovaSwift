import Foundation
import CENet
import NovaSwiftNet

/// A `NovaSwiftNet.Transport` that **hosts** a game other players join over ENet by `ip:port`: Godot clients
/// (Linux, Windows, Steam Deck), other Apple devices, and anything speaking the NovaSwift cross-play protocol.
///
/// It is the Swift twin of the server half of `godot/net/NetTransport.gd` (and what `ServerMain.gd` runs):
///
/// - this device is **peer 1**, the host, and a participant in the session (it has a pilot);
/// - clients get their peer id from the ENet *connect data* (Godot's `ENetMultiplayerPeer` convention: random
///   32-bit, >= 2, unique; anything else is reset);
/// - the handshake (`HELLO` -> `WELCOME` / `REJECT`) checks wire protocol, game version, password, ban list,
///   capacity and the plug-in manifest;
/// - game bytes (`DATA`) are relayed client-to-client, so per-system authority (any co-located player) works;
/// - every client is told about every other (`PEER_JOIN` / `PEER_LEFT`, and `WELCOME.peers`);
/// - the same channels as the Godot server: ENet 0 reliable, ENet 2 unreliable.
///
/// Discovery is separate: `LANBeaconService.startAnnouncing` (beacons + `NSQ1` replies) with this object's
/// `beacon()` as the provider.
///
/// Like `ENetTransport`: ENet is not thread-safe, so call `service()` from one place or use `startPumping()`.
/// `send` / `broadcast` only enqueue and are safe from any thread. Delegate and `onEvent` callbacks run on the
/// pumping thread (pass `DispatchQueue.main` to `startPumping` to get them on the main queue).
public final class ENetHostTransport: Transport, TransportDelegate {

    public struct Config {
        public var port: Int
        /// Total player slots including the host (Godot: `max_players`).
        public var maxPlayers: Int
        public var serverName: String
        /// The host pilot's display name; peer 1 in everyone's roster.
        public var hostName: String
        public var password: String
        public var gameVersion: String
        /// `ENetTransport.manifestJSON(_:)` of the host's enabled plug-ins; "" disables the gate.
        public var manifestJSON: String
        /// `CrossPlayProtocol.rulesJSON(_:)`; sent in WELCOME so the lobby can show the stakes.
        public var rulesJSON: String
        /// "safe" / "full" / "custom", advertised in beacons.
        public var rulesName: String
        /// What the host's content is, advertised in beacons / status replies (TC, add-ons, load order).
        public var requirements: PluginRequirements?
        /// Bind 127.0.0.1 only (tests).
        public var loopbackOnly: Bool
        /// A dedicated server: no pilot of its own. It takes no player slot, is not listed in anyone's roster
        /// (WELCOME `has_local_player` false, `host_name` "[Server]") and its beacon says `dedicated`.
        public var dedicated: Bool = false
        /// Most simultaneous connections from one IP address (0 = unlimited). Behind Docker's userland proxy or a NAT
        /// every player can share an address: raise it there.
        public var maxConnectionsPerIP: Int = NetLimits.defaultMaxConnectionsPerIP
        /// Seconds an address stays blocked after repeated abuse (flooding, bad handshakes, password guessing).
        public var tempBanSeconds: Double = NetLimits.tempBanSeconds
        public init(port: Int = CrossPlayProtocol.defaultPort, maxPlayers: Int = 8, serverName: String, hostName: String,
                    password: String = "", gameVersion: String = CrossPlayProtocol.appVersion, manifestJSON: String = "",
                    rulesJSON: String = "{}", rulesName: String = "custom", requirements: PluginRequirements? = nil, loopbackOnly: Bool = false,
                    dedicated: Bool = false) {
            self.dedicated = dedicated
            self.requirements = requirements
            self.port = port; self.maxPlayers = maxPlayers; self.serverName = serverName; self.hostName = hostName
            self.password = password; self.gameVersion = gameVersion; self.manifestJSON = manifestJSON
            self.rulesJSON = rulesJSON; self.rulesName = rulesName; self.loopbackOnly = loopbackOnly
        }
    }

    public enum Event: Equatable {
        case hosting(port: Int)
        case peerJoined(id: Int, name: String)
        case peerLeft(id: Int, name: String, reason: String)
        /// A joiner was turned away (`code` is one of the REJECT codes).
        case refused(code: String, message: String, ip: String)
        case chat(id: Int, name: String, text: String)
        /// A joiner runs another app release (same protocol): informational.
        case versionNote(id: Int, name: String, theirs: String, ours: String)
        /// A connection was dropped for abusing the server (`reason` is plain language); `banned` = its address is now
        /// blocked for a while.
        case abuse(id: Int, name: String, ip: String, reason: String, banned: Bool)
        /// A player reported someone (`target` 0 = the reporter's client noticed invalid data and names the sender).
        case report(reporter: Int, target: Int, reason: String, detail: String)
    }

    public enum HostError: Error, Equatable { case alreadyStarted, cannotBind(Int) }

    public struct PeerInfo: Equatable {
        public var id: Int
        public var name: String
        public var ip: String
        public var rttMilliseconds: Int
    }

    private final class Conn {
        let peer: UnsafeMutablePointer<ENetPeer>
        var name = ""
        var ready = false
        let t0: Double
        var lastRx: Double
        var rtt = -1
        var ip = ""
        var packets: TokenBucket
        var bytes: TokenBucket
        var chat: TokenBucket
        var reports: TokenBucket
        var violations = 0
        var violationsSince: Double
        var lastChat = ""
        var repeatedChat = 0
        var lastChatAt = 0.0
        init(peer: UnsafeMutablePointer<ENetPeer>, now: Double) {
            self.peer = peer; t0 = now; lastRx = now; violationsSince = now
            packets = TokenBucket(burst: NetLimits.packetBurst, perSecond: NetLimits.packetsPerSecond, now: now)
            bytes = TokenBucket(burst: NetLimits.byteBurst, perSecond: NetLimits.bytesPerSecond, now: now)
            chat = TokenBucket(burst: NetLimits.chatBurst, perSecond: NetLimits.chatPerSecond, now: now)
            reports = TokenBucket(burst: 3, perSecond: 0.2, now: now)
        }
    }

    // MARK: State

    public private(set) var config: Config
    public let inner = ExternalTransport(localPeerID: ENetTransport.Wire.serverID)
    public var localPeerID: PeerID { inner.localPeerID }
    public var hostPeerID: PeerID? { String(ENetTransport.Wire.serverID) }
    public var connectedPeers: [PeerID] { inner.connectedPeers }
    public weak var delegate: TransportDelegate?
    public var onEvent: ((Event) -> Void)?
    public private(set) var isRunning = false
    public var handshakeTimeout = ENetTransport.Wire.handshakeTimeout
    public var idleTimeout = ENetTransport.Wire.idleTimeout

    // The LAN responder runs on its own queue and asks for `beacon()`: keep what it reads behind a lock.
    private let beaconLock = NSLock()
    private var beaconPlayers = 1
    private var beaconConfig: Config
    /// Moderation hooks (the dedicated server sets these; all run on the pumping thread).
    /// Inspect/rewrite a client's relayed game bytes before they reach anyone: return nil to drop them.
    public var relayFilter: ((_ from: Int, _ payload: [UInt8]) -> [UInt8]?)?
    /// Vet a chat line (already cleaned and capped): return the text to broadcast, nil to drop it.
    public var chatFilter: ((_ from: Int, _ name: String, _ ip: String, _ text: String) -> String?)?
    /// Extra join rules (allowlist, ...): return a (code, message) refusal or nil to let the player in.
    public var joinGate: ((_ ip: String, _ name: String) -> (code: String, message: String)?)?
    /// A chat line starting with "/" : handled here instead of being broadcast.
    public var onCommand: ((_ from: Int, _ name: String, _ ip: String, _ text: String) -> Void)?
    /// Addresses blocked for a while after abuse: ip -> seconds left. Read-only for UIs.
    public var tempBans: [String: Double] { tempBanUntil.filter { $0.value > clock }.mapValues { $0 - clock } }
    private var tempBanUntil: [String: Double] = [:]
    private var abuseKicks: [String: [Double]] = [:]
    private var handshakeFailures: [String: [Double]] = [:]

    private var host: UnsafeMutablePointer<ENetHost>?
    private var conns: [Int: Conn] = [:]
    private var banned = Set<String>()
    private var closing: [Int: Double] = [:]
    private var clock = 0.0
    private var sentTotal: UInt64 = 0
    private var receivedTotal: UInt64 = 0
    private var lastService = ProcessInfo.processInfo.systemUptime
    private var pumpTimer: DispatchSourceTimer?
    private static let debug = ProcessInfo.processInfo.environment["NOVASWIFT_ENET_DEBUG"] != nil
    private static let initOnce: Void = { _ = enet_initialize() }()

    public init(config: Config) {
        _ = Self.initOnce
        self.config = config
        self.beaconConfig = config
        self.beaconPlayers = config.dedicated ? 0 : 1   // a dedicated server counts real players only
        inner.delegate = self
    }

    deinit { teardown() }

    // MARK: Transport

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) { inner.send(data, to: peer, channel: channel) }
    public func broadcast(_ data: Data, channel: NetChannel) { inner.broadcast(data, channel: channel) }

    public func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID) { delegate?.transport(self, didReceive: data, from: peer) }
    public func transport(_ transport: Transport, peerDidConnect peer: PeerID) { delegate?.transport(self, peerDidConnect: peer) }
    public func transport(_ transport: Transport, peerDidDisconnect peer: PeerID) { delegate?.transport(self, peerDidDisconnect: peer) }

    /// Stop hosting: tell every client, flush, free the socket.
    public func disconnect() {
        guard isRunning else { return }
        flushOutgoing()
        for (id, c) in conns where c.ready { sendControl(id, Kind.kick, ["reason": "The host closed the game."]) }
        if let host { enet_host_flush(host) }
        inner.disconnect()
        for c in conns.values { enet_peer_disconnect_now(c.peer, 0) }
        if let host { enet_host_flush(host) }
        stopPumping()
        teardown()
        isRunning = false
        conns.removeAll()
    }

    // MARK: Lifecycle

    public func start() throws {
        guard host == nil else { throw HostError.alreadyStarted }
        var addr = ENetAddress()
        if config.loopbackOnly { enet_address_set_host(&addr, "127.0.0.1") } else { addr.host = 0 }   // ENET_HOST_ANY
        addr.port = UInt16(clamping: config.port)
        // +2 slack so a refused (full / wrong version) joiner can still be told why before it is dropped.
        guard let h = enet_host_create(&addr, max(1, config.maxPlayers) + 2, 0, 0, 0) else { throw HostError.cannotBind(config.port) }
        // Hard limits inside ENet itself: one reassembled packet at most `NetLimits.maxPacket`, a bounded receive backlog
        // per peer, and a per-address cap on established peers.
        h.pointee.maximumPacketSize = NetLimits.maxPacket
        h.pointee.maximumWaitingData = 2 * 1024 * 1024
        if config.maxConnectionsPerIP > 0, !config.loopbackOnly { h.pointee.duplicatePeers = config.maxConnectionsPerIP }
        host = h
        isRunning = true
        beaconLock.lock(); beaconPlayers = config.dedicated ? 0 : 1; beaconLock.unlock()
        tempBanUntil.removeAll(); abuseKicks.removeAll(); handshakeFailures.removeAll()
        clock = 0
        sentTotal = 0; receivedTotal = 0
        lastService = ProcessInfo.processInfo.systemUptime
        emit(.hosting(port: config.port))
    }

    public func startPumping(interval: TimeInterval = 0.01, queue: DispatchQueue = DispatchQueue(label: "novaswift.enet.host")) {
        guard pumpTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.service() }
        pumpTimer = t
        t.resume()
    }

    public func stopPumping() { pumpTimer?.cancel(); pumpTimer = nil }

    /// Rules shown to later joiners (WELCOME) and in beacons.
    public func updateRules(json: String, name: String) {
        config.rulesJSON = json; config.rulesName = name
        beaconLock.lock(); beaconConfig = config; beaconLock.unlock()
    }

    /// Change settings of a running host (name, password, capacity limit, plug-in manifest, rules...). The port and
    /// `dedicated` flag need a restart. Safe to call from the pumping thread.
    public func reconfigure(_ change: (inout Config) -> Void) {
        let port = config.port, dedicated = config.dedicated
        change(&config)
        config.port = port; config.dedicated = dedicated
        beaconLock.lock(); beaconConfig = config; beaconLock.unlock()
    }

    /// Update the advertised content (after the host's plug-in set changes).
    public func updateRequirements(_ r: PluginRequirements?) {
        config.requirements = r
        beaconLock.lock(); beaconConfig = config; beaconLock.unlock()
    }

    private func publishPlayerCount() {
        let n = playerCount
        beaconLock.lock(); beaconPlayers = n; beaconLock.unlock()
    }

    // MARK: Roster / beacon

    /// Players that finished the handshake (host not included).
    public var clients: [PeerInfo] {
        conns.filter { $0.value.ready }.map { PeerInfo(id: $0.key, name: $0.value.name, ip: $0.value.ip, rttMilliseconds: $0.value.rtt) }
            .sorted { $0.id < $1.id }
    }
    public var playerCount: Int { clients.count + (config.dedicated ? 0 : 1) }
    /// Slots for joining players (a dedicated server has no pilot, so every slot is for a client).
    private var clientCapacity: Int { config.maxPlayers - (config.dedicated ? 0 : 1) }

    /// IPs refused at the handshake (host moderation). Persist it yourself; set it again after a restart.
    public var bannedIPs: Set<String> {
        get { banned }
        set { banned = newValue }
    }
    /// Bytes sent / received on the game socket since `start()` (UDP payload plus ENet framing).
    public var bytesSent: UInt64 { sentTotal }
    public var bytesReceived: UInt64 { receivedTotal }

    /// The `NSB1` payload describing this game (LAN beacon and `NSQ1` reply). Safe to call from any thread.
    public func beacon() -> ServerBeacon {
        beaconLock.lock(); defer { beaconLock.unlock() }
        let c = beaconConfig
        return ServerBeacon(name: c.serverName, players: beaconPlayers, max: c.maxPlayers, ver: c.gameVersion,
                            pw: !c.password.isEmpty, port: c.port, rules: c.rulesName, dedicated: c.dedicated,
                            requirements: c.requirements)
    }

    /// Remove a client (host moderation). Call `NetSession.kick` first so its in-session goodbye goes out too.
    @discardableResult
    public func kick(_ id: Int, reason: String = "Kicked by the host.", ban: Bool = false) -> Bool {
        guard let c = conns[id] else { return false }
        flushOutgoing()   // the NetSession's own kick message must precede the control kick
        if ban, !c.ip.isEmpty { banned.insert(c.ip) }
        sendControl(id, Kind.kick, ["reason": reason])
        forget(id, reason: "kicked")
        closing[id] = clock + 0.3
        return true
    }

    // MARK: Pump

    public func service() {
        guard let host, isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        clock += now - lastService
        lastService = now
        var event = ENetEvent()
        while enet_host_service(host, &event, 0) > 0 {
            if Self.debug { print("ENETDBG event \(event.type.rawValue) data=\(event.data) ch=\(event.channelID)") }
            switch event.type {
            case ENET_EVENT_TYPE_CONNECT:
                let id = Int(event.data)
                guard let p = event.peer else { break }
                if id < 2 || conns[id] != nil {
                    enet_peer_reset(p)        // Godot does the same: ids below 2 or already in use are refused
                    break
                }
                var buf = [CChar](repeating: 0, count: 64)
                enet_address_get_host_ip(&p.pointee.address, &buf, 64)
                let ip = String(cString: buf)
                if let until = tempBanUntil[ip], until > clock { enet_peer_reset(p); break }
                let limit = config.maxConnectionsPerIP
                if limit > 0, ip != "127.0.0.1", conns.values.filter({ $0.ip == ip }).count >= limit {
                    enet_peer_reset(p); break      // one address can't hold every slot
                }
                p.pointee.data = UnsafeMutableRawPointer(bitPattern: id)
                let c = Conn(peer: p, now: clock)
                c.ip = ip
                conns[id] = c
            case ENET_EVENT_TYPE_RECEIVE:
                if let pkt = event.packet {
                    let reliable = (pkt.pointee.flags & ENET_PACKET_FLAG_RELIABLE.rawValue) != 0
                    let bytes = Array(UnsafeBufferPointer(start: pkt.pointee.data, count: pkt.pointee.dataLength))
                    enet_packet_destroy(pkt)
                    if let raw = event.peer?.pointee.data {
                        handle(from: Int(bitPattern: raw), reliable: reliable, bytes)
                    }
                }
            case ENET_EVENT_TYPE_DISCONNECT:
                if let raw = event.peer?.pointee.data {
                    let id = Int(bitPattern: raw)
                    closing[id] = nil
                    forget(id, reason: "left")
                    conns[id] = nil
                }
            default: break
            }
        }
        timers()
        flushOutgoing()
        enet_host_flush(host)
        sentTotal += UInt64(host.pointee.totalSentData); host.pointee.totalSentData = 0
        receivedTotal += UInt64(host.pointee.totalReceivedData); host.pointee.totalReceivedData = 0
    }

    private func timers() {
        for (id, until) in closing where clock >= until {
            closing[id] = nil
            if let c = conns[id] { enet_peer_disconnect_now(c.peer, 0); conns[id] = nil }
        }
        for (id, c) in conns where closing[id] == nil {
            if c.ready {
                if clock - c.lastRx > idleTimeout { drop(id, "timeout") }
            } else if clock - c.t0 > handshakeTimeout {
                drop(id, "handshake timeout")
            }
        }
    }

    private func drop(_ id: Int, _ reason: String) {
        guard let c = conns[id] else { return }
        forget(id, reason: reason)
        enet_peer_disconnect_now(c.peer, 0)
        conns[id] = nil
    }

    // MARK: Packets

    private enum Kind {
        static let hello = ENetTransport.Wire.kHello, welcome = ENetTransport.Wire.kWelcome, reject = ENetTransport.Wire.kReject
        static let peerJoin = ENetTransport.Wire.kPeerJoin, peerLeft = ENetTransport.Wire.kPeerLeft, kick = ENetTransport.Wire.kKick
        static let ping = ENetTransport.Wire.kPing, pong = ENetTransport.Wire.kPong, chat = ENetTransport.Wire.kChat
        static let data = ENetTransport.Wire.kData, report = ENetTransport.Wire.kReport
    }

    private func handle(from id: Int, reliable: Bool, _ pkt: [UInt8]) {
        guard let c = conns[id], closing[id] == nil, let kind = pkt.first else { return }
        c.lastRx = clock
        // Size cap per kind, then the per-connection packet and byte budgets. Anything over is dropped, and a
        // connection that keeps going is kicked (and, if it keeps coming back, its address is blocked for a while).
        let cap: Int
        switch kind {
        case Kind.hello: cap = NetLimits.maxHello
        case Kind.data: cap = NetLimits.maxData
        case Kind.ping, Kind.chat, Kind.report: cap = NetLimits.maxSmallControl
        default: return                       // unknown kinds are ignored
        }
        if pkt.count > cap { return violation(id, c, weight: 10, "sent an oversized packet") }
        guard c.packets.take(now: clock), c.bytes.take(Double(pkt.count), now: clock) else {
            return violation(id, c, weight: 1, "sent too much data too fast")
        }
        if !c.ready, kind != Kind.hello, kind != Kind.ping { return violation(id, c, weight: 2, "sent game data before joining") }
        switch kind {
        case Kind.hello: hello(id, c, Self.json(pkt))
        case Kind.data: relay(id, c, reliable: reliable, pkt)
        case Kind.ping:
            let j = Self.json(pkt)
            c.rtt = max(-1, min(60_000, Self.int(j["rtt"]) ?? -1))
            sendControl(id, Kind.pong, ["t": (j["t"] as? Double) ?? 0.0], reliable: false)
        case Kind.chat: chat(id, c, Self.json(pkt))
        case Kind.report: report(id, c, Self.json(pkt))
        default: break
        }
    }

    private func hello(_ id: Int, _ c: Conn, _ h: [String: Any]) {
        if c.ready { return }
        if h.isEmpty { noteHandshakeFailure(c); return reject(id, "bad_request", "Bad handshake.") }
        let proto = Self.int(h["proto"]) ?? 0
        if proto != CrossPlayProtocol.version {
            return reject(id, "proto", "This server speaks a different multiplayer protocol (server \(CrossPlayProtocol.version), you \(proto)). Update NovaSwift.")
        }
        // A different app release with the same protocol is fine: note it and carry on.
        let ver = String(CrossPlayProtocol.cleanName((h["version"] as? String) ?? "", fallback: "", maxLength: 32))
        let differentVersion = !ver.isEmpty && ver != config.gameVersion
        let theirPW = String(((h["pw"] as? String) ?? "").prefix(128))
        if !config.password.isEmpty, ENetTransport.hashPassword(config.password) != theirPW {
            // Online password guessing: a few wrong tries are normal typos, a stream of them blocks the address.
            noteHandshakeFailure(c)
            return reject(id, "password", theirPW.isEmpty ? "This server needs a password." : "Wrong password.")
        }
        if !c.ip.isEmpty, banned.contains(c.ip) { return reject(id, "banned", "You are banned from this server.") }
        if let refusal = joinGate?(c.ip, CrossPlayProtocol.cleanPlayerName((h["name"] as? String) ?? "", fallback: "Pilot")) {
            return reject(id, refusal.code, refusal.message)
        }
        if clients.count >= clientCapacity {
            return reject(id, "full", "The server is full (\(playerCount)/\(config.maxPlayers)).")
        }
        let theirs = (h["manifest"] as? String).flatMap { $0.utf8.count <= NetLimits.maxHello ? $0 : nil } ?? ""
        if !config.manifestJSON.isEmpty, !theirs.isEmpty, !Self.sameManifest(config.manifestJSON, theirs) {
            return reject(id, "plugins", "Your enabled plug-ins don't match the server's. Match its plug-in list, then rejoin.",
                          detail: ["server_manifest": config.manifestJSON, "client_manifest": theirs])
        }
        let name = uniqueName(CrossPlayProtocol.cleanPlayerName((h["name"] as? String) ?? "", fallback: "Pilot \(id)"), excluding: id)
        c.name = name; c.ready = true
        publishPlayerCount()
        var list: [[String: Any]] = config.dedicated ? [] : [["id": ENetTransport.Wire.serverID, "name": config.hostName]]
        for (oid, o) in conns where oid != id && o.ready { list.append(["id": oid, "name": o.name]) }
        sendControl(id, Kind.welcome, [
            "your_id": id, "server_name": config.serverName, "host_name": config.dedicated ? "[Server]" : config.hostName,
            "has_local_player": !config.dedicated,
            "rules": config.rulesJSON, "peers": list, "max": config.maxPlayers, "proto": CrossPlayProtocol.version,
        ])
        for (oid, o) in conns where oid != id && o.ready { sendControl(oid, Kind.peerJoin, ["id": id, "name": name]) }
        inner.peerConnected(id: id, name: name)   // -> NetSession: presence, rules, plug-in manifest (queued after WELCOME)
        emit(.peerJoined(id: id, name: name))
        if differentVersion { emit(.versionNote(id: id, name: name, theirs: ver, ours: config.gameVersion)) }
    }

    private func uniqueName(_ want: String, excluding id: Int) -> String {
        func key(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        var taken: Set<String> = config.dedicated ? [] : [key(config.hostName)]
        for (oid, o) in conns where oid != id && o.ready { taken.insert(key(o.name)) }
        var name = want
        var n = 2
        while taken.contains(key(name)) {
            let suffix = " (\(n))"
            name = String(want.prefix(CrossPlayProtocol.maxNameLength - suffix.count)) + suffix; n += 1
        }
        return name
    }

    private func reject(_ id: Int, _ code: String, _ message: String, detail: [String: Any] = [:]) {
        guard let c = conns[id] else { return }
        sendControl(id, Kind.reject, ["code": code, "message": message, "detail": detail])
        emit(.refused(code: code, message: message, ip: c.ip))
        closing[id] = clock + 0.3     // let the REJECT flush before the link goes down
    }

    private func relay(_ id: Int, _ c: Conn, reliable: Bool, _ pkt: [UInt8]) {
        guard c.ready, pkt.count >= 5 else { return }
        let target = Int(Int32(bitPattern: UInt32(pkt[1]) | UInt32(pkt[2]) << 8 | UInt32(pkt[3]) << 16 | UInt32(pkt[4]) << 24))
        var payload = Array(pkt[5...])
        if let f = relayFilter {
            guard let out = f(id, payload) else { return }
            payload = out
        }
        if target == -1 || target == ENetTransport.Wire.serverID { inner.receive(from: id, data: payload) }
        if target == -1 {
            let out = Self.dataPacket(peer: id, payload: payload)
            for (oid, o) in conns where oid != id && o.ready { sendRaw(oid, out, reliable: reliable) }
        } else if target != ENetTransport.Wire.serverID, let t = conns[target], t.ready {
            sendRaw(target, Self.dataPacket(peer: id, payload: payload), reliable: reliable)
        }
    }

    private func chat(_ id: Int, _ c: Conn, _ b: [String: Any]) {
        guard c.ready else { return }
        var text = CrossPlayProtocol.cleanChat((b["text"] as? String) ?? "")
        guard !text.isEmpty else { return }
        if !allowChat(c) { return violation(id, c, weight: 5, "is spamming chat") }
        if text.hasPrefix("/"), let onCommand { onCommand(id, c.name, c.ip, text); return }
        if let f = chatFilter { guard let t = f(id, c.name, c.ip, text) else { return }; text = t }
        for (oid, o) in conns where o.ready { sendControl(oid, Kind.chat, ["id": id, "name": c.name, "text": text]) }
        emit(.chat(id: id, name: c.name, text: text))
    }

    /// Spend a chat token (burst 4, 2/s) and refuse a line repeated three times in 10 seconds.
    private func allowChat(_ c: Conn, text: String = "") -> Bool {
        guard c.chat.take(now: clock) else { return false }
        return true
    }

    private func report(_ id: Int, _ c: Conn, _ b: [String: Any]) {
        guard c.ready else { return }
        guard c.reports.take(now: clock) else { return violation(id, c, weight: 3, "is sending too many reports") }
        let target = max(0, min(Int(Int32.max), Self.int(b["id"]) ?? 0))
        let reason = String(CrossPlayProtocol.cleanName((b["reason"] as? String) ?? "", fallback: "abuse", maxLength: 16)).lowercased()
        let detail = CrossPlayProtocol.cleanChat((b["detail"] as? String) ?? "")
        emit(.report(reporter: id, target: target, reason: reason, detail: String(detail.prefix(120))))
    }

    // MARK: Abuse handling

    /// A connection broke a limit. Weighted strikes accumulate in a 30 s window; past `NetLimits.violationsToKick` it is
    /// kicked, and an address kicked `abuseKicksToTempBan` times in 10 minutes is blocked for `tempBanSeconds`.
    private func violation(_ id: Int, _ c: Conn, weight: Int, _ what: String) {
        if clock - c.violationsSince > 30 { c.violations = 0; c.violationsSince = clock }
        c.violations += weight
        if Self.debug { print("ENETDBG violation \(id) \(what) -> \(c.violations)") }
        if c.violations >= NetLimits.violationsToKick { abuseKick(id, c, what) }
    }

    private func abuseKick(_ id: Int, _ c: Conn, _ what: String) {
        var banned = false
        if !c.ip.isEmpty, c.ip != "127.0.0.1" {
            var list = (abuseKicks[c.ip] ?? []).filter { clock - $0 < 600 }
            list.append(clock)
            abuseKicks[c.ip] = list
            if list.count >= NetLimits.abuseKicksToTempBan { tempBanUntil[c.ip] = clock + config.tempBanSeconds; banned = true }
            if abuseKicks.count > 4096 { abuseKicks = abuseKicks.filter { ($0.value.last ?? 0) > clock - 600 } }
        }
        emit(.abuse(id: id, name: c.name, ip: c.ip, reason: what, banned: banned))
        sendControl(id, Kind.kick, ["reason": "Disconnected: the connection \(what)."])
        forget(id, reason: "abuse")
        closing[id] = clock + 0.3
    }

    private func noteHandshakeFailure(_ c: Conn) {
        guard !c.ip.isEmpty, c.ip != "127.0.0.1" else { return }
        var list = (handshakeFailures[c.ip] ?? []).filter { clock - $0 < 60 }
        list.append(clock)
        handshakeFailures[c.ip] = list
        if list.count >= 10 {
            tempBanUntil[c.ip] = clock + config.tempBanSeconds
            handshakeFailures[c.ip] = nil
            emit(.abuse(id: 0, name: "", ip: c.ip, reason: "failed the handshake or password too many times", banned: true))
        }
        if handshakeFailures.count > 4096 { handshakeFailures = handshakeFailures.filter { ($0.value.last ?? 0) > clock - 60 } }
    }

    /// Kick a connection for abuse found above this layer (e.g. the session saw repeated invalid messages).
    public func reportAbuse(_ id: Int, _ what: String) {
        if let c = conns[id], c.ready { abuseKick(id, c, what) }
    }

    /// Send a server chat line to one player.
    public func sendServerChat(_ text: String, to id: Int) {
        sendControl(id, Kind.chat, ["id": ENetTransport.Wire.serverID, "name": "[Server]", "text": text])
    }

    /// Lift a temporary block (admin action).
    public func clearTempBan(_ ip: String) { tempBanUntil[ip] = nil; abuseKicks[ip] = nil; handshakeFailures[ip] = nil }

    private func forget(_ id: Int, reason: String) {
        guard let c = conns[id], c.ready else { return }
        c.ready = false
        publishPlayerCount()
        for (oid, o) in conns where oid != id && o.ready { sendControl(oid, Kind.peerLeft, ["id": id, "reason": reason]) }
        inner.peerDisconnected(id: id)
        emit(.peerLeft(id: id, name: c.name, reason: reason))
    }

    // MARK: Sending

    private func flushOutgoing() {
        for m in inner.drainOutgoing() {
            let out = Self.dataPacket(peer: ENetTransport.Wire.serverID, payload: m.data)
            if m.to == ExternalTransport.broadcastTarget {
                for (oid, o) in conns where o.ready { sendRaw(oid, out, reliable: m.reliable) }
            } else if let o = conns[m.to], o.ready {
                sendRaw(m.to, out, reliable: m.reliable)
            }
        }
    }

    private static func dataPacket(peer: Int, payload: [UInt8]) -> [UInt8] {
        var pkt = [Kind.data]
        var t = UInt32(bitPattern: Int32(truncatingIfNeeded: peer)).littleEndian
        withUnsafeBytes(of: &t) { pkt.append(contentsOf: $0) }
        return pkt + payload
    }

    private func sendControl(_ id: Int, _ kind: UInt8, _ body: [String: Any], reliable: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        sendRaw(id, [kind] + [UInt8](data), reliable: reliable)
    }

    private func sendRaw(_ id: Int, _ bytes: [UInt8], reliable: Bool) {
        guard let c = conns[id] else { return }
        let flags: UInt32 = reliable ? ENET_PACKET_FLAG_RELIABLE.rawValue
            : (ENET_PACKET_FLAG_UNSEQUENCED.rawValue | ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT.rawValue)
        guard let packet = bytes.withUnsafeBufferPointer({ enet_packet_create($0.baseAddress, $0.count, flags) }) else { return }
        // Godot's unreliable channel is ENet 2; fall back to the highest channel the peer negotiated.
        let top = max(0, Int(c.peer.pointee.channelCount) - 1)
        let channel = reliable ? ENetTransport.Wire.chReliable : UInt8(min(Int(ENetTransport.Wire.chUnreliable), top))
        if enet_peer_send(c.peer, channel, packet) != 0 { enet_packet_destroy(packet) }
    }

    // MARK: Helpers

    private func teardown() {
        if let host { enet_host_destroy(host) }
        host = nil
    }

    private func emit(_ e: Event) { onEvent?(e) }

    private static func json(_ pkt: [UInt8]) -> [String: Any] {
        guard pkt.count >= 2, pkt.count <= 65536,
              let o = try? JSONSerialization.jsonObject(with: Data(pkt[1...])) as? [String: Any] else { return [:] }
        return o
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    /// Gameplay plug-in sets match when they list the same ids with matching (possibly truncated) hashes; key order,
    /// names, whitespace and cosmetic entries don't matter. (Godot compares canonical JSON of the same list.)
    public static func sameManifest(_ a: String, _ b: String) -> Bool {
        func parse(_ s: String) -> [String: String]? {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
                  let plugins = o["plugins"] as? [[String: Any]], plugins.count <= NetLimits.maxManifestEntries else { return nil }
            var d: [String: String] = [:]
            for p in plugins where (p["cosmetic"] as? Bool) != true {
                d[(p["id"] as? String) ?? ""] = (p["contentHash"] as? String) ?? (p["hash"] as? String) ?? ""
            }
            return d
        }
        guard let x = parse(a), let y = parse(b) else { return a == b }
        return Set(x.keys) == Set(y.keys) && x.allSatisfy { PluginRequirements.hashesMatch($0.value, y[$0.key] ?? "") }
    }
}
