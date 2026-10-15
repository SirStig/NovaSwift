import Foundation
import CENet
import NovaSwiftNet
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A `NovaSwiftNet.Transport` that joins a **Godot / dedicated-server** game over ENet by `host:port`.
///
/// The Godot build (Linux, Windows, Steam Deck) hosts with `ENetMultiplayerPeer` plus its own small
/// application protocol (`godot/net/NetProto.gd`, `NetTransport.gd`). This class is the Apple-side client
/// for exactly that protocol, so an iPhone / iPad / Mac / Apple TV can sit in the same session as Godot
/// players. It is a *client* only (hosting from Apple stays Game Center / Multipeer); see
/// docs/MULTIPLAYER.md, "Cross-play with the Apple app", for the wire spec this implements.
///
/// Layering: an inner `ExternalTransport` (the byte pipe `NetSession` already knows) carries the game
/// bytes; this class owns the ENet socket, the handshake and the control packets, and pumps the two
/// together in `service()`.
///
/// Threading: ENet is not thread-safe. Call `service()` yourself from one thread, or call
/// `startPumping()` and never touch it directly. `Transport` methods (`send`, `broadcast`) are safe from
/// any thread; they only enqueue.
///
/// Addressing: the vendored ENet is dual-stack (IPv4 stored IPv4-mapped in a 16 byte address, one AF_INET6 socket).
/// `host` may be an IPv4 or IPv6 literal (bare or `[bracketed]`) or a host name; names and IPv4 literals resolve
/// through getaddrinfo, so an IPv6-only NAT64 network (Apple App Review) connects through its synthesized address.
/// Limits: no encryption (the password is sent as a SHA-256 hash, same as Godot).
public final class ENetTransport: Transport, TransportDelegate {

    // MARK: Wire constants (mirror godot/net/NetProto.gd)

    public enum Wire {
        public static let protocolVersion = CrossPlayProtocol.version
        public static let defaultPort = 53735
        public static let serverID = 1
        // First byte of every packet.
        static let kHello: UInt8 = 0x01, kWelcome: UInt8 = 0x02, kReject: UInt8 = 0x03, kPeerJoin: UInt8 = 0x04
        static let kPeerLeft: UInt8 = 0x05, kKick: UInt8 = 0x06, kPing: UInt8 = 0x07, kPong: UInt8 = 0x08
        static let kChat: UInt8 = 0x09, kReport: UInt8 = 0x0A, kData: UInt8 = 0x10
        // ENet channels as Godot's ENetMultiplayerPeer maps them (SYSCH_RELIABLE=0, SYSCH_UNRELIABLE=1, user ch1 = 2).
        static let chReliable: UInt8 = 0
        static let chUnreliable: UInt8 = 2
        static let channelCount = 3
        static let connectTimeout = 10.0, handshakeTimeout = 8.0, idleTimeout = 20.0, pingEvery = 2.0
    }

    public struct Config {
        public var host: String
        public var port: Int
        public var displayName: String
        public var password: String
        /// The app release string; informational (the gate is `CrossPlayProtocol.version`).
        public var gameVersion: String
        /// `ENetTransport.manifestJSON(_:)` of this player's enabled plug-ins; "" skips the check.
        public var manifestJSON: String
        public init(host: String, port: Int = Wire.defaultPort, displayName: String, password: String = "",
                    gameVersion: String, manifestJSON: String = "") {
            self.host = host; self.port = port; self.displayName = displayName
            self.password = password; self.gameVersion = gameVersion; self.manifestJSON = manifestJSON
        }
    }

    public enum State: Equatable { case idle, connecting, handshaking, connected, closed }

