import XCTest
import CENet
@testable import NovaSwiftENet
import NovaSwiftNet

/// A minimal stand-in for the Godot server (`godot/net/NetTransport.gd`): same ENet channels, same packet
/// kinds, same JSON control bodies. It lets the Swift client be tested on loopback with no Godot binary.
/// `testAgainstLiveGodotServer` runs the same client against a real dedicated server when asked to.
final class StubGodotServer {
    var host: UnsafeMutablePointer<ENetHost>
    var peers: [Int: UnsafeMutablePointer<ENetPeer>] = [:]     // id -> peer
    var ready: Set<Int> = []
    var names: [Int: String] = [:]
    var receivedData: [(from: Int, target: Int, payload: [UInt8], reliable: Bool)] = []
    var hellos: [[String: Any]] = []
    var gameVersion = "9.9.9"
    var password = ""
    let port: UInt16

    init(port: UInt16) {
        _ = enet_initialize()
        var a = ENetAddress(); enet_address_set_host(&a, "127.0.0.1"); a.port = port
        host = enet_host_create(&a, 8, 0, 0, 0)!
        self.port = port
    }
    deinit { enet_host_destroy(host) }

    func step() {
        var e = ENetEvent()
        while enet_host_service(host, &e, 0) > 0 {
            switch e.type {
            case ENET_EVENT_TYPE_CONNECT:
                peers[Int(e.data)] = e.peer
                e.peer!.pointee.data = UnsafeMutableRawPointer(bitPattern: Int(e.data))
            case ENET_EVENT_TYPE_RECEIVE:
                let id = Int(bitPattern: e.peer!.pointee.data)
                let p = e.packet!
                let bytes = Array(UnsafeBufferPointer(start: p.pointee.data, count: p.pointee.dataLength))
                enet_packet_destroy(p)
                handle(from: id, channel: e.channelID, bytes)
            case ENET_EVENT_TYPE_DISCONNECT:
                let id = Int(bitPattern: e.peer!.pointee.data)
                peers[id] = nil
                if ready.remove(id) != nil {
                    for o in ready { control(o, 0x05, ["id": id, "reason": "left"]) }
                }
            default: break
            }
        }
        enet_host_flush(host)
    }

    func handle(from id: Int, channel: UInt8, _ b: [UInt8]) {
        switch b[0] {
        case 0x01:
            let h = (try? JSONSerialization.jsonObject(with: Data(b[1...])) as? [String: Any]) ?? [:]
            hellos.append(h)
            if (h["proto"] as? Int) != 1 { return reject(id, "proto", "bad proto") }
            if (h["version"] as? String) != gameVersion { return reject(id, "version", "Game version mismatch") }
            if password != "", (h["pw"] as? String) != ENetTransport.hashPassword(password) { return reject(id, "password", "Wrong password.") }
            names[id] = (h["name"] as? String) ?? "?"
            let others = ready.map { ["id": $0, "name": names[$0] ?? ""] as [String: Any] }
            control(id, 0x02, ["your_id": id, "server_name": "Stub", "host_name": "[Server]", "has_local_player": false,
                               "rules": "{\"allow_pvp\":true}", "peers": others, "max": 8, "proto": 1])
            for o in ready { control(o, 0x04, ["id": id, "name": names[id] ?? ""]) }
            ready.insert(id)
        case 0x07:
            control(id, 0x08, ["t": ((try? JSONSerialization.jsonObject(with: Data(b[1...])) as? [String: Any])?["t"]) ?? 0.0], reliable: false)
        case 0x10:
            let target = Int(Int32(bitPattern: UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24))
            let payload = Array(b[5...])
            let reliable = channel != 2
            receivedData.append((id, target, payload, reliable))
            var out: [UInt8] = [0x10]
            withUnsafeBytes(of: UInt32(id).littleEndian) { out.append(contentsOf: $0) }
            out += payload
            if target == -1 { for o in ready where o != id { raw(o, out, reliable: reliable) } }
            else if target != 1, ready.contains(target) { raw(target, out, reliable: reliable) }
        default: break
        }
    }

    func reject(_ id: Int, _ code: String, _ msg: String) {
        control(id, 0x03, ["code": code, "message": msg, "detail": [String: String]()])
    }
    func control(_ id: Int, _ kind: UInt8, _ body: [String: Any], reliable: Bool = true) {
        raw(id, [kind] + [UInt8](try! JSONSerialization.data(withJSONObject: body)), reliable: reliable)
    }
    func raw(_ id: Int, _ bytes: [UInt8], reliable: Bool) {
        guard let peer = peers[id] else { return }
        let flags: UInt32 = reliable ? ENET_PACKET_FLAG_RELIABLE.rawValue : ENET_PACKET_FLAG_UNSEQUENCED.rawValue
        let pk = bytes.withUnsafeBufferPointer { enet_packet_create($0.baseAddress, $0.count, flags) }
        enet_peer_send(peer, reliable ? 0 : 2, pk)
    }
}

