import XCTest
import Foundation
import CENet
import _CryptoExtras
import NovaSwiftNet
import NovaSwiftENet
@testable import NovaSwiftServerCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Raw ENet client that can send arbitrary bytes (what a malicious client would do).
final class RawClient {
    var host: UnsafeMutablePointer<ENetHost>?
    var peer: UnsafeMutablePointer<ENetPeer>?
    var connected = false, closed = false
    var received: [[UInt8]] = []
    private static let once: Void = { _ = enet_initialize() }()

    init(port: Int, id: Int = Int.random(in: 1000...2_000_000_000)) {
        _ = Self.once
        host = enet_host_create(nil, 1, 3, 0, 0)
        var a = ENetAddress(); enet_address_set_host(&a, "127.0.0.1"); a.port = UInt16(port)
        peer = enet_host_connect(host, &a, 3, UInt32(id))
    }
    deinit { if let peer { enet_peer_reset(peer) }; if let host { enet_host_destroy(host) } }

    func pump(_ seconds: Double = 0.05) {
        guard let host else { return }
        let end = Date().addingTimeInterval(seconds)
        repeat {
            var e = ENetEvent()
            while enet_host_service(host, &e, 0) > 0 {
                switch e.type {
                case ENET_EVENT_TYPE_CONNECT: connected = true
                case ENET_EVENT_TYPE_DISCONNECT: closed = true
                case ENET_EVENT_TYPE_RECEIVE:
                    if let p = e.packet { received.append(Array(UnsafeBufferPointer(start: p.pointee.data, count: p.pointee.dataLength))); enet_packet_destroy(p) }
                default: break
                }
            }
            if seconds > 0.06 { Thread.sleep(forTimeInterval: 0.002) }
        } while Date() < end
    }

    func waitConnected() { let end = Date().addingTimeInterval(3); while !connected && !closed && Date() < end { pump(0.02) } }

    func send(_ bytes: [UInt8], reliable: Bool = true) {
        guard let peer, !closed else { return }
        let flags: UInt32 = reliable ? ENET_PACKET_FLAG_RELIABLE.rawValue : ENET_PACKET_FLAG_UNSEQUENCED.rawValue
        if let p = bytes.withUnsafeBufferPointer({ enet_packet_create($0.baseAddress, $0.count, flags) }) {
            if enet_peer_send(peer, reliable ? 0 : 2, p) != 0 { enet_packet_destroy(p) }
        }
    }

    func hello(name: String = "raw") {
        let j = try! JSONSerialization.data(withJSONObject: ["proto": CrossPlayProtocol.version, "version": "x", "name": name, "pw": "", "manifest": ""])
        send([0x01] + [UInt8](j))
    }
}

final class SecurityTests: XCTestCase {
    final class Rec: TransportDelegate {
        var messages: [NetMessage] = []
        var peers: [PeerID] = []
        func transport(_ t: Transport, didReceive data: Data, from peer: PeerID) { if let m = try? NetCodec.decode(data) { messages.append(m) } }
        func transport(_ t: Transport, peerDidConnect peer: PeerID) { peers.append(peer) }
        func transport(_ t: Transport, peerDidDisconnect peer: PeerID) { peers.removeAll { $0 == peer } }
    }
    final class Events { var items: [ENetTransport.Event] = [] }
    struct C { let t: ENetTransport; let rec: Rec; let ev: Events }

    func client(_ port: Int, name: String) -> C {
        let t = ENetTransport(config: .init(host: "127.0.0.1", port: port, displayName: name, gameVersion: "9.9.9"))
        let rec = Rec(), ev = Events()
        t.delegate = rec; t.onEvent = { ev.items.append($0) }
        t.connectTimeout = 2
        return C(t: t, rec: rec, ev: ev)
    }
    func pump(_ cs: [C], until cond: () -> Bool = { false }, seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !cond() { cs.forEach { $0.t.service() }; Thread.sleep(forTimeInterval: 0.004) }
    }
    func join(_ port: Int, _ name: String, others: [C] = []) throws -> C {
        let c = client(port, name: name)
        try c.t.connect()
        pump(others + [c], until: { c.t.state == .connected || c.t.state == .closed })
        XCTAssertEqual(c.t.state, .connected, "\(name): \(c.ev.items)")
        return c
    }

    // MARK: Bug fix: an empty dedicated server has zero players

