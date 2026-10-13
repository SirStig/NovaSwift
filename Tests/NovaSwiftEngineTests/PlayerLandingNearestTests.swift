import XCTest
@testable import NovaSwiftEngine

/// UI-06: the Land key's nearest search with nothing selected
/// (`Stellar_FindNearestAvailableTravelStellar` 0x00462db0).
final class PlayerLandingNearestTests: XCTestCase {
    private func slot(_ id: Int, x: Double, gate: Bool = false, canLand: Bool = true, available: Bool = true) -> PlayerLanding.TravelSlot {
        PlayerLanding.TravelSlot(id: id, position: Vec2(x, 0), canLand: canLand, isGate: gate, available: available)
    }

    func testNearestIgnoresDestroyedAndFlaglessStellars() {
        let slots = [slot(1, x: 50, available: false),          // destroyed: closest, but not available
                     slot(2, x: 80, canLand: false),            // no Flags 0x0001
                     slot(3, x: 900), slot(4, x: 400)]
        XCTAssertEqual(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0), slots: slots), 4)
    }

    func testGateCountsOnlyInsideTheFixedRadiusAndTiesGoToTheFirstSlot() {
        // 500 px: dist^2 < 250000.
        XCTAssertNil(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0), slots: [slot(1, x: 500, gate: true)]),
                     "a hypergate at exactly 500 px does not count")
        XCTAssertEqual(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0), slots: [slot(1, x: 499, gate: true)]), 1)
        XCTAssertEqual(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0),
                                                          slots: [slot(1, x: 800, gate: true), slot(2, x: 2000)]), 2,
                       "a far gate is skipped for a planet at any range")
        XCTAssertEqual(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0), slots: [slot(7, x: 100), slot(8, x: -100)]), 7,
                       "equal distance keeps the first slot")
    }

    func testOnlyTheFirstSixteenSlotsAreSearched() {
        var slots = (0..<16).map { slot($0, x: 5000, available: false) }
        slots.append(slot(99, x: 10))
        XCTAssertNil(PlayerLanding.nearestTravelStellar(from: Vec2(0, 0), slots: slots))
    }
}