final class ENetTransportTests: XCTestCase {
    static var nextPort: UInt16 = 53900

    final class Recorder: TransportDelegate {
        var received: [(Data, PeerID)] = []
        var joined: [PeerID] = []
        var left: [PeerID] = []
        func transport(_ t: Transport, didReceive data: Data, from peer: PeerID) { received.append((data, peer)) }
        func transport(_ t: Transport, peerDidConnect peer: PeerID) { joined.append(peer) }
        func transport(_ t: Transport, peerDidDisconnect peer: PeerID) { left.append(peer) }
    }

    func makeServer() -> StubGodotServer {
        Self.nextPort += 1
        return StubGodotServer(port: Self.nextPort)
    }

    func makeClient(_ s: StubGodotServer, name: String = "swift", pw: String = "", version: String = "9.9.9",
                    manifest: String = "") -> (ENetTransport, Recorder, EventLog) {
        let t = ENetTransport(config: .init(host: "127.0.0.1", port: Int(s.port), displayName: name, password: pw,
                                            gameVersion: version, manifestJSON: manifest))
        let rec = Recorder(); let log = EventLog()
        t.delegate = rec
        t.onEvent = { log.events.append($0) }
        return (t, rec, log)
    }

    final class EventLog { var events: [ENetTransport.Event] = [] }

