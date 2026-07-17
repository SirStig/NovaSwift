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
        // The carrier flies for the player, on Attack. It needs a gun of its own
        // to engage: `AIBrain.armed` counts only firing weapons, not bays.
        carrier.weapons.append(WeaponMount(spec: WeaponSpec(
            id: 300, name: "Gun", shieldDamage: 10, armorDamage: 10, reloadSeconds: 0.1,
            projectileSpeed: 2000, range: 4000, accuracyRadians: 0, isBeam: false,
            isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)))
        carrier.brain = AIBrain(aiType: .warship, govt: 128)
        carrier.brain?.leaderID = World.playerEntityID
        world.setPlayerEscortOrder(.aggressive)
        XCTAssertEqual(carrier.brain?.escortOrder, .aggressive)

        // Something that has already traded fire with the player's fleet: the
        // carrier engages it on its own, which is what puts its bays into combat.
        let enemy = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                         position: Vec2(0, 600))
        enemy.brain = AIBrain(aiType: .warship, govt: 200)
        enemy.brain?.provokedByPlayer = true
        _ = world.addNPC(enemy)
        world.player.currentTargetID = enemy.entityID
        for _ in 0..<3 { world.step(1.0 / 30.0) }
        XCTAssertEqual(carrier.currentTargetID, enemy.entityID, "the carrier engaged on its wing order")

        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })
        XCTAssertTrue(world.isPlayerFleetMember(fighter.entityID),
                      "the fleet test follows the chain of command through the carrier")
        XCTAssertTrue(world.isPlayerEscort(fighter), "so the radar/targeting read it as yours")
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

    func testFightersStayOutWhenCarrierLeavesCombatButDockWhenBadlyHurt() throws {
        // Regression-guarding the *current*, deliberate behavior (see
        // `updateFighterBays`'s doc comment): a fighter does NOT get yanked home
        // just because its carrier lost its target/left combat — only when the
        // fighter itself is dry on ammo or badly hurt (or the player explicitly
        // recalls it). The old version of this test asserted the opposite
        // (carrier-leaves-combat ⇒ auto-recall), which is exactly the "yank every
        // fighter home the instant you deselected a target" behavior the current
        // code deliberately moved away from.
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

        // Carrier leaves combat: place the fighter right on the carrier (so
        // proximity is never the blocker) and step — it should NOT dock.
        carrier.currentTargetID = nil
        fighter.position = carrier.position
        for _ in 0..<3 { world.step(1.0 / 30.0) }
        XCTAssertTrue(world.npcs.contains { $0.entityID == fighter.entityID },
                      "leaving combat alone shouldn't recall a healthy, armed fighter")
        XCTAssertEqual(carrier.fighterBays.first?.docked, 2, "bay unchanged — fighter still deployed")

        // Now badly hurt it (below the 30% health-fraction recall threshold):
        // still on top of the carrier, it should dock on the next step.
        fighter.armor = fighter.maxArmor * 0.1
        fighter.shield = 0
        world.step(1.0 / 30.0)
        XCTAssertFalse(world.npcs.contains { $0.entityID == fighter.entityID }, "badly hurt fighter docks away")
        XCTAssertEqual(carrier.fighterBays.first?.docked, 3, "bay restored on dock")
    }

    func testBadlyHurtFighterFliesHomeToDockFromRange() throws {
        // Previously the recall flag steered nothing — a hurt fighter far from its
        // carrier kept dogfighting and only ever docked if it happened to drift back
        // over the bay, which read as fighters wandering off and never coming home.
        // Now the brain flies a recalled fighter straight home.
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil   // brainless → sits still, so the carrier doesn't move under the test
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        let enemyID = world.addNPC(Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        carrier.currentTargetID = enemyID
        world.step(1.0 / 30.0)
        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })

        // Teleport the fighter far away and badly hurt it (below the 30% recall
        // threshold), so it will be flagged to return.
        fighter.position = carrier.position + Vec2(4000, 0)
        fighter.armor = fighter.maxArmor * 0.1
        fighter.shield = 0
        let startDist = (fighter.position - carrier.position).length

        for _ in 0..<120 { world.step(1.0 / 30.0) }   // ~4s to fly home
        if let f = world.npcs.first(where: { $0.entityID == fighter.entityID }) {
            XCTAssertTrue(f.recallToCarrier, "a badly hurt fighter is flagged to return")
            XCTAssertLessThan((f.position - carrier.position).length, startDist,
                              "a recalled fighter closes on its carrier instead of loitering at range")
        }
        // (If it already docked and despawned, that's the fully-correct outcome too.)
    }

    // MARK: a live, brain-driven (not manually-targeted) NPC carrier

    private func govtData(classes: [Int], enemies: [Int] = []) -> Data {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        return Data(d)
    }
    private func govt(_ id: Int, classes: [Int], enemies: [Int] = []) -> GovtRes {
        GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: govtData(classes: classes, enemies: enemies)))
    }

    /// Regression-guarding the gap the other tests in this file leave open:
    /// they all strip `carrier.brain` and hand-set `currentTargetID`, so the
    /// carrier's *own* AI decision to fight (and thereby trigger
    /// `carrierInCombat`) was never actually exercised end-to-end. Here the
    /// carrier keeps its real brain and only diplomacy/proximity drive it
    /// into combat, same as it would in a live system.
    func testLiveBrainDrivenCarrierLaunchesFightersWithoutManualTargeting() throws {
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 300, extraOutfits: [200: 1]))
        carrier.weapons = [WeaponMount(spec: WeaponSpec(id: 999, name: "Gun", shieldDamage: 10, armorDamage: 10,
                                                        reloadSeconds: 1, projectileSpeed: 1000, range: 3000,
                                                        accuracyRadians: 0, isBeam: false, isGuided: false,
                                                        turnRate: 0, blastRadius: 0, ammoPerShot: 0))]
        carrier.brain = AIBrain(aiType: .warship, govt: 300)

        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.galaxy = galaxy
        world.diplomacy = Diplomacy(govts: [
            govt(300, classes: [30], enemies: [31]),
            govt(301, classes: [31], enemies: [30]),
        ])
        _ = world.addNPC(carrier)
        let hostile = Ship(name: "Hostile", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3), position: Vec2(0, 400))
        hostile.government = 301
        hostile.weapons = [WeaponMount(spec: WeaponSpec(id: 998, name: "Gun", shieldDamage: 10, armorDamage: 10,
                                                        reloadSeconds: 1, projectileSpeed: 1000, range: 3000,
                                                        accuracyRadians: 0, isBeam: false, isGuided: false,
                                                        turnRate: 0, blastRadius: 0, ammoPerShot: 0))]
        _ = world.addNPC(hostile)

        for _ in 0..<90 { world.step(1.0 / 30.0) }   // up to 3s for the carrier to close/engage/launch

        XCTAssertEqual(carrier.brain?.state, .attacking, "the carrier's own brain should pick the hostile as a target")
        let fighters = world.npcs.filter { $0.carrierID == carrier.entityID }
        XCTAssertFalse(fighters.isEmpty, "a live, brain-driven carrier in real combat should launch fighters on its own")
    }
}
