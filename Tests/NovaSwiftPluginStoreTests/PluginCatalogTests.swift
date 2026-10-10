import XCTest
import NovaSwiftKit
@testable import NovaSwiftPluginStore

final class PluginCatalogTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func entry(_ id: String, version: String = "1.0", tc: Bool = false, tags: [String] = [],
                       pop: Int = 0, updated: String? = nil, deps: [String] = []) -> PluginCatalogEntry {
        PluginCatalogEntry(id: id, name: id.capitalized, author: "A", version: version, summary: "s",
                           tags: tags, isTotalConversion: tc,
                           downloadURLs: [URL(string: "https://example.com/\(id).zip")!],
                           dependencies: deps, addedDate: "2026-01-01", updatedDate: updated, popularity: pop)
    }

    private func json(_ doc: PluginCatalogDocument) -> Data { try! JSONEncoder().encode(doc) }

    // MARK: decoding

    func testBundledCatalogDecodesAndIsInstallable() {
        XCTAssertEqual(PluginCatalog.bundled.schemaVersion, 1)
        XCTAssertEqual(PluginCatalog.all.count, 23)
        for e in PluginCatalog.all {
            XCTAssertFalse(e.summary.isEmpty, e.id)
            XCTAssertFalse(e.downloadURLs.isEmpty, e.id)
            XCTAssertEqual(e.downloadURLs.first?.scheme, "https", e.id)
            XCTAssertNotNil(e.sizeBytes, e.id)
            for d in e.dependencies { XCTAssertNotNil(PluginCatalog.entry(id: d), "\(e.id) -> \(d)") }
        }
    }

    func testMinimalEntryGetsDefaults() throws {
        let raw = #"{"schemaVersion":1,"plugins":[{"id":"x","name":"X","author":"Me","summary":"s"}]}"#
        let doc = try PluginCatalogProvider.decode(Data(raw.utf8))
        let e = try XCTUnwrap(doc.plugins.first)
        XCTAssertEqual(e.version, "1.0")
        XCTAssertTrue(e.downloadURLs.isEmpty)
        XCTAssertEqual(e.popularity, 0)
        XCTAssertFalse(e.isTotalConversion)
    }

    func testRejectsNewerSchemaAndDuplicates() {
        XCTAssertThrowsError(try PluginCatalogProvider.decode(json(PluginCatalogDocument(schemaVersion: 99, plugins: []))))
        let dup = PluginCatalogDocument(plugins: [entry("a"), entry("a")])
        XCTAssertThrowsError(try PluginCatalogProvider.decode(json(dup))) {
            XCTAssertEqual($0 as? PluginCatalogError, .duplicateIDs(["a"]))
        }
    }

    // MARK: fallback + caching

    func testRemoteSuccessIsCachedThenUsedOffline() async throws {
        let cache = tmp().appendingPathComponent("c.json")
        let remote = PluginCatalogDocument(plugins: [entry("remote-one")])
        let ok = PluginCatalogProvider(cacheFile: cache, bundled: PluginCatalogDocument(plugins: [entry("bundled")])) { _ in
            self.json(remote)
        }
        let first = await ok.load()
        XCTAssertEqual(first.source, .remote)
        XCTAssertEqual(first.document.plugins.map(\.id), ["remote-one"])

        let offline = PluginCatalogProvider(cacheFile: cache, bundled: PluginCatalogDocument(plugins: [entry("bundled")])) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let second = await offline.load()
        XCTAssertEqual(second.source, .cache)
        XCTAssertEqual(second.document.plugins.map(\.id), ["remote-one"])
        XCTAssertNotNil(second.remoteError)
    }

    func testFallsBackToBundledWithoutCache() async {
        let p = PluginCatalogProvider(cacheFile: tmp().appendingPathComponent("none.json"),
                                      bundled: PluginCatalogDocument(plugins: [entry("bundled")])) { _ in
            throw URLError(.timedOut)
        }
        let r = await p.load()
        XCTAssertEqual(r.source, .bundled)
        XCTAssertEqual(r.document.plugins.map(\.id), ["bundled"])
    }

    func testGarbageRemoteDoesNotOverwriteGoodCache() async throws {
        let cache = tmp().appendingPathComponent("c.json")
        let good = PluginCatalogProvider(cacheFile: cache, bundled: PluginCatalogDocument(plugins: [])) { _ in
            self.json(PluginCatalogDocument(plugins: [self.entry("keep")]))
        }
        _ = await good.load()
        let bad = PluginCatalogProvider(cacheFile: cache, bundled: PluginCatalogDocument(plugins: [])) { _ in
            Data("<html>404</html>".utf8)
        }
        let r = await bad.load()
        XCTAssertEqual(r.source, .cache)
        XCTAssertEqual(r.document.plugins.map(\.id), ["keep"])
    }

    // MARK: browser / manager state

    func testFiltersAndSorts() {
        let es = [
            entry("tc-old", tc: true, tags: ["story"], pop: 5, updated: "2025-01-01"),
            entry("gfx", tags: ["graphics", "patch"], pop: 9, updated: "2026-05-01"),
            entry("tweak", tags: ["gameplay"], pop: 1),
        ]
        let b = PluginBrowser(entries: es, installedVersions: ["gfx": "0.9", "tweak": ""])
        XCTAssertEqual(b.results(filter: .popular).map(\.id), ["gfx", "tc-old", "tweak"])
        XCTAssertEqual(b.results(filter: .recent).first?.id, "gfx")
        XCTAssertEqual(b.results(filter: .totalConversions).map(\.id), ["tc-old"])
        XCTAssertEqual(b.results(filter: .story).map(\.id), ["tc-old"])
        XCTAssertEqual(b.results(filter: .installed).map(\.id), ["gfx", "tweak"])
        XCTAssertEqual(b.results(filter: .updates).map(\.id), ["gfx"])
        XCTAssertEqual(b.results(filter: .popular, query: "TWE").map(\.id), ["tweak"])
        XCTAssertEqual(b.results(filter: .ships).count, 0)
    }

    func testStatusAndVersionCompare() {
        let e = entry("p", version: "1.10")
        let b = PluginBrowser(entries: [e], installedVersions: ["p": "1.9"])
        XCTAssertEqual(b.status(for: e), .updateAvailable(installed: "1.9", latest: "1.10"))
        let same = PluginBrowser(entries: [e], installedVersions: ["p": "1.10"])
        XCTAssertEqual(same.status(for: e), .installed(version: "1.10"))
        XCTAssertEqual(PluginBrowser(entries: [e]).status(for: e), .notInstalled)
    }

    func testMissingDependencies() {
        let e = entry("child", deps: ["base-tc", "other"])
        let b = PluginBrowser(entries: [e], installedVersions: ["base-tc": "1.0"])
        XCTAssertEqual(b.missingDependencies(of: e), ["other"])
    }

    // MARK: install pipeline

    func testPipelineInstallsLooseRezAndRecordsVersion() async throws {
        let src = tmp().appendingPathExtension("rez")
        try Data("not really a rez".utf8).write(to: src)
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = entry("loose", version: "2.1")
        let dir = try await PluginInstallPipeline.install(e, into: root, download: { _, _, _ in (src, "Loose.rez") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Loose.rez").path))
        XCTAssertEqual(PluginInstaller.info(id: "loose", in: root)?.version, "2.1")
        XCTAssertEqual(PluginInstaller.files(id: "loose", in: root).map(\.path), ["Loose.rez"])
        // Metadata file must not be mistaken for a plug-in file.
        XCTAssertEqual(GameLibrary.discoverPlugins(in: root).count, 1)
    }

    func testPipelineRejectsUnknownFormat() async throws {
        let src = tmp().appendingPathExtension("sit")
        try Data("SIT!".utf8).write(to: src)
        let root = tmp()
        do {
            _ = try await PluginInstallPipeline.install(entry("sit"), into: root, download: { _, _, _ in (src, "x.sit") })
            XCTFail("should throw")
        } catch {
            XCTAssertFalse(PluginInstaller.isInstalled(id: "sit", in: root))
        }
    }

    func testSHA256() throws {
        let f = tmp()
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try PluginDownloader.sha256Hex(of: f),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: image cache

    func testImageCacheDownloadsOnce() async throws {
        final class Counter: @unchecked Sendable { var n = 0; let l = NSLock(); func bump() { l.lock(); n += 1; l.unlock() } }
        let counter = Counter()
        let dir = tmp()
        let url = URL(string: "https://example.com/i.png")!
        let c1 = RemoteImageCache(directory: dir) { _ in counter.bump(); return Data([1, 2, 3]) }
        _ = try await c1.data(for: url)
        _ = try await c1.data(for: url)
        // A fresh cache instance (new launch) reads from disk.
        let c2 = RemoteImageCache(directory: dir) { _ in counter.bump(); return Data([9]) }
        let d = try await c2.data(for: url)
        XCTAssertEqual(d, Data([1, 2, 3]))
        XCTAssertEqual(counter.n, 1)
    }
}
