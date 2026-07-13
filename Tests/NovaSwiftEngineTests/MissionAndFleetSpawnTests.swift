import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Galaxy-wide fleet population (`flët.LinkSyst`), the `AppearOn` NCB gate, and
/// mission-driven ship spawning (`mïsn` special ships + `ShipBehav` overrides).
final class MissionAndFleetSpawnTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    // MARK: synthetic resources

    /// A minimal spawnable hull: free mass + armor set so `makeLoadedShip`
    /// produces a living ship.
    private func ship(_ id: Int, name: String = "Hull") -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 12, 40)      // free mass
        put16(&b, 14, 120)     // armor
        return Resource(type: NovaType.ship, id: id, name: name, data: Data(b))
    }

    /// A `düde` archetype: AI type, govt, and a weighted ship table.
    private func dude(_ id: Int, aiType: Int, govt: Int, ships: [(Int, Int)]) -> Resource {
        var b = [UInt8](repeating: 0, count: 88)
        put16(&b, 0, aiType); put16(&b, 2, govt)
        for (i, s) in ships.prefix(16).enumerated() {
            put16(&b, 8 + i * 2, s.0); put16(&b, 40 + i * 2, s.1)
        }
        return Resource(type: NovaType.dude, id: id, name: "Dude\(id)", data: Data(b))
    }

    /// A `flët`: lead ship, up to four escort types, govt, `LinkSyst`, `AppearOn`.
    private func fleet(_ id: Int, lead: Int, escorts: [(Int, Int, Int)] = [],
                       govt: Int, linkSyst: Int, appearOn: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 306)
        put16(&b, 0, lead)
        for (i, e) in escorts.prefix(4).enumerated() {
            put16(&b, 2 + i * 2, e.0); put16(&b, 10 + i * 2, e.1); put16(&b, 18 + i * 2, e.2)
        }
        put16(&b, 26, govt); put16(&b, 28, linkSyst)
        for (i, byte) in Array(appearOn.utf8).prefix(255).enumerated() { b[30 + i] = byte }
        return Resource(type: NovaType.fleet, id: id, name: "Fleet\(id)", data: Data(b))
    }

    /// A `gövt` with a single class (enough for diplomacy + LinkSyst bands).
    private func govt(_ id: Int, classes: [Int] = [1]) -> Resource {
        var b = [UInt8](repeating: 0, count: 200)
        for i in 0..<4 { put16(&b, 24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { put16(&b, 32 + i * 2, -1) }
        for i in 0..<4 { put16(&b, 40 + i * 2, -1) }
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }

    // MARK: Phase 1 — galaxy-wide fleets via LinkSyst

    func testFleetSpawnsGalaxyWideByLinkSystEvenWhenNotInSystemTable() {
        // A Federation fleet whose LinkSyst = 10000 ("any Federation system"),
        // listed in NO system's own DudeTypes table — it must still spawn in a
        // Federation system purely from the galaxy-wide sweep.
        var col = ResourceCollection()
        col.add(ship(128, name: "Cruiser"))
        col.add(govt(128))
        col.add(fleet(128, lead: 128, govt: 128, linkSyst: 10000))   // 10000 + index 0 → govt 128
        let galaxy = Galaxy(game: NovaGame(col))

        // System govt 128, an EMPTY spawn table (no dudes, no explicit fleets).
        let table = SpawnTable(dudes: [], fleets: [], averageShips: 4,
                               systemGovt: 128, systemID: 500)
        let spawner = Spawner(galaxy: galaxy, table: table)
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        spawner.populate(world)

        XCTAssertTrue(world.npcs.contains { $0.shipTypeID == 128 },
                      "the Federation fleet's lead ship should appear via LinkSyst, not the system table")
    }

    func testFleetLinkSystForeignGovtIsNotEligible() {
        // Same fleet, but the system belongs to a different government (129) — the
        // LinkSyst 10000+0 band pins it to govt 128 only, so it must NOT spawn.
        var col = ResourceCollection()
        col.add(ship(128)); col.add(govt(128)); col.add(govt(129))
        col.add(fleet(128, lead: 128, govt: 128, linkSyst: 10000))
        let galaxy = Galaxy(game: NovaGame(col))
        let table = SpawnTable(dudes: [], fleets: [], averageShips: 4, systemGovt: 129, systemID: 500)
        let spawner = Spawner(galaxy: galaxy, table: table)
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        spawner.populate(world)
        XCTAssertFalse(world.npcs.contains { $0.shipTypeID == 128 },
                       "a fleet pinned to Federation systems must not spawn in another govt's system")
    }

    func testSingleShipsAreTheBackboneAndFleetsStayCapped() {
        // Regression for "I only ever see the same couple of fleets and barely any
        // lone ships": fleets used to top the head-count up to maxPopulation on
        // their own timer while the single-ship trickle only filled to the smaller
        // ambient target, so a fleet or two crowded lone ships out. Single ships
        // must now be the maintained backbone, with fleets a capped accent.
        var col = ResourceCollection()
        col.add(ship(128, name: "Hull"))
        col.add(govt(128))
        col.add(dude(200, aiType: AIType.wimpyTrader.rawValue, govt: 128, ships: [(128, 100)]))
        col.add(fleet(128, lead: 128, escorts: [(128, 3, 3)], govt: 128, linkSyst: 10000)) // 4-ship fleet
        let galaxy = Galaxy(game: NovaGame(col))

        let table = SpawnTable(dudes: [(200, 100)], fleets: [], averageShips: 8,
                               systemGovt: 128, systemID: 500)
        let spawner = Spawner(galaxy: galaxy, table: table)
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        spawner.populate(world)
        // A stretch of ambient updates (no world.step, so nothing departs) — the
        // population settles at its fill targets and the fleet cadence keeps firing.
        for _ in 0..<2000 { spawner.update(1.0 / 30.0, world: world) }

        let fleetShips = world.npcs.filter { $0.brain?.isFleetMember == true }.count
        let singles = world.npcs.count - fleetShips
        let distinctFleets = Set(world.npcs.compactMap { $0.brain?.fleetID }).count

        XCTAssertLessThanOrEqual(distinctFleets, spawner.maxConcurrentFleets,
                                 "fleets must stay capped, not accumulate every timer tick (had \(distinctFleets))")
        XCTAssertGreaterThanOrEqual(singles, spawner.targetPopulation - 1,
                                    "lone ships fill to the ambient backbone target (had \(singles))")
        XCTAssertGreaterThan(singles, fleetShips,
                             "single ships should be the bulk of traffic, not fleets (singles \(singles) vs fleet ships \(fleetShips))")
    }

    // MARK: Phase 2 — AppearOn NCB gate

    func testAppearOnGatedFleetSuppressedByDefaultAndEnabledByHost() {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(govt(128))
        // Non-blank AppearOn: a story control-bit test the engine can't evaluate.
        col.add(fleet(129, lead: 128, govt: 128, linkSyst: 10000, appearOn: "b1000"))
        let galaxy = Galaxy(game: NovaGame(col))
        let table = SpawnTable(dudes: [], fleets: [], averageShips: 4, systemGovt: 128, systemID: 500)

        // Default host gate returns false → the gated fleet is suppressed.
        let spawner1 = Spawner(galaxy: galaxy, table: table)
        let world1 = World(player: Ship(name: "P", stats: stats()))
        world1.galaxy = galaxy
        spawner1.populate(world1)
        XCTAssertFalse(world1.npcs.contains { $0.shipTypeID == 128 },
                       "a fleet with a non-blank AppearOn must not spawn while the host gate says no")

        // Host says the story bit is set → the fleet becomes eligible.
        let spawner2 = Spawner(galaxy: galaxy, table: table)
        let world2 = World(player: Ship(name: "P", stats: stats()))
        world2.galaxy = galaxy
        world2.fleetSpawnEligible = { _ in true }
        spawner2.populate(world2)
        XCTAssertTrue(world2.npcs.contains { $0.shipTypeID == 128 },
                      "once the host permits it, the AppearOn-gated fleet spawns")
    }

    // MARK: Phase 3 — mission spawning + ShipBehav

    private func missionGalaxy() -> Galaxy {
        var col = ResourceCollection()
        col.add(ship(128, name: "Freighter"))
        col.add(govt(128))
        col.add(dude(200, aiType: AIType.braveTrader.rawValue, govt: 128, ships: [(128, 100)]))
        return Galaxy(game: NovaGame(col))
    }

    func testSpawnMissionShipsPlacesTagsAndEmitsEvent() {
        let galaxy = missionGalaxy()
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        let ids = world.spawnMissionShips(missionID: 42, dudeID: 200, count: 3, goal: .destroy)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(world.missionShips(missionID: 42).count, 3)
        for s in world.missionShips(missionID: 42) {
            XCTAssertEqual(s.missionID, 42)
            XCTAssertEqual(s.missionShipGoal, .destroy)
        }
        XCTAssertTrue(world.events.contains {
            if case .missionShipsSpawned(let mid, let e) = $0 { return mid == 42 && e.count == 3 }
            return false
        })
    }

    func testRescueGoalShipsStartDisabled() {
        let galaxy = missionGalaxy()
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.spawnMissionShips(missionID: 7, dudeID: 200, count: 2, goal: .rescue)
        XCTAssertEqual(world.missionShips().count, 2)
        XCTAssertTrue(world.missionShips().allSatisfy { $0.disabled }, "a rescue objective's ships start crippled")
    }

    func testProtectPlayerShipsWireAsPlayerEscorts() {
        let galaxy = missionGalaxy()
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.spawnMissionShips(missionID: 9, dudeID: 200, count: 2, behavior: .protectPlayer)
        for s in world.missionShips() {
            XCTAssertEqual(s.brain?.leaderID, World.playerEntityID, "protect-player ships fly as the player's wing")
            XCTAssertEqual(s.brain?.behaviorOverride, .protectPlayer)
        }
    }

    func testDespawnMissionShipsRemovesTaggedShipsAndEmitsEvent() {
        let galaxy = missionGalaxy()
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.spawnMissionShips(missionID: 5, dudeID: 200, count: 3, goal: .escort)
        _ = world.drainEvents()
        let removed = world.despawnMissionShips(missionID: 5)
        XCTAssertEqual(removed.count, 3)
        XCTAssertTrue(world.missionShips(missionID: 5).isEmpty, "escorts leave cleanly at a plot point")
        XCTAssertTrue(world.events.contains {
            if case .missionShipsDespawned(let mid, _) = $0 { return mid == 5 }
            return false
        })
    }

    func testDestroyGoalFiresGoalReachedEvent() {
        let galaxy = missionGalaxy()
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        let ids = world.spawnMissionShips(missionID: 3, dudeID: 200, count: 1, goal: .destroy)
        _ = world.drainEvents()
        // Zero the ship's armor and let the despawn pass finalize the kill.
        let target = try! XCTUnwrap(world.ship(id: ids[0]))
        target.armor = 0
        world.step(1.0 / 30.0)
        XCTAssertTrue(world.events.contains {
            if case .missionShipGoalReached(let mid, let eid, let goal, _) = $0 {
                return mid == 3 && eid == ids[0] && goal == .destroy
            }
            return false
        }, "destroying a destroy-goal mission ship reports the objective reached")
    }

    // MARK: Phase 3 — ShipBehav friend/foe overrides (no galaxy needed)

    private func armedShip(_ name: String, govt: Int, at pos: Vec2) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 400, acceleration: 300, turnRate: 3), position: pos)
        s.government = govt; s.radius = 20
        s.maxShield = 80; s.shield = 80; s.maxArmor = 120; s.armor = 120
        s.weapons = [WeaponMount(spec: WeaponSpec(id: 128, name: "Gun", shieldDamage: 40, armorDamage: 40,
            reloadSeconds: 0.1, projectileSpeed: 2200, range: 5000, accuracyRadians: 0, isBeam: false,
            isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0))]
        return s
    }

    func testAttackPlayerOverrideMakesShipHostileToOtherwiseNeutralPlayer() {
        let player = Ship(name: "Player", stats: stats(), position: Vec2(0, 400))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [])   // nobody is diplomatically hostile to the player
        let ship = armedShip("Assassin", govt: 300, at: Vec2())
        let brain = AIBrain(aiType: .braveTrader, govt: 300)   // a *trader* — would normally flee, not hunt
        brain.behaviorOverride = .attackPlayer
        ship.brain = brain
        world.addNPC(ship)

        world.step(1.0 / 30.0)
        XCTAssertTrue(brain.isHostile(ship, player, world), "attack-player override treats the player as hostile")
        XCTAssertEqual(ship.currentTargetID, World.playerEntityID, "and locks the player even as a trader hull")
        XCTAssertEqual(brain.state, .attacking)
    }

    func testProtectPlayerOverrideNeverHostileEvenToAlwaysAttackGovt() {
        let player = Ship(name: "Player", stats: stats(), position: Vec2(0, 400))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        // Govt 300 is flagged "always attacks player" — but the protect override wins.
        var gd = [UInt8](repeating: 0, count: 200); gd[3] = 0x04   // flags1 0x0004 alwaysAttacksPlayer
        world.diplomacy = Diplomacy(govts: [GovtRes(Resource(type: NovaType.govt, id: 300, name: "G", data: Data(gd)))])
        let ship = armedShip("Guardian", govt: 300, at: Vec2())
        let brain = AIBrain(aiType: .warship, govt: 300)
        brain.behaviorOverride = .protectPlayer
        ship.brain = brain
        world.addNPC(ship)
        world.step(1.0 / 30.0)
        XCTAssertFalse(brain.isHostile(ship, player, world), "protect-player override is never hostile to the player")
    }
}
