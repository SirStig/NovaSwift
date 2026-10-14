import XCTest
import Foundation
import NovaSwiftNet
import NovaSwiftENet
@testable import NovaSwiftServerCore

/// The real server (ENet host + NetSession + gate) against the real Swift ENet client over loopback UDP.
final class HandshakeTests: XCTestCase {
    final class Rec: TransportDelegate {
        var chats: [String] = []
        var joined: [PeerID] = []
        func transport(_ t: Transport, didReceive data: Data, from peer: PeerID) {
            if case .chat(let m)? = try? NetCodec.decode(data) { chats.append("\(m.senderName): \(m.text)") }
        }
        func transport(_ t: Transport, peerDidConnect peer: PeerID) { joined.append(peer) }
        func transport(_ t: Transport, peerDidDisconnect peer: PeerID) {}
    }
    final class Events { var items: [ENetTransport.Event] = [] }

    func client(_ port: Int, name: String = "pilot", pw: String = "", manifest: PluginManifest? = nil) -> (ENetTransport, Rec, Events) {
        let t = ENetTransport(config: .init(host: "127.0.0.1", port: port, displayName: name, password: pw, gameVersion: "9.9.9",
                                            manifestJSON: manifest.map { ENetTransport.manifestJSON($0) } ?? ""))
        let rec = Rec(), ev = Events()
        t.delegate = rec; t.onEvent = { ev.items.append($0) }
        return (t, rec, ev)
    }

