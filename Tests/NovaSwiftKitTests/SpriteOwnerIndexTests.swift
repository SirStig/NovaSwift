import XCTest
@testable import NovaSwiftKit

final class SpriteOwnerIndexTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func res(_ type: NovaSwiftKit.FourCharCode, _ id: Int, _ name: String, size: Int = 200, _ fields: [Int: Int]) -> Resource {
        var b = [UInt8](repeating: 0, count: size)
        for (off, v) in fields { put16(&b, off, v) }
        return Resource(type: type, id: id, name: name, data: Data(b))
    }

    private func fixture() -> NovaGame {
        var c = ResourceCollection()
        // Two hulls share base sprite 1000; the second also has an engine layer 1001.
        c.add(res(NovaType.ship, 128, "Kestrel", [:]))
        c.add(res(NovaType.ship, 129, "Kestrel (Escort)", [:]))
        c.add(res(NovaType.shan, 128, "", [0: 1000, 4: 1]))
        c.add(res(NovaType.shan, 129, "", [0: 1000, 4: 1, 22: 1001]))
        // spïn 1128 -> sprite 2000, used by planet 150 in system 130.
        c.add(res(NovaType.spin, 1128, "", [0: 2000]))
        c.add(res(NovaType.spob, 150, "Earth", [4: 128]))
        c.add(res(NovaType.syst, 130, "Sol", size: 428, [36: 150]))
        // wëap 140 -> spïn 3005 -> sprite 3000; bööm 129 (+400) -> spïn 529 -> sprite 4000.
        c.add(res(NovaType.spin, 3005, "", [0: 3000]))
        c.add(res(NovaType.weapon, 140, "Blaster", [14: 5]))
        c.add(res(NovaType.spin, 529, "", [0: 4000]))
        c.add(res(NovaType.boom, 129, "Pop", [4: 129]))
        // röid 128 -> spïn 800 -> sprite 5000. Unowned spïn 700 -> sprite 6000.
        c.add(res(NovaType.spin, 800, "", [0: 5000]))
        c.add(res(NovaType.roid, 128, "Rock", [:]))
        c.add(res(NovaType.spin, 700, "", [0: 6000]))
        return NovaGame(c)
    }

    func testOwnersAcrossCategories() {
        let index = SpriteOwnerIndex(game: fixture())
        let hull = index[1000]
        XCTAssertEqual(hull?.category, .ships)
        XCTAssertEqual(hull?.shipIDs, [128, 129])
        XCTAssertEqual(hull?.title, "Kestrel (+1 variant)")
        XCTAssertEqual(index[1001]?.owners.first?.layer, .engine)
        let planet = index[2000]
        XCTAssertEqual(planet?.title, "Earth")
        XCTAssertEqual(planet?.systems.map(\.name), ["Sol"])
        XCTAssertEqual(index[3000]?.category, .weapons)
        XCTAssertEqual(index[4000]?.category, .explosions)
        XCTAssertEqual(index[5000]?.category, .asteroids)
        XCTAssertEqual(index[6000]?.category, .other)
        XCTAssertEqual(index[6000]?.title, "Stars (background)")
    }

    func testSearchTextAndTitles() {
        let index = SpriteOwnerIndex(game: fixture())
        XCTAssertTrue(index[2000]!.searchText.contains("sol"))
        XCTAssertTrue(index[1001]!.searchText.contains("engine"))
        XCTAssertEqual(SpriteOwnerIndex.title(names: ["A", "B", "C"], category: .stellars), "A (+2 more)")
        XCTAssertEqual(SpriteOwnerIndex.title(names: [], category: .other), "")
    }
}
