import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftPluginStore

final class PluginIconGeneratorTests: XCTestCase {
    private func res(_ t: NovaSwiftKit.FourCharCode, _ id: Int, name: String = "", _ bytes: [UInt8] = [0, 0]) -> Resource {
        Resource(type: t, id: id, name: name, data: Data(bytes))
    }
    private func collection(_ rs: [Resource]) -> ResourceCollection {
        var c = ResourceCollection(); rs.forEach { c.add($0) }; return c
    }

    func testEmptyPluginHasNoSource() {
        XCTAssertEqual(PluginIconGenerator.selectSource(in: collection([])), .none)
    }

    func testNamedLogoBeatsShip() {
        let c = collection([
            res(NovaType.ship, 128), res(NovaType.shan, 128, [0, 200]), res(NovaType.rleD, 200),
            res(NovaType.pict, 700, name: "Plugin Logo"),
            res(NovaType.cicn, 300, name: "Fancy icon"),
        ])
        XCTAssertEqual(PluginIconGenerator.selectSource(in: c), .cicn(id: 300))
    }

    func testPictLogoWhenNoCicn() {
        let c = collection([res(NovaType.pict, 5000, name: "plain"), res(NovaType.pict, 5001, name: "Logo")])
        XCTAssertEqual(PluginIconGenerator.selectSource(in: c), .pict(id: 5001))
    }

    func testFirstShipWithSpriteIsUsed() {
        let c = collection([
            res(NovaType.ship, 128), res(NovaType.shan, 128, [0, 150]),        // rlëD 150 missing
            res(NovaType.ship, 129), res(NovaType.shan, 129, [0, 151]), res(NovaType.rleD, 151),
        ])
        XCTAssertEqual(PluginIconGenerator.selectSource(in: c), .shipSprite(shipID: 129, rleID: 151))
    }

    func testShipSpriteViaSpin() {
        let c = collection([
            res(NovaType.ship, 128), res(NovaType.shan, 128, [0, 160]),
            res(NovaType.spin, 160, [0, 170]), res(NovaType.rleD, 170),
        ])
        XCTAssertEqual(PluginIconGenerator.selectSource(in: c), .shipSprite(shipID: 128, rleID: 170))
    }

    func testUndecodableResourcesGiveNoPNG() {
        let c = collection([res(NovaType.cicn, 1, name: "logo", [1, 2, 3])])
        XCTAssertNil(PluginIconGenerator.renderPNG(from: c))
    }

    func testMissingPluginFolderCachesNegativeResult() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = tmp.appendingPathComponent("cache")
        XCTAssertNil(PluginIconGenerator.iconPNG(for: "nope", pluginsRoot: tmp, cacheDir: cache))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 1)
        XCTAssertNil(PluginIconGenerator.iconPNG(for: "nope", pluginsRoot: tmp, cacheDir: cache))
    }

    func testSingleFrameCrop() {
        let w = 2, h = 1
        var px = [UInt8](repeating: 0, count: 6 * w * h * 4)
        for i in 0..<px.count { px[i] = UInt8(i % 250) }
        let sheet = SpriteSheet(frameWidth: w, frameHeight: h, frameCount: 6, columns: 6, rows: 1,
                                surfaceWidth: 6 * w, surfaceHeight: h, rgba: px)
        XCTAssertEqual(sheet.singleFrame(1)?.rgba, Array(px[8..<16]))
        XCTAssertNil(sheet.singleFrame(6))
    }
}
