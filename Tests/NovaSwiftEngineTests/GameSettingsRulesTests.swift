import XCTest
@testable import NovaSwiftEngine

final class GameSettingsRulesTests: XCTestCase {
    func testDifficultyScalesMatchTheSettingsTable() {
        XCTAssertEqual(GameDifficulty.veryEasy.playerDamageScale, 0.3)
        XCTAssertEqual(GameDifficulty.easy.playerDamageScale, 0.6)
        XCTAssertEqual(GameDifficulty.normal.playerDamageScale, 1.0)
        XCTAssertEqual(GameDifficulty.hard.playerDamageScale, 1.5)
    }

    func testTrafficLevelsPickTheSpawnModelAndScale() {
        XCTAssertEqual(SystemTrafficLevel.original.spawnModel, .original)
        for l in [SystemTrafficLevel.authentic, .normal, .bustling] { XCTAssertEqual(l.spawnModel, .port) }
        XCTAssertEqual(SystemTrafficLevel.authentic.populationScale, 0.55)
        XCTAssertEqual(SystemTrafficLevel.bustling.populationScale, 1.35)
        XCTAssertEqual(SystemTrafficLevel.original.populationScale, 1.0)
    }

    func testGameSpeedMultipliers() {
        XCTAssertEqual(GameSpeedSetting.x1.multiplier, 1)
        XCTAssertEqual(GameSpeedSetting.x0_5.multiplier, 0.5)
        XCTAssertEqual(GameSpeedSetting.x8.multiplier, 8)
    }

    func testColorblindMatrices() {
        XCTAssertNil(ColorblindFilter.none.matrixRows)
        XCTAssertEqual(ColorblindFilter.protanopia.matrixRows, ColorblindFilter.deuteranopia.matrixRows)
        XCTAssertEqual(ColorblindFilter.protanopia.matrixRows?[2], [0.5, -0.5, 1, 0])
        XCTAssertEqual(ColorblindFilter.tritanopia.matrixRows?[1], [-0.5, 1, 0.5, 0])
        XCTAssertEqual(ColorblindFilter.tritanopia.matrixRows?[3], [0, 0, 0, 1])
    }

    func testLandingRulesOriginalVersusForgiving() {
        let original = LandingRules(forgiving: false)
        let forgiving = LandingRules(forgiving: true)
        XCTAssertEqual(original.speedLimit, PlayerLanding.perAxisSpeedLimit)
        XCTAssertEqual(forgiving.speedLimit, 130)
        XCTAssertEqual(original.reach(radius: 40), PlayerLanding.reach(radius: 40))
        XCTAssertEqual(forgiving.reach(radius: 40), 110)
        // 100 px out, moving at 60 px/s: the original refuses (too fast, no clearance), forgiving lands.
        let d = Vec2(100, 0), v = Vec2(60, 0)
        XCTAssertFalse(original.canLand(offset: d, radius: 40, velocity: v, cleared: true, cloaked: false))
        XCTAssertTrue(forgiving.canLand(offset: d, radius: 40, velocity: v, cleared: false, cloaked: true))
        // Slow, inside, cleared: the original lands; uncleared or cloaked it does not.
        let slow = Vec2(5, 5)
        XCTAssertTrue(original.canLand(offset: Vec2(50, 50), radius: 40, velocity: slow, cleared: true, cloaked: false))
        XCTAssertFalse(original.canLand(offset: Vec2(50, 50), radius: 40, velocity: slow, cleared: false, cloaked: false))
        XCTAssertFalse(original.canLand(offset: Vec2(50, 50), radius: 40, velocity: slow, cleared: true, cloaked: true))
    }

    func testAutoLandPilotFliesTowardTheBodyThenArrives() {
        let ship = Ship(name: "P", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 100), position: Vec2(0, 0))
        let body = StellarBody(id: 130, position: Vec2(0, 2000), radius: 40, canLand: true)
        let rules = LandingRules(forgiving: false)
        // Pointed at it (heading 0 = +y) and far away: thrust on.
        guard case .fly(let i) = AutoLandPilot.step(player: ship, body: body, rules: rules, cleared: true) else {
            return XCTFail("should still be flying")
        }
        XCTAssertTrue(i.thrust)
        XCTAssertEqual(i.desiredHeading ?? 99, 0, accuracy: 1e-9)
        // Parked on it, cleared: arrived.
        ship.position = body.position
        XCTAssertEqual(AutoLandPilot.step(player: ship, body: body, rules: rules, cleared: true), .arrived)
        // Too fast on approach: brakes toward retrograde.
        ship.position = Vec2(0, 1900); ship.velocity = Vec2(0, 300)
        guard case .fly(let b) = AutoLandPilot.step(player: ship, body: body, rules: rules, cleared: true) else {
            return XCTFail("should be braking")
        }
        XCTAssertEqual(abs(angleDelta(from: 0, to: b.desiredHeading ?? 0)), .pi, accuracy: 1e-6)
    }
}
