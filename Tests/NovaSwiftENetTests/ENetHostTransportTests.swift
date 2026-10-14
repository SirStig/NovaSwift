import XCTest
@testable import NovaSwiftENet
import NovaSwiftNet

/// The Apple host (`ENetHostTransport`) against the Apple client (`ENetTransport`) over real loopback ENet sockets,
/// plus beacon / status-query round trips. The wire format is the Godot one; `testGodotClientJoinsSwiftHost`
/// (opt-in) runs a real headless Godot client against it.
final class ENetHostTransportTests: XCTestCase {
    static var nextPort = 54100

    final class Recorder: TransportDelegate {
        var received: [(Data, PeerID)] = []
        var joined: [PeerID] = []
        var left: [PeerID] = []
        func transport(_ t: Transport, didReceive data: Data, from peer: PeerID) { received.append((data, peer)) }
        func transport(_ t: Transport, peerDidConnect peer: PeerID) { joined.append(peer) }
        func transport(_ t: Transport, peerDidDisconnect peer: PeerID) { left.append(peer) }
    }
    final class Log<T> { var items: [T] = [] }

    struct Rig {
        let host: ENetHostTransport
        let hostRec: Recorder
        let hostLog: Log<ENetHostTransport.Event>
        let port: Int
    }

    func makeHost(password: String = "", manifest: String = "", max: Int = 8, version: String = "9.9.9") throws -> Rig {
        Self.nextPort += 2
        let h = ENetHostTransport(config: .init(port: Self.nextPort, maxPlayers: max, serverName: "Test Game", hostName: "Hosty",
                                                password: password, gameVersion: version, manifestJSON: manifest,
                                                rulesJSON: "{\"allow_pvp\":true}", rulesName: "safe", loopbackOnly: true))
        let rec = Recorder(); let log = Log<ENetHostTransport.Event>()
        h.delegate = rec
        h.onEvent = { log.items.append($0) }
        try h.start()
        return Rig(host: h, hostRec: rec, hostLog: log, port: Self.nextPort)
    }

    func makeClient(_ r: Rig, name: String, pw: String = "", version: String = "9.9.9", manifest: String = "",
                    localID: Int? = nil) -> (ENetTransport, Recorder, Log<ENetTransport.Event>) {
        let t = ENetTransport(config: .init(host: "127.0.0.1", port: r.port, displayName: name, password: pw,
                                            gameVersion: version, manifestJSON: manifest), localID: localID)
        let rec = Recorder(); let log = Log<ENetTransport.Event>()
        t.delegate = rec
        t.onEvent = { log.items.append($0) }
        return (t, rec, log)
    }

