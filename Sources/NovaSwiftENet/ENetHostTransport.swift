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
        public init(port: Int = CrossPlayProtocol.defaultPort, maxPlayers: Int = 8, serverName: String, hostName: String,
                    password: String = "", gameVersion: String = CrossPlayProtocol.appVersion, manifestJSON: String = "",
                    rulesJSON: String = "{}", rulesName: String = "custom", requirements: PluginRequirements? = nil, loopbackOnly: Bool = false) {
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
        init(peer: UnsafeMutablePointer<ENetPeer>, now: Double) { self.peer = peer; t0 = now; lastRx = now }
    }

    // MARK: State

    public private(set) var config: Config
    public let inner = ExternalTransport(localPeerID: ENetTransport.Wire.serverID)
    public var localPeerID: PeerID { inner.localPeerID }
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

    private var host: UnsafeMutablePointer<ENetHost>?
    private var conns: [Int: Conn] = [:]
    private var banned = Set<String>()
    private var closing: [Int: Double] = [:]
    private var clock = 0.0
    private var lastService = ProcessInfo.processInfo.systemUptime
    private var pumpTimer: DispatchSourceTimer?
    private static let debug = ProcessInfo.processInfo.environment["NOVASWIFT_ENET_DEBUG"] != nil
    private static let initOnce: Void = { _ = enet_initialize() }()

    public init(config: Config) {
        _ = Self.initOnce
        self.config = config
        self.beaconConfig = config
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
        host = h
        isRunning = true
        clock = 0
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

    /// Update the advertised content (after the host's plug-in set changes).
    public func updateRequirements(_ r: PluginRequirements?) {
        config.requirements = r
        beaconLock.lock(); beaconConfig = config; beaconLock.unlock()
    }

    private func publishPlayerCount() {
        let n = clients.count + 1
        beaconLock.lock(); beaconPlayers = n; beaconLock.unlock()
    }

    // MARK: Roster / beacon

    /// Players that finished the handshake (host not included).
    public var clients: [PeerInfo] {
        conns.filter { $0.value.ready }.map { PeerInfo(id: $0.key, name: $0.value.name, ip: $0.value.ip, rttMilliseconds: $0.value.rtt) }
            .sorted { $0.id < $1.id }
    }
    public var playerCount: Int { clients.count + 1 }

    /// The `NSB1` payload describing this game (LAN beacon and `NSQ1` reply). Safe to call from any thread.
    public func beacon() -> ServerBeacon {
        beaconLock.lock(); defer { beaconLock.unlock() }
        let c = beaconConfig
        return ServerBeacon(name: c.serverName, players: beaconPlayers, max: c.maxPlayers, ver: c.gameVersion,
                            pw: !c.password.isEmpty, port: c.port, rules: c.rulesName, dedicated: false,
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
                p.pointee.data = UnsafeMutableRawPointer(bitPattern: id)
                let c = Conn(peer: p, now: clock)
                var buf = [CChar](repeating: 0, count: 64)
                enet_address_get_host_ip(&p.pointee.address, &buf, 64)
                c.ip = String(cString: buf)
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
        static let data = ENetTransport.Wire.kData
    }

    private func handle(from id: Int, reliable: Bool, _ pkt: [UInt8]) {
        guard let c = conns[id], closing[id] == nil, let kind = pkt.first else { return }
        c.lastRx = clock
        switch kind {
        case Kind.hello: hello(id, c, Self.json(pkt))
        case Kind.data: relay(id, c, reliable: reliable, pkt)
        case Kind.ping:
            c.rtt = Self.int(Self.json(pkt)["rtt"]) ?? -1
            sendControl(id, Kind.pong, ["t": Self.json(pkt)["t"] ?? 0.0], reliable: false)
        case Kind.chat: chat(id, c, Self.json(pkt))
        default: break
        }
    }

    private func hello(_ id: Int, _ c: Conn, _ h: [String: Any]) {
        if c.ready { return }
        if h.isEmpty { return reject(id, "bad_request", "Bad handshake.") }
        let proto = Self.int(h["proto"]) ?? 0
        if proto != CrossPlayProtocol.version {
            return reject(id, "proto", "This server speaks a different multiplayer protocol (server \(CrossPlayProtocol.version), you \(proto)). Update NovaSwift.")
        }
        // A different app release with the same protocol is fine: note it and carry on.
        let ver = (h["version"] as? String) ?? ""
        let differentVersion = !ver.isEmpty && ver != config.gameVersion
        let theirPW = (h["pw"] as? String) ?? ""
        if !config.password.isEmpty, ENetTransport.hashPassword(config.password) != theirPW {
            return reject(id, "password", theirPW.isEmpty ? "This server needs a password." : "Wrong password.")
        }
        if !c.ip.isEmpty, banned.contains(c.ip) { return reject(id, "banned", "You are banned from this server.") }
        if clients.count >= config.maxPlayers - 1 {
            return reject(id, "full", "The server is full (\(playerCount)/\(config.maxPlayers)).")
        }
        let theirs = (h["manifest"] as? String) ?? ""
        if !config.manifestJSON.isEmpty, !theirs.isEmpty, !Self.sameManifest(config.manifestJSON, theirs) {
            return reject(id, "plugins", "Your enabled plug-ins don't match the server's. Match its plug-in list, then rejoin.",
                          detail: ["server_manifest": config.manifestJSON, "client_manifest": theirs])
        }
        let name = uniqueName(CrossPlayProtocol.cleanName((h["name"] as? String) ?? "", fallback: "Pilot \(id)"), excluding: id)
        c.name = name; c.ready = true
        publishPlayerCount()
        var list: [[String: Any]] = [["id": ENetTransport.Wire.serverID, "name": config.hostName]]
        for (oid, o) in conns where oid != id && o.ready { list.append(["id": oid, "name": o.name]) }
        sendControl(id, Kind.welcome, [
            "your_id": id, "server_name": config.serverName, "host_name": config.hostName, "has_local_player": true,
            "rules": config.rulesJSON, "peers": list, "max": config.maxPlayers, "proto": CrossPlayProtocol.version,
        ])
        for (oid, o) in conns where oid != id && o.ready { sendControl(oid, Kind.peerJoin, ["id": id, "name": name]) }
        inner.peerConnected(id: id, name: name)   // -> NetSession: presence, rules, plug-in manifest (queued after WELCOME)
        emit(.peerJoined(id: id, name: name))
        if differentVersion { emit(.versionNote(id: id, name: name, theirs: ver, ours: config.gameVersion)) }
    }

    private func uniqueName(_ want: String, excluding id: Int) -> String {
        var taken: Set<String> = [config.hostName.lowercased()]
        for (oid, o) in conns where oid != id && o.ready { taken.insert(o.name.lowercased()) }
        var name = want
        var n = 2
        while taken.contains(name.lowercased()) { name = "\(want) (\(n))"; n += 1 }
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
        let payload = Array(pkt[5...])
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
        let text = String(((b["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !text.isEmpty else { return }
        for (oid, o) in conns where o.ready { sendControl(oid, Kind.chat, ["id": id, "name": c.name, "text": text]) }
        emit(.chat(id: id, name: c.name, text: text))
    }

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
                  let plugins = o["plugins"] as? [[String: Any]] else { return nil }
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