    /// UI-level events, delivered from `service()`.
    public enum Event: Equatable {
        /// Handshake done. Peers are announced to the delegate right AFTER this callback returns, so create
        /// the `NetSession` (which sets the delegate) in here.
        case connected(serverName: String, hostName: String, rulesJSON: String, hasHostPlayer: Bool, maxPlayers: Int)
        /// Refused: `code` is "version", "proto", "password", "full", "plugins", "banned" or "bad_request".
        case rejected(code: String, message: String)
        case kicked(reason: String)
        case timedOut(String)
        case disconnected(reason: String)
        case chat(id: Int, name: String, text: String)
    }

    // MARK: State

    public let config: Config
    /// The id the server will use for us (we choose it; ENet carries it as the connect data).
    public let localID: Int
    public var localPeerID: PeerID { inner.localPeerID }
    /// The relay server / host is always peer 1.
    public var hostPeerID: PeerID? { String(Wire.serverID) }
    public private(set) var state: State = .idle
    public private(set) var serverName = ""
    public private(set) var rttMilliseconds = -1
    /// After a `.rejected(code: "plugins")`: the server's manifest JSON (REJECT `detail.server_manifest`), for the
    /// "what do I need to install" diff. Additive; nil otherwise.
    public private(set) var rejectServerManifest: String?
    public var onEvent: ((Event) -> Void)?
    /// Seconds to wait for ENet to connect / the server to answer HELLO (Godot uses 10 / 8).
    public var connectTimeout = Wire.connectTimeout
    public var handshakeTimeout = Wire.handshakeTimeout

    /// The pipe `NetSession` talks to (also usable directly). Its delegate is forwarded.
    public let inner: ExternalTransport
    public weak var delegate: TransportDelegate?

    public var connectedPeers: [PeerID] { inner.connectedPeers }

    private var host: UnsafeMutablePointer<ENetHost>?
    private var peer: UnsafeMutablePointer<ENetPeer>?
    private var clock = 0.0
    private var lastService = ProcessInfo.processInfo.systemUptime
    private var stateSince = 0.0
    private var lastRx = 0.0
    private var nextPing = 0.0
    private var closedReason = ""
    /// Most other players one session can announce to us (a server allows 64).
    static let maxPeers = 256
    private var pumpQueue: DispatchQueue?
    private var pumpTimer: DispatchSourceTimer?
    private static let initOnce: Void = { _ = enet_initialize() }()

    public init(config: Config, localID: Int? = nil) {
        _ = Self.initOnce
        self.config = config
        let id = localID ?? Int.random(in: 2...Int(Int32.max - 1))   // Godot refuses ids < 2 and duplicates
        self.localID = id
        self.inner = ExternalTransport(localPeerID: id)
        self.inner.delegate = self
    }

    deinit { teardown() }

    // MARK: Transport

    public func send(_ data: Data, to peer: PeerID, channel: NetChannel) { inner.send(data, to: peer, channel: channel) }
    public func broadcast(_ data: Data, channel: NetChannel) { inner.broadcast(data, channel: channel) }

    /// Leave: flush a final packet, send an ENet disconnect, free the socket.
    public func disconnect() {
        guard state != .closed && state != .idle else { return }
        flushOutgoing()
        inner.disconnect()
        if let peer = peer, let host = host {
            enet_peer_disconnect_now(peer, 0)
            enet_host_flush(host)
        }
        finish(.closed)
        emit(.disconnected(reason: "Left the game."))
    }

    // MARK: TransportDelegate forwarding

