import XCTest
@testable import NovaSwiftKit

/// Batch 0 of FIDELITY_PLAN.md: the loader's normalisations (LD-01, LD-02),
/// load order (UI-16), commodity base prices (EC-01) and the buoy string (UI-12).
final class LoaderFidelityTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func record(_ type: NovaSwiftKit.FourCharCode, _ id: Int, size: Int, _ fields: [(Int, Int)] = []) -> Resource {
        var b = [UInt8](repeating: 0, count: size)
        for (off, v) in fields { put16(&b, off, v) }
        return Resource(type: type, id: id, data: Data(b))
    }

    private func strList(_ id: Int, _ strings: [String]) -> Resource {
        var b: [UInt8] = [UInt8(strings.count >> 8), UInt8(strings.count & 0xff)]
        for s in strings { b.append(UInt8(s.utf8.count)); b += Array(s.utf8) }
        return Resource(type: NovaType.strList, id: id, data: Data(b))
    }

    private func str(_ id: Int, _ s: String) -> Resource {
        Resource(type: NovaSwiftKit.FourCharCode("STR ")!, id: id, data: Data([UInt8(s.utf8.count)] + Array(s.utf8)))
    }

    // MARK: EC-01

    func testCommodityPricesComeFromSTR4004WithTheOriginalScale() {
        var col = ResourceCollection()
        col.add(strList(4004, ["75", "350", "750", "900", "200", "550"]))
        col.add(str(9301, "400"))   // a plug-in's single-string override wins
        let game = NovaGame(col)
        XCTAssertEqual(game.commodityBasePrice(.food), 75)
        XCTAssertEqual(game.commodityBasePrice(.industrial), 400)
        let medical = game.commodityPrices(.medical)
        XCTAssertEqual([medical.low, medical.medium, medical.high], [600, 750, 937])
        let food = game.commodityPrices(.food)
        XCTAssertEqual([food.low, food.medium, food.high], [60, 75, 93])
        // Floor of 5 on every level.
        let tiny = Commodity.prices(base: 4)
        XCTAssertEqual([tiny.low, tiny.medium, tiny.high], [5, 5, 5])
    }

    // MARK: UI-12

    func testBuoyMessageIsOneBasedWithSTROverride() {
        var col = ResourceCollection()
        col.add(strList(1000, ["first", "second", "third"]))
        col.add(str(1002, "override for 3"))
        let game = NovaGame(col)
        XCTAssertNil(game.systemMessageText(0))
        XCTAssertNil(game.systemMessageText(-1))
        XCTAssertEqual(game.systemMessageText(1), "first")
        XCTAssertEqual(game.systemMessageText(2), "second")
        XCTAssertEqual(game.systemMessageText(3), "override for 3")
        XCTAssertNil(game.systemMessageText(4))
    }

    // MARK: LD-02 and UI-16 slot ranges

    func testShortRecordsArePaddedAndOutOfSlotIdsDropped() throws {
        var col = ResourceCollection()
        col.add(record(NovaType.ship, 128, size: 100, [(2, 70)]))
        col.add(record(NovaType.ship, 1000, size: 1860))      // past shïp slot 0x2ff
        col.add(record(NovaType.weapon, 383, size: 134))      // last wëap slot
        col.add(record(NovaType.weapon, 384, size: 134))
        col.add(record(NovaType.mission, 5000, size: 10))     // mïsn: 1000 slots (0x0043bbb0)
        col.add(record(NovaType.mission, 1127, size: 10))
        col.normalizeScenarioRecords()

        let ship = try XCTUnwrap(col.resource(NovaType.ship, 128))
        XCTAssertEqual(ship.data.count, 1860)
        XCTAssertEqual(ShipRes(ship).shield, 70)
        XCTAssertEqual(ShipRes(ship).escortCategory, 0, "a missing tail reads as zeros")
        XCTAssertNil(col.resource(NovaType.ship, 1000))
        XCTAssertNotNil(col.resource(NovaType.weapon, 383))
        XCTAssertNil(col.resource(NovaType.weapon, 384))
        XCTAssertNil(col.resource(NovaType.mission, 5000))
        XCTAssertEqual(col.resource(NovaType.mission, 1127)?.data.count, 1970)
    }

    // MARK: UI-16 order

    func testOriginalLoadOrder() {
        let base = [URL(fileURLWithPath: "/d/Nova Files/Nova Data 2.ndat"),
                    URL(fileURLWithPath: "/d/Nova.rez"),
                    URL(fileURLWithPath: "/d/Nova Files/nova data 1.ndat")]
        XCTAssertEqual(GameLibrary.baseLoadOrder(base).map(\.lastPathComponent),
                       ["Nova.rez", "nova data 1.ndat", "Nova Data 2.ndat"],
                       "Nova.rez loads first, so it is the weakest layer")

        let plugins = ["b.rez", "A.rez", "c.rez"].map {
            PluginBundle(id: $0, name: $0, fileURLs: [URL(fileURLWithPath: "/p/\($0)")])
        }
        let ordered = GameLibrary.originalPluginOrder(plugins)
        XCTAssertEqual(ordered.map(\.id), ["A.rez", "b.rez", "c.rez"])
        XCTAssertTrue(ordered.allSatisfy(\.isEnabled), "every installed plug-in loads")
    }

    // MARK: LD-01

    func testLoaderNormalisedFields() {
        let govt = GovtRes(record(NovaType.govt, 128, size: 192, [(22, 0), (48, 0)]))
        XCTAssertEqual(govt.maxOddsRatio, 0.01, accuracy: 1e-12)
        XCTAssertEqual(govt.skillMult, 1.0)
        let govt2 = GovtRes(record(NovaType.govt, 129, size: 192, [(22, 250), (48, 120)]))
        XCTAssertEqual(govt2.maxOddsRatio, 2.5, accuracy: 1e-12)
        XCTAssertEqual(govt2.skillMult, 1.2, accuracy: 1e-12)

        let ship = ShipRes(record(NovaType.ship, 128, size: 1860,
                                  [(96, 0), (904, 150), (906, -3), (66, 2), (1842, -1)]))
        XCTAssertEqual(ship.skillVar, 1)
        XCTAssertEqual(ship.buyRandom, 100)
        XCTAssertEqual(ship.hireRandom, 0)
        XCTAssertEqual(ship.escortClass, 3, "Automatic with InherentAI < 3 is a freighter")
        XCTAssertEqual(ShipRes(record(NovaType.ship, 129, size: 1860, [(96, 80)])).skillVar, 50)
        let fighter = ShipRes(record(NovaType.ship, 130, size: 1860, [(66, 4), (62, 30), (1842, 9)]))
        XCTAssertEqual(fighter.escortClass, 0)

        let outfit = OutfRes(record(NovaType.outfit, 128, size: 1028, [(1008, -1)]))
        XCTAssertEqual(outfit.buyRandom, 0)

        for (raw, level) in [(0, 1), (1, 1), (2, 2), (3, 4), (7, 4)] {
            XCTAssertEqual(PersRes(record(NovaType.pers, 128, size: 400, [(6, raw)])).aggressionLevel, level)
        }

        let syst = SystRes(record(NovaType.syst, 128, size: 428,
                                  [(110, 200), (112, -1), (126, 30), (128, 50), (114, 201), (130, 140)]))
        XCTAssertEqual(syst.persons.map(\.id), [200, 201])
        XCTAssertEqual(syst.persons.map(\.chance), [30, 100])
    }

    // MARK: Stock data

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    func testStockCommodityPricesAndBuoys() throws {
        let game = try stockGame()
        XCTAssertEqual(Commodity.allCases.map(game.commodityBasePrice), [75, 350, 750, 900, 200, 550])
        let list = try XCTUnwrap(game.stringList(1000))
        XCTAssertEqual(game.systemMessageText(1), list.strings[0])
        // Every in-range buoy resolves (Nil'kol's 20003 has no string and shows nothing).
        let buoyed = game.systems().filter { $0.message > 0 && $0.message <= list.strings.count }
        XCTAssertFalse(buoyed.isEmpty)
        for sys in buoyed { XCTAssertEqual(game.systemMessageText(sys.message), list.strings[sys.message - 1], sys.name) }
    }

    func testStockRecordsMeetMinimumSizes() throws {
        let game = try stockGame()
        for (type, size) in NovaType.minimumRecordSize {
            for r in game.resources.resources(of: type) {
                XCTAssertGreaterThanOrEqual(r.data.count, size, "\(type) #\(r.id)")
            }
        }
        for (type, range) in NovaType.slotRange {
            XCTAssertTrue(game.resources.resources(of: type).allSatisfy { range.contains($0.id) }, "\(type)")
        }
    }
}