    func pump(_ cs: [ENetTransport], until cond: () -> Bool, seconds: Double = 5) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !cond() { cs.forEach { $0.service() }; Thread.sleep(forTimeInterval: 0.005) }
    }

    func connect(_ c: (ENetTransport, Rec, Events)) throws {
        try c.0.connect()
        pump([c.0], until: { c.0.state == .connected || c.0.state == .closed })
    }

    func testJoinStatusQueryAndDedicatedFlag() throws {
        let r = try TestSupport.rig { $0.motd = "Welcome aboard"; $0.maxPlayers = 3 }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let c = client(port, name: "alpha")
        try connect(c)
        XCTAssertEqual(c.0.state, .connected)
        guard case .connected(let sname, let hname, _, let hasHost, let max)? = c.2.items.first else { return XCTFail("\(c.2.items)") }
        XCTAssertEqual(sname, "Test Server"); XCTAssertEqual(hname, "[Server]")
        XCTAssertFalse(hasHost, "a dedicated server has no pilot and takes no slot")
        XCTAssertEqual(max, 3)
        pump([c.0], until: { !c.1.chats.isEmpty }, seconds: 3)
        XCTAssertEqual(c.1.chats.first, "[Server]: Welcome aboard", "the MOTD arrives as server chat")
        XCTAssertEqual(r.server.players().map(\.name), ["alpha"])
        XCTAssertEqual(r.server.playerCount, 1)

        // NSQ1 status reply on port + 1
        let q = try XCTUnwrap(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3))
        XCTAssertEqual(q.beacon.name, "Test Server"); XCTAssertTrue(q.beacon.dedicated)
        XCTAssertEqual(q.beacon.players, 1); XCTAssertEqual(q.beacon.max, 3)
        XCTAssertEqual(q.beacon.rules, "safe"); XCTAssertFalse(q.beacon.pw)
        XCTAssertEqual(q.beacon.proto, CrossPlayProtocol.version)
        c.0.disconnect()
    }

    func testPasswordBansCapacityAndKick() throws {
        let r = try TestSupport.rig { $0.password = "open sesame"; $0.maxPlayers = 2 }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let noPW = client(port); try connect(noPW)
        guard case .rejected("password", _)? = noPW.2.items.first else { return XCTFail("\(noPW.2.items)") }
        let ok1 = client(port, name: "one", pw: "open sesame"); try connect(ok1)
        let ok2 = client(port, name: "two", pw: "open sesame"); try connect(ok2)
        XCTAssertEqual(ok1.0.state, .connected); XCTAssertEqual(ok2.0.state, .connected)
        let full = client(port, name: "three", pw: "open sesame"); try connect(full)
        guard case .rejected("full", _)? = full.2.items.first else { return XCTFail("\(full.2.items)") }
        XCTAssertGreaterThanOrEqual(r.server.snapshot().refusals, 2)

        // Kick one of them from the server side.
        let target = try XCTUnwrap(r.server.findPlayer("two"))
        XCTAssertTrue(r.server.kick(target.id, reason: "bye", ban: true))
        pump([ok1.0, ok2.0], until: { ok2.0.state == .closed })
        XCTAssertEqual(ok2.0.state, .closed)
        XCTAssertEqual(r.server.players().map(\.name), ["one"])
        // Banned by address: 127.0.0.1 is now blocked for everyone, which is what an IP ban means.
        XCTAssertNotNil(r.store.config.bans["127.0.0.1"])
        let again = client(port, name: "two", pw: "open sesame"); try connect(again)
        guard case .rejected("banned", _)? = again.2.items.first else { return XCTFail("\(again.2.items)") }
        r.server.unban(ip: "127.0.0.1")
        let back = client(port, name: "two", pw: "open sesame"); try connect(back)
        XCTAssertEqual(back.0.state, .connected)
        ok1.0.disconnect(); back.0.disconnect()
    }

    func testPluginGateAndLiveManifestUpdate() throws {
        let r = try TestSupport.rig()
        try TestSupport.makePlugin("gp", in: r.paths.pluginsDir, resources: [("shïp", 128, [1, 2, 3])])
        try TestSupport.makePlugin("skin", in: r.paths.pluginsDir, resources: [("PICT", 128, [1, 2, 3])])
        try r.store.update { $0.enabledPlugins = ["gp", "skin"] }
        try r.server.start(); defer { r.server.stop() }
        let port = r.store.config.port
        let serverManifest = r.server.manifest.all
        XCTAssertEqual(serverManifest.gameplay.map(\.id), ["gp"]); XCTAssertEqual(serverManifest.cosmetic.map(\.id), ["skin"])

        // A stock player is refused, with the server's manifest in the detail so the game can show the diff.
        let stock = client(port, manifest: PluginManifest([])); try connect(stock)
        guard case .rejected("plugins", _)? = stock.2.items.first else { return XCTFail("\(stock.2.items)") }
        XCTAssertNotNil(stock.0.rejectServerManifest)
        let parsed = try XCTUnwrap(ENetTransport.parseManifest(stock.0.rejectServerManifest ?? ""))
        XCTAssertEqual(parsed.plugins.map(\.id), ["gp"], "cosmetic plug-ins aren't part of the gate")
        // Same gameplay plug-in (hash from the same files), extra cosmetic one the server doesn't have: joins.
        let joiner = PluginManifest(serverManifest.gameplay + [PluginRequirement(id: "other-art", name: "x", contentHash: "z", cosmetic: true)])
        let good = client(port, name: "good", manifest: joiner); try connect(good)
        XCTAssertEqual(good.0.state, .connected, "\(good.2.items)")
        // Wrong version of the plug-in is refused.
        let wrong = client(port, name: "wrong", manifest: PluginManifest([PluginRequirement(id: "gp", name: "gp", contentHash: "deadbeefdeadbeef")])); try connect(wrong)
        guard case .rejected("plugins", _)? = wrong.2.items.first else { return XCTFail("\(wrong.2.items)") }
        // Turn the plug-in off live: a stock player may now join.
        let old = r.store.config
        try r.store.update { $0.enabledPlugins = [] }
        _ = r.server.apply(old: old, new: r.store.config)
        let stock2 = client(port, name: "stock2", manifest: PluginManifest([])); try connect(stock2)
        XCTAssertEqual(stock2.0.state, .connected, "\(stock2.2.items)")
        // The advertised requirements follow it.
        let q = try XCTUnwrap(ServerStatusQuery.query(host: "127.0.0.1", gamePort: port, timeout: 3))
        XCTAssertEqual(q.beacon.requirements?.plugins.count ?? 0, 0)
        good.0.disconnect(); stock2.0.disconnect()
    }

    func testLiveRulesAndAnnouncements() throws {
        let r = try TestSupport.rig()
        try r.server.start(); defer { r.server.stop() }
        let c = client(r.store.config.port, name: "alpha"); try connect(c)
        let session = NetSession(transport: c.0, rules: .safe)
        var rulesSeen: [SessionRules] = []
        session.onRulesChanged = { rulesSeen.append($0) }
        pump([c.0], until: { false }, seconds: 0.5)
        let old = r.store.config
        try r.store.update { $0.rulesPreset = "full" }
        _ = r.server.apply(old: old, new: r.store.config)
        pump([c.0], until: { !rulesSeen.isEmpty }, seconds: 3)
        XCTAssertEqual(rulesSeen.last, .fullStakes, "rules changes reach players already online")
        var chats: [String] = []
        session.onChat = { chats.append($0.text) }
        r.server.say("Server restarts in 5")
        pump([c.0], until: { !chats.isEmpty }, seconds: 3)
        XCTAssertTrue(chats.contains("Server restarts in 5"))
        let q = try XCTUnwrap(ServerStatusQuery.query(host: "127.0.0.1", gamePort: r.store.config.port, timeout: 3))
        XCTAssertEqual(q.beacon.rules, "full")
        c.0.disconnect()
    }

    func testPortInUseGivesPlainLanguageError() throws {
        let a = try TestSupport.rig()
        try a.server.start(); defer { a.server.stop() }
        let b = try TestSupport.rig { $0.port = a.store.config.port }
        XCTAssertThrowsError(try b.server.start()) { e in
            let m = (e as? ServerError)?.message ?? ""
            XCTAssertTrue(m.contains("already in use"), m)
            XCTAssertTrue(m.contains("\(a.store.config.port)"), m)
        }
    }

    func testConsoleCommands() throws {
        let root = TestSupport.tempRoot()
        let p = TestSupport.ports()
        var o = ServerOptions(); o.dataDir = root.path; o.port = p.game; o.adminPort = p.admin; o.noBrowser = true; o.noStdin = true; o.quiet = true
        let app = try ServerApp(options: o)
        XCTAssertNotNil(app.generatedPassword, "first run generates the admin password")
        XCTAssertTrue(app.store.config.adminPasswordHash.hasPrefix("sha256i$"))
        try app.start(); defer { app.server.stop(); app.http?.stop() }
        XCTAssertTrue(ConsoleCommands.run("help", app: app).contains("kick"))
        XCTAssertTrue(ConsoleCommands.run("status", app: app).contains("running"))
        XCTAssertEqual(ConsoleCommands.run("players", app: app), "No players online.")
        XCTAssertTrue(ConsoleCommands.run("kick nobody", app: app).contains("No player matches"))
        XCTAssertTrue(ConsoleCommands.run("rules full", app: app).contains("full"))
        XCTAssertEqual(app.store.config.rulesPreset, "full")
        XCTAssertTrue(ConsoleCommands.run("plugins", app: app).contains("stock game"))
        XCTAssertTrue(ConsoleCommands.run("frobnicate", app: app).contains("Unknown command"))
        // second start of the same folder keeps the password hash and doesn't regenerate
        let app2 = try ServerApp(options: { var x = o; x.port = nil; x.adminPort = nil; return x }(), paths: ServerPaths(root: root))
        XCTAssertNil(app2.generatedPassword)
    }
}
