import XCTest
import Foundation
@testable import NovaSwiftKit

final class GameLibraryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testDiscoverAndMergeAppliesOverrides() throws {
        // Base: ship 128 "Base". Stored as .ndat (classic fork in a data fork).
        let baseData = ClassicForkBuilder.build(type: "shïp", resources: [
            (id: 128, name: "Base", payload: Data([0x00])),
        ])
        _ = try write(baseData, to: "base/Nova Data 1.ndat")

        // Plugin (folder): overrides ship 128 → "Modded" and adds ship 200 "New".
        let pluginData = ClassicForkBuilder.build(type: "shïp", resources: [
            (id: 128, name: "Modded", payload: Data([0xFF])),
            (id: 200, name: "New", payload: Data([0x42])),
        ])
        _ = try write(pluginData, to: "plugins/My Mod/data.ndat")

        let baseDir = tempRoot.appendingPathComponent("base")
        let pluginsDir = tempRoot.appendingPathComponent("plugins")

        let baseFiles = GameLibrary.discoverResourceFiles(in: baseDir)
        XCTAssertEqual(baseFiles.count, 1)

        let plugins = GameLibrary.discoverPlugins(in: pluginsDir)
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].name, "My Mod")
        XCTAssertEqual(plugins[0].fileURLs.count, 1)
        XCTAssertFalse(plugins[0].isEnabled) // discovered disabled by default

        let ship = try XCTUnwrap(FourCharCode("shïp"))

        // Disabled plug-in must not affect the base.
        let baseOnly = try GameLibrary.merge(baseFiles: baseFiles, plugins: plugins)
        XCTAssertEqual(baseOnly.totalCount, 1)
        XCTAssertEqual(baseOnly.resource(ship, 128)?.name, "Base")

        // Enable it → override 128, add 200.
        var enabled = plugins
        enabled[0].isEnabled = true
        let merged = try GameLibrary.merge(baseFiles: baseFiles, plugins: enabled)
        XCTAssertEqual(merged.totalCount, 2)
        XCTAssertEqual(merged.resource(ship, 128)?.name, "Modded")
        XCTAssertEqual(merged.resource(ship, 200)?.name, "New")
    }

    func testLooseFileBecomesItsOwnPlugin() throws {
        let data = ClassicForkBuilder.build(type: "oütf", resources: [
            (id: 128, name: "Thing", payload: Data([0x01])),
        ])
        _ = try write(data, to: "plugins/Standalone.ndat")
        let plugins = GameLibrary.discoverPlugins(in: tempRoot.appendingPathComponent("plugins"))
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].name, "Standalone")
    }
}
