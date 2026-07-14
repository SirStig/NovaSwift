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

    // MARK: fuel plunder ("Energy" button)

    func testPlunderFuelSiphonsCappedAtPlayerCapacity() {
        let player = Ship(name: "P", stats: stats())
        player.maxFuel = 400; player.fuel = 100          // room for 300
        let world = World(player: player)
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.maxFuel = 500; hulk.fuel = 500
        XCTAssertEqual(world.fuelAboard(hulk.entityID), 500)

        let took = world.takePlunderFuel(from: hulk.entityID)
        XCTAssertEqual(took, 300, "clamped to the player's 300 units of room")
        XCTAssertEqual(player.fuel, 400)
        XCTAssertEqual(hulk.fuel, 200, "the siphoned fuel leaves the hulk")
        // Re-boarding a full tank yields nothing more.
        XCTAssertEqual(world.takePlunderFuel(from: hulk.entityID), 0)
    }

    func testPlunderFuelIgnoresNonHulks() {
        let player = Ship(name: "P", stats: stats())
        player.maxFuel = 400; player.fuel = 0
        let world = World(player: player)
        // An alive, *not* disabled ship can't be boarded/siphoned.
        let live = Ship(name: "Live", stats: stats())
        live.maxFuel = 500; live.fuel = 500
        _ = world.addNPC(live)
        XCTAssertEqual(world.fuelAboard(live.entityID), 0)
        XCTAssertEqual(world.takePlunderFuel(from: live.entityID), 0)
        XCTAssertEqual(player.fuel, 0)
    }

    // MARK: ammo plunder ("Ammo" button)

    private func ammoWeap(_ id: Int, maxAmmo: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 200)
        put16(&b, 108, maxAmmo)   // WeapRes.MaxAmmo @108
        return Resource(type: NovaType.weapon, id: id, name: "Missile", data: Data(b))
    }
    private func ammoSpec(_ id: Int) -> WeaponSpec {
        WeaponSpec(id: id, name: "Missile", shieldDamage: 10, armorDamage: 10,
                   reloadSeconds: 1, projectileSpeed: 500, range: 500,
                   accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 1)
    }

    func testPlunderAmmoToppsUpMatchingWeapons() {
        var col = ResourceCollection()
        col.add(ammoWeap(140, maxAmmo: 10))
        let galaxy = Galaxy(game: NovaGame(col))

        let player = Ship(name: "P", stats: stats())
        player.weapons = [WeaponMount(spec: ammoSpec(140), ammo: 2)]   // room for 8
        let world = World(player: player)
        world.galaxy = galaxy
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.weapons = [WeaponMount(spec: ammoSpec(140), ammo: 6)]

        XCTAssertEqual(world.ammoAboard(hulk.entityID), 6, "6 rounds fit in the 8 rounds of room")
        let took = world.takePlunderAmmo(from: hulk.entityID)
        XCTAssertEqual(took, 6)
        XCTAssertEqual(player.weapons[0].ammo, 8)
        XCTAssertEqual(hulk.weapons[0].ammo, 0, "rounds leave the hulk (can't be duplicated)")
    }

    func testPlunderAmmoOnlyForWeaponsThePlayerCarries() {
        var col = ResourceCollection()
        col.add(ammoWeap(140, maxAmmo: 10))
        col.add(ammoWeap(141, maxAmmo: 10))
        let galaxy = Galaxy(game: NovaGame(col))

        let player = Ship(name: "P", stats: stats())
        player.weapons = [WeaponMount(spec: ammoSpec(140), ammo: 0)]   // player has weapon 140 only
        let world = World(player: player)
        world.galaxy = galaxy
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.weapons = [WeaponMount(spec: ammoSpec(141), ammo: 9)]     // hulk carries 141

        XCTAssertEqual(world.ammoAboard(hulk.entityID), 0, "no matching weapon → nothing to take")
        XCTAssertEqual(world.takePlunderAmmo(from: hulk.entityID), 0)
        XCTAssertEqual(hulk.weapons[0].ammo, 9)
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
