import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// Exercises the NPC AI end-to-end (the original AI drives every brained NPC):
/// perception, firing, disabling, and a full deterministic duel driven only by
/// governments + AI.
final class AIBehaviorTests: XCTestCase {

    // MARK: helpers

    /// `maxOdds` defaults high: the original reads 0 as "almost never engage"
    /// (× 0.01, floored at 0.01), so tests about engaging set a real ceiling.
    private func govtData(classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0, maxOdds: Int = 1000) -> Data {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        putW(2, Int(flags1))
        putW(18, 2)
        putW(22, maxOdds)
        return Data(d)
    }
    private func govt(_ id: Int, classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0, maxOdds: Int = 1000) -> GovtRes {
        GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)",
                         data: govtData(classes: classes, enemies: enemies, flags1: flags1, maxOdds: maxOdds)))
    }

    private func gun() -> WeaponSpec {
        WeaponSpec(id: 128, name: "Gun", shieldDamage: 40, armorDamage: 40, reloadSeconds: 0.1,
                   projectileSpeed: 2200, range: 5000, accuracyRadians: 0, isBeam: false,
                   isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
    }
    private func warship(_ name: String, govt: Int, at pos: Vec2, angle: Double = 0, armed: Bool = true) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 400, acceleration: 300, turnRate: 3),
                     position: pos, angle: angle)
        s.government = govt; s.radius = 20
        s.maxShield = 80; s.shield = 80; s.maxArmor = 120; s.armor = 120
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        if armed { s.weapons = [WeaponMount(spec: gun())] }
        return s
    }

    // MARK: tests

    func testWarshipEngagesHostilePlayer() {
        let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 400))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(200, classes: [1], flags1: 0x0004)]) // always attacks player

        let npc = warship("Raider", govt: 200, at: Vec2())         // facing north, toward player
        npc.brain = AIBrain(aiType: .warship, govt: 200)
        world.addNPC(npc)

        world.step(1.0 / 30.0)
        XCTAssertEqual(npc.brain?.state, .attacking)
        XCTAssertEqual(npc.currentTargetID, player.entityID)

        for _ in 0..<60 { world.step(1.0 / 30.0) }
        XCTAssertLessThan(player.shield, 100, "an engaged warship should be scoring hits")
    }

    func testSelfDefenseHitDoesNotProvokeAttackersGovernment() {
        // Regression: the player returning fire on a ship that attacked them
        // first used to run the full "player aggression" reaction — marking
        // the player an aggressor for the police and flipping the attacker's
        // whole (otherwise neutral) government hostile in-system. Self-defense
        // must not.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 10, acceleration: 10, turnRate: 3))
        player.maxShield = 4000; player.shield = 4000; player.maxArmor = 4000; player.armor = 4000
        player.weapons = [WeaponMount(spec: gun())]
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(600, classes: [60])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 3000), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)

        // The attacker shot first (its provocation flag is what the reverse
        // rule in `applyHit` sets when its first hit lands on the player).
        let attacker = warship("Grudge", govt: 600, at: Vec2(0, 150))
        let abrain = AIBrain(aiType: .warship, govt: 600)
        abrain.provokedByPlayer = true
        attacker.brain = abrain
        world.addNPC(attacker)
        // An uninvolved same-government bystander, well out of the line of fire.
        let bystander = warship("Bystander", govt: 600, at: Vec2(-600, -400), armed: false)
        bystander.brain = AIBrain(aiType: .wimpyTrader, govt: 600)
        world.addNPC(bystander)

        // The player defends themselves; run until a return hit actually lands.
        player.currentTargetID = attacker.entityID
        world.intent.firePrimary = true
        var hitLanded = false
        for _ in 0..<300 {   // up to 10 seconds
            world.step(1.0 / 30.0)
            if attacker.shield < attacker.maxShield { hitLanded = true; break }
        }
        XCTAssertTrue(hitLanded, "fixture: the player's return fire must actually connect")
        XCTAssertFalse(world.provokedGovernments.contains(600),
                       "return fire in self-defense must not flip the attacker's whole government hostile")
        XCTAssertNotEqual(bystander.brain?.provokedByPlayer, true,
                          "an uninvolved same-government bystander stays neutral through the player's self-defense")
    }

    func testDepartedShipJumpsOutPastEdge() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.systemContext = SystemContext(bodies: [], center: Vec2(), jumpRadius: 1000, spawnRadius: 800)
        let leaver = warship("Leaver", govt: 300, at: Vec2(0, 1200), armed: false) // already past the edge
        leaver.wantsToDepart = true
        let brain = AIBrain(aiType: .warship, govt: 300)
        // Actually departing, not just carrying the flag: the brain now clears
        // a stale `wantsToDepart` whenever it isn't flying an exit (an
        // interrupted departure used to leave it set forever, silently eating
        // the ship the next time it strayed near a gate or the edge), so the
        // despawn sweep only honors the flag while the departure is real.
        brain.state = .departing
        leaver.brain = brain
        world.addNPC(leaver)

        world.step(1.0 / 30.0)
        XCTAssertTrue(world.npcs.isEmpty, "a departing ship past the jump radius leaves the system")
        XCTAssertTrue(world.events.contains { if case .shipDeparted = $0 { return true } else { return false } })
    }

    func testDisabledHulkIsIgnoredAndDrifts() {
        // A hostile warship should leave a disabled hulk alone, and the hulk should
        // bleed off its momentum instead of flying under power.
        let hunter = warship("Hunter", govt: 210, at: Vec2(0, -300), angle: 0)
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11]),
            govt(211, classes: [11], enemies: [10]),
        ])
        hunter.brain = AIBrain(aiType: .warship, govt: 210)
        world.addNPC(hunter)

        let hulk = warship("Hulk", govt: 211, at: Vec2(0, 100), armed: false)
        hulk.brain = AIBrain(aiType: .braveTrader, govt: 211)
        hulk.disabled = true
        hulk.velocity = Vec2(120, 0)
        let startSpeed = hulk.velocity.length
        world.addNPC(hulk)

        for _ in 0..<60 { world.step(1.0 / 30.0) }
        XCTAssertNotEqual(hunter.brain?.state, .attacking, "nobody attacks a helpless hulk")
        XCTAssertTrue(world.npcs.contains { $0 === hulk }, "a fresh hulk lingers in space")
        XCTAssertLessThan(hulk.velocity.length, startSpeed, "a hulk drifts to a stop")
    }

    func testLethalDamageDisablesAtThresholdThenDestroysOnFurtherDamage() {
        // EV Nova disables a ship the instant its armor crosses a fixed
        // percentage of max armor (33% default) — a deterministic threshold, not
        // a random roll — and only a *further* hit on the now-disabled hulk
        // actually destroys it.
        func bigGun() -> WeaponSpec {
            WeaponSpec(id: 129, name: "Cannon", shieldDamage: 25, armorDamage: 25, reloadSeconds: 0.1,
                       projectileSpeed: 3000, range: 6000, accuracyRadians: 0, isBeam: false,
                       isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
        }
        let player = Ship(name: "Gunner", stats: ShipStats(maxSpeed: 10, acceleration: 10, turnRate: 3),
                          position: Vec2())
        player.weapons = [WeaponMount(spec: bigGun())]
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])

        let trader = warship("Freighter", govt: 202, at: Vec2(0, 120), armed: false)
        trader.maxArmor = 60; trader.armor = 60; trader.maxShield = 0; trader.shield = 0
        trader.brain = AIBrain(aiType: .wimpyTrader, govt: 202)
        world.addNPC(trader)
        player.currentTargetID = trader.entityID
        world.intent.firePrimary = true

        var disabledAt: Int?
        for frame in 0..<200 {
            world.step(1.0 / 30.0)
            if trader.disabled { disabledAt = frame; break }
            XCTAssertTrue(world.npcs.contains(where: { $0 === trader }),
                          "the trader shouldn't be destroyed before ever being disabled")
        }
        XCTAssertNotNil(disabledAt, "the first blow through the 33% armor floor should disable, not destroy")
        XCTAssertTrue(trader.isAlive, "a disabled ship is a hulk, not a kill")

        for _ in 0..<200 {
            world.step(1.0 / 30.0)
            if !world.npcs.contains(where: { $0 === trader }) { return }
        }
        XCTFail("further damage on an already-disabled hulk should destroy it outright")
    }

    func testDeterministicDuelResolves() {
        // Two mutually hostile warships, armed, closing head-on. Pure AI + combat.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11]),
            govt(211, classes: [11], enemies: [10]),
        ])
        let a = warship("A", govt: 210, at: Vec2(0, -500), angle: 0)          // facing north (+y)
        a.brain = AIBrain(aiType: .interceptor, govt: 210)
        let b = warship("B", govt: 211, at: Vec2(0, 500), angle: .pi)         // facing south (−y)
        b.brain = AIBrain(aiType: .interceptor, govt: 211)
        world.addNPC(a)
        world.addNPC(b)

        var destroyed = false
        for _ in 0..<1800 {                                                   // up to 60s
            world.step(1.0 / 30.0)
            if !b.isAlive || !a.isAlive || a.disabled || b.disabled { destroyed = true; break }
        }
        XCTAssertTrue(destroyed, "a duel between two armed, hostile interceptors should resolve")
    }

    // MARK: government-gated patrols + scanning

    func testWorldWrapRecentresThePlayerAndCarriesNeighbours() {
        // FL-21 (0x0045baa0): crossing x = 15000 shifts the player — and every
        // ship within 15000 px of them — back 25000 px; distant ships stay put.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(15005, 40))
        let world = World(player: player)
        let escort = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(14800, 100))
        let faraway = Ship(name: "F", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                           position: Vec2(-2000, 0))
        world.addNPC(escort)
        world.addNPC(faraway)

        world.step(1.0 / 30.0)
        XCTAssertEqual(player.position.x, -9995, accuracy: 1e-9, "15005 − 25000")
        XCTAssertEqual(player.position.y, 40, accuracy: 1e-9, "the in-bounds axis is untouched")
        XCTAssertEqual(escort.position.x, -10200, accuracy: 1e-9, "a nearby ship comes along")
        XCTAssertEqual(faraway.position.x, -2000, accuracy: 1e-9, "a ship 17000 px away is left behind")
    }

    // MARK: fleet spawn eligibility (the LinkSyst govt-index → resource-id fix)

    func testFleetGovtBandEligibilityUsesResourceBase() {
        // A fleet with LinkSyst 10000 means "any system of government *index 0*",
        // and governments are resources 128+, so index 0 = resource id 128. The
        // fleet must be eligible in a system owned by govt 128 and ineligible in
        // one owned by govt 129 — the off-by-128 bug made it eligible in neither.
        func fleet(linkSystem: Int) -> FleetRes {
            var d = [UInt8](repeating: 0, count: 306)
            func putW(_ off: Int, _ v: Int) {
                let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
                d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
            }
            putW(0, 128)              // leadShip
            putW(26, -1)              // fleet's own govt: none
            putW(28, linkSystem)      // LinkSyst
            return FleetRes(Resource(type: NovaType.fleet, id: 128, name: "F", data: Data(d)))
        }
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.diplomacy = Diplomacy(govts: [govt(128, classes: [0]), govt(129, classes: [1])])

        let galaxy = Galaxy(game: NovaGame(ResourceCollection()))
        let ownedBy128 = Spawner(galaxy: galaxy, table: SpawnTable(systemGovt: 128))
        let ownedBy129 = Spawner(galaxy: galaxy, table: SpawnTable(systemGovt: 129))
        XCTAssertTrue(ownedBy128.isFleetEligible(fleet(linkSystem: 10000), world: world),
                      "LinkSyst 10000 (govt index 0 = resource 128) is eligible in a govt-128 system")
        XCTAssertFalse(ownedBy129.isFleetEligible(fleet(linkSystem: 10000), world: world),
                       "…and not in a govt-129 system")
    }

    // MARK: pêrs Aggress/Coward tuning (SESSION_AUDIT_FOLLOWUPS.md §A)

    /// AI-21: a përs's cadence is its Aggress, 3 or more clamped to 4.
    func testPersCadenceFromAggress() {
        XCTAssertEqual(AIBrain.cadence(forAggress: 1), 1)
        XCTAssertEqual(AIBrain.cadence(forAggress: 2), 2)
        XCTAssertEqual(AIBrain.cadence(forAggress: 3), 4)
    }

    /// AI-05: the player is picked up by reputation only inside the
    /// `cadence × 600` px box on each axis.
    func testPlayerAcquisitionBoxIsCadenceTimes600() {
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(1100, 1150))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        let owner = GovtRes(Resource(type: NovaType.govt, id: 250, name: "G",
                                     data: govtData(classes: [50])))   // CrimeTol 0
        world.diplomacy = Diplomacy(govts: [owner], currentSystemID: 500)
        world.diplomacy?.reputationMap = ReputationMap(systems: [.init(id: 500, govt: 250, x: 0, y: 0, links: [])])
        world.diplomacy?.seed(reputation: [500: -1])
        let npc = warship("Cop", govt: 250, at: Vec2())
        let brain = AIBrain(aiType: .warship, govt: 250)
        npc.brain = brain
        world.addNPC(npc)
        brain.cadence = 2   // 1200 px box
        XCTAssertTrue(brain.flagsPlayer(npc, player: player, world))
        brain.cadence = 1   // 600 px box
        XCTAssertFalse(brain.flagsPlayer(npc, player: player, world))
        brain.cadence = 0   // never by distance
        player.position = npc.position
        XCTAssertTrue(brain.flagsPlayer(npc, player: player, world), "cadence 0 only when coincident")
        player.position = Vec2(1, 0)
        XCTAssertFalse(brain.flagsPlayer(npc, player: player, world))
    }

    /// AI-02: an NPC fires only its selected bank — with a gun and a missile
    /// launcher aboard and the target in range of both, the homing launcher
    /// (the first guided bank that can track) is the one armed.
    func testNPCFiresOneSelectedBank() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        let shooter = warship("Shooter", govt: 1, at: Vec2())
        let missile = WeaponSpec(id: 129, name: "Missile", shieldDamage: 10, armorDamage: 10, reloadSeconds: 1,
                                 projectileSpeed: 600, range: 2000, accuracyRadians: 0, isBeam: false,
                                 isGuided: true, turnRate: 3, blastRadius: 0, ammoPerShot: 1,
                                 guidance: .guided)
        let heavyGun = WeaponSpec(id: 130, name: "Heavy", shieldDamage: 90, armorDamage: 5, reloadSeconds: 1,
                                  projectileSpeed: 2000, range: 2000, accuracyRadians: 0, isBeam: false,
                                  isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
        shooter.weapons = [WeaponMount(spec: gun()), WeaponMount(spec: heavyGun)]
        let target = warship("Target", govt: 2, at: Vec2(0, 500))
        world.addNPC(shooter); world.addNPC(target)
        // Shields up: the gun with the most energy damage wins.
        XCTAssertEqual(world.npcSelectedMounts(for: shooter, target: target), [1])
        // Shields down (negative): the most mass damage.
        target.shield = -1
        XCTAssertEqual(world.npcSelectedMounts(for: shooter, target: target), [0])
        // A trackable homing launcher in range takes precedence.
        let m = WeaponMount(spec: missile); m.ammo = 4
        shooter.weapons.append(m)
        XCTAssertEqual(world.npcSelectedMounts(for: shooter, target: target), [2])
    }

    // MARK: carrier-launched fighters escort their (possibly NPC) carrier

    // MARK: retreat / escort-disposition regressions

}
