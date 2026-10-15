import XCTest
@testable import NovaSwiftServerCore
import NovaSwiftNet

final class ConfigTests: XCTestCase {
    func testFreshDefaultsAreSensible() {
        let c = ServerConfig.fresh(hostname: "joshuas-macbook-air.local").normalized()
        XCTAssertLessThanOrEqual(c.name.count, CrossPlayProtocol.maxNameLength)
        XCTAssertTrue(c.name.contains("Joshuas"), c.name)
        XCTAssertEqual(c.port, 53735)
        XCTAssertEqual(c.adminPort, 53737)
        XCTAssertEqual(c.maxPlayers, 8)
        XCTAssertEqual(c.password, "")
        XCTAssertEqual(c.rulesPreset, "safe")
        XCTAssertFalse(c.setupDone)
        XCTAssertTrue(c.problems().isEmpty, "\(c.problems())")
    }

    func testDefaultNameFitsTheLimit() {
        XCTAssertEqual(ServerConfig.defaultName(hostname: "bob"), "Bob's NovaSwift server")
        XCTAssertEqual(ServerConfig.defaultName(hostname: "localhost"), "My's NovaSwift server")
        for h in ["a-very-long-computer-hostname-here", "x", "DESKTOP-ABC123"] {
            let n = ServerConfig.defaultName(hostname: h)
            XCTAssertLessThanOrEqual(n.count, CrossPlayProtocol.maxNameLength, n)
            XCTAssertTrue(n.hasSuffix("server") || n.hasSuffix("NovaSwift"), n)
        }
    }

    func testRenderParseRoundTrip() {
        var c = ServerConfig.fresh(hostname: "box")
        c.name = "Sector 7"; c.description = "Co-op # night"; c.port = 54000; c.maxPlayers = 12; c.password = "s3cret"
        c.motd = "Welcome, pilot!"; c.region = "eu"; c.lanAnnounce = false; c.upnp = true
        c.rulesPreset = "custom"; c.pvpDamageReal = true; c.deathReal = true; c.friendlyFire = true; c.allowPvP = false; c.allowTrade = false; c.gameSpeed = 1.5
        c.adminPort = 54001; c.adminBind = "127.0.0.1"; c.adminPasswordHash = AdminPassword.hash("x12345678"); c.setupDone = true
        c.enabledPlugins = ["frozen-heart", "my local"]
        c.publicListed = true; c.publicAddress = "play.example.com"; c.ownerName = "Me"; c.ownerContact = "me#1"; c.website = "https://example.com"
        c.checkForUpdates = false; c.autoUpdate = true
        c.bans = ["203.0.113.7": "griefing", "198.51.100.2": "spam"]
        let text = c.render()
        XCTAssertTrue(text.contains("# You normally never need to edit this file"))
        let (back, warnings) = ServerConfig.parse(text)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(back, c)
    }

    func testBadValuesWarnButNeverFail() {
        let (c, w) = ServerConfig.parse("""
        [server]
        port = banana
        max_players = 4
        mystery = 1
        [rules]
        allow_pvp = maybe
        garbage line
        """)
        XCTAssertEqual(c.port, 53735)
        XCTAssertEqual(c.maxPlayers, 4)
        XCTAssertEqual(w.count, 4, "\(w)")
        XCTAssertTrue(w.contains { $0.contains("server.port") })
    }

    func testNormalizeClampsAndProblemsExplain() {
        var c = ServerConfig.fresh(hostname: "h")
        c.maxPlayers = 500; c.port = 80; c.gameSpeed = 99; c.rulesPreset = "weird"; c.region = "mars"; c.adminBind = "8.8.8.8"
        let n = c.normalized()
        XCTAssertEqual(n.maxPlayers, 64); XCTAssertEqual(n.port, 53735); XCTAssertEqual(n.gameSpeed, 4.0)
        XCTAssertEqual(n.rulesPreset, "safe"); XCTAssertEqual(n.region, "global"); XCTAssertEqual(n.adminBind, "127.0.0.1")
        var d = ServerConfig.fresh(hostname: "h"); d.adminPort = d.port + 1
        XCTAssertTrue(d.problems().contains { $0.contains("clashes") })
        d.adminPort = 53737; d.port = 80
        XCTAssertTrue(d.problems().contains { $0.contains("game port") })
    }

