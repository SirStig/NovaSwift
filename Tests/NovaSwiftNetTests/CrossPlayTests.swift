import XCTest
@testable import NovaSwiftNet

final class CrossPlayTests: XCTestCase {

    func testAppVersionMatchesGodotProject() throws {
        // #filePath = <repo>/Tests/NovaSwiftNetTests/CrossPlayTests.swift
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("godot/project.godot"), encoding: .utf8)
        let line = try XCTUnwrap(project.split(separator: "\n").first { $0.hasPrefix("config/version=") })
        XCTAssertEqual(String(line.dropFirst("config/version=\"".count).dropLast()), CrossPlayProtocol.appVersion,
                       "Bump CrossPlayProtocol.appVersion together with godot/project.godot config/version")
        let proto = try String(contentsOf: root.appendingPathComponent("godot/net/NetProto.gd"), encoding: .utf8)
        XCTAssertTrue(proto.contains("const PROTO := \(CrossPlayProtocol.version)"), "godot/net/NetProto.gd PROTO must equal CrossPlayProtocol.version")
    }

    func testAddressParsing() {
        func ok(_ s: String) -> CrossPlayAddress? { if case .success(let a) = CrossPlayAddress.parse(s) { return a } else { return nil } }
        XCTAssertEqual(ok("play.example.com"), CrossPlayAddress(host: "play.example.com", port: 53735))
        XCTAssertEqual(ok(" 192.168.1.20:4000 "), CrossPlayAddress(host: "192.168.1.20", port: 4000))
        XCTAssertEqual(ok("[::1]:99"), CrossPlayAddress(host: "::1", port: 99))
        XCTAssertEqual(ok("::1"), CrossPlayAddress(host: "::1", port: 53735))
        XCTAssertEqual(ok("novaswift://host:1/"), CrossPlayAddress(host: "host", port: 1))
        XCTAssertEqual(CrossPlayAddress.parse(""), .failure(.empty))
        XCTAssertEqual(CrossPlayAddress.parse("host:0"), .failure(.badPort))
        XCTAssertEqual(CrossPlayAddress.parse("host:99999"), .failure(.badPort))
        XCTAssertEqual(CrossPlayAddress.parse("[::1"), .failure(.badIPv6))
        XCTAssertEqual(CrossPlayAddress(host: "h", port: 53735).formatted, "h")
        XCTAssertEqual(CrossPlayAddress(host: "::1", port: 5).formatted, "[::1]:5")
        XCTAssertEqual(CrossPlayProtocol.queryPort(forGamePort: 53735), 53736)
        XCTAssertEqual(CrossPlayProtocol.queryPort(forGamePort: 4000), 4001)
    }

    func testBeaconRoundTripAndGodotShape() throws {
        let req = PluginRequirements(plugins: [PluginRequirement(id: "a", name: "A", contentHash: String(repeating: "ab", count: 32))], totalConversion: "tc", addOns: ["x"])
        let b = ServerBeacon(name: "Srv", players: 2, max: 8, pw: true, port: 4000, rules: "safe", dedicated: true, requirements: req)
        let full = try XCTUnwrap(ServerBeacon.decode(b.encode()))
        XCTAssertEqual(full.name, "Srv"); XCTAssertEqual(full.players, 2); XCTAssertEqual(full.max, 8)
        XCTAssertTrue(full.pw); XCTAssertEqual(full.port, 4000); XCTAssertTrue(full.dedicated)
        XCTAssertEqual(full.requirements?.plugins.map(\.id), ["a"])
        XCTAssertEqual(full.requirements?.plugins.first?.contentHash.count, 16, "wire hashes are truncated to 16 hex")
        XCTAssertEqual(full.requirements?.totalConversion, "tc"); XCTAssertEqual(full.requirements?.addOns, ["x"])
        XCTAssertEqual(full.proto, CrossPlayProtocol.version); XCTAssertTrue(full.isCompatible)
        // The LAN broadcast form: signature + count + tc, no list.
        let lite = try XCTUnwrap(ServerBeacon.decode(b.encode(full: false)))
        XCTAssertEqual(lite.pluginSignature, req.manifest.signature); XCTAssertEqual(lite.pluginCount, 1)
        XCTAssertEqual(lite.requirements?.plugins.count ?? 0, 0)
        // A packet written by Godot's NetProto.encode_beacon (no proto / plug-in fields).
        let godot = Data(("NSB1" + #"{"name":"G","players":1,"max":4,"ver":"\#(CrossPlayProtocol.appVersion)","pw":false,"port":53735,"rules":"full","dedicated":false}"#).utf8)
        let g = try XCTUnwrap(ServerBeacon.decode(godot))
        XCTAssertEqual(g.rules, "full"); XCTAssertNil(g.proto); XCTAssertTrue(g.isCompatible); XCTAssertFalse(g.isDifferentAppVersion)
        XCTAssertTrue(ServerBeacon.isQuery(Data("NSQ1".utf8)))
        XCTAssertNil(ServerBeacon.decode(Data("NSB1{".utf8)))
        XCTAssertNil(ServerBeacon.decode(Data(("NSB1" + #"{"port":0}"#).utf8)))
        var other = g; other.ver = "0.6.0"
        XCTAssertTrue(ServerBeacon.decode(Data(("NSB1" + #"{"name":"G","port":9,"ver":"0.6.0"}"#).utf8))!.isDifferentAppVersion)
        _ = other
        // Another protocol is incompatible.
        XCTAssertFalse(ServerBeacon.decode(Data(("NSB1" + #"{"name":"G","port":9,"proto":2}"#).utf8))!.isCompatible)
    }

    func testDirectoryParseSkipsBadEntriesAndDedupes() throws {
        let json = """
        {"version":1,"servers":[
         {"id":"a","name":"Alpha","host":"a.example.com","port":53735,"region":"eu","description":"d","owner":{"name":"o","contact":"c"},"rules":"safe","plugins":[{"id":"p","name":"P","contentHash":"h"}],"maxPlayers":8,"added":"2026-10-01","website":"https://a.example.com","tc":"conv"},
         {"id":"dup","name":"Dup","host":"A.example.com","port":53735,"region":"eu","description":"","owner":{"name":"o"},"rules":"safe","maxPlayers":8,"added":"2026-10-01"},
         {"id":"bad","name":"Bad","host":"","port":53735},
         {"id":"badport","name":"BadPort","host":"x.com","port":70000},
         {"id":"http","name":"Http","host":"h.com","port":1,"website":"http://insecure"}]}
        """
        guard case .success(let list) = ServerDirectory.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(list.map(\.id), ["a", "http"])
        XCTAssertEqual(list[0].plugins.first?.contentHash, "h"); XCTAssertEqual(list[0].totalConversion, "conv")
        XCTAssertEqual(list[0].website, "https://a.example.com"); XCTAssertNil(list[1].website)
        XCTAssertEqual(ServerDirectory.parse(Data("[]".utf8)), .failure(.notAServerList))
        XCTAssertEqual(ServerDirectory.parse(Data("{\"version\":1,\"servers\":[]}".utf8)), .success([]))
    }

    func testRowsFilterAndSort() throws {
        func entry(_ id: String, region: String = "eu") -> DirectoryServer {
            DirectoryServer(id: id, name: id, host: "\(id).x", port: 53735, region: region, description: "", ownerName: "", contact: "",
                            rules: "safe", plugins: [], maxPlayers: 8, added: "", website: nil)
        }
        let rows = [
            ServerRow(entry: entry("off"), live: nil, rtt: nil, checking: false),
            ServerRow(entry: entry("slow"), live: ServerBeacon(name: "slow", players: 0, max: 8), rtt: 90, checking: false),
            ServerRow(entry: entry("fast", region: "na-east"), live: ServerBeacon(name: "fast", players: 3, max: 8), rtt: 20, checking: false),
            ServerRow(entry: entry("wait"), live: nil, rtt: nil, checking: true),
            ServerRow(entry: entry("old", region: "as"), live: ServerBeacon(name: "old", players: 1, max: 8, proto: 99), rtt: 10, checking: false),
        ]
        XCTAssertEqual(ServerRow.sorted(rows).map(\.name), ["old", "fast", "slow", "wait", "off"])
        XCTAssertEqual(ServerFilter(compatibleOnly: true).apply(rows).map(\.name).sorted(), ["fast", "slow"])
        XCTAssertEqual(ServerFilter(hasPlayers: true).apply(rows).map(\.name).sorted(), ["fast", "old"])
        XCTAssertEqual(ServerFilter(region: "eu").apply(rows).count, 3)
        XCTAssertTrue(rows[2].isCompatible); XCTAssertFalse(rows[4].isCompatible)
    }

    func testPluginCompatibility() {
        func r(_ id: String, _ h: String, cosmetic: Bool = false) -> PluginRequirement { PluginRequirement(id: id, name: id.uppercased(), contentHash: h, cosmetic: cosmetic) }
        let server = PluginRequirements(plugins: [r("a", "1111111111111111aaaa"), r("b", "2222"), r("art", "x", cosmetic: true)], totalConversion: "tc")
        XCTAssertEqual(server.plugins.map(\.id), ["a", "b"], "cosmetic plug-ins are never part of the requirements")
        let local = PluginRequirements(plugins: [r("a", "1111111111111111zzzz"), r("c", "3333")], totalConversion: nil)
        let c = PluginCompatibility.evaluate(local: local, server: server)
        XCTAssertEqual(c.missing.map(\.id), ["b"]); XCTAssertEqual(c.extra.map(\.id), ["c"]); XCTAssertTrue(c.wrongVersion.isEmpty, "16-hex wire hashes compare by prefix")
        XCTAssertEqual(c.wrongTotalConversion, "tc"); XCTAssertFalse(c.isCompatible)
        let ok = PluginCompatibility.evaluate(local: PluginRequirements(plugins: [r("a", "1111111111111111"), r("b", "2222")], totalConversion: "tc"), server: server)
        XCTAssertTrue(ok.isCompatible)
        XCTAssertEqual(PluginCompatibility.checklist(local: local, server: server).map(\.ok), [true, false])
        let wrong = PluginCompatibility.evaluate(local: PluginRequirements(plugins: [r("a", "ffff"), r("b", "2222")], totalConversion: "tc"), server: server)
        XCTAssertEqual(wrong.wrongVersion.map(\.id), ["a"])
    }

    func testCosmeticPluginsNeverGateTheManifest() {
        let gameplay = PluginRequirement(id: "g", name: "G", contentHash: "h")
        let art = PluginRequirement(id: "art", name: "Art", contentHash: "zzz", cosmetic: true)
        let a = PluginManifest([gameplay]), b = PluginManifest([gameplay, art])
        XCTAssertEqual(a.signature, b.signature)
        XCTAssertTrue(a.isCompatible(with: b)); XCTAssertTrue(a.mismatch(against: b).isCompatible)
        XCTAssertEqual(b.cosmetic.map(\.id), ["art"]); XCTAssertEqual(b.gameplayOnly, a)
        // Codable: manifests from older builds (no `cosmetic` key) still decode.
        let old = #"{"plugins":[{"id":"g","name":"G","contentHash":"h"}]}"#
        XCTAssertEqual((try? JSONDecoder().decode(PluginManifest.self, from: Data(old.utf8)))?.plugins.first?.cosmetic, false)
    }

    func testSavedServersStore() {
        let d = UserDefaults(suiteName: "novaswift.test.\(UUID().uuidString)")!
        let s = SavedServersStore(defaults: d)
        s.save(SavedServer(name: "One", host: "a.com", port: 53735))
        s.save(SavedServer(name: "One renamed", host: "A.com", port: 53735, password: "pw"))
        XCTAssertEqual(s.saved.count, 1); XCTAssertEqual(s.saved.first?.name, "One renamed"); XCTAssertTrue(s.isSaved(host: "a.com", port: 53735))
        s.remove(host: "a.com", port: 53735); XCTAssertTrue(s.saved.isEmpty)
        for i in 0..<12 { s.addRecent(CrossPlayAddress(host: "h\(i)", port: 1)) }
        s.addRecent(CrossPlayAddress(host: "H5", port: 1))
        XCTAssertEqual(s.recent.count, SavedServersStore.maxRecent); XCTAssertEqual(s.recent.first?.host, "H5")
        XCTAssertEqual(s.recent.filter { $0.host.lowercased() == "h5" }.count, 1)
    }
}