    func pump(_ s: StubGodotServer, _ cs: [ENetTransport], until cond: () -> Bool, seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !cond() {
            s.step(); cs.forEach { $0.service() }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func testHandshakeAndPeerList() throws {
        let s = makeServer()
        let (a, ra, la) = makeClient(s, name: "alpha")
        try a.connect()
        pump(s, [a], until: { a.state == .connected })
        XCTAssertEqual(a.state, .connected)
        XCTAssertEqual(s.hellos.first?["name"] as? String, "alpha")
        XCTAssertEqual(s.hellos.first?["proto"] as? Int, 1)
        XCTAssertEqual(a.localPeerID, String(a.localID))
        guard case .connected(let name, let host, let rules, let hasHost, let max)? = la.events.first else { return XCTFail("no connected event") }
        XCTAssertEqual(name, "Stub"); XCTAssertEqual(host, "[Server]"); XCTAssertTrue(rules.contains("allow_pvp")); XCTAssertFalse(hasHost); XCTAssertEqual(max, 8)
        XCTAssertEqual(ra.joined, ["1"], "the server is peer 1")

        let (b, rb, _) = makeClient(s, name: "beta")
        try b.connect()
        pump(s, [a, b], until: { b.state == .connected && ra.joined.contains(String(b.localID)) })
        XCTAssertEqual(Set(rb.joined), ["1", String(a.localID)])
        XCTAssertTrue(ra.joined.contains(String(b.localID)))
    }

    func testRelayReliableAndUnreliableBetweenClients() throws {
        let s = makeServer()
        let (at, _, _) = makeClient(s, name: "a")
        let (bt, rb, _) = makeClient(s, name: "b")
        try at.connect(); try bt.connect()
        pump(s, [at, bt], until: { at.state == .connected && bt.state == .connected && at.connectedPeers.count == 2 })
        at.send(Data([1, 2, 3]), to: String(bt.localID), channel: .reliable)
        at.broadcast(Data([9]), channel: .unreliable)
        pump(s, [at, bt], until: { rb.received.count >= 2 })
        XCTAssertEqual(rb.received.first?.0, Data([1, 2, 3]))
        XCTAssertEqual(rb.received.first?.1, String(at.localID), "payload attributed to the sending client, not the relay")
        XCTAssertEqual(rb.received.last?.0, Data([9]))
        XCTAssertEqual(s.receivedData.map(\.reliable), [true, false], "reliable on channel 0, unreliable on channel 2")
        XCTAssertEqual(s.receivedData.map(\.target), [bt.localID, -1])
    }

    func testServerDataReachesClient() throws {
        let s = makeServer()
        let (c, rc, _) = makeClient(s)
        try c.connect()
        pump(s, [c], until: { c.state == .connected })
        var pkt: [UInt8] = [0x10]
        withUnsafeBytes(of: UInt32(1).littleEndian) { pkt.append(contentsOf: $0) }
        s.raw(c.localID, pkt + [7, 7], reliable: true)
        pump(s, [c], until: { !rc.received.isEmpty })
        XCTAssertEqual(rc.received.first?.1, "1")
        XCTAssertEqual(rc.received.first?.0, Data([7, 7]))
    }

    func testRejections() throws {
        let s = makeServer(); s.password = "secret"
        let (v, _, lv) = makeClient(s, version: "1.0.0")
        try v.connect()
        pump(s, [v], until: { v.state == .closed })
        XCTAssertEqual(lv.events.first, .rejected(code: "version", message: "Game version mismatch"))

        let (p, _, lp) = makeClient(s, pw: "wrong")
        try p.connect()
        pump(s, [p], until: { p.state == .closed })
        XCTAssertEqual(lp.events.first, .rejected(code: "password", message: "Wrong password."))

        let (ok, _, _) = makeClient(s, pw: "secret")
        try ok.connect()
        pump(s, [ok], until: { ok.state == .connected })
        XCTAssertEqual(ok.state, .connected)
        XCTAssertEqual(ENetTransport.hashPassword(""), "")
        XCTAssertEqual(ENetTransport.hashPassword("secret").count, 64)
    }

    func testPeerLeavesAndClientDisconnect() throws {
        let s = makeServer()
        let (at, ra, _) = makeClient(s)
        let (bt, _, _) = makeClient(s)
        try at.connect(); try bt.connect()
        pump(s, [at, bt], until: { at.connectedPeers.count == 2 && bt.state == .connected })
        bt.disconnect()
        XCTAssertEqual(bt.state, .closed)
        pump(s, [at], until: { !ra.left.isEmpty })
        XCTAssertEqual(ra.left, [String(bt.localID)])
        _ = ra
    }

    func testConnectTimeoutToDeadPort() throws {
        Self.nextPort += 1
        let t = ENetTransport(config: .init(host: "127.0.0.1", port: Int(Self.nextPort), displayName: "x", gameVersion: "1"))
        let log = EventLog(); t.onEvent = { log.events.append($0) }
        t.connectTimeout = 1
        try t.connect()
        let end = Date().addingTimeInterval(4)
        while Date() < end && t.state != .closed { t.service(); Thread.sleep(forTimeInterval: 0.01) }
        guard case .timedOut? = log.events.first else { return XCTFail("expected a timeout, got \(log.events)") }
    }

    func testManifestJSONShape() {
        let m = PluginManifest([PluginRequirement(id: "b", name: "B", contentHash: "h2"), PluginRequirement(id: "a", name: "A", contentHash: "h1")])
        let obj = try! JSONSerialization.jsonObject(with: Data(ENetTransport.manifestJSON(m).utf8)) as! [String: Any]
        XCTAssertEqual(obj["signature"] as? String, m.signature)
        XCTAssertEqual(obj["count"] as? Int, 2)
        XCTAssertEqual((obj["plugins"] as? [[String: String]])?.first?["id"], "a")
    }

    /// NOVASWIFT_ENET_INTEROP=127.0.0.1:53735 NOVASWIFT_ENET_VERSION=0.7.0-beta.1 swift test --filter testAgainstLiveGodotServer
    func testAgainstLiveGodotServer() throws {
        guard let addr = ProcessInfo.processInfo.environment["NOVASWIFT_ENET_INTEROP"] else { throw XCTSkip("set NOVASWIFT_ENET_INTEROP=host:port to test against a real Godot server") }
        let parts = addr.split(separator: ":")
        let version = ProcessInfo.processInfo.environment["NOVASWIFT_ENET_VERSION"] ?? "0"
        let t = ENetTransport(config: .init(host: String(parts[0]), port: Int(parts.count > 1 ? String(parts[1]) : "53735")!, displayName: "swift-xplay", gameVersion: version))
        let log = EventLog(); t.onEvent = { log.events.append($0) }
        try t.connect()
        let end = Date().addingTimeInterval(6)
        while Date() < end && t.state != .connected && t.state != .closed { t.service(); Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(t.state, .connected, "events: \(log.events)")
        // Stay long enough for a ping/pong round trip.
        let end2 = Date().addingTimeInterval(4)
        while Date() < end2 && t.rttMilliseconds < 0 { t.service(); Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertGreaterThanOrEqual(t.rttMilliseconds, 0, "no PONG from the Godot server")
        XCTAssertTrue(t.connectedPeers.contains("1"))
        t.disconnect()
    }
}
