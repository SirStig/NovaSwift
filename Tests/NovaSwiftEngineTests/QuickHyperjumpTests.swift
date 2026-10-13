import XCTest
@testable import NovaSwiftEngine

/// The `quickHyperjump` enhancement's maneuver, shared by the Apple scene and the Godot bridge
/// (moved out of `GameScene.stepJump` unchanged).
final class QuickHyperjumpTests: XCTestCase {

    private func ship(angle: Double = 0) -> Ship {
        Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3), position: Vec2(), angle: angle)
    }

    func testAlignThenAccelerateThenFlashThenCommitOnce() {
        let p = ship(angle: 0)
        var q = QuickHyperjump(outboundHeading: 0, instant: false)
        XCTAssertEqual(q.phase, .align)
        XCTAssertTrue(q.chargeLoopSounding)
        // Already pointing the right way: the first frame settles the align and moves on.
        var f = q.step(dt: 1.0 / 60, player: p)
        XCTAssertEqual(f.intent.desiredHeading, 0)
        XCTAssertNil(f.flash)
        XCTAssertEqual(q.phase, .accelerate)
        // The burst: thrust, lifted speed cap, streaks building; it lasts 0.45 s.
        var commits = 0
        var sawFlash = false
        for _ in 0..<240 {
            f = q.step(dt: 1.0 / 60, player: p)
            if q.phase == .accelerate { XCTAssertTrue(f.intent.thrust); XCTAssertNotNil(f.streakIntensity) }
            if f.flash != nil { sawFlash = true }
            if f.commit { commits += 1; XCTAssertTrue(f.stopChargeLoop) }
        }
        XCTAssertTrue(sawFlash)
        XCTAssertEqual(commits, 1, "the jump fires exactly once")
        XCTAssertFalse(q.chargeLoopSounding, "the charge loop is cut at the commit")
        XCTAssertGreaterThanOrEqual(p.entryOverspeed, p.stats.maxSpeed * QuickHyperjump.overspeedFactor)
    }

    func testFastJumpStartsAtTheBurstAndIsShorter() {
        let p = ship()
        var instant = QuickHyperjump(outboundHeading: 0, instant: true)
        var normal = QuickHyperjump(outboundHeading: 0, instant: false)
        XCTAssertEqual(instant.phase, .accelerate)
        func framesToFlash(_ q: inout QuickHyperjump) -> Int {
            var n = 0
            while q.phase != .flash, n < 1000 { _ = q.step(dt: 0.01, player: p); n += 1 }
            return n
        }
        XCTAssertLessThan(framesToFlash(&instant), framesToFlash(&normal))
    }

    func testSpeedOutfitsShortenTheBurst() {
        let p = ship()
        func frames(speed: Double) -> Int {
            var q = QuickHyperjump(outboundHeading: 0, instant: true, speed: speed)
            var n = 0
            while q.phase != .flash, n < 1000 { _ = q.step(dt: 0.01, player: p); n += 1 }
            return n
        }
        XCTAssertLessThan(frames(speed: 3), frames(speed: 1))
    }

    func testAlignHasAThreeSecondSafetyCap() {
        let p = ship(angle: .pi)       // pointing away, and the test never turns it
        var q = QuickHyperjump(outboundHeading: 0, instant: false)
        var t = 0.0
        while q.phase == .align, t < 10 { _ = q.step(dt: 0.1, player: p); t += 0.1 }
        XCTAssertEqual(q.phase, .accelerate)
        XCTAssertLessThanOrEqual(t, QuickHyperjump.alignCapSeconds + 0.2)
    }

    func testGateFlashIsSilentAndCommitsAtTheRampEnd() {
        let p = ship()
        var q = QuickHyperjump(flashOnly: 1)
        XCTAssertEqual(q.phase, .flash)
        XCTAssertFalse(q.chargeLoopSounding)
        var committed = false
        var t = 0.0
        while !committed, t < 1 {
            let f = q.step(dt: 0.02, player: p)
            t += 0.02
            committed = f.commit
        }
        XCTAssertTrue(committed)
        XCTAssertGreaterThanOrEqual(t, QuickHyperjump.flashRampSeconds - 0.001)
    }
}
