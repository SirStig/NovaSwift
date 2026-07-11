import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// EV Nova boarding & capture: the crew/marines/strength capture-odds formula
/// (replacing the old invented toughness math) and the marines (ModType 25)
/// loadout consumption that feeds it.
final class BoardingTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func stats() -> ShipStats {
        ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)
    }

    private func disabledTarget(crew: Int, strength: Double, in world: World) -> Ship {
        let t = Ship(name: "Target", stats: stats())
        t.crew = crew
        t.combatStrength = strength
        t.maxArmor = 100; t.armor = 5     // isAlive (armor > 0)…
        t.disabled = true                  // …and a boardable hulk
        _ = world.addNPC(t)
        return t
    }

    // MARK: capture-odds formula

    func testCaptureChanceCrewRatio() {
        let player = Ship(name: "P", stats: stats())
        player.crew = 50; player.combatStrength = 10
        let world = World(player: player)
        let target = disabledTarget(crew: 20, strength: 10, in: world)
        // (50 / (20×10)) × 100 = 25%. Strength 10 is not > 5×10=50, so no bonus.
        XCTAssertEqual(world.captureChance(of: target), 25)
    }

    func testCaptureChanceStrengthBonus() {
        let player = Ship(name: "P", stats: stats())
        player.crew = 50; player.combatStrength = 100
        let world = World(player: player)
        let target = disabledTarget(crew: 20, strength: 10, in: world)
        // 25% + 10 (strength 100 > 5×10=50) = 35%.
        XCTAssertEqual(world.captureChance(of: target), 35)
    }

    func testCaptureChanceMarinesAndEscortCrew() {
        let player = Ship(name: "P", stats: stats())
        player.crew = 30; player.marineCrew = 10; player.captureOddsBonus = 5
        player.combatStrength = 1
        let world = World(player: player)
        // An escort with 10 crew, allied to the player.
        let escort = Ship(name: "E", stats: stats())
        escort.crew = 10
        escort.brain = AIBrain(aiType: .warship, govt: player.government)
        escort.brain?.leaderID = World.playerEntityID
        _ = world.addNPC(escort)
        let target = disabledTarget(crew: 20, strength: 100, in: world)
        // attackerCrew = 30 + 10 marines + 10 escort = 50 → (50/200)×100 = 25,
        // + 5 odds bonus = 30. Strength 1 not > 5×100, no strength bonus.
        XCTAssertEqual(world.playerBoardingCrew, 50)
        XCTAssertEqual(world.captureChance(of: target), 30)
    }

    func testCaptureChanceClampsAndUncapturable() {
        let player = Ship(name: "P", stats: stats())
        player.crew = 10_000; player.combatStrength = 1
        let world = World(player: player)
        let strong = disabledTarget(crew: 20, strength: 1, in: world)
        XCTAssertEqual(world.captureChance(of: strong), 75, "odds clamp at 75%")

        let weakPlayer = Ship(name: "P2", stats: stats())
        weakPlayer.crew = 1
        let world2 = World(player: weakPlayer)
        let tough = disabledTarget(crew: 5000, strength: 1, in: world2)
        XCTAssertEqual(world2.captureChance(of: tough), 1, "odds floor at 1%")

        let crewless = disabledTarget(crew: 0, strength: 1, in: world)
        XCTAssertNil(world.captureChance(of: crewless), "0-crew target is uncapturable")
    }

    // MARK: marines (ModType 25) loadout consumption

    private func shipRes(_ id: Int, crew: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100)   // shield
        put16(&b, 12, 40)   // free mass
        put16(&b, 14, 100)  // armor
        put16(&b, 68, crew) // crew
        return Resource(type: NovaType.ship, id: id, name: "Hull", data: Data(b))
    }
    private func marinesOutfit(_ id: Int, value: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 6, 25); put16(&b, 8, value)   // ModType 25 (marines)
        return Resource(type: NovaType.outfit, id: id, name: "Marines", data: Data(b))
    }

    func testMarinesLoadoutConsumption() throws {
        var col = ResourceCollection()
        col.add(shipRes(128, crew: 30))
        col.add(marinesOutfit(200, value: 10))    // +10 effective crew
        col.add(marinesOutfit(201, value: -15))   // +15% capture odds
        let galaxy = Galaxy(game: NovaGame(col))
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128, extraOutfits: [200: 1, 201: 1]))
        XCTAssertEqual(lo.crew, 30)
        XCTAssertEqual(lo.marineCrew, 10)
        XCTAssertEqual(lo.captureOddsBonus, 15)
    }
}
