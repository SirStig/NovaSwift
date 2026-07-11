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

    private func put32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        b[off] = UInt8((u >> 24) & 0xff); b[off + 1] = UInt8((u >> 16) & 0xff)
        b[off + 2] = UInt8((u >> 8) & 0xff); b[off + 3] = UInt8(u & 0xff)
    }
    private func putStr(_ b: inout [UInt8], _ off: Int, _ s: String) {
        for (i, byte) in Array(s.utf8).enumerated() { b[off + i] = byte }
    }

    func testFullPersDecode() {
        var b = [UInt8](repeating: 0, count: 400)
        put16(&b, 2, 149); put16(&b, 4, 3); put16(&b, 6, 2); put16(&b, 8, 25); put16(&b, 10, 133)
        put16(&b, 12, 200)                          // WeapType[0]
        put32(&b, 36, 250000)                       // Credits
        put16(&b, 40, 200)                          // ShieldMod 200%
        put16(&b, 42, 7800)                         // HailPict
        put16(&b, 44, 3); put16(&b, 46, 5)          // CommQuote / HailQuote
        put16(&b, 48, 140)                          // LinkMission
        put16(&b, 50, 0x0801)                       // Flags: grudge + leave-after-mission
        putStr(&b, 52, "b1000")                     // ActiveOn
        let p = PersRes(Resource(type: NovaType.pers, id: 131, name: "Jack Folstam", data: Data(b)))
        XCTAssertEqual(p.credits, 250000)
        XCTAssertEqual(p.shieldMod, 200)
        XCTAssertEqual(p.hailPict, 7800)
        XCTAssertEqual(p.commQuote, 3)
        XCTAssertEqual(p.hailQuote, 5)
        XCTAssertEqual(p.linkMission, 140)
        XCTAssertEqual(p.activeOn, "b1000")
        XCTAssertEqual(p.weapType.first, 200)
        XCTAssertTrue(p.holdsGrudge)
        XCTAssertTrue(p.leaveAfterMission)
        XCTAssertFalse(p.usesEscapePod)
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
