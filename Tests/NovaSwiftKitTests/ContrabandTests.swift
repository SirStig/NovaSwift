import XCTest
@testable import NovaSwiftKit

/// Contraband detection (`gövt.ScanMask` ∩ item `ScanMask`) and the `ScanFine`
/// credit-fine rule.
final class ContrabandTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func govt(_ id: Int, scanMask: Int, scanFine: Int = 0, crimeTol: Int = 0, smug: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 192)
        put16(&b, 6, scanFine)
        put16(&b, 8, crimeTol)
        put16(&b, 10, smug)
        put16(&b, 50, scanMask)
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }
    private func outfit(_ id: Int, scanMask: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 1006, scanMask)
        return Resource(type: NovaType.outfit, id: id, name: "Out\(id)", data: Data(b))
    }
    private func junk(_ id: Int, scanMask: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 120)
        put16(&b, 36, scanMask)
        return Resource(type: NovaType.junk, id: id, name: "Junk\(id)", data: Data(b))
    }
    private func mission(_ id: Int, scanMask: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 24, scanMask)
        return Resource(type: NovaType.mission, id: id, name: "Msn\(id)", data: Data(b))
    }

    func testMatchesSharedBit() {
        XCTAssertTrue(Contraband.matches(0x8000, 0x8008))   // Fed contraband vs Bureau
        XCTAssertFalse(Contraband.matches(0x8000, 0x4000))  // Fed vs Auroran — different
        XCTAssertFalse(Contraband.matches(0, 0x8000))       // no item mask
        XCTAssertFalse(Contraband.matches(0x8000, 0))       // govt polices nothing
    }

    func testFineRule() {
        XCTAssertEqual(Contraband.fine(scanFine: 5000, cash: 20000).amount, 5000)   // flat
        XCTAssertFalse(Contraband.fine(scanFine: 5000, cash: 20000).warningOnly)
        XCTAssertEqual(Contraband.fine(scanFine: 5000, cash: 3000).amount, 3000, "never more than cash")
        XCTAssertTrue(Contraband.fine(scanFine: 0, cash: 20000).warningOnly)         // warning
        XCTAssertEqual(Contraband.fine(scanFine: 0, cash: 20000).amount, 0)
        XCTAssertEqual(Contraband.fine(scanFine: -5, cash: 20000).amount, 1000)      // 5% of cash
        XCTAssertEqual(Contraband.fine(scanFine: -200, cash: 20000).amount, 20000, "clamp at 100%")
    }

    func testGovtItemContraband() {
        var col = ResourceCollection()
        col.add(govt(128, scanMask: 0x8000))            // Federation
        col.add(govt(137, scanMask: 0x0800))            // Pirate
        col.add(outfit(200, scanMask: 0x8000))          // illegal to Federation
        col.add(outfit(201, scanMask: 0x0004))          // illegal to neither above
        col.add(junk(300, scanMask: 0x8000))            // illegal cargo to Federation
        col.add(mission(400, scanMask: 0x8000))         // illegal mission cargo to Federation
        let game = NovaGame(col)

        XCTAssertTrue(game.isOutfitContraband(200, to: 128))
        XCTAssertFalse(game.isOutfitContraband(200, to: 137), "Pirates don't police Federation contraband")
        XCTAssertFalse(game.isOutfitContraband(201, to: 128))
        XCTAssertTrue(game.isCargoContraband(300, to: 128))
        XCTAssertFalse(game.isCargoContraband(300, to: 137))
        XCTAssertTrue(game.isMissionCargoContraband(400, to: 128))
        XCTAssertEqual(game.governmentScanMask(128), 0x8000)
    }
}