    func testEmptyDedicatedServerReportsZeroPlayersEverywhere() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        XCTAssertEqual(r.server.beacon()?.players, 0)
        XCTAssertEqual(r.server.playerCount, 0)
        XCTAssertEqual(try XCTUnwrap(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3)).beacon.players, 0)
        XCTAssertEqual(r.admin.statusJSON()["players"] as? Int, 0)
        let c = try join(port, "alpha")
        XCTAssertEqual(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3)?.beacon.players, 1)
        c.t.disconnect()
        let end = Date().addingTimeInterval(3)
        while r.server.playerCount != 0 && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3)?.beacon.players, 0)
        // a restart (reopening the game port) starts from zero too
        try r.server.restartNetwork()
        XCTAssertEqual(r.server.beacon()?.players, 0)
    }

    // MARK: NSQ1 on the wire

    private func rawUDP(_ port: Int, _ payload: Data, wait: Double = 0.4) -> Data? {
        let fd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: Int32(wait * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(port).bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        _ = payload.withUnsafeBytes { b in withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf[0..<n]) : nil
    }

    func testStatusQueryRulesOnTheWire() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let qp = CrossPlayProtocol.queryPort(forGamePort: r.store.config.port)
        // Padded v2 and the status prober's v1 request (exactly 1200 bytes) are answered, never with more bytes than sent.
        for v in [UInt8(2), UInt8(1)] {
            var q = Data("NSQ1".utf8); q.append(v); q.append(Data(count: 1195))
            let reply = try XCTUnwrap(rawUDP(qp, q), "version \(v)")
            XCTAssertLessThanOrEqual(reply.count, 1200)
            XCTAssertEqual(ServerBeacon.decode(reply)?.name, "Test Server")
        }
        // Short / wrong requests: no answer at all.
        XCTAssertNil(rawUDP(qp, Data("NSQ1x".utf8)))
        XCTAssertNil(rawUDP(qp, Data("NSQ1".utf8) + Data([2]) + Data(count: 50)))
        XCTAssertNil(rawUDP(qp, Data(repeating: 0, count: 1200)))
        // The bare legacy query gets only the tiny upgrade notice.
        let legacy = try XCTUnwrap(rawUDP(qp, Data("NSQ1".utf8)))
        XCTAssertLessThanOrEqual(legacy.count, 64)
        XCTAssertTrue(String(decoding: legacy, as: UTF8.self).contains("\"upgrade\":true"))
        // A burst from one address is cut off (token bucket) instead of being reflected 1:1.
        var answered = 0
        for _ in 0..<40 {
            var q = Data("NSQ1".utf8); q.append(2); q.append(Data(count: 1195))
            if rawUDP(qp, q, wait: 0.02) != nil { answered += 1 }
        }
        XCTAssertLessThan(answered, 20)
    }

    // MARK: Connection abuse

    func testRandomGarbageFromManyConnectionsNeverBreaksTheServer() throws {
        let r = try TestSupport.rig { $0.maxPlayers = 8 }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        var seed: UInt64 = 0xFEEDFACE
        func rnd() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let kinds: [UInt8] = [0x01, 0x02, 0x03, 0x07, 0x09, 0x0A, 0x10, 0x00, 0xFF, 0x55]
        var iterations = 0
        var raw = RawClient(port: port); raw.waitConnected()
        for i in 0..<4000 {
            if raw.closed || i % 400 == 0 { raw = RawClient(port: port); raw.waitConnected() }
            iterations += 1
            let kind = kinds[Int(rnd() % UInt64(kinds.count))]
            var body = (0..<Int(rnd() % 200)).map { _ in UInt8(truncatingIfNeeded: rnd()) }
            switch rnd() % 6 {
            case 0: body = Array(#"{"proto":1,"name":"x","pw":"","manifest":"{\"plugins\":[1,2,{}]}"}"#.utf8)
            case 1: body = Array(#"{"text":"/votekick \u0000 [b]","id":99999999999,"rtt":1e999}"#.utf8)
            case 2: body = [0xFF, 0xFF, 0xFF, 0xFF] + body                   // data to a weird target
            case 3: body = Array(#"{"chat":{"playerID":"1","senderName":"[Server]","text":"x"}}"#.utf8)
            default: break
            }
            raw.send([kind] + body, reliable: i % 3 != 0)
            if i % 20 == 0 { raw.pump(0.01) }
        }
        raw.pump(0.2)
        // Random datagrams at the status port.
        let qp = CrossPlayProtocol.queryPort(forGamePort: port)
        for _ in 0..<500 { _ = rawUDP(qp, Data((0..<Int(rnd() % 1500)).map { _ in UInt8(truncatingIfNeeded: rnd()) }), wait: 0.001) }
        XCTAssertGreaterThan(iterations, 3999)
        // The server is alive and a normal player can still join and be queried.
        let c = try join(port, "survivor")
        XCTAssertNotNil(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3))
        XCTAssertTrue(r.server.players().contains { $0.name == "survivor" })
        c.t.disconnect()
    }

    func testFloodingConnectionIsKicked() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let raw = RawClient(port: port); raw.waitConnected(); raw.hello(name: "flooder"); raw.pump(0.3)
        XCTAssertTrue(r.server.players().contains { $0.name == "flooder" })
        let junk = [UInt8](repeating: 0x41, count: 400)
        for _ in 0..<40 { for _ in 0..<150 { raw.send([0x10, 0xFF, 0xFF, 0xFF, 0xFF] + junk) }; raw.pump(0.01) }
        let end = Date().addingTimeInterval(4)
        while !r.server.players().isEmpty && Date() < end { raw.pump(0.05) }
        XCTAssertTrue(r.server.players().isEmpty, "a flooding connection is removed")
        XCTAssertGreaterThan(r.server.snapshot().abuseKicks, 0)
    }

    func testOversizedPacketsAreKicked() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let raw = RawClient(port: r.store.config.port); raw.waitConnected(); raw.hello(name: "big"); raw.pump(0.3)
        for _ in 0..<8 { raw.send([0x10, 1, 0, 0, 0] + [UInt8](repeating: 7, count: 100_000)); raw.pump(0.05) }
        let end = Date().addingTimeInterval(4)
        while !r.server.players().isEmpty && Date() < end { raw.pump(0.05) }
        XCTAssertTrue(r.server.players().isEmpty)
    }

    func testPerAddressConnectionLimit() throws {
        let r = try TestSupport.rig { $0.maxConnectionsPerIP = 2 }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let a = try join(port, "a"), b = try join(port, "b", others: [a])
        let c = client(port, name: "c"); try c.t.connect()
        pump([a, b, c], until: { c.t.state == .closed }, seconds: 4)
        XCTAssertNotEqual(c.t.state, .connected, "a third connection from one address is refused")
        XCTAssertEqual(r.server.players().count, 2)
        a.t.disconnect(); b.t.disconnect()
    }

    func testAllowlistMode() throws {
        let r = try TestSupport.rig { $0.allowlistMode = true }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let denied = client(port, name: "nope"); try denied.t.connect()
        pump([denied], until: { denied.t.state == .closed })
        guard case .rejected("allowlist", _)? = denied.ev.items.first else { return XCTFail("\(denied.ev.items)") }
        r.server.allow(ip: "127.0.0.1")
        let ok = try join(port, "yes")
        ok.t.disconnect()
    }

    // MARK: Forged relay traffic, mutes, votes, reports

    func testRelayDropsForgedMessagesAndRewritesIdentity() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let a = try join(port, "alice"), b = try join(port, "bob", others: [])
        pump([a, b], seconds: 0.6)
        b.rec.messages.removeAll()
        let aID = a.t.localPeerID
        func send(_ m: NetMessage) { a.t.broadcast(try! NetCodec.encode(m), channel: .reliable) }
        send(.presence(PlayerPresence(playerID: "424242", name: "Ghost", currentSystemID: 1)))          // someone else's presence
        send(.chat(ChatMessage(playerID: "1", senderName: "[Server]", text: "I am the server")))        // forged server chat
        send(.sessionRules(.fullStakes)); send(.kick(b.t.localPeerID))                                  // host-only
        send(.chat(ChatMessage(playerID: aID, senderName: "[Server]", text: "hello\u{202E}")))          // own id, lying name
        send(.presence(PlayerPresence(playerID: aID, name: "[b]Boss[/b]", currentSystemID: 3)))         // own presence, fake name
        pump([a, b], seconds: 1.0)
        var chats: [ChatMessage] = [], presences: [PlayerPresence] = []
        for m in b.rec.messages {
            switch m {
            case .chat(let c): chats.append(c)
            case .presence(let p): presences.append(p)
            case .sessionRules(let s) where s == .fullStakes: XCTFail("rules from a client reached a player")
            case .kick: XCTFail("a client's kick reached a player")
            default: break
            }
        }
        XCTAssertFalse(presences.contains { $0.playerID == "424242" })
        XCTAssertEqual(chats.filter { $0.text.contains("I am the server") }.count, 0)
        let mine = chats.filter { $0.playerID == aID }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.senderName, "alice", "the server stamps the real name")
        XCTAssertEqual(presences.last(where: { $0.playerID == aID })?.name, "alice")
        a.t.disconnect(); b.t.disconnect()
    }

    func testMuteVoteKickAndReportsEndToEnd() throws {
        let r = try TestSupport.rig { $0.maxPlayers = 8 }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let a = try join(port, "alpha"), b = try join(port, "bravo", others: [a]), c = try join(port, "charlie", others: [a, b])
        let d = try join(port, "delta", others: [a, b, c])
        let all = [a, b, c, d]
        pump(all, seconds: 0.5)
        func say(_ who: C, _ t: String) { who.t.broadcast(try! NetCodec.encode(.chat(ChatMessage(playerID: who.t.localPeerID, senderName: "x", text: t))), channel: .reliable) }
        func chats(_ who: C) -> [String] { who.rec.messages.compactMap { if case .chat(let m) = $0 { return m.text } else { return nil } } }
        say(c, "hello from charlie"); pump(all, until: { chats(a).contains("hello from charlie") }, seconds: 2)
        XCTAssertTrue(chats(a).contains("hello from charlie"))
        // Admin mutes charlie: nobody hears him any more.
        XCTAssertNotNil(r.server.mute("charlie"))
        say(c, "can anyone hear me"); pump(all, seconds: 0.8)
        XCTAssertFalse(chats(a).contains("can anyone hear me"))
        XCTAssertTrue(r.server.unmute("charlie"))
        say(c, "back again"); pump(all, until: { chats(a).contains("back again") }, seconds: 2)
        XCTAssertTrue(chats(a).contains("back again"))
        // Commands are not chat.
        say(a, "/votekick charlie"); pump(all, seconds: 0.5)
        XCTAssertFalse(chats(b).contains("/votekick charlie"))
        XCTAssertTrue(chats(a).contains { $0.contains("Vote to remove") }, "the voter gets the tally privately: \(chats(a))")
        // Second vote passes (2 of 4 online, 51% rounds up to 3? needs >= 2 minimum and ceil(4*0.51)=3): a third vote is needed.
        say(b, "/votekick charlie"); pump(all, seconds: 0.4)
        XCTAssertNotEqual(c.t.state, .closed)
        say(d, "/votekick charlie"); pump(all, until: { c.t.state == .closed }, seconds: 3)
        XCTAssertEqual(c.t.state, .closed, "a vote-kick that reaches the threshold removes the player")
        // Three distinct reporters remove somebody.
        let e = try join(port, "echo", others: [a, b, d])
        let all2 = [a, b, d, e]
        for who in [a, b, d] { who.t.sendReport(target: Int(e.t.localPeerID)!, reason: "abuse", detail: "test") }
        pump(all2, until: { e.t.state == .closed }, seconds: 3)
        XCTAssertEqual(e.t.state, .closed)
        a.t.disconnect(); b.t.disconnect(); d.t.disconnect()
    }

    // MARK: Pure moderation logic

    func testRelayInspectorUnit() throws {
        let ins = RelayInspector()
        ins.context = { _ in .init(name: "Real", ip: "1.2.3.4") }
        var violations: [String] = []
        ins.violation = { _, w in violations.append(w) }
        func enc(_ m: NetMessage) -> [UInt8] { [UInt8](try! NetCodec.encode(m)) }
        XCTAssertNotNil(ins.inspect(from: 7, payload: enc(.snapshot(WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [])))))
        XCTAssertNil(ins.inspect(from: 7, payload: enc(.kick("8"))))
        XCTAssertNil(ins.inspect(from: 7, payload: enc(.sessionRules(.safe))))
        XCTAssertNil(ins.inspect(from: 7, payload: Array("garbage".utf8)))
        XCTAssertNil(ins.inspect(from: 7, payload: [UInt8](repeating: 0x7b, count: 70_000)))
        XCTAssertNil(ins.inspect(from: 7, payload: enc(.presence(PlayerPresence(playerID: "8", name: "x", currentSystemID: 1)))))
        XCTAssertEqual(violations.count, 5)
        let out = try XCTUnwrap(ins.inspect(from: 7, payload: enc(.chat(ChatMessage(playerID: "7", senderName: "Admin", text: "hi\u{202E}")))))
        guard case .chat(let m)? = try? NetCodec.decode(Data(out)) else { return XCTFail() }
        XCTAssertEqual(m.senderName, "Real"); XCTAssertEqual(m.text, "hi")
        var commanded: String?
        ins.command = { _, _, t in commanded = t }
        XCTAssertNil(ins.inspect(from: 7, payload: enc(.chat(ChatMessage(playerID: "7", senderName: "x", text: "/help")))))
        XCTAssertEqual(commanded, "/help")
    }

    func testModerationCenterVotesFilterAndSpam() {
        let m = ModerationCenter()
        m.config.wordFilter = ["badword"]
        XCTAssertEqual(m.vet(id: 1, text: "this BadWord is bad", now: 0), "this ******* is bad")
        _ = m.vet(id: 2, text: "same", now: 0); _ = m.vet(id: 2, text: "same", now: 1)
        XCTAssertNil(m.vet(id: 2, text: "same", now: 2), "third identical line in 10 s is spam")
        XCTAssertNotNil(m.vet(id: 2, text: "same", now: 30))
        let roster = [(id: 1, name: "ann"), (id: 2, name: "bob"), (id: 3, name: "cy"), (id: 4, name: "di")]
        XCTAssertEqual(m.needed(4), 3)
        guard case .reply = m.command("/votekick cy", from: 1, players: roster, now: 100) else { return XCTFail() }
        guard case .reply(let again) = m.command("/votekick cy", from: 1, players: roster, now: 101) else { return XCTFail() }
        XCTAssertTrue(again.contains("already"))
        _ = m.command("/votekick cy", from: 2, players: roster, now: 102)
        XCTAssertEqual(m.command("/votekick cy", from: 4, players: roster, now: 103), .kick(target: 3, reason: "Removed by a vote of the other players."))
        // Expired votes don't count; self-votes and tiny servers are refused.
        _ = m.command("/votekick bob", from: 1, players: roster, now: 1000)
        guard case .reply(let late) = m.command("/votes", from: 1, players: roster, now: 1100) else { return XCTFail() }
        XCTAssertTrue(late.contains("No vote"))
        guard case .reply(let few) = m.command("/votekick bob", from: 1, players: Array(roster.prefix(2)), now: 2000) else { return XCTFail() }
        XCTAssertTrue(few.contains("at least 3"))
        m.config.voteKick = false
        guard case .reply(let off) = m.command("/votekick bob", from: 1, players: roster, now: 3000) else { return XCTFail() }
        XCTAssertTrue(off.contains("off"))
        // Reports need a real target.
        guard case .reply = m.command("/report nobody", from: 1, players: roster, now: 5) else { return XCTFail() }
        guard case .report(let t, _, _, _) = m.command("/report di rude", from: 1, players: roster, now: 5) else { return XCTFail() }
        XCTAssertEqual(t, 4)
    }

    // MARK: Admin panel

    private func req(_ method: String, _ path: String, body: [String: Any]? = nil, cookie: String? = nil, headers: [String: String] = [:], ip: String = "127.0.0.1") -> HTTPRequest {
        var h = headers
        h["x-ns-admin"] = "1"
        if let cookie { h["cookie"] = "nsadmin=\(cookie)" }
        return HTTPRequest(method: method, path: path, headers: h, body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data(), remoteIP: ip)
    }
    private func json(_ r: HTTPResponse) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]) ?? [:] }
    private func loginCookie(_ a: AdminService, headers: [String: String] = [:]) -> (String, HTTPResponse) {
        let r = a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"], headers: headers))
        return ((r.headers["Set-Cookie"] ?? "").split(separator: ";").first.map { String($0).replacingOccurrences(of: "nsadmin=", with: "") } ?? "", r)
    }

    func testAdminSecurityHeadersAndCookieFlags() throws {
        let a = try TestSupport.rig().admin
        let page = a.handle(HTTPRequest(method: "GET", path: "/"))
        XCTAssertTrue((page.headers["Content-Security-Policy"] ?? "").contains("script-src 'self'"))
        XCTAssertTrue((page.headers["Content-Security-Policy"] ?? "").contains("frame-ancestors 'none'"))
        XCTAssertEqual(page.headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(page.headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(page.headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(a.handle(req("GET", "/api/session")).headers["X-Frame-Options"], "DENY", "API answers carry the headers too")
        let (_, plain) = loginCookie(a)
        let c = plain.headers["Set-Cookie"] ?? ""
        XCTAssertTrue(c.contains("HttpOnly")); XCTAssertTrue(c.contains("SameSite=Strict")); XCTAssertFalse(c.contains("Secure"))
        // Behind a local TLS-terminating proxy the cookie becomes Secure; a remote client can't claim that.
        let (_, tls) = loginCookie(a, headers: ["x-forwarded-proto": "https"])
        XCTAssertTrue((tls.headers["Set-Cookie"] ?? "").contains("; Secure"))
        let remote = a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"], headers: ["x-forwarded-proto": "https"], ip: "203.0.113.4"))
        XCTAssertFalse((remote.headers["Set-Cookie"] ?? "").contains("Secure"))
    }

    func testAdminRefusesForeignHostAndCrossOriginWrites() throws {
        let a = try TestSupport.rig().admin
        XCTAssertEqual(a.handle(req("GET", "/api/session", headers: ["host": "evil.example.com:53737"])).status, 421, "DNS rebinding")
        XCTAssertEqual(a.handle(req("GET", "/api/session", headers: ["host": "localhost:53737"])).status, 200)
        XCTAssertEqual(a.handle(req("GET", "/api/session", headers: ["host": "203.0.113.9:53737"])).status, 200)
        XCTAssertEqual(a.handle(req("GET", "/api/session", headers: ["host": "[::1]:53737"])).status, 200)
        let (cookie, _) = loginCookie(a)
        let cross = a.handle(req("POST", "/api/settings", body: ["name": "X"], cookie: cookie, headers: ["host": "localhost:53737", "origin": "https://evil.example.com"]))
        XCTAssertEqual(cross.status, 403)
        let same = a.handle(req("POST", "/api/settings", body: ["name": "Fine"], cookie: cookie, headers: ["host": "localhost:53737", "origin": "http://localhost:53737"]))
        XCTAssertEqual(same.status, 200)
        a.extraHosts.insert("panel.example.org")
        XCTAssertEqual(a.handle(req("GET", "/api/session", headers: ["host": "panel.example.org"])).status, 200)
    }

    func testLoginBackoffDoublesAndStrongPasswordsAreRequired() throws {
        let a = try TestSupport.rig().admin
        func wait(after fails: Int) -> Int {
            for _ in 0..<fails { _ = a.handle(req("POST", "/api/login", body: ["password": "x"], ip: "198.51.100.77")) }
            let r = a.handle(req("POST", "/api/login", body: ["password": "hunter22hunter"], ip: "198.51.100.77"))
            XCTAssertEqual(r.status, 429)
            return Int((json(r)["error"] as? String ?? "").components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "0") ?? 0
        }
        let first = wait(after: 5)
        XCTAssertGreaterThan(first, 50); XCTAssertLessThanOrEqual(first, 60)
        XCTAssertNil(AdminPassword.strengthProblem("Tr0ub4dor&3-horse"))
        XCTAssertNil(AdminPassword.strengthProblem("correct horse battery staple"))
        for weak in ["short1A!", "password1234", "aaaaaaaaaaaaaa", "alllowercaseletters", "123456789012"] {
            XCTAssertNotNil(AdminPassword.strengthProblem(weak), weak)
        }
        XCTAssertNotNil(AdminPassword.strengthProblem("Tr0ub4dor&3-horse", current: "Tr0ub4dor&3-horse"))
        let (cookie, _) = loginCookie(a)
        let weak = a.handle(req("POST", "/api/admin-password", body: ["current": "hunter22hunter", "new": "abcdefgh"], cookie: cookie))
        XCTAssertEqual(weak.status, 400)
        let strong = a.handle(req("POST", "/api/admin-password", body: ["current": "hunter22hunter", "new": "Tr0ub4dor&3-horse"], cookie: cookie))
        XCTAssertEqual(strong.status, 200)
    }

    func testAuditLogRecordsActionsButNeverSecrets() throws {
        let r = try TestSupport.rig()
        let a = r.admin
        let (cookie, _) = loginCookie(a)
        _ = a.handle(req("POST", "/api/settings", body: ["name": "Audited", "password": "topsecretpw"], cookie: cookie, ip: "127.0.0.1"))
        _ = a.handle(req("POST", "/api/bans/add", body: ["ip": "203.0.113.50", "note": "spam"], cookie: cookie))
        _ = a.handle(req("POST", "/api/admin-password", body: ["current": "hunter22hunter", "new": "Tr0ub4dor&3-horse"], cookie: cookie))
        _ = a.handle(req("POST", "/api/login", body: ["password": "wrong"], ip: "203.0.113.8"))
        let entries = r.server.audit.entries()
        let text = entries.map { "\($0.actor) \($0.action) \($0.detail)" }.joined(separator: "\n")
        XCTAssertTrue(text.contains("ban-ip"), text)
        XCTAssertTrue(text.contains("login-failed"), text)
        XCTAssertTrue(text.contains("settings"), text)
        for secret in ["topsecretpw", "hunter22hunter", "Tr0ub4dor", "wrong"] { XCTAssertFalse(text.contains(secret), "\(secret) leaked into the audit log") }
        let (c2, _) = loginCookie(a)   // password changed above; this login fails, so get a fresh session another way
        _ = c2
        XCTAssertEqual(a.handle(req("GET", "/api/audit", cookie: cookie)).status, 401, "changing the password signs every session out")
    }

    func testPanelDefaultsAndModerationSettingsPersist() throws {
        XCTAssertEqual(ServerConfig().adminBind, "127.0.0.1")
        XCTAssertEqual(ServerConfig.fresh(hostname: "h").adminBind, "127.0.0.1")
        var c = ServerConfig.fresh(hostname: "h")
        c.voteKick = false; c.voteKickPercent = 70; c.allowlistMode = true; c.allowlist["1.2.3.4"] = "pal"
        c.wordFilter = ["foo", "bar"]; c.mutes["name:bob"] = "rude"; c.maxConnectionsPerIP = 3; c.announceJoins = false
        let back = ServerConfig.parse(c.render()).config
        XCTAssertEqual(back.voteKick, false); XCTAssertEqual(back.voteKickPercent, 70); XCTAssertTrue(back.allowlistMode)
        XCTAssertEqual(back.allowlist, ["1.2.3.4": "pal"]); XCTAssertEqual(back.wordFilter, ["foo", "bar"])
        XCTAssertEqual(back.mutes, ["name:bob": "rude"]); XCTAssertEqual(back.maxConnectionsPerIP, 3); XCTAssertFalse(back.announceJoins)
    }

    func testPanelScriptEscapesPlayerData() throws {
        let js = AdminAssets.appJS
        for risky in ["${p.name}", "${p.ip}", "${b.note}", "${x.note}", "${x.key}", "${x.ip}", "${r}"] where risky != "${r}" {
            XCTAssertFalse(js.contains(risky), "\(risky) must go through esc()")
        }
        XCTAssertTrue(js.contains("esc(p.name)"))
        XCTAssertTrue(js.contains("textContent = l.t"), "log lines are inserted as text")
    }

    // MARK: Start-up banner

    func testBannerShowsPublicAddressOrLabelsTheLanOne() {
        var cfg = ServerConfig.fresh(hostname: "h"); cfg.name = "N"
        let withIP = ServerApp.banner(cfg: cfg, join: ("203.0.113.9", "10.138.0.2"), adminURL: "http://localhost:53737", adminLocalOnly: true, dataFolder: "/d", password: nil, setupCode: nil)
        XCTAssertTrue(withIP.contains("Players join : 203.0.113.9"))
        XCTAssertFalse(withIP.contains("10.138.0.2"))
        let without = ServerApp.banner(cfg: cfg, join: (nil, "10.138.0.2"), adminURL: "http://localhost:53737", adminLocalOnly: true, dataFolder: "/d", password: nil, setupCode: nil)
        XCTAssertTrue(without.contains("Players join : your public IP"))
        XCTAssertTrue(without.contains("(LAN: 10.138.0.2)"))
        let none = ServerApp.banner(cfg: cfg, join: (nil, nil), adminURL: "u", adminLocalOnly: false, dataFolder: "/d", password: "pw", setupCode: "abc")
        XCTAssertTrue(none.contains("your public IP")); XCTAssertTrue(none.contains("pw")); XCTAssertTrue(none.contains("?setup=abc"))
    }

    // MARK: Self-update trust

    func testUpdateSignatureVerification() throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let pem = key.publicKey.pemRepresentation
        let manifest = Data(#"{"platforms":{"linux-arm64":{"asset":"NovaSwiftServer-linux-arm64.tar.gz","sha256":"\#(String(repeating: "ab", count: 32))","size":1234}},"version":"9.9.9"}"#.utf8)
        let sig = try key.signature(for: manifest, padding: .insecurePKCS1v1_5)
        XCTAssertTrue(ServerUpdateTrust.verify(manifest: manifest, signature: sig.rawRepresentation, publicKeyPEM: pem))
        var tampered = manifest; tampered[tampered.count - 3] ^= 1
        XCTAssertFalse(ServerUpdateTrust.verify(manifest: tampered, signature: sig.rawRepresentation, publicKeyPEM: pem), "a changed manifest fails")
        let other = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        XCTAssertFalse(ServerUpdateTrust.verify(manifest: manifest, signature: sig.rawRepresentation, publicKeyPEM: other.publicKey.pemRepresentation), "another key fails")
        XCTAssertFalse(ServerUpdateTrust.verify(manifest: manifest, signature: Data(count: 10), publicKeyPEM: pem))
        XCTAssertFalse(ServerUpdateTrust.verify(manifest: manifest, signature: sig.rawRepresentation), "the embedded NovaSwift key doesn't accept a test signature")
        let parsed = try XCTUnwrap(ServerUpdateTrust.parse(manifest))
        XCTAssertEqual(parsed.version, "9.9.9"); XCTAssertEqual(parsed.platforms["linux-arm64"]?.size, 1234)
        XCTAssertNil(ServerUpdateTrust.parse(Data("[1]".utf8)))
        XCTAssertTrue(ServerUpdateTrust.publicKeyPEM.contains("BEGIN PUBLIC KEY"))
    }

    func testEmbeddedUpdateKeyMatchesTheGameUpdaterKey() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pem = try String(contentsOf: here.appendingPathComponent("godot/updater/update_pubkey.pem"), encoding: .utf8)
        XCTAssertEqual(pem.trimmingCharacters(in: .whitespacesAndNewlines), ServerUpdateTrust.publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testOnlyOfficialReleaseAssetsAreTrusted() {
        let ok = "https://github.com/SirStig/NovaSwift/releases/download/server-v0.2.0/NovaSwiftServer-linux-x86_64.tar.gz"
        XCTAssertTrue(ServerUpdateTrust.isTrustedAssetURL(ok))
        for bad in ["http://github.com/SirStig/NovaSwift/releases/download/server-v0.2.0/a.tar.gz",
                    "https://evil.com/SirStig/NovaSwift/releases/download/server-v0.2.0/a.tar.gz",
                    "https://github.com/Other/NovaSwift/releases/download/server-v0.2.0/a.tar.gz",
                    "https://github.com/SirStig/NovaSwift/releases/download/v0.7.0/a.tar.gz",
                    "https://github.com/SirStig/NovaSwift/releases/download/server-v0.2.0/../../x",
                    "https://github.com.evil.com/SirStig/NovaSwift/releases/download/server-v0.2.0/a", "file:///etc/passwd"] {
            XCTAssertFalse(ServerUpdateTrust.isTrustedAssetURL(bad), bad)
        }
    }

    func testUnsignedReleaseIsRefused() {
        let log = ServerLog(); log.echoToConsole = false
        let u = UpdateChecker(log: log)
        let rel: [[String: Any]] = [["tag_name": "server-v99.0.0", "html_url": "https://github.com/x", "assets": [
            ["name": PlatformTools.releaseAssetName, "browser_download_url": "https://github.com/SirStig/NovaSwift/releases/download/server-v99.0.0/\(PlatformTools.releaseAssetName)"]]]]
        u.fetch = { _ in try? JSONSerialization.data(withJSONObject: rel) }
        let info = u.check()
        XCTAssertTrue(info.available)
        XCTAssertNil(info.manifestURL)
        let r = u.apply()
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("not signed"), r.message)
    }

    // MARK: Packaging

    func testSystemdUnitIsHardened() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: here.appendingPathComponent("packaging/server/install-server.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "<<UNIT\n")), end = try XCTUnwrap(script.range(of: "\nUNIT\n", range: start.upperBound..<script.endIndex))
        let unit = String(script[start.upperBound..<end.lowerBound])
        for d in ["NoNewPrivileges=true", "ProtectSystem=strict", "ProtectHome=true", "PrivateTmp=true", "PrivateDevices=true",
                  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK", "CapabilityBoundingSet=\n", "LockPersonality=true",
                  "MemoryDenyWriteExecute=true", "SystemCallFilter=@system-service", "Restart=always", "StartLimitBurst=", "LimitNOFILE=",
                  "ReadWritePaths=$DIR/data", "LimitCORE=0", "LimitNICE=40", "SystemCallErrorNumber=EPERM", "ProtectKernelTunables=true", "RestrictNamespaces=true"] {
            XCTAssertTrue(unit.contains(d), "unit is missing \(d)")
        }
        XCTAssertFalse(unit.contains("User=root"))
        XCTAssertTrue(script.contains("bind = 127.0.0.1"), "the installer closes the admin panel to the network")
        // Real linter where available (Linux CI / a container with systemd).
        if let sa = ["/usr/bin/systemd-analyze", "/bin/systemd-analyze"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unit-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let exe = dir.appendingPathComponent("NovaSwiftServer"); try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let text = unit.replacingOccurrences(of: "$USER_NAME", with: "root").replacingOccurrences(of: "$DIR", with: dir.path)
                .replacingOccurrences(of: "$REPO", with: "SirStig/NovaSwift")
            let f = dir.appendingPathComponent("novaswift-server.service"); try text.write(to: f, atomically: true, encoding: .utf8)
            let out = PlatformTools.run(sa, ["verify", f.path])
            XCTAssertFalse(out.output.contains("Unknown key") || out.output.contains("Unknown lvalue"), out.output)
        }
    }

    func testDockerAndComposeAreLockedDown() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docker = try String(contentsOf: here.appendingPathComponent("packaging/server/Dockerfile"), encoding: .utf8)
        XCTAssertTrue(docker.contains("USER 10001:10001")); XCTAssertFalse(docker.contains("USER root"))
        let compose = try String(contentsOf: here.appendingPathComponent("packaging/server/docker-compose.yml"), encoding: .utf8)
        for d in ["read_only: true", "cap_drop: [ALL]", "no-new-privileges:true", "127.0.0.1:53737:53737/tcp"] { XCTAssertTrue(compose.contains(d), d) }
    }

    func testPackagingScriptsStripMacMetadata() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for s in ["scripts/package-server.sh", "scripts/package-linux.sh"] {
            let t = try String(contentsOf: here.appendingPathComponent(s), encoding: .utf8)
            XCTAssertTrue(t.contains("COPYFILE_DISABLE=1") && t.contains("--no-xattrs") && t.contains("--no-mac-metadata"), s)
        }
    }
}
