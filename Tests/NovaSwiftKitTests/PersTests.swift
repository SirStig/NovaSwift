import XCTest
@testable import NovaSwiftKit

/// përs decoding + the ItemClass boarding-loot grant.
final class PersTests: XCTestCase {
    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func pers(_ id: Int, ship: Int, govt: Int, grantClass: Int, grantProb: Int, grantCount: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 2, govt); put16(&b, 4, 3); put16(&b, 10, ship)
        put16(&b, 308, grantClass); put16(&b, 310, grantProb); put16(&b, 312, grantCount)
        return Resource(type: NovaType.pers, id: id, name: "Person\(id)", data: Data(b))
    }
    private func outfit(_ id: Int, itemClass: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028); put16(&b, 1004, itemClass)
        return Resource(type: NovaType.outfit, id: id, name: "O\(id)", data: Data(b))
    }

    func testPersDecode() {
        let p = PersRes(pers(500, ship: 134, govt: 157, grantClass: 25, grantProb: 100, grantCount: 4))
        XCTAssertEqual(p.shipType, 134)
        XCTAssertEqual(p.govt, 157)
        XCTAssertEqual(p.grantClass, 25)
        XCTAssertEqual(p.grantProb, 100)
        XCTAssertEqual(p.grantCount, 4)
        XCTAssertTrue(p.grantsLoot)
    }

    func testOutfitsOfClass() {
        var col = ResourceCollection()
        col.add(outfit(200, itemClass: 7)); col.add(outfit(201, itemClass: 7)); col.add(outfit(202, itemClass: 3))
        XCTAssertEqual(NovaGame(col).outfits(ofClass: 7), [200, 201])
    }

    func testBoardingGrantAlways() {
        var col = ResourceCollection()
        col.add(outfit(200, itemClass: 7)); col.add(outfit(201, itemClass: 7))
        let p = PersRes(pers(500, ship: 128, govt: 128, grantClass: 7, grantProb: 100, grantCount: 4))
        let game = NovaGame(col)
        let loot = game.personBoardingGrant(p, seed: 12345)
        XCTAssertGreaterThanOrEqual(loot.count, 2, "GrantCount/2 … GrantCount = 2…4")
        XCTAssertLessThanOrEqual(loot.count, 4)
        XCTAssertTrue(loot.allSatisfy { [200, 201].contains($0) })
    }

    func testBoardingGrantZeroProbGivesNothing() {
        var col = ResourceCollection()
        col.add(outfit(200, itemClass: 7))
        let p = PersRes(pers(500, ship: 128, govt: 128, grantClass: 7, grantProb: 0, grantCount: 4))
        XCTAssertTrue(NovaGame(col).personBoardingGrant(p, seed: 1).isEmpty)
    }

    func testBoardingGrantNoMatchingOutfits() {
        var col = ResourceCollection()
        col.add(outfit(200, itemClass: 3))   // wrong class
        let p = PersRes(pers(500, ship: 128, govt: 128, grantClass: 7, grantProb: 100, grantCount: 4))
        XCTAssertTrue(NovaGame(col).personBoardingGrant(p, seed: 1).isEmpty)
    }
}