    func testRulesMapping() {
        var c = ServerConfig(); c.rulesPreset = "full"
        XCTAssertEqual(CrossPlayProtocol.presetName(c.sessionRules), "full")
        c.rulesPreset = "safe"; c.gameSpeed = 2
        XCTAssertEqual(c.sessionRules.gameSpeedMultiplier, 2)
        XCTAssertEqual(CrossPlayProtocol.presetName(c.sessionRules), "safe")
        c.rulesPreset = "custom"; c.allowTrade = false; c.pvpDamageReal = true
        XCTAssertEqual(CrossPlayProtocol.presetName(c.sessionRules), "custom")
        XCTAssertFalse(c.sessionRules.allowTrade)
    }

    func testConfigStoreCreatesFileOnFirstRunAndPersists() throws {
        let root = TestSupport.tempRoot()
        let paths = ServerPaths(root: root)
        let s1 = try ConfigStore(paths: paths)
        XCTAssertTrue(s1.createdNew)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pluginsDir.path))
        try s1.update { $0.name = "Changed"; $0.maxPlayers = 3 }
        let s2 = try ConfigStore(paths: paths)
        XCTAssertFalse(s2.createdNew)
        XCTAssertEqual(s2.config.name, "Changed"); XCTAssertEqual(s2.config.maxPlayers, 3)
    }

    func testPathResolutionOrder() {
        let p = ServerPaths.resolve(explicit: "/tmp/x-explicit", environment: ["NOVASWIFT_SERVER_DIR": "/tmp/x-env"])
        XCTAssertEqual(p.root.path, "/tmp/x-explicit")
        let q = ServerPaths.resolve(explicit: nil, environment: ["NOVASWIFT_SERVER_DIR": "/tmp/x-env"])
        XCTAssertEqual(q.root.path, "/tmp/x-env")
        // A dev build directory never becomes the data folder.
        let dev = ServerPaths.resolve(explicit: nil, executable: URL(fileURLWithPath: "/repo/.build/debug/NovaSwiftServer"), environment: [:])
        XCTAssertFalse(dev.root.path.contains(".build"))
        // A writable folder next to the program wins (portable download).
        let tmp = TestSupport.tempRoot()
        let beside = ServerPaths.resolve(explicit: nil, executable: tmp.appendingPathComponent("NovaSwiftServer"), environment: [:])
        XCTAssertEqual(beside.root.standardizedFileURL.path, tmp.standardizedFileURL.path)
    }

    func testOptionsParsing() {
        let o = ServerOptions.parse(["--data", "/d", "--port", "1234", "--admin-port", "2345", "--no-browser", "--no-stdin"])
        XCTAssertEqual(o.dataDir, "/d"); XCTAssertEqual(o.port, 1234); XCTAssertEqual(o.adminPort, 2345)
        XCTAssertTrue(o.noBrowser && o.noStdin); XCTAssertTrue(o.errors.isEmpty)
        XCTAssertFalse(ServerOptions.parse(["--bogus"]).errors.isEmpty)
        XCTAssertFalse(ServerOptions.parse(["--port", "x"]).errors.isEmpty)
        XCTAssertFalse(ServerOptions.parse(["--port"]).errors.isEmpty)
    }
}

final class AdminPasswordTests: XCTestCase {
    func testHashVerifyAndFormat() {
        let h = AdminPassword.hash("correct horse")
        XCTAssertTrue(h.hasPrefix("sha256i$"))
        XCTAssertFalse(h.contains("correct horse"))
        XCTAssertTrue(AdminPassword.verify("correct horse", against: h))
        XCTAssertFalse(AdminPassword.verify("correct horsf", against: h))
        XCTAssertFalse(AdminPassword.verify("", against: h))
        XCTAssertFalse(AdminPassword.verify("anything", against: ""))
        XCTAssertFalse(AdminPassword.verify("anything", against: "garbage$1$zz$zz"))
        XCTAssertNotEqual(h, AdminPassword.hash("correct horse"), "salted")
    }

    func testGeneratedPasswordIsReadable() {
        for _ in 0..<20 {
            let p = AdminPassword.generate()
            XCTAssertEqual(p.count, 14)
            XCTAssertNil(p.firstIndex(where: { "01ol".contains($0) }), p)
        }
    }
}

final class ServerVersionOrderTests: XCTestCase {
    func testPreReleasesRankBelowTheirRelease() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-beta.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "1.0.0-beta.1"), "the final release must reach beta servers")
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-beta.10", than: "1.0.0-beta.2"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0-rc.1", than: "1.0.0-beta.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0-beta.1"))
    }
}
