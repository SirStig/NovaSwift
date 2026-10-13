import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// shän Flags 0x0002: hulls unfold and fold (`Ship_UpdateVisualState` 0x00428340 and the trigger
/// sites named on each `HullFoldState` method).
final class HullFoldTests: XCTestCase {

    private func config(weaponsFold: Bool = false, sets: Int = 4, delay: Double = 2) -> HullFoldConfig {
        var c = HullFoldConfig()
        c.folds = true
        c.weaponsFold = weaponsFold
        c.setCount = sets
        c.delayTicks = delay
        return c
    }

    private func state(_ c: HullFoldConfig) -> HullFoldState {
        var s = HullFoldState()
        s.config = c
        s.configResolved = true
        return s
    }

    /// Step in whole 1/30 s ticks until `done` or `limit` ticks pass.
    private func run(_ s: inout HullFoldState, limit: Int = 200, until done: (HullFoldState) -> Bool) -> Int {
        var ticks = 0
        while !done(s), ticks < limit { s.step(ticks: 1); ticks += 1 }
        return ticks
    }

    func testFreshShipIsFullyExtended() {
        XCTAssertEqual(state(config()).currentSet, 3, "a newly allocated ship sits at setCount - 1")
        XCTAssertEqual(HullFoldState().currentSet, 0, "a hull that does not fold always draws set 0")
    }

    func testLaunchUnfoldsFromSetZeroOneStepPerDelay() {
        var s = state(config(delay: 2))
        s.beginLaunch()
        XCTAssertEqual(s.currentSet, 0)
        XCTAssertEqual(s.direction, 1)
        var seen: [Int] = [s.currentSet]
        for _ in 0..<40 {
            s.step(ticks: 1)
            if seen.last != s.currentSet { seen.append(s.currentSet) }
        }
        XCTAssertEqual(seen, [0, 1, 2, 3], "one set per AnimDelay, never skipping")
        XCTAssertEqual(s.direction, 0, "the direction clears after the last set")
        // The original wraps past the last set before clearing: one extra period.
        var t = state(config(delay: 2))
        t.beginLaunch()
        let toLast = run(&t) { $0.currentSet == 3 }  // 9 ticks
        let toRest = run(&t) { $0.direction == 0 }
        XCTAssertEqual(toLast, 3 * 3, "each step needs the timer to pass AnimDelay (3 ticks at delay 2)")
        XCTAssertEqual(toRest, 3, "one more period to clear the direction")
    }

    func testJumpFoldsBackToSetZeroAndStops() {
        var s = state(config(delay: 1))
        s.foldForPlayerJump()
        XCTAssertEqual(s.direction, -1)
        _ = run(&s) { $0.direction == 0 }
        XCTAssertEqual(s.currentSet, 0)
    }

    func testWeaponsFoldHullDoesNotFoldForTheJump() {
        var s = state(config(weaponsFold: true))
        s.foldForPlayerJump()
        XCTAssertEqual(s.direction, 0)
        XCTAssertEqual(s.currentSet, 3)
        s.foldForJump()
        XCTAssertEqual(s.direction, 0)
    }

    func testLaunchPutsAWeaponsFoldHullAtItsLastSet() {
        var s = state(config(weaponsFold: true))
        s.beginLaunch()
        XCTAssertEqual(s.currentSet, 3)
        XCTAssertEqual(s.direction, 0)
    }

    func testWeaponsFoldHullUnfoldsBeforeFiringThenRefoldsAfter45Ticks() {
        var s = state(config(weaponsFold: true, delay: 1))
        // At its last set the first shot is refused and starts the move toward set 0.
        XCTAssertTrue(s.noteFireAttempt())
        XCTAssertEqual(s.direction, -1)
        _ = run(&s) { $0.currentSet == 0 }
        XCTAssertFalse(s.noteFireAttempt(), "at set 0 it fires")
        // 45 ticks of the 60 Hz clock (22.5 of the 30 Hz ticks) after the last attempt it extends again.
        var ticks = 0
        while s.direction == 0, ticks < 100 { s.step(ticks: 1); ticks += 1 }
        XCTAssertEqual(s.direction, 1)
        XCTAssertGreaterThanOrEqual(Double(ticks) * 2, HullFoldState.idleTicks60)
        XCTAssertLessThanOrEqual(Double(ticks - 1) * 2, HullFoldState.idleTicks60)
    }

    func testStellarParkFoldsEvenAWeaponsFoldHull() {
        var s = state(config(weaponsFold: true))
        s.foldAtStellar()
        XCTAssertEqual(s.direction, -1, "0x00405590 folds regardless of 0x0080")
    }

    func testUnfoldIfIdleWaitsForTheIdleClockOnlyForWeaponsFold() {
        var normal = state(config())
        normal.foldAtStellar()
        _ = run(&normal) { $0.direction == 0 }
        normal.unfoldIfIdle()
        XCTAssertEqual(normal.direction, 1)

        var weapons = state(config(weaponsFold: true, delay: 1))
        _ = weapons.noteFireAttempt()
        _ = run(&weapons) { $0.currentSet == 0 }
        weapons.lastFire60 = weapons.clock60
        weapons.unfoldIfIdle()
        XCTAssertEqual(weapons.direction, 0, "just fired: stays out")
    }

    func testBaseSetFoldingReadsTheFoldSetAndIgnoresDisabled() {
        var c = HullAnimConfig()
        c.setCount = 4; c.mode = .folding
        XCTAssertEqual(c.baseSet(turnSign: 1, animClock: 0, disabled: false, foldSet: 2), 2)
        XCTAssertEqual(c.baseSet(turnSign: 0, animClock: 0, disabled: true, foldSet: 3), 3)
        XCTAssertEqual(c.baseSet(turnSign: 0, animClock: 0, disabled: false, foldSet: 9), 3, "clamped")
        c.mode = .banking
        XCTAssertEqual(c.baseSet(turnSign: 1, animClock: 0, disabled: false, foldSet: 3), 1, "only .folding reads it")
    }
}

