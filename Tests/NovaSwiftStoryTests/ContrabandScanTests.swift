import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Government scan → fine / smuggling-penalty enforcement against a live pilot.
final class ContrabandScanTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func govt(_ id: Int, scanMask: Int, scanFine: Int, crimeTol: Int = 100, smug: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 192)
        put16(&b, 6, scanFine); put16(&b, 8, crimeTol); put16(&b, 10, smug); put16(&b, 50, scanMask)
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }
    private func outfit(_ id: Int, scanMask: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028); put16(&b, 1006, scanMask)
        return Resource(type: NovaType.outfit, id: id, name: "Out\(id)", data: Data(b))
    }
    private func mission(_ id: Int, scanMask: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000); put16(&b, 24, scanMask)
        return Resource(type: NovaType.mission, id: id, name: "Msn\(id)", data: Data(b))
    }

    private func game(scanFine: Int, crimeTol: Int = 100, smug: Int = 0) -> NovaGame {
        var col = ResourceCollection()
        col.add(govt(128, scanMask: 0x8000, scanFine: scanFine, crimeTol: crimeTol, smug: smug))
        col.add(outfit(200, scanMask: 0x8000))   // illegal to govt 128
        col.add(outfit(201, scanMask: 0x0004))   // legal to govt 128
        col.add(mission(400, scanMask: 0x8000))  // illegal mission cargo
        return NovaGame(col)
    }

    func testFlatFineDeducted() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000; p.outfits = [200: 1]
        let r = ContrabandScan.enforce(on: &p, game: game(scanFine: 5000), govtID: 128)
        XCTAssertEqual(r?.contrabandOutfits, [200])
        XCTAssertEqual(p.credits, 15000)
        XCTAssertFalse(r?.warningOnly ?? true)
    }

    func testLegalCargoNoFine() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000; p.outfits = [201: 1]
        XCTAssertNil(ContrabandScan.enforce(on: &p, game: game(scanFine: 5000), govtID: 128))
        XCTAssertEqual(p.credits, 20000)
    }

    func testWarningOnlyGovt() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000; p.outfits = [200: 1]
        let r = ContrabandScan.enforce(on: &p, game: game(scanFine: 0), govtID: 128)
        XCTAssertEqual(r?.foundContraband, true)
        XCTAssertEqual(r?.warningOnly, true)
        XCTAssertEqual(p.credits, 20000, "warning-only govt takes nothing")
    }

    func testPercentFine() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000; p.outfits = [200: 1]
        _ = ContrabandScan.enforce(on: &p, game: game(scanFine: -10), govtID: 128)   // 10% of cash
        XCTAssertEqual(p.credits, 18000)
    }

    func testSmugglingAppliesEvilness() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000
        p.activeMissions = [ActiveMission(missionID: 400, acceptedDate: p.date, deadline: nil,
                                          cargoPickedUp: true, shipObjectivesRemaining: 0)]
        let r = ContrabandScan.enforce(on: &p, game: game(scanFine: 1000, smug: 50), govtID: 128)
        XCTAssertEqual(r?.smugglingMissions, [400])
        XCTAssertEqual(p.credits, 19000, "still fined for the illegal cargo")
        // Smuggling is a hostile-action-style event, so it's LOCAL (the wiki's
        // Legal Status radius rule) — it lands in `localLegalRecord`, not the
        // universal `legalRecord`.
        XCTAssertNil(p.legalRecord[128], "smuggling penalty must not touch the universal component")
        XCTAssertEqual(p.effectiveLegalRecord(govt: 128, atSystem: 128), -50,
                       "detected smuggling makes you more wanted here")
    }

    func testAlreadyCriminalIsNotFined() {
        var p = PlayerState(currentSystem: 128); p.credits = 20000; p.outfits = [200: 1]
        p.legalRecord[128] = -150   // evilness 150 ≥ CrimeTol 100 → attackable, not fined
        XCTAssertNil(ContrabandScan.enforce(on: &p, game: game(scanFine: 5000, crimeTol: 100), govtID: 128))
        XCTAssertEqual(p.credits, 20000)
    }
}
