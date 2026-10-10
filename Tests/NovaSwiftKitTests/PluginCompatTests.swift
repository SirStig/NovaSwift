import XCTest
import Foundation
@testable import NovaSwiftKit

/// Plug-in discovery order and total conversions (compat R1, R2). Synthetic data only.
final class PluginCompatTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("novaswift-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func put(_ type: String, _ res: [(Int, String)], at path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ClassicForkBuilder.build(type: type, resources: res.map { (id: $0.0, name: $0.1, payload: Data([1])) }).write(to: url)
        return url
    }

    func testFlatFileOrderAcrossFoldersAndInertSubfolders() throws {
        // Flat order by file name: alpha < Zeta, whatever folder they sit in.
        try put("shïp", [(128, "Z")], at: "plugins/Zeta.ndat")
        try put("shïp", [(128, "A")], at: "plugins/Folder/alpha.ndat")
        try put("shïp", [(128, "O")], at: "plugins/Folder/Optionals/opt.ndat")
        let bundles = GameLibrary.originalPluginOrder(GameLibrary.discoverPlugins(in: root.appendingPathComponent("plugins")))
        XCTAssertEqual(bundles.filter(\.isEnabled).count, 2, "the Optionals sub-item is inert")
        let base = try put("shïp", [(128, "Base")], at: "base/b.ndat")
        let merged = try GameLibrary.merge(baseFiles: [base], plugins: bundles)
        XCTAssertEqual(merged.resource(NovaType.ship, 128)?.name, "Z")
    }

    func testFileNameOrderIsCaseInsensitive() throws {
        try put("shïp", [(128, "lower")], at: "plugins/b.ndat")
        try put("shïp", [(128, "upper")], at: "plugins/B2.ndat")
        let base = try put("shïp", [(128, "Base")], at: "base/b.ndat")
        let bundles = GameLibrary.originalPluginOrder(GameLibrary.discoverPlugins(in: root.appendingPathComponent("plugins")))
        let merged = try GameLibrary.merge(baseFiles: [base], plugins: bundles)
        XCTAssertEqual(merged.resource(NovaType.ship, 128)?.name, "upper", "b.ndat < B2.ndat")
    }

    func testTotalConversionReplacesStockNovaFiles() throws {
        let novaRez = try put("STR#", [(130, "stock")], at: "base/Nova.rez")
        let stock = try put("sÿst", [(128, "S1"), (129, "S2")], at: "base/Nova Files/a.ndat")
        try put("sÿst", [(128, "TC1")], at: "tcs/tc/Nova Files/b.ndat")
        try put("shïp", [(200, "tcPlug")], at: "tcs/tc/Plug-Ins/p.ndat")
        try Data("{}".utf8).write(to: root.appendingPathComponent("tcs/tc/Play.nplay"))
        try put("shïp", [(300, "global")], at: "tcs/g.ndat")

        var plugins = GameLibrary.discoverPlugins(in: root.appendingPathComponent("tcs"))
        let tcIdx = try XCTUnwrap(plugins.firstIndex { $0.isTotalConversion })
        XCTAssertEqual(plugins[tcIdx].id, "tc")
        // Auto-loading never picks a TC.
        let auto = GameLibrary.originalPluginOrder(plugins)
        XCTAssertFalse(auto.first { $0.id == "tc" }!.isEnabled)
        let stockOnly = try GameLibrary.merge(baseFiles: [novaRez, stock], plugins: auto)
        XCTAssertNotNil(stockOnly.resource(NovaType.syst, 129))

        plugins[tcIdx].isEnabled = true
        plugins = GameLibrary.originalPluginOrder(plugins)
        let merged = try GameLibrary.merge(baseFiles: [novaRez, stock], plugins: plugins)
        XCTAssertEqual(merged.resource(NovaType.syst, 128)?.name, "TC1")
        XCTAssertNil(merged.resource(NovaType.syst, 129), "stock Nova Files do not load")
        XCTAssertNotNil(merged.resource(FourCharCode("STR#")!, 130), "Nova.rez is shared")
        XCTAssertNotNil(merged.resource(NovaType.ship, 200), "the TC's own Plug-Ins load")
        XCTAssertNil(merged.resource(NovaType.ship, 300), "global plug-ins do not apply")
    }
}
