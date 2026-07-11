import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// Exercises the NPC brain end-to-end: perception → state transitions → steering
/// → firing, and a full deterministic duel driven only by governments + AI.
final class AIBehaviorTests: XCTestCase {

    // MARK: helpers

    private func govtData(classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0, maxOdds: Int = 0) -> Data {
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
    private func govt(_ id: Int, classes: [Int], enemies: [Int] = [], flags1: UInt16 = 0, maxOdds: Int = 0) -> GovtRes {
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

    func testAmmoExhaustedWarshipFleesOrDocksInsteadOfFighting() {
        // Bible: "AI ships of this type will run away/dock if out of ammo for
        // all ammo-using weapons" (shïp.Flags2 0x0080).
        // With a hostile present, it should flee rather than attack.
        do {
            let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                              position: Vec2(0, 400))
            let world = World(player: player)
            world.diplomacy = Diplomacy(govts: [govt(200, classes: [1], flags1: 0x0004)])
            let npc = warship("Raider", govt: 200, at: Vec2())
            npc.fleeWhenOutOfAmmo = true
            npc.weapons = [WeaponMount(spec: npc.weapons[0].spec, ammo: 0)]   // dry
            npc.brain = AIBrain(aiType: .warship, govt: 200)
            world.addNPC(npc)

            world.step(1.0 / 30.0)
            XCTAssertEqual(npc.brain?.state, .fleeing, "out of ammo with a hostile present -> run, not fight")
        }
        // With nothing chasing it, it should head off to dock (travel/land),
        // not just keep patrolling empty-handed.
        do {
            let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                           position: Vec2(9_000, 9_000)))
            world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])   // nobody hostile
            world.systemContext = SystemContext(
                bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: true)],
                center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)
            let npc = warship("Patrol", govt: 202, at: Vec2())
            npc.fleeWhenOutOfAmmo = true
            npc.weapons = [WeaponMount(spec: npc.weapons[0].spec, ammo: 0)]
            npc.brain = AIBrain(aiType: .warship, govt: 202)
            world.addNPC(npc)

            world.step(1.0 / 30.0)
            XCTAssertEqual(npc.brain?.state, .traveling, "out of ammo with nothing chasing it -> dock to rearm")
        }
    }

    func testWarshipDeclinesUnfavorableOdds() {
        // gövt.MaxOdds = 100 means "won't fight unless as strong or stronger."
        // A lone warship facing three equal-strength hostiles is outnumbered
        // 3-to-1 and should hold its ground instead of charging in.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11], maxOdds: 100),
            govt(211, classes: [11], enemies: [10]),
        ])
        let defender = warship("Defender", govt: 210, at: Vec2(0, -300), angle: 0)
        defender.brain = AIBrain(aiType: .warship, govt: 210)
        world.addNPC(defender)
        for i in 0..<3 {
            let raider = warship("Raider\(i)", govt: 211, at: Vec2(Double(i) * 40, 0))
            world.addNPC(raider)
        }

        world.step(1.0 / 30.0)
        XCTAssertNotEqual(defender.brain?.state, .attacking,
                          "outnumbered 3-to-1 against a MaxOdds-100 govt, it shouldn't pick the fight")
    }

    func testWarshipEngagesFavorableOdds() {
        // Same setup, but only one hostile: 1-to-1 is exactly the odds a
        // MaxOdds-100 government will accept.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11], maxOdds: 100),
            govt(211, classes: [11], enemies: [10]),
        ])
        let defender = warship("Defender", govt: 210, at: Vec2(0, -300), angle: 0)
        defender.brain = AIBrain(aiType: .warship, govt: 210)
        world.addNPC(defender)
        let raider = warship("Raider", govt: 211, at: Vec2(0, 0))
        world.addNPC(raider)

        world.step(1.0 / 30.0)
        XCTAssertEqual(defender.brain?.state, .attacking, "1-to-1 odds are acceptable — it should engage")
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

    func testBraveTraderFightsInRangeButFleesOutOfRange() {
        // Bible: brave traders "fight back when attacked, but run away when
        // their attacker is out of range" — not a hull-damage threshold.
        func shortGun() -> WeaponSpec {
            WeaponSpec(id: 130, name: "Short Gun", shieldDamage: 20, armorDamage: 20, reloadSeconds: 0.1,
                       projectileSpeed: 1500, range: 300, accuracyRadians: 0, isBeam: false,
                       isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
        }
        // Out of the trader's 300px weapon range (but within its scan range) —
        // should flee rather than close in and fight.
        do {
            let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                              position: Vec2(0, 900))
            let world = World(player: player)
            world.diplomacy = Diplomacy(govts: [govt(201, classes: [2], flags1: 0x0004)])
            let trader = warship("Freighter", govt: 201, at: Vec2())
            trader.weapons = [WeaponMount(spec: shortGun())]
            trader.brain = AIBrain(aiType: .braveTrader, govt: 201)
            world.addNPC(trader)

            world.step(1.0 / 30.0)
            XCTAssertEqual(trader.brain?.state, .fleeing, "attacker is well outside the trader's weapon range")
        }
        // Well within the trader's 300px weapon range — should fight back.
        do {
            let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                              position: Vec2(0, 150))
            let world = World(player: player)
            world.diplomacy = Diplomacy(govts: [govt(201, classes: [2], flags1: 0x0004)])
            let trader = warship("Freighter", govt: 201, at: Vec2())
            trader.weapons = [WeaponMount(spec: shortGun())]
            trader.brain = AIBrain(aiType: .braveTrader, govt: 201)
            world.addNPC(trader)

            world.step(1.0 / 30.0)
            XCTAssertEqual(trader.brain?.state, .attacking, "attacker is well within the trader's weapon range")
        }
    }

    func testInterceptorOrbitsInsteadOfPatrollingWhenIdle() {
        // Bible: interceptors "park in orbit around a planet" if they can't
        // find any enemies — not walk the warship patrol beat.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [govt(220, classes: [20])])   // nobody hostile
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 1200), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)

        let interceptor = warship("Watchdog", govt: 220, at: Vec2(0, 900))
        interceptor.brain = AIBrain(aiType: .interceptor, govt: 220)
        world.addNPC(interceptor)

        world.step(1.0 / 30.0)
        XCTAssertEqual(interceptor.brain?.state, .orbiting, "an idle interceptor holds orbit, not a patrol beat")
    }

    func testInterceptorActsAsPiracyPolice() {
        // Bible: interceptors act as "piracy police" — attacking any ship
        // that fires on/targets another, non-enemy ship while watching, even
        // if that aggressor isn't normally the interceptor's own enemy.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(220, classes: [20]),   // the interceptor's own govt: no declared enemies
            govt(221, classes: [21]),   // aggressor's govt
            govt(222, classes: [22]),   // victim's govt — not an enemy of anyone here
        ])
        let interceptor = warship("Watchdog", govt: 220, at: Vec2(0, -300), angle: 0)
        interceptor.brain = AIBrain(aiType: .interceptor, govt: 220)
        world.addNPC(interceptor)

        let victim = warship("Trader", govt: 222, at: Vec2(0, 200), armed: false)
        world.addNPC(victim)
        let aggressor = warship("Raider", govt: 221, at: Vec2(0, 150))
        aggressor.currentTargetID = victim.entityID   // actively firing on a non-enemy
        world.addNPC(aggressor)

        world.step(1.0 / 30.0)
        XCTAssertEqual(interceptor.brain?.state, .attacking, "should intervene against the aggressor")
        XCTAssertEqual(interceptor.brain?.targetID, aggressor.entityID)
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

    func testShipWithSidewaysMomentumCancelsDriftInsteadOfLoopingBack() {
        // The drift fix: a ship whose momentum is carrying it *across* its course
        // must steer that momentum back onto the line and settle onto the target,
        // not sail off to the side and loop back (naïve "point the nose at the
        // target and thrust" steering). Trader at the origin heading for a planet
        // due north, but launched with a strong sideways (+x) velocity.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(90_000, 90_000)))   // far — no threat
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 2500), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 8000, spawnRadius: 7000)

        let trader = warship("Trader", govt: 202, at: Vec2(), armed: false)
        trader.velocity = Vec2(300, 0)                                   // full-cruise drift straight sideways
        trader.brain = AIBrain(aiType: .braveTrader, govt: 202)
        world.addNPC(trader)

        // Track how far off the straight-north course line (the x axis) the ship
        // ever strays, and whether it reaches the planet.
        var maxCrossTrack = 0.0
        var landed = false
        for _ in 0..<600 {                                              // up to 20s
            world.step(1.0 / 30.0)
            maxCrossTrack = max(maxCrossTrack, abs(trader.position.x))
            if world.events.contains(where: { if case .shipLanded = $0 { return true } else { return false } }) {
                landed = true; break
            }
        }
        // Velocity-compensated steering pulls the +x drift back toward the course:
        // the excursion stays bounded (naïve steering would fling it far off and
        // orbit), and it still sets down on the planet.
        XCTAssertLessThan(maxCrossTrack, 900, "sideways momentum should be steered back onto course, not looped")
        XCTAssertTrue(landed, "even launched off-axis, the trader should still settle onto the planet")
    }

    func testTraderNoseDoesNotSpinChasingTheArrivalBrake() {
        // Regression for "ship is angled one way but flying towards another" —
        // steering the final approach off a raw (desiredVelocity − velocity)
        // heading recomputes a target bearing that shifts faster than a
        // turn-rate-limited hull can track, so the nose just spins in place
        // (confirmed against real Argosy-class stats: 500°+ of continuous
        // rotation on final approach while velocity barely turned at all).
        // Track the ship's *total* rotation over the whole approach — clean
        // steering costs at most an initial turn-to-course plus one flip-and-burn
        // braking maneuver (comfortably under 3 full turns); the spin bug blew
        // well past that without ever settling.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(90_000, 90_000)))
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 2500), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 8000, spawnRadius: 7000)

        // Real Argosy hull stats (speed/accel/turn), not the tests' generic slow
        // fixture — this bug only shows up at realistic turn rates.
        let trader = Ship(name: "Trader", stats: ShipStats(speed: 250, acceleration: 350, turnRate: 35),
                           position: Vec2())
        trader.government = 202
        trader.brain = AIBrain(aiType: .braveTrader, govt: 202)
        world.addNPC(trader)

        var totalRotation = 0.0
        var landed = false
        for _ in 0..<600 {                                              // up to 20s
            let before = trader.angle
            world.step(1.0 / 30.0)
            totalRotation += abs(trader.angle - before)
            if world.events.contains(where: { if case .shipLanded = $0 { return true } else { return false } }) {
                landed = true; break
            }
        }
        XCTAssertTrue(landed, "a trader on a clean, direct approach should still land")
        XCTAssertLessThan(totalRotation, 3 * 2 * .pi,
                          "the nose shouldn't spin chasing a jittery brake heading — total turning should stay near one course correction + one flip-and-burn")
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

    func testLethalDamageDisablesAtThresholdThenDestroysOnFurtherDamage() {
        // EV Nova disables a ship the instant its armor crosses a fixed
        // percentage of max armor (33% default) — a deterministic threshold, not
        // a random roll — and only a *further* hit on the now-disabled hulk
        // actually destroys it.
        func bigGun() -> WeaponSpec {
            WeaponSpec(id: 129, name: "Cannon", shieldDamage: 500, armorDamage: 500, reloadSeconds: 0.1,
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

    func testTraderNeverLandsOnUninhabitedOrNonLandableBody() {
        // Regression: `pickPlanetBody` used to fall back to *any* stellar body
        // (including uninhabited/non-landable ones) when the system had no
        // landable body at all. The AI should only ever land on inhabited
        // planets/stations (`canLand` already folds in `!isUninhabited`) —
        // with none available, a trader should just fly on/depart, never
        // "land" on the uninhabited rock.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [govt(202, classes: [3])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: false)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)

        let trader = warship("Trader", govt: 202, at: Vec2(), armed: false)
        trader.brain = AIBrain(aiType: .braveTrader, govt: 202)
        world.addNPC(trader)

        for _ in 0..<600 {                                     // up to 20s
            world.step(1.0 / 30.0)
            XCTAssertNotEqual(trader.brain?.state, .landing, "no landable body exists in this system")
            if world.events.contains(where: { if case .shipLanded = $0 { return true } else { return false } }) {
                XCTFail("should never land — the only stellar body isn't landable")
            }
        }
        XCTAssertNil(trader.landingSpob)
        XCTAssertFalse(trader.wantsToLand)
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

    // MARK: government-gated patrols + scanning

    func testOnlyLocalAuthorityPatrolsForeignersTravelThrough() {
        // In a Federation-owned (govt 500) system: a Federation warship runs the
        // patrol beat; a warship of an unrelated government (501) has no business
        // policing someone else's space, so it just crosses the system.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(90_000, 90_000))        // far — nothing to scan/fight
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50]), govt(501, classes: [51])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 2000), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        // Keep them beyond scan reach of each other so this test isolates the
        // patrol-vs-travel decision (a nearby neutral would be scanned instead).
        let local = warship("Local", govt: 500, at: Vec2())
        local.brain = AIBrain(aiType: .warship, govt: 500)
        world.addNPC(local)
        let foreign = warship("Foreign", govt: 501, at: Vec2(40_000, 0))
        foreign.brain = AIBrain(aiType: .warship, govt: 501)
        world.addNPC(foreign)

        world.step(1.0 / 30.0)
        XCTAssertEqual(local.brain?.state, .patrolling, "the system's own government patrols")
        XCTAssertEqual(foreign.brain?.state, .traveling, "a foreign warship passes through, it doesn't patrol")
    }

    func testLocalAuthorityScansThePlayer() {
        // An armed authority ship with the player close by and non-hostile flies
        // a scan pass and emits a shipScanned event aimed at the player.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 180))                 // within scan-complete range
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 1500), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        let patrol = warship("Patrol", govt: 500, at: Vec2())
        patrol.brain = AIBrain(aiType: .warship, govt: 500)
        world.addNPC(patrol)

        world.step(1.0 / 30.0)
        XCTAssertEqual(patrol.brain?.state, .scanning, "authority breaks off its beat to scan a passing ship")
        let scanned = world.events.contains {
            if case let .shipScanned(_, targetID, _) = $0 { return targetID == player.entityID }
            return false
        }
        XCTAssertTrue(scanned, "the scan pass should emit a shipScanned event targeting the player")
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

    func testHyperspaceArrivalTearsInAboveCruise() {
        // A jump-in should enter above its cruise cap (the visible inrush) and
        // then decelerate, rather than snapping straight to cruise speed.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.systemContext = SystemContext(bodies: [], center: Vec2(), jumpRadius: 6000, spawnRadius: 5000)
        let arrival = warship("Inbound", govt: 500, at: Vec2(0, 5000), angle: .pi)  // pointed inward (−y)
        arrival.brain = AIBrain(aiType: .warship, govt: 500)
        world.addNPC(arrival, arrival: .hyperspace)

        world.step(1.0 / 30.0)
        XCTAssertGreaterThan(arrival.velocity.length, arrival.stats.maxSpeed,
                             "immediately after a jump-in the ship is still above cruise speed")
        for _ in 0..<120 { world.step(1.0 / 30.0) }              // ~4s later
        XCTAssertLessThanOrEqual(arrival.velocity.length, arrival.stats.maxSpeed + 1,
                                 "the entry over-speed bleeds back down to cruise")
    }
}
