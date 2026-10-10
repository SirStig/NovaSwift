import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Fighter bays (`wëap` Guidance 99): loadout extraction and the launch/dock
/// runtime — a carrier deploys fighters in combat and reclaims them.
final class FighterBayTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func ship(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100); put16(&b, 6, 300); put16(&b, 4, 200); put16(&b, 8, 30)  // shield/speed/accel/turn
        put16(&b, 12, 40); put16(&b, 14, 100)   // free mass, armor
        put16(&b, 10, 400)                        // fuel
        return Resource(type: NovaType.ship, id: id, name: "Ship\(id)", data: Data(b))
    }
    /// A fighter-bay weapon: guidance 99, AmmoType = fighter ship, MaxAmmo = capacity.
    private func bayWeapon(_ id: Int, fighter: Int, capacity: Int, reload: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, reload)          // reload
        put16(&b, 8, 99)              // guidance = carried ship
        put16(&b, 12, fighter)        // AmmoType = fighter ship class
        put16(&b, 108, capacity)      // MaxAmmo = fighters carried
        return Resource(type: NovaType.weapon, id: id, name: "Bay\(id)", data: Data(b))
    }
    private func weaponGrantOutfit(_ id: Int, weapon: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 6, 1); put16(&b, 8, weapon)   // ModType 1 (weapon) → weapon id
        return Resource(type: NovaType.outfit, id: id, name: "BayOutfit", data: Data(b))
    }

    private func game() -> NovaGame {
        var col = ResourceCollection()
        col.add(ship(128))                                 // carrier hull
        col.add(ship(144))                                 // fighter hull
        col.add(bayWeapon(149, fighter: 144, capacity: 3, reload: 30))
        col.add(weaponGrantOutfit(200, weapon: 149))       // grants the bay
        return NovaGame(col)
    }

    func testLoadoutExtractsFighterBay() throws {
        let galaxy = Galaxy(game: game())
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128, extraOutfits: [200: 1]))
        XCTAssertEqual(lo.fighterBays.count, 1)
        XCTAssertEqual(lo.fighterBays.first?.fighterShipID, 144)
        XCTAssertEqual(lo.fighterBays.first?.capacity, 3)
        // The bay's own mount stays in `weapons` too, so it's selectable as a
        // secondary — real EV Nova bays act exactly like a missile launcher:
        // select it, pull the trigger, one fighter launches.
        XCTAssertTrue(lo.weapons.contains { $0.id == 149 })
    }

    func testCarrierLaunchesFightersInCombat() throws {
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil   // no brain → its target won't be re-evaluated away
        XCTAssertEqual(carrier.fighterBays.first?.docked, 3)

        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let world = World(player: player)
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)

        // A live enemy for the carrier to be "in combat" with.
        let enemy = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let enemyID = world.addNPC(enemy)
        carrier.currentTargetID = enemyID

        // Step a couple frames: the bay should deploy a fighter and decrement docked.
        for _ in 0..<3 { world.step(1.0 / 30.0) }

        let fighters = world.npcs.filter { $0.carrierID == carrier.entityID }
        XCTAssertEqual(fighters.count, 1, "one fighter launched")
        XCTAssertEqual(fighters.first?.shipTypeID, 144)
        XCTAssertEqual(carrier.fighterBays.first?.docked, 2, "one fighter spent from the bay")
    }

    func testLaunchedFightersGetDistinctFormationSlots() throws {
        // Regression: `launchFighter` never assigned `formationSlot`, so every
        // fighter from the same bay defaulted to slot 0 and piled onto the
        // same escort position instead of fanning out.
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        let enemyID = world.addNPC(Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        carrier.currentTargetID = enemyID

        // Bay capacity 3, ~1s reload between launches — plenty of time for
        // all three to deploy.
        for _ in 0..<200 { world.step(1.0 / 30.0) }

        let fighters = world.npcs.filter { $0.carrierID == carrier.entityID }
        XCTAssertEqual(fighters.count, 3, "all three fighters launched")
        let slots = Set(fighters.compactMap { $0.brain?.formationSlot })
        XCTAssertEqual(slots.count, 3, "each fighter got its own formation slot instead of stacking on 0")
    }

    /// A fighter off one of the player's escort carriers is the player's too.
    /// Its leader is the *carrier*, not the player, so a one-level "leaderID ==
    /// player" fleet test read it as an outsider: any stray hit from the player's
    /// own fleet marked it `provokedByPlayer`, and it turned on the carrier it
    /// launched from. It also fights under the wing's standing order, like every
    /// other escort, rather than a hardcoded Defend.
    func testFighterOffAPlayerEscortCarrierIsPlayerFleetAndTakesTheWingOrder() throws {
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        // The carrier flies for the player, on Attack.
        carrier.brain = AIBrain(aiType: .warship, govt: 128)
        carrier.brain?.leaderID = World.playerEntityID
        world.setPlayerEscortOrder(.aggressive)
        XCTAssertEqual(carrier.brain?.escortOrder, .aggressive)

        // Something the carrier is fighting puts its bays into combat. The
        // carrier flies brainless for the launch so no AI re-aims it.
        let enemy = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                         position: Vec2(0, 600))
        _ = world.addNPC(enemy)
        let carrierBrain = carrier.brain
        carrier.brain = nil
        carrier.currentTargetID = enemy.entityID
        for _ in 0..<3 { world.step(1.0 / 30.0) }
        carrier.brain = carrierBrain

        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })
        XCTAssertTrue(world.isPlayerFleetMember(fighter.entityID),
                      "the fleet test follows the chain of command through the carrier")
        XCTAssertTrue(world.isPlayerEscort(fighter), "so the radar/targeting read it as yours")
        world.setPlayerEscortOrder(.aggressive)
        XCTAssertEqual(fighter.brain?.escortOrder, .aggressive,
                       "it flies under the same standing order as the wing it belongs to")
        // Even if something has marked the fighter as provoked, it is on the
        // player's side of `isHostile`'s fleet-vs-outsider test, so it never
        // turns on the carrier it launched from (or on the player).
        fighter.brain?.provokedByPlayer = true
        XCTAssertFalse(fighter.brain!.isHostile(fighter, carrier, world),
                       "a fighter never turns on the carrier it launched from")
        XCTAssertFalse(fighter.brain!.isHostile(fighter, world.player, world),
                       "nor on the player whose fleet it belongs to")
    }

    func testFightersReturnAndDockWhenTheCarrierStandsDown() throws {
        // OS-03: a carrier that stands down (no target) calls its fighters
        // home; they dock within 75 px on both axes and the bay gains them back.
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        let enemyID = world.addNPC(Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        carrier.currentTargetID = enemyID
        world.step(1.0 / 30.0)
        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })
        XCTAssertEqual(carrier.fighterBays.first?.docked, 2)
        XCTAssertEqual(fighter.currentTargetID, enemyID, "a launched fighter takes the carrier's target")

        // In combat, a fighter next to its carrier stays out.
        fighter.position = carrier.position + Vec2(10, 10)
        world.step(1.0 / 30.0)
        XCTAssertTrue(world.npcs.contains { $0.entityID == fighter.entityID })

        // Standing down recalls it; at 74 px it docks, at 76 px it doesn't.
        carrier.currentTargetID = nil
        fighter.position = carrier.position + Vec2(76, 0)
        fighter.velocity = Vec2()
        world.step(1.0 / 30.0)
        XCTAssertTrue(fighter.recallToCarrier)
        fighter.position = carrier.position + Vec2(74, -74)
        world.step(1.0 / 30.0)
        XCTAssertFalse(world.npcs.contains { $0.entityID == fighter.entityID }, "docked")
        XCTAssertEqual(carrier.fighterBays.first?.docked, 3, "bay restored on dock")
    }

    func testLaunchedFighterIsBehaviorFiveWithTheBaysLaunchVelocity() throws {
        // AI-41: × 1.333 max shield/armor and shield regen; OS-03: launched
        // from the carrier's centre at the bay's Speed / 100 px/tick.
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil
        carrier.angle = .pi / 2
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        carrier.currentTargetID = world.addNPC(Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.step(1.0 / 30.0)
        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })
        let stock = try XCTUnwrap(galaxy.makeLoadedShip(144))
        XCTAssertEqual(fighter.maxShield, Double(Float(stock.maxShield * 1.333)), accuracy: 1e-6)
        XCTAssertEqual(fighter.maxArmor, Double(Float(stock.maxArmor * 1.333)), accuracy: 1e-6)
        XCTAssertEqual(fighter.shieldRechargePerSec, stock.shieldRechargePerSec * 1.333, accuracy: 1e-9)
        XCTAssertEqual(fighter.armorRechargePerSec, stock.armorRechargePerSec, accuracy: 1e-9)
        XCTAssertEqual(carrier.fighterBays.first?.launchCooldown ?? 0, 1, accuracy: 1e-9,
                       "the next launch waits Reload / mounted (30 ticks / 1)")
    }
}
