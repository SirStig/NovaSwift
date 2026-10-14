import XCTest
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftENet
@testable import NovaSwiftServerCore

final class PluginManifestTests: XCTestCase {
    func rigWithPlugins() throws -> (TestSupport.Rig, PluginManager) {
        let r = try TestSupport.rig()
        try TestSupport.makePlugin("gameplay-a", in: r.paths.pluginsDir, resources: [("shïp", 128, [1, 2, 3, 4]), ("PICT", 128, [9, 9, 9])])
        try TestSupport.makePlugin("skin-only", in: r.paths.pluginsDir, resources: [("PICT", 200, [5, 5, 5]), ("snd ", 300, [7, 7])])
        return (r, r.plugins)
    }

    func testManifestIsComputedFromTheFiles() throws {
        let (_, pm) = try rigWithPlugins()
        let m = pm.manifest(enabled: ["gameplay-a", "skin-only", "ghost"])
        XCTAssertEqual(m.missing, ["ghost"])
        XCTAssertEqual(m.all.plugins.map(\.id), ["gameplay-a", "skin-only"])
        XCTAssertEqual(m.requirements.plugins.map(\.id), ["gameplay-a"], "gameplay plug-ins are required")
        XCTAssertEqual(m.all.cosmetic.map(\.id), ["skin-only"], "art/sound-only plug-ins are optional")
        XCTAssertEqual(m.all.gameplayOnly.plugins.map(\.id), ["gameplay-a"])
        XCTAssertEqual(m.requirements.plugins[0].contentHash.count, 64)
        XCTAssertNil(m.requirements.totalConversion)
    }

    func testHashCoversGameplayResourcesOnly() throws {
        let (r, pm) = try rigWithPlugins()
        let before = pm.manifest(enabled: ["gameplay-a"]).requirements.plugins[0].contentHash
        // Same ship, different artwork: same gameplay hash.
        try TestSupport.makePlugin("gameplay-a", in: r.paths.pluginsDir, resources: [("shïp", 128, [1, 2, 3, 4]), ("PICT", 128, [0, 0, 0, 0, 0])])
        XCTAssertEqual(pm.manifest(enabled: ["gameplay-a"]).requirements.plugins[0].contentHash, before)
        // Different ship: different hash.
        try TestSupport.makePlugin("gameplay-a", in: r.paths.pluginsDir, resources: [("shïp", 128, [1, 2, 3, 5])])
        XCTAssertNotEqual(pm.manifest(enabled: ["gameplay-a"]).requirements.plugins[0].contentHash, before)
    }

    func testMatchesTheHashThePlayersGameComputes() throws {
        let (r, pm) = try rigWithPlugins()
        // The game's AppModel does exactly this for each enabled bundle; a joiner's hash must equal ours.
        let bundle = GameLibrary.discoverPlugins(in: r.paths.pluginsDir).first { $0.id == "gameplay-a" }!
        XCTAssertEqual(PluginGameplay.analyze(bundle).hash, pm.manifest(enabled: ["gameplay-a"]).requirements.plugins[0].contentHash)
    }

    func testAddLocalPluginFromFile() throws {
        let (r, pm) = try rigWithPlugins()
        var col = ResourceCollection()
        col.add(Resource(type: FourCharCode("shïp")!, id: 150, name: "x", data: Data([4, 4])))
        let tmp = r.root.appendingPathComponent("My Cool Plug-in.rez")
        try RezWriter.write(col).write(to: tmp)
        let id = try pm.addLocal(file: tmp, originalName: "My Cool Plug-in.rez")
        XCTAssertEqual(id, "My Cool Plug-in")
        XCTAssertTrue(pm.installed().contains { $0.id == id && !$0.cosmetic && !$0.fromCatalog })
        XCTAssertThrowsError(try pm.addLocal(file: tmp, originalName: "notes.txt"))
        let junk = r.root.appendingPathComponent("empty.zip")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try pm.addLocal(file: junk, originalName: "empty.zip"))
    }

    func testCatalogParsesFromTheFetchedJSON() throws {
        let r = try TestSupport.rig()
        let json = """
        {"schemaVersion":1,"plugins":[{"id":"demo","name":"Demo","author":"A","version":"1.0","summary":"s","downloadURLs":["https://example.com/demo.zip"]}]}
        """
        r.plugins.catalogFetch = { _ in Data(json.utf8) }
        let done = expectation(description: "catalog")
        r.plugins.refreshCatalog { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(r.plugins.catalog.entries.map(\.id), ["demo"])
        XCTAssertEqual(r.plugins.catalog.source, "remote")
        // Offline later: the saved copy is used.
        r.plugins.catalogFetch = { _ in throw URLError(.notConnectedToInternet) }
        let done2 = expectation(description: "offline")
        r.plugins.refreshCatalog { done2.fulfill() }
        wait(for: [done2], timeout: 5)
        XCTAssertEqual(r.plugins.catalog.entries.map(\.id), ["demo"])
        XCTAssertNotNil(r.plugins.catalog.error)
    }

    func testInstallFromCatalogUsesTheDownloader() throws {
        let r = try TestSupport.rig()
        let json = """
        {"schemaVersion":1,"plugins":[{"id":"demo-pack","name":"Demo Pack","author":"A","version":"2.0","summary":"s","downloadURLs":["https://example.com/demo.rez"]}]}
        """
        r.plugins.catalogFetch = { _ in Data(json.utf8) }
        let loaded = expectation(description: "catalog")
        r.plugins.refreshCatalog { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        var col = ResourceCollection()
        col.add(Resource(type: FourCharCode("shïp")!, id: 130, name: "x", data: Data(repeating: 7, count: 2000)))
        let src = r.root.appendingPathComponent("demo.rez")
        try RezWriter.write(col).write(to: src)
        r.plugins.archiveFetch = { _, _ in (src, "demo.rez") }
        let done = expectation(description: "install")
        r.plugins.install(catalogID: "demo-pack") { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(r.plugins.isInstalled("demo-pack"))
        XCTAssertEqual(r.plugins.job("demo-pack")?.state, .done)
        let m = r.plugins.manifest(enabled: ["demo-pack"])
        XCTAssertEqual(m.requirements.plugins.map(\.id), ["demo-pack"])
        XCTAssertEqual(m.requirements.plugins.first?.name, "Demo Pack")
        // Unknown id fails in plain language.
        r.plugins.install(catalogID: "nope")
        XCTAssertEqual(r.plugins.job("nope")?.state, .failed)
    }
}
