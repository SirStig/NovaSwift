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
        // EC-18: an escort adds a tenth of its crew. attackerCrew = 30 + 1
        // escort + 10 marines = 41 → trunc(41/200 × 100) = 20, + 5 odds bonus
        // = 25. Strength 1 not > 5×100, no strength bonus.
        XCTAssertEqual(world.playerBoardingCrew, 41)
        XCTAssertEqual(world.captureChance(of: target), 25)
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

    /// A hull with `holds` tons and `fuel` units, for the loot rolls.
    private func lootHull(_ id: Int, holds: Int, fuel: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 0, holds); put16(&b, 10, fuel); put16(&b, 14, 100)
        return Resource(type: NovaType.ship, id: id, name: "Hull", data: Data(b))
    }

    /// EC-18: the fuel option is `rand(fuel / 10) × 10` of the hull's
    /// capacity, cut to the player's room, and spent once taken.
    func testPlunderFuelIsARollOfTheHullsCapacity() {
        var col = ResourceCollection()
        col.add(lootHull(128, holds: 0, fuel: 500))
        let player = Ship(name: "P", stats: stats())
        player.maxFuel = 400; player.fuel = 380          // room for 20
        let world = World(player: player)
        world.galaxy = Galaxy(game: NovaGame(col))
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.shipTypeID = 128
        hulk.fuel = 0                                     // what is left aboard does not matter
        let offered = world.fuelAboard(hulk.entityID)
        XCTAssertEqual(offered.truncatingRemainder(dividingBy: 10), 0)
        XCTAssertLessThan(offered, 500)
        XCTAssertEqual(world.fuelAboard(hulk.entityID), offered, "rolled once")
        let took = world.takePlunderFuel(from: hulk.entityID)
        XCTAssertEqual(took, min(offered, 20))
        XCTAssertEqual(world.takePlunderFuel(from: hulk.entityID), 0, "spent")
    }

    /// EC-18: the cargo option is one Booty commodity in
    /// `rand(holds/2) + holds/2` tons, whatever the hold carries; no Booty
    /// commodity bit, no cargo.
    func testPlunderCargoIsRolledFromTheBooty() {
        var col = ResourceCollection()
        col.add(lootHull(128, holds: 40, fuel: 0))
        let player = Ship(name: "P", stats: stats())
        player.cargoCapacity = 100
        let world = World(player: player)
        world.galaxy = Galaxy(game: NovaGame(col))
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.shipTypeID = 128
        hulk.cargo = [0: 40]
        hulk.dudeBooty = 0x0008 | 0x0040                 // luxury goods, credits
        let cargo = world.boardingManifest(for: hulk.entityID)?.cargo ?? []
        XCTAssertEqual(cargo.count, 1)
        XCTAssertEqual(cargo.first?.commodity, 3)
        XCTAssertTrue((20..<40).contains(cargo.first?.tons ?? 0))
        XCTAssertEqual(world.takePlunderCargo(from: hulk.entityID, room: 5).first?.tons, 5)
        XCTAssertTrue(world.takePlunderCargo(from: hulk.entityID).isEmpty, "spent")

        let plain = disabledTarget(crew: 5, strength: 1, in: world)
        plain.shipTypeID = 128
        plain.cargo = [0: 40]
        XCTAssertEqual(world.boardingManifest(for: plain.entityID)?.cargo.count, 0)
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

    /// An ammo outfit (ModType 3 naming weapon `weaponID`) with the given Mass and Max.
    private func ammoOutfit(_ id: Int, weaponID: Int, mass: Int, max: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 60)
        put16(&b, 2, mass); put16(&b, 10, max)
        put16(&b, 6, 3); put16(&b, 8, weaponID)
        return Resource(type: NovaType.outfit, id: id, name: "Missile", data: Data(b))
    }
    /// A weapon drawing from AmmoType pool `type` (the ammo outfit names 128 + type).
    private func ammoSpec(_ id: Int, type: Int) -> WeaponSpec {
        WeaponSpec(id: id, name: "Missile", shieldDamage: 10, armorDamage: 10,
                   reloadSeconds: 1, projectileSpeed: 500, range: 500,
                   accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 1, ammoTypeRaw: type)
    }

    /// B-11: one bank's rounds, matched by AmmoType pool, limited by the ammo
    /// outfit's Max and the player's free mass.
    func testPlunderAmmoToppsUpMatchingWeapons() {
        var col = ResourceCollection()
        col.add(ammoOutfit(300, weaponID: 140, mass: 1, max: 10))
        let galaxy = Galaxy(game: NovaGame(col))

        let player = Ship(name: "P", stats: stats())
        player.weapons = [WeaponMount(spec: ammoSpec(140, type: 12), ammo: 2)]   // room for 8 under Max 10
        let world = World(player: player)
        world.galaxy = galaxy
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.weapons = [WeaponMount(spec: ammoSpec(140, type: 12), ammo: 6)]

        XCTAssertEqual(world.ammoAboard(hulk.entityID), 6, "6 rounds fit in the 8 rounds of room")
        XCTAssertEqual(world.ammoAboard(hulk.entityID, freeMass: 4), 4, "free mass limits the take")
        let took = world.takePlunderAmmo(from: hulk.entityID)
        XCTAssertEqual(took, 6)
        XCTAssertEqual(player.weapons[0].ammo, 8)
        XCTAssertEqual(hulk.weapons[0].ammo, 0, "rounds leave the hulk (can't be duplicated)")
    }

    func testPlunderAmmoOnlyForWeaponsThePlayerCarries() {
        var col = ResourceCollection()
        col.add(ammoOutfit(300, weaponID: 140, mass: 1, max: 10))
        col.add(ammoOutfit(301, weaponID: 141, mass: 1, max: 10))
        let galaxy = Galaxy(game: NovaGame(col))

        let player = Ship(name: "P", stats: stats())
        player.weapons = [WeaponMount(spec: ammoSpec(140, type: 12), ammo: 0)]   // player draws pool 12 only
        let world = World(player: player)
        world.galaxy = galaxy
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.weapons = [WeaponMount(spec: ammoSpec(141, type: 13), ammo: 9)]     // hulk carries pool 13

        XCTAssertEqual(world.ammoAboard(hulk.entityID), 0, "no matching pool → nothing to take")
        XCTAssertEqual(world.takePlunderAmmo(from: hulk.entityID), 0)
        XCTAssertEqual(hulk.weapons[0].ammo, 9)
    }

    /// Two qualifying hulk banks: one boarding offers only one of them.
    func testPlunderAmmoOffersOneBank() {
        var col = ResourceCollection()
        col.add(ammoOutfit(300, weaponID: 140, mass: 1, max: 10))
        col.add(ammoOutfit(301, weaponID: 141, mass: 1, max: 10))
        let galaxy = Galaxy(game: NovaGame(col))
        let player = Ship(name: "P", stats: stats())
        player.weapons = [WeaponMount(spec: ammoSpec(140, type: 12), ammo: 0),
                          WeaponMount(spec: ammoSpec(141, type: 13), ammo: 0)]
        let world = World(player: player)
        world.galaxy = galaxy
        let hulk = disabledTarget(crew: 5, strength: 1, in: world)
        hulk.weapons = [WeaponMount(spec: ammoSpec(140, type: 12), ammo: 3),
                        WeaponMount(spec: ammoSpec(141, type: 13), ammo: 4)]
        let offered = world.ammoAboard(hulk.entityID)
        XCTAssertTrue(offered == 3 || offered == 4)
        XCTAssertEqual(world.takePlunderAmmo(from: hulk.entityID), offered)
        XCTAssertEqual(hulk.weapons.map(\.ammo).reduce(0, +), 7 - offered, "the other bank is untouched")
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

    // MARK: an NPC boarding (AI-29)

    func testNPCBoardingRatioIsClampedAndCrewScaled() {
        // 40 crew vs 10: trunc(4000 / 20) = 200, + 10 − 0 → clamped to 100.
        XCTAssertEqual(World.npcBoardingRatio(boarderCrew: 40, boarderOddsBonus: 0, victimCrew: 10,
                                              victimOddsBonus: 0) { _ in 0 }, 100)
        // 4 vs 10: 20, + 10 − 20 = 10; a victim with no crew counts as 1.
        XCTAssertEqual(World.npcBoardingRatio(boarderCrew: 4, boarderOddsBonus: 0, victimCrew: 10,
                                              victimOddsBonus: 0) { _ in 20 }, 10)
        XCTAssertEqual(World.npcBoardingRatio(boarderCrew: 0, boarderOddsBonus: 25, victimCrew: 0,
                                              victimOddsBonus: 0) { _ in 10 }, 25)
    }

    func testNPCBoardingCreditsAndCargoTransfer() {
        XCTAssertEqual(World.npcBoardingCreditsTaken(playerCredits: 100_000, ratio: 50), 15_000)
        var cargo = [0: 10, 3: 4]
        var picks = [3, 1, 0, 0].makeIterator()
        let moved = World.npcBoardingCargoTransfer(victimCargo: &cargo, victimCapacity: 20,
                                                   boarderFree: 9) { _ in picks.next() ?? 0 }
        XCTAssertEqual(moved, [3: 4, 0: 5], "random slots until the boarder's hold is full")
        XCTAssertEqual(cargo, [0: 5])
    }

    func testNPCBoardsAnNPCVictimAndTakesItsCargo() {
        let world = World(player: Ship(name: "P", stats: stats()))
        let victim = disabledTarget(crew: 5, strength: 10, in: world)
        victim.cargoCapacity = 20; victim.cargo = [1: 6]; victim.plunderCredits = 900
        let pirate = Ship(name: "Pirate", stats: stats())
        pirate.crew = 20; pirate.cargoCapacity = 50
        _ = world.addNPC(pirate)
        world.npcBoard(victim, by: pirate)
        XCTAssertEqual(pirate.cargo, [1: 6])
        XCTAssertEqual(victim.cargo, [:])
        XCTAssertEqual(victim.plunderCredits, 0)
    }

    /// AI-29's capture arm: a strong boarding party (ratio ≥ 41) takes the hulk
    /// into its wing about ratio/2 % of the time; a captured player escort is
    /// announced and leaves the roster.
    func testNPCBoarderSometimesCapturesThePlayersEscort() {
        var captured = 0, trials = 0, stolen = 0
        for seed in 1...300 {
            let world = World(player: Ship(name: "P", stats: stats()))
            world.rng = NovaRandom(seed: UInt32(seed))
            let victim = disabledTarget(crew: 5, strength: 10, in: world)
            victim.brain = AIBrain(aiType: .warship, govt: 128)
            victim.brain?.leaderID = World.playerEntityID
            victim.escortRecordID = 3
            let pirate = Ship(name: "Pirate", stats: stats())
            pirate.crew = 50; pirate.government = 129
            pirate.brain = AIBrain(aiType: .warship, govt: 129)
            _ = world.addNPC(pirate)
            world.step(1.0 / 30.0)
            world.npcBoard(victim, by: pirate)
            trials += 1
            if victim.brain?.leaderID == pirate.entityID {
                captured += 1
                XCTAssertEqual(victim.government, 129)
                XCTAssertNil(victim.escortRecordID)
                XCTAssertEqual(victim.shield, 0)
                XCTAssertEqual(victim.armor, Double(Float(victim.maxArmor) * 0.66), accuracy: 1e-3)
                XCTAssertEqual(world.originalAI.record(for: victim.entityID)?.behavior, 6)
            }
            if world.events.contains(where: { if case .shipCapturedByNPC(_, _, 168) = $0 { return true }; return false }) {
                stolen += 1
            }
        }
        XCTAssertEqual(captured, stolen, "every captured escort is announced")
        // Ratio 100 (capped): Rand(101) ≤ 50 → about half.
        XCTAssertTrue((100...200).contains(captured), "\(captured) of \(trials)")
    }
}