    func pump(_ r: Rig, _ cs: [ENetTransport], until cond: () -> Bool, seconds: Double = 4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !cond() {
            r.host.service(); cs.forEach { $0.service() }
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    func testHandshakeAndPeerAnnouncements() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let (a, ra, la) = makeClient(r, name: "alpha")
        try a.connect()
        pump(r, [a], until: { a.state == .connected })
        XCTAssertEqual(a.state, .connected)
        guard case .connected(let sname, let hname, let rules, let hasHost, let max)? = la.items.first else { return XCTFail("no connected: \(la.items)") }
        XCTAssertEqual(sname, "Test Game"); XCTAssertEqual(hname, "Hosty"); XCTAssertTrue(rules.contains("allow_pvp"))
        XCTAssertTrue(hasHost); XCTAssertEqual(max, 8)
        XCTAssertEqual(ra.joined, ["1"], "the host is peer 1")
        XCTAssertEqual(r.hostRec.joined, [String(a.localID)])
        XCTAssertEqual(r.host.playerCount, 2)

        let (b, rb, _) = makeClient(r, name: "alpha")   // same name -> uniquified
        try b.connect()
        pump(r, [a, b], until: { b.state == .connected && ra.joined.contains(String(b.localID)) })
        XCTAssertEqual(Set(rb.joined), ["1", String(a.localID)], "WELCOME lists everyone already in")
        XCTAssertTrue(ra.joined.contains(String(b.localID)), "PEER_JOIN reaches the earlier client")
        XCTAssertEqual(Set(r.host.clients.map(\.name)), ["alpha", "alpha (2)"])

        b.disconnect()
        pump(r, [a], until: { !ra.left.isEmpty })
        XCTAssertEqual(ra.left, [String(b.localID)], "PEER_LEFT")
        XCTAssertEqual(r.hostRec.left, [String(b.localID)])
        XCTAssertEqual(r.host.playerCount, 2)
    }

    func testRelayAndHostData() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let (a, ra, _) = makeClient(r, name: "a")
        let (b, rb, _) = makeClient(r, name: "b")
        try a.connect(); try b.connect()
        pump(r, [a, b], until: { a.connectedPeers.count == 2 && b.connectedPeers.count == 2 })
        XCTAssertEqual(a.connectedPeers.count, 2)

        a.send(Data([1, 2, 3]), to: String(b.localID), channel: .reliable)    // client -> client via the relay
        a.broadcast(Data([9]), channel: .unreliable)                          // everyone else, host included
        a.send(Data([4]), to: "1", channel: .reliable)                        // host only
        pump(r, [a, b], until: { rb.received.count >= 2 && r.hostRec.received.count >= 2 })
        XCTAssertEqual(rb.received.map(\.0), [Data([1, 2, 3]), Data([9])])
        XCTAssertEqual(rb.received.first?.1, String(a.localID), "attributed to the sender, not the relay")
        XCTAssertEqual(r.hostRec.received.map(\.0), [Data([9]), Data([4])])
        XCTAssertEqual(r.hostRec.received.first?.1, String(a.localID))

        // Host -> one client and host broadcast.
        r.host.send(Data([7]), to: String(a.localID), channel: .reliable)
        r.host.broadcast(Data([8]), channel: .unreliable)
        pump(r, [a, b], until: { ra.received.count >= 2 && rb.received.count >= 3 })
        XCTAssertEqual(ra.received.map(\.0), [Data([7]), Data([8])])
        XCTAssertEqual(ra.received.first?.1, "1")
        XCTAssertEqual(rb.received.last?.0, Data([8]))
    }

    func testRejections() throws {
        let manifest = ENetTransport.manifestJSON(PluginManifest([PluginRequirement(id: "p", name: "P", contentHash: "h1")]))
        let r = try makeHost(password: "secret", manifest: manifest, max: 2)
        defer { r.host.disconnect() }

        func attempt(_ c: (ENetTransport, Recorder, Log<ENetTransport.Event>)) throws -> ENetTransport.Event? {
            try c.0.connect()
            pump(r, [c.0], until: { c.0.state == .closed || c.0.state == .connected }, seconds: 3)
            return c.2.items.first
        }
        // A different app release (same protocol) is NOT refused: it joins, and the host notes it.
        let (v, _, lv) = makeClient(r, name: "v", pw: "secret", version: "1.0.0", manifest: manifest)
        try v.connect()
        pump(r, [v], until: { v.state == .connected })
        XCTAssertEqual(v.state, .connected, "\(lv.items)")
        XCTAssertTrue(r.hostLog.items.contains { if case .versionNote(_, _, "1.0.0", "9.9.9") = $0 { return true } else { return false } })
        v.disconnect()
        pump(r, [], until: { r.host.clients.isEmpty })
        guard case .rejected(let c2, _)? = try attempt(makeClient(r, name: "p", pw: "nope", manifest: manifest)) else { return XCTFail("password") }
        XCTAssertEqual(c2, "password")
        guard case .rejected(let c3, _)? = try attempt(makeClient(r, name: "m", pw: "secret", manifest: "{\"plugins\":[]}")) else { return XCTFail("plugins") }
        XCTAssertEqual(c3, "plugins")
        // A cosmetic-only difference doesn't count: the same gameplay plug-in plus an extra cosmetic one joins.
        let withCosmetic = ENetTransport.manifestJSON(PluginManifest([
            PluginRequirement(id: "p", name: "P", contentHash: "h1"),
            PluginRequirement(id: "art", name: "Art", contentHash: "zz", cosmetic: true)]))
        XCTAssertEqual(ENetTransport.parseManifest(withCosmetic)?.plugins.map(\.id), ["p"], "cosmetic plug-ins never go on the wire")
        let (ok, _, lok) = makeClient(r, name: "ok", pw: "secret", manifest: withCosmetic)
        try ok.connect()
        pump(r, [ok], until: { ok.state == .connected })
        XCTAssertEqual(ok.state, .connected, "\(lok.items)")
        // max 2 = host + 1 client, so the next one is told the server is full.
        guard case .rejected(let c4, _)? = try attempt(makeClient(r, name: "late", pw: "secret", manifest: manifest)) else { return XCTFail("full") }
        XCTAssertEqual(c4, "full")
        XCTAssertTrue(r.hostLog.items.contains { if case .refused("full", _, _) = $0 { return true } else { return false } })
    }