    public func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID) {
        delegate?.transport(self, didReceive: data, from: peer)
    }
    public func transport(_ transport: Transport, peerDidConnect peer: PeerID) {
        delegate?.transport(self, peerDidConnect: peer)
    }
    public func transport(_ transport: Transport, peerDidDisconnect peer: PeerID) {
        delegate?.transport(self, peerDidDisconnect: peer)
    }

    // MARK: Connecting

    public enum ConnectError: Error, Equatable { case alreadyStarted, cannotResolve(String), enetFailure }

    /// Start connecting (asynchronous: watch `onEvent`). Resolves the host name synchronously.
    public func connect() throws {
        guard state == .idle else { throw ConnectError.alreadyStarted }
        var address = ENetAddress()
        var hostText = config.host.trimmingCharacters(in: .whitespaces)
        if hostText.hasPrefix("["), hostText.hasSuffix("]") { hostText = String(hostText.dropFirst().dropLast()) }
        guard enet_address_set_host(&address, hostText) == 0 else { throw ConnectError.cannotResolve(config.host) }
        address.port = UInt16(clamping: config.port)
        guard let h = enet_host_create(nil, 1, Wire.channelCount, 0, 0),
              let p = enet_host_connect(h, &address, Wire.channelCount, UInt32(localID)) else {
            throw ConnectError.enetFailure
        }
        host = h; peer = p
        state = .connecting
        clock = 0; stateSince = 0; lastRx = 0; nextPing = 0
        lastService = ProcessInfo.processInfo.systemUptime
    }

    /// Pump on a private queue every `interval` seconds (events arrive on that queue).
    public func startPumping(interval: TimeInterval = 0.01, queue: DispatchQueue = DispatchQueue(label: "novaswift.enet")) {
        guard pumpTimer == nil else { return }
        pumpQueue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.service() }
        pumpTimer = t
        t.resume()
    }

    public func stopPumping() {
        pumpTimer?.cancel(); pumpTimer = nil
    }

    // MARK: Pump

    /// One tick: read the socket, run handshake / timers, send what `NetSession` queued.
    public func service() {
        guard let host = host, state != .idle, state != .closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        clock += now - lastService
        lastService = now
        var event = ENetEvent()
        while state != .closed, enet_host_service(host, &event, 0) > 0 {
            switch event.type {
            case ENET_EVENT_TYPE_CONNECT:
                state = .handshaking; stateSince = clock; lastRx = clock
                sendHello()
            case ENET_EVENT_TYPE_RECEIVE:
                if let pkt = event.packet {
                    let bytes = Array(UnsafeBufferPointer(start: pkt.pointee.data, count: pkt.pointee.dataLength))
                    enet_packet_destroy(pkt)
                    handle(bytes)
                }
            case ENET_EVENT_TYPE_DISCONNECT:
                if state == .connecting || state == .handshaking {
                    let r = closedReason
                    finish(.closed)
                    emit(r.isEmpty ? .timedOut("Couldn't reach \(IPAddressTools.joinHostPort(config.host, config.port)). Check the address, that the server is running, and that UDP \(config.port) is open.") : .rejected(code: "refused", message: r))
                } else {
                    let r = closedReason.isEmpty ? "Lost the connection to the server." : closedReason
                    finish(.closed); emit(.disconnected(reason: r))
                }
            default: break
            }
        }
        guard state != .closed else { return }
        if state == .connecting, clock - stateSince > connectTimeout {
            finish(.closed); emit(.timedOut("Timed out connecting to \(config.host):\(config.port)."))
            return
        }
        if state == .handshaking, clock - stateSince > handshakeTimeout {
            finish(.closed); emit(.timedOut("\(config.host):\(config.port) didn't answer the handshake. It may be a different game or a stalled server."))
            return
        }
        if state == .connected {
            if clock >= nextPing {
                nextPing = clock + Wire.pingEvery
                sendControl(Wire.kPing, ["t": clock, "rtt": rttMilliseconds], reliable: false)
            }
            if clock - lastRx > Wire.idleTimeout {
                finish(.closed); emit(.timedOut("The server stopped responding."))
                return
            }
            flushReports()
            flushOutgoing()
        }
        enet_host_flush(host)
    }

    // MARK: Packets

    private func handle(_ pkt: [UInt8]) {
        guard let kind = pkt.first else { return }
        lastRx = clock
        switch kind {
        case Wire.kWelcome: welcome(Self.json(pkt))
        case Wire.kReject:
            let b = Self.json(pkt)
            closedReason = String(CrossPlayProtocol.cleanChat((b["message"] as? String) ?? "").prefix(300)).nonEmpty ?? "The server refused the connection."
            let code = (b["code"] as? String) ?? "refused"
            rejectServerManifest = (b["detail"] as? [String: Any])?["server_manifest"] as? String
            finish(.closed); emit(.rejected(code: code, message: closedReason))
        case Wire.kPeerJoin:
            guard state == .connected else { return }
            let b = Self.json(pkt)
            if let id = Self.int(b["id"]), id >= 2, id != localID, inner.connectedPeers.count < Self.maxPeers {
                inner.peerConnected(id: id, name: CrossPlayProtocol.cleanPlayerName((b["name"] as? String) ?? "", fallback: "Pilot \(id)"))
            }
        case Wire.kPeerLeft:
            if let id = Self.int(Self.json(pkt)["id"]), id >= 2 { inner.peerDisconnected(id: id) }
        case Wire.kKick:
            let why = String(CrossPlayProtocol.cleanChat((Self.json(pkt)["reason"] as? String) ?? "").prefix(200)).nonEmpty ?? "Disconnected by the host."
            inner.disconnect(); finish(.closed); emit(.kicked(reason: why))
        case Wire.kPong:
            let sent = (Self.json(pkt)["t"] as? Double) ?? clock
            let ms = Int(((clock - sent) * 1000).rounded())
            rttMilliseconds = rttMilliseconds < 0 ? ms : Int((Double(rttMilliseconds) * 0.7 + Double(ms) * 0.3).rounded())
        case Wire.kChat:
            let b = Self.json(pkt)
            let text = CrossPlayProtocol.cleanChat((b["text"] as? String) ?? "")
            guard !text.isEmpty else { return }
            emit(.chat(id: Self.int(b["id"]) ?? 0, name: CrossPlayProtocol.cleanName((b["name"] as? String) ?? "", fallback: "?"), text: text))
        case Wire.kData:
            guard state == .connected, pkt.count >= 5 else { return }
            let id = Int(Int32(bitPattern: UInt32(pkt[1]) | UInt32(pkt[2]) << 8 | UInt32(pkt[3]) << 16 | UInt32(pkt[4]) << 24))
            // Only bytes from someone the server told us about (or the server itself): a forged sender id is ignored.
            guard id == Wire.serverID || inner.connectedPeers.contains(String(id)) else { return }
            inner.receive(from: id, data: Array(pkt[5...]))
        default: break
        }
    }

    private func welcome(_ w: [String: Any]) {
        guard state == .handshaking, !w.isEmpty else { return }
        state = .connected
        serverName = CrossPlayProtocol.cleanName((w["server_name"] as? String) ?? "", fallback: "Server", maxLength: CrossPlayProtocol.maxServerNameLength)
        let hostName = CrossPlayProtocol.cleanName((w["host_name"] as? String) ?? "", fallback: serverName)
        let others = Array((((w["peers"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }).prefix(Self.maxPeers))
        emit(.connected(serverName: serverName, hostName: hostName, rulesJSON: String(((w["rules"] as? String) ?? "").prefix(4096)),
                        hasHostPlayer: (w["has_local_player"] as? Bool) ?? true, maxPlayers: Self.int(w["max"]) ?? 0))
        // The server (peer 1) is always a participant; a dedicated server just has no pilot.
        inner.peerConnected(id: Wire.serverID, name: hostName)
        for o in others {
            guard let id = Self.int(o["id"]), id != Wire.serverID else { continue }
            guard id >= 2, id != localID, inner.connectedPeers.count < Self.maxPeers else { continue }
            inner.peerConnected(id: id, name: CrossPlayProtocol.cleanPlayerName((o["name"] as? String) ?? "", fallback: "Pilot \(id)"))
        }
    }

    /// Tell the server about a misbehaving player (`target` = their id, 0 = unknown). `reason`: invalid, abuse, cheat, spam.
    /// Rate limited server-side.
    public func sendReport(target: Int, reason: String, detail: String = "") {
        // Safe from any thread: queued here, sent by the pumping thread in `service()`. At most a few are kept.
        reportLock.lock()
        if pendingReports.count < 8 { pendingReports.append(["id": target, "reason": String(reason.prefix(16)), "detail": String(detail.prefix(120))]) }
        reportLock.unlock()
    }
    private let reportLock = NSLock()
    private var pendingReports: [[String: Any]] = []
    private var lastReportAt = -100.0

    private func flushReports() {
        guard state == .connected, clock - lastReportAt >= 1 else { return }
        reportLock.lock(); let next = pendingReports.isEmpty ? nil : pendingReports.removeFirst(); reportLock.unlock()
        if let next { lastReportAt = clock; sendControl(Wire.kReport, next, reliable: true) }
    }

    private func sendHello() {
        sendControl(Wire.kHello, ["proto": Wire.protocolVersion, "version": config.gameVersion,
                                  "name": config.displayName, "pw": Self.hashPassword(config.password),
                                  "manifest": config.manifestJSON], reliable: true)
    }

    private func flushOutgoing() {
        for m in inner.drainOutgoing() {
            var pkt = [Wire.kData]
            var t = UInt32(bitPattern: Int32(truncatingIfNeeded: m.to)).littleEndian
            withUnsafeBytes(of: &t) { pkt.append(contentsOf: $0) }
            pkt.append(contentsOf: m.data)
            sendRaw(pkt, reliable: m.reliable)
        }
    }

    private func sendControl(_ kind: UInt8, _ body: [String: Any], reliable: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        sendRaw([kind] + [UInt8](data), reliable: reliable)
    }

    private func sendRaw(_ bytes: [UInt8], reliable: Bool) {
        guard let peer = peer else { return }
        let flags: UInt32 = reliable ? UInt32(truncatingIfNeeded: ENET_PACKET_FLAG_RELIABLE.rawValue)
            : (UInt32(truncatingIfNeeded: ENET_PACKET_FLAG_UNSEQUENCED.rawValue) | UInt32(truncatingIfNeeded: ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT.rawValue))
        guard let packet = bytes.withUnsafeBufferPointer({ enet_packet_create($0.baseAddress, $0.count, flags) }) else { return }
        if enet_peer_send(peer, reliable ? Wire.chReliable : Wire.chUnreliable, packet) != 0 { enet_packet_destroy(packet) }
    }

    // MARK: Teardown

    private func finish(_ s: State) {
        state = s
        stopPumping()
        teardown()
    }

    private func teardown() {
        if let host = host { enet_host_destroy(host) }
        host = nil; peer = nil
    }

    private func emit(_ e: Event) { onEvent?(e) }

    // MARK: Helpers

    /// SHA-256 hex of "novaswift:" + password; "" for no password (godot/net/NetProto.gd `hash_password`).
    public static func hashPassword(_ pw: String) -> String {
        guard !pw.isEmpty else { return "" }
        return SHA256.hash(data: Data(("novaswift:" + pw).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `manifest` string in the same shape as the Godot bridge's `net_ready_manifest()`.
    public static func manifestJSON(_ m: PluginManifest) -> String {
        let m = m.gameplayOnly   // cosmetic plug-ins never go on the wire
        let obj: [String: Any] = ["plugins": m.plugins.map { ["id": $0.id, "name": $0.name, "contentHash": $0.contentHash] },
                                  "signature": m.signature, "count": m.count]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Parse a `net_ready_manifest()`-shaped JSON back into a `PluginManifest` (nil if malformed).
    public static func parseManifest(_ json: String) -> PluginManifest? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let list = o["plugins"] as? [[String: Any]] else { return nil }
        return PluginManifest(list.map {
            PluginRequirement(id: ($0["id"] as? String) ?? "", name: ($0["name"] as? String) ?? "", contentHash: ($0["contentHash"] as? String) ?? "")
        })
    }

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
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
