import XCTest
@testable import NovaSwiftEngine

final class GameSpeedRulesTests: XCTestCase {
    func testEffectiveMultiplierCombinesSettingAndCapsLock() {
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 1, x2Flag: false), 1)
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 1, x2Flag: true), 2)
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 4, x2Flag: true), 8)
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 8, x2Flag: true), 16)
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 100, x2Flag: true), 16)
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 0.5, x2Flag: false), 0.5)
    }

    func testCoopOverrideIgnoresCapsLock() {
        XCTAssertEqual(GameSpeedRules.effectiveMultiplier(setting: 4, x2Flag: true, coopOverride: 1.5), 1.5)
    }

    func testX2FlagFollowsCapsLock() {
        XCTAssertFalse(GameSpeedRules.x2Flag(capsLockOn: false, x2CueSounding: false, normalCueSounding: false,
                                             headingWithinTenOfJump: false))
        XCTAssertTrue(GameSpeedRules.x2Flag(capsLockOn: true, x2CueSounding: false, normalCueSounding: false,
                                            headingWithinTenOfJump: false))
    }

    func testJumpStartedAtNormalSpeedStaysNormalWhenAligned() {
        // Caps Lock turned on mid-jump: held off only with the nose within 10 degrees and snd 128 sounding.
        XCTAssertFalse(GameSpeedRules.x2Flag(capsLockOn: true, x2CueSounding: false, normalCueSounding: true,
                                             headingWithinTenOfJump: true))
        XCTAssertTrue(GameSpeedRules.x2Flag(capsLockOn: true, x2CueSounding: false, normalCueSounding: true,
                                            headingWithinTenOfJump: false))
        XCTAssertTrue(GameSpeedRules.x2Flag(capsLockOn: true, x2CueSounding: false, normalCueSounding: false,
                                            headingWithinTenOfJump: true))
    }

    func testJumpStartedAtX2StaysX2EvenWithCapsLockOff() {
        XCTAssertTrue(GameSpeedRules.x2Flag(capsLockOn: false, x2CueSounding: true, normalCueSounding: false,
                                            headingWithinTenOfJump: true))
    }

    func testCompensationsMatchTheOriginalAtOneAndTwo() {
        XCTAssertEqual(GameSpeedRules.jumpProgressOffsetFactor(multiplier: 1), 1)
        XCTAssertEqual(GameSpeedRules.jumpProgressOffsetFactor(multiplier: 2), 1.5)   // _DAT_005755d0
        XCTAssertEqual(GameSpeedRules.departureProgressScale(multiplier: 1, followsPlayer: true), 1)
        XCTAssertEqual(GameSpeedRules.departureProgressScale(multiplier: 1, followsPlayer: false), 1)
        XCTAssertEqual(GameSpeedRules.departureProgressScale(multiplier: 2, followsPlayer: true), 0.667, accuracy: 0.001)
        XCTAssertEqual(GameSpeedRules.departureProgressScale(multiplier: 2, followsPlayer: false), 0.5)
    }

    func testCatchupCapScalesWithMultiplier() {
        XCTAssertEqual(GameSpeedRules.catchupTickCap(multiplier: 1), 5)
        XCTAssertEqual(GameSpeedRules.catchupTickCap(multiplier: 4), 7)
        XCTAssertEqual(GameSpeedRules.catchupTickCap(multiplier: 16), 25)
    }

    func testJumpClockRunsOnTheWallClock() {
        let player = Ship(name: "P", stats: ShipStats(speed: 300, acceleration: 200, turnRate: 30))
        var jump = PlayerHyperjump(bearing: 0, fastJump: true, multiplier: 1.3)
        // Fast jump skips the brake: the first tick enters spin-up and latches the cue.
        jump.tick(player, dt: 1.0 / 30, timeScale: 2, x2Mode: true)
        XCTAssertEqual(jump.cueX2, true)
        jump.tick(player, dt: 1.0 / 30, timeScale: 2, x2Mode: true)
        XCTAssertEqual(jump.elapsed60, 1.0, accuracy: 1e-9)   // a 30 Hz tick is 2 sixty-Hz ticks, / N = 2 on the wall clock
        XCTAssertEqual(jump.timeScale, 2)
    }
}