    func testKickAndBan() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let (a, ra, la) = makeClient(r, name: "a")
        let (b, _, _) = makeClient(r, name: "b")
        try a.connect(); try b.connect()
        pump(r, [a, b], until: { a.connectedPeers.count == 2 && b.connectedPeers.count == 2 })
        XCTAssertTrue(r.host.kick(b.localID, reason: "Behave.", ban: true))
        pump(r, [a, b], until: { b.state == .closed && !ra.left.isEmpty })
        XCTAssertEqual(ra.left, [String(b.localID)])
        XCTAssertEqual(r.host.playerCount, 2)
        _ = la
        let (b2, _, lb2) = makeClient(r, name: "b")
        try b2.connect()
        pump(r, [b2], until: { b2.state == .closed })
        guard case .rejected("banned", _)? = lb2.items.first else { return XCTFail("expected banned, got \(lb2.items)") }
    }

    func testBadConnectIDIsReset() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let (a, _, la) = makeClient(r, name: "a", localID: 1)    // id 1 is the host's
        try a.connect()
        pump(r, [a], until: { a.state == .closed }, seconds: 2)
        XCTAssertNotEqual(a.state, .connected)
        XCTAssertTrue(r.host.clients.isEmpty)
        _ = la
    }

    func testSessionsRunOverTheHost() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let hostSession = NetSession(transport: r.host, rules: .safe)
        hostSession.providesRules = true
        hostSession.updateLocalPresence(name: "Hosty", systemID: 128)
        let (c, _, _) = makeClient(r, name: "guest")
        var guestSession: NetSession?
        c.onEvent = { if case .connected = $0 { guestSession = NetSession(transport: c, rules: .fullStakes) } }
        try c.connect()
        pump(r, [c], until: { guestSession?.presence["1"] != nil })
        let gs = try XCTUnwrap(guestSession)
        gs.updateLocalPresence(name: "Guest", systemID: 128)
        gs.sendChat("hello host")
        pump(r, [c], until: { hostSession.chatLog.count == 1 && hostSession.presence[gs.localPlayerID] != nil })
        XCTAssertEqual(gs.presence["1"]?.name, "Hosty")
        XCTAssertEqual(hostSession.chatLog.first?.text, "hello host")
        XCTAssertEqual(hostSession.coLocatedPlayers().map(\.name), ["Guest"])
        XCTAssertEqual(gs.sessionRules, .safe, "the host pushes its rules to the late joiner")
    }

    func testBeaconAnnounceAndStatusQuery() throws {
        let r = try makeHost(password: "pw")
        defer { r.host.disconnect() }
        let (a, _, _) = makeClient(r, name: "a", pw: "pw")
        try a.connect()
        pump(r, [a], until: { a.state == .connected })

        // Announce on a private beacon port (not the real 53736), unicast to loopback.
        let beaconPort = Self.nextPort + 1000
        let svc = LANBeaconService(listenPort: beaconPort)
        let listener = LANBeaconService(listenPort: beaconPort)
        let heard = expectation(description: "beacon heard")
        heard.assertForOverFulfill = false
        listener.onServers = { list in if list.first?.beacon.name == "Test Game" { heard.fulfill() } }
        XCTAssertTrue(listener.startListening())
        // Game port + 1 is the query responder; the service answers on its own thread, so the host's
        // player count is read through the provider each time.
        XCTAssertTrue(svc.startAnnouncing(gamePort: r.port, provider: { r.host.beacon() }, broadcastTarget: in_addr(s_addr: UInt32(0x7f000001).bigEndian)))
        wait(for: [heard], timeout: 5)
        let b = try XCTUnwrap(listener.servers.first?.beacon)
        XCTAssertEqual(b.players, 2); XCTAssertEqual(b.max, 8); XCTAssertTrue(b.pw); XCTAssertEqual(b.port, r.port)
        XCTAssertEqual(b.rules, "safe"); XCTAssertFalse(b.dedicated)

        let q = ServerStatusQuery.query(host: "127.0.0.1", gamePort: r.port, timeout: 3)
        XCTAssertEqual(q?.beacon.name, "Test Game")
        XCTAssertEqual(q?.beacon.ver, "9.9.9")
        XCTAssertGreaterThanOrEqual(q?.rttMilliseconds ?? 0, 1)
        // Wrong port -> no answer.
        XCTAssertNil(ServerStatusQuery.query(host: "127.0.0.1", gamePort: r.port + 10, timeout: 0.4))

        let prober = ServerStatusProber(callbackQueue: DispatchQueue(label: "t"))
        let answered = expectation(description: "probe")
        prober.probe([CrossPlayAddress(host: "127.0.0.1", port: r.port)]) { addr, res in
            XCTAssertEqual(addr.port, r.port); XCTAssertEqual(res?.beacon.players, 2); answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        svc.stop(); listener.stop()
    }

    func testDirectoryClientCachesWithETag() throws {
        let body = Data("""
        {"version":1,"servers":[{"id":"a","name":"Alpha","host":"a.example.com","port":53735,"region":"eu","description":"d","owner":{"name":"o"},"rules":"safe","maxPlayers":8,"added":"2026-10-01"}]}
        """.utf8)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("nsdir-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        var calls: [String?] = []
        var mode = 200
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let fetcher: ServerDirectoryClient.Fetcher = { req, done in
            calls.append(req.value(forHTTPHeaderField: "If-None-Match"))
            let resp = HTTPURLResponse(url: req.url!, statusCode: mode, httpVersion: nil, headerFields: ["ETag": "\"v1\""])
            if mode == -1 { return done(nil, nil, URLError(.notConnectedToInternet)) }
            done(mode == 200 ? body : nil, resp, nil)
        }
        let c = ServerDirectoryClient(cacheURL: cache, fetcher: fetcher, now: { clock })
        var st: ServerDirectoryClient.Status?
        c.refresh { s, _ in st = s }
        XCTAssertEqual(st, .ok); XCTAssertEqual(c.servers.map(\.name), ["Alpha"])
        c.refresh { s, _ in st = s }
        XCTAssertEqual(st, .cached); XCTAssertEqual(calls.count, 1, "within 24 h: no request")

        clock.addTimeInterval(25 * 3600)
        mode = 304
        c.refresh { s, _ in st = s }
        XCTAssertEqual(st, .ok); XCTAssertEqual(calls.last ?? nil, "\"v1\"", "revalidates with If-None-Match")
        XCTAssertEqual(c.servers.count, 1)

        // A new client picks up the cache; offline refresh keeps it.
        mode = -1
        clock.addTimeInterval(25 * 3600)
        let c2 = ServerDirectoryClient(cacheURL: cache, fetcher: fetcher, now: { clock })
        XCTAssertEqual(c2.servers.count, 1)
        c2.refresh { s, _ in st = s }
        guard case .offline? = st else { return XCTFail("\(String(describing: st))") }
        XCTAssertEqual(c2.servers.count, 1)
    }

    /// NOVASWIFT_GODOT_CLIENT=1 NOVASWIFT_HOST_SECONDS=20 NOVASWIFT_HOST_PORT=53777 swift test --filter testHostForGodotClient
    /// Hosts for N seconds with a NetSession so an external (headless Godot) client can join. See docs/MULTIPLAYER.md.
    func testHostForGodotClient() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NOVASWIFT_GODOT_CLIENT"] != nil else { throw XCTSkip("opt-in interop host") }
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer so a driver script sees HOSTREADY immediately
        let port = Int(env["NOVASWIFT_HOST_PORT"] ?? "53777")!
        let seconds = Double(env["NOVASWIFT_HOST_SECONDS"] ?? "20")!
        let h = ENetHostTransport(config: .init(port: port, maxPlayers: 4, serverName: "Swift Host", hostName: "AppleHost",
                                                password: env["NOVASWIFT_HOST_PASSWORD"] ?? "",
                                                gameVersion: CrossPlayProtocol.appVersion, manifestJSON: "",
                                                rulesJSON: CrossPlayProtocol.rulesJSON(.safe), rulesName: "safe",
                                                loopbackOnly: env["NOVASWIFT_HOST_LOOPBACK"] != nil))
        let session = NetSession(transport: h, rules: .safe)
        session.providesRules = true
        session.updateLocalPresence(name: "AppleHost", systemID: 128)
        let logFile = env["NOVASWIFT_HOST_LOG_FILE"]
        func log(_ m: String) { print(m); if let logFile, let fh = FileHandle(forWritingAtPath: logFile) ?? { FileManager.default.createFile(atPath: logFile, contents: nil); return FileHandle(forWritingAtPath: logFile) }() { fh.seekToEndOfFile(); fh.write(Data((m + "\n").utf8)); fh.closeFile() } }
        h.onEvent = { log("HOSTEVENT \($0)") }
        session.onChat = { log("HOSTCHAT \($0.senderName): \($0.text)") }
        session.onPresenceChanged = { s in log("HOSTPRESENCE \(s.presence.values.map { "\($0.playerID)=\($0.name)@\($0.currentSystemID)" }.sorted())") }
        try h.start()
        let svc = LANBeaconService()
        _ = svc.startAnnouncing(gamePort: port, provider: { h.beacon() })
        print("HOSTREADY \(port)")
        if let f = env["NOVASWIFT_HOST_READY_FILE"] { try? "ready".write(toFile: f, atomically: true, encoding: .utf8) }
        let end = Date().addingTimeInterval(seconds)
        var said = false
        while Date() < end {
            h.service()
            if !said, h.playerCount > 1 { session.sendChat("hello from apple"); said = true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        svc.stop(); h.disconnect()
    }
}

import CENet
extension ENetHostTransportTests {
    /// Godot's ENetMultiplayerPeer asks for 255 channels in CONNECT; the host must accept that and negotiate down.
    func testHostAcceptsAClientRequestingManyChannels() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        _ = enet_initialize()
        let client = enet_host_create(nil, 1, 255, 0, 0)!
        defer { enet_host_destroy(client) }
        var a = ENetAddress(); enet_address_set_host(&a, "127.0.0.1"); a.port = UInt16(r.port)
        let peer = enet_host_connect(client, &a, 255, 777_777)
        XCTAssertNotNil(peer)
        var connected = false
        let end = Date().addingTimeInterval(3)
        while Date() < end && !connected {
            r.host.service()
            var e = ENetEvent()
            while enet_host_service(client, &e, 0) > 0 { if e.type == ENET_EVENT_TYPE_CONNECT { connected = true } }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(connected, "ENet-level connect with 255 channels")
    }
}

extension ENetHostTransportTests {
    /// The exact CONNECT datagram a Godot 4.7 `ENetMultiplayerPeer.create_client` sends (captured).
    func testHostRepliesToACapturedGodotConnect() throws {
        let r = try makeHost()
        defer { r.host.disconnect() }
        let hex = "8fff079b82ff00010000ffff0000057000010000000000ff000000000000000000001388000000020000000269c26a884af7acd9"
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let fd = try XCTUnwrap(UDP.makeSocket(bindPort: nil, broadcast: false, shared: false))
        defer { close(fd) }
        UDP.send(fd, Data(bytes), to: UDP.sockaddr(in_addr(s_addr: UInt32(0x7f000001).bigEndian), port: r.port))
        var got = false
        let end = Date().addingTimeInterval(2)
        while Date() < end && !got { r.host.service(); if UDP.receive(fd) != nil { got = true }; Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(got, "VERIFY_CONNECT expected")
    }
}
