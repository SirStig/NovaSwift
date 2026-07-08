import XCTest
@testable import EVNovaEngine
import EVNovaKit

/// Exercises the NPC brain end-to-end: perception → state transitions → steering
/// → firing, and a full deterministic duel driven only by governments + AI.
final class AIBehaviorTests: XCTestCase {

    // MARK: helpers

    private func govtData(classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0) -> Data {
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
        return Data(d)
    }
    private func govt(_ id: Int, classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0) -> GovtRes {
        GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)",
                         data: govtData(classes: classes, enemies: enemies, flags1: flags1)))
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

    func testWimpyTraderFlees() {
        let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 300))
        let world = World(player: player)
        // Government 201 treats the player as an enemy, so its trader sees a threat.
        world.diplomacy = Diplomacy(govts: [govt(201, classes: [2], flags1: 0x0004)])

        let trader = warship("Freighter", govt: 201, at: Vec2(), armed: false)
        trader.brain = AIBrain(aiType: .wimpyTrader, govt: 201)
        world.addNPC(trader)

        world.step(1.0 / 30.0)
        XCTAssertEqual(trader.brain?.state, .fleeing)
        XCTAssertTrue(trader.wantsToDepart)
    }

    func testTraderTravelsTowardPlanet() {
        let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(9_000, 9_000))                // far away, no threat
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])  // nobody hostile
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 2500), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)

        let trader = warship("Trader", govt: 202, at: Vec2(), armed: false)
        trader.brain = AIBrain(aiType: .braveTrader, govt: 202)
        world.addNPC(trader)

        for _ in 0..<90 { world.step(1.0 / 30.0) }                     // 3s
        XCTAssertGreaterThan(trader.velocity.y, 0, "trader should be steering toward the planet to its north")
        XCTAssertTrue(trader.brain?.state == .traveling || trader.brain?.state == .departing)
    }

    func testDepartedShipJumpsOutPastEdge() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.systemContext = SystemContext(bodies: [], center: Vec2(), jumpRadius: 1000, spawnRadius: 800)
        let leaver = warship("Leaver", govt: 300, at: Vec2(0, 1200), armed: false) // already past the edge
        leaver.wantsToDepart = true
        leaver.brain = AIBrain(aiType: .warship, govt: 300)
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

    func testLethalDamageCanDisableOrDestroy() {
        // Across seeds, a killing blow on a trader sometimes leaves a boardable
        // hulk and sometimes destroys it — proving both branches are reachable.
        func bigGun() -> WeaponSpec {
            WeaponSpec(id: 129, name: "Cannon", shieldDamage: 500, armorDamage: 500, reloadSeconds: 0.1,
                       projectileSpeed: 3000, range: 6000, accuracyRadians: 0, isBeam: false,
                       isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
        }
        var disabled = 0, destroyed = 0
        for seed in 0..<40 {
            let player = Ship(name: "Gunner", stats: ShipStats(maxSpeed: 10, acceleration: 10, turnRate: 3),
                              position: Vec2())
            player.weapons = [WeaponMount(spec: bigGun())]
            let world = World(player: player)
            world.rng = SplitMix64(seed: UInt64(seed) &* 0x9E37 &+ 1)
            world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])

            let trader = warship("Freighter", govt: 202, at: Vec2(0, 120), armed: false)
            trader.maxArmor = 60; trader.armor = 60; trader.maxShield = 0; trader.shield = 0
            trader.brain = AIBrain(aiType: .wimpyTrader, govt: 202)
            world.addNPC(trader)
            player.currentTargetID = trader.entityID
            world.intent.firePrimary = true

            for _ in 0..<200 {
                world.step(1.0 / 30.0)
                if trader.disabled { disabled += 1; break }
                if !world.npcs.contains(where: { $0 === trader }) { destroyed += 1; break }
            }
        }
        XCTAssertGreaterThan(disabled, 0, "some killing blows should merely disable")
        XCTAssertGreaterThan(destroyed, 0, "some killing blows should destroy outright")
    }

    func testTraderLandsAndVanishesIntoSpaceport() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)

        let trader = warship("Trader", govt: 202, at: Vec2(), armed: false)
        trader.brain = AIBrain(aiType: .braveTrader, govt: 202)
        world.addNPC(trader)

        var landed = false
        for _ in 0..<600 {                                     // up to 20s
            world.step(1.0 / 30.0)
            if world.events.contains(where: { if case .shipLanded = $0 { return true } else { return false } }) {
                landed = true; break
            }
        }
        XCTAssertTrue(landed, "a trader should reach a planet and set down")
        XCTAssertFalse(world.npcs.contains { $0 === trader }, "a landed ship vanishes into the spaceport")
    }

    func testDeterministicDuelResolves() {
        // Two mutually hostile warships, armed, closing head-on. Pure AI + combat.
        let a = warship("A", govt: 210, at: Vec2(0, -500), angle: 0)         // facing north (+y)
        let world = World(player: a)                                          // A is the "player" slot
        a.government = 210
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11]),
            govt(211, classes: [11], enemies: [10]),
        ])
        // A needs a brain too (player slot usually has none) — drive it via its brain.
        let brainA = AIBrain(aiType: .interceptor, govt: 210)
        let b = warship("B", govt: 211, at: Vec2(0, 500), angle: .pi)         // facing south (−y)
        b.brain = AIBrain(aiType: .interceptor, govt: 211)
        world.addNPC(b)

        // Manually think for the player-slot ship each frame so both sides fight.
        var destroyed = false
        for _ in 0..<600 {                                                    // up to 20s
            world.intent = brainA.think(ship: a, world: world, dt: 1.0 / 30.0)
            a.currentTargetID = brainA.state == .attacking ? brainA.targetID : nil
            world.step(1.0 / 30.0)
            if !b.isAlive || !a.isAlive { destroyed = true; break }
        }
        XCTAssertTrue(destroyed, "a duel between two armed, hostile interceptors should resolve")
    }
}
