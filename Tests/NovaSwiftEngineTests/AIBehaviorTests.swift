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

    func testOutnumberedShipStillRetaliatesWhenPersonallyUnderFire() {
        // Same 3-to-1 setup as testWarshipDeclinesUnfavorableOdds, but one of
        // the hostiles is actively engaging the defender itself. MaxOdds gates
        // *picking* a fight it isn't already in — it must not also stop a ship
        // that's personally being shot at from defending itself (the "escort
        // never fights back" bug: an outnumbered/isolated ship under fire
        // should never just sit there and take it).
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(210, classes: [10], enemies: [11], maxOdds: 100),
            govt(211, classes: [11], enemies: [10]),
        ])
        let defender = warship("Defender", govt: 210, at: Vec2(0, -300), angle: 0)
        defender.brain = AIBrain(aiType: .warship, govt: 210)
        world.addNPC(defender)
        var raiders: [Ship] = []
        for i in 0..<3 {
            let raider = warship("Raider\(i)", govt: 211, at: Vec2(Double(i) * 40, 0))
            world.addNPC(raider)
            raiders.append(raider)
        }
        raiders[0].currentTargetID = defender.entityID   // actively engaging the defender itself

        world.step(1.0 / 30.0)
        XCTAssertEqual(defender.brain?.state, .attacking,
                       "personally engaged by a hostile, it must fight back despite being outnumbered")
    }

    func testTurretFiresRegardlessOfHullHeading() {
        // `World.fireAngle` already aims turret/beam-turret mounts straight at
        // the target regardless of hull facing — but the AI's own "should I
        // pull the trigger" gate used to require the hull be roughly pointed at
        // the target for every weapon alike, so a ship armed only with a turret
        // would never fire unless it happened to be nose-on to its target,
        // defeating the entire point of carrying one.
        let player = Ship(name: "Player", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 400))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(200, classes: [1], flags1: 0x0004)]) // always attacks player

        let npc = Ship(name: "Gunship", stats: ShipStats(maxSpeed: 400, acceleration: 300, turnRate: 3),
                      position: Vec2(), angle: .pi)   // facing directly AWAY from the player
        npc.government = 200; npc.radius = 20
        npc.maxShield = 80; npc.shield = 80; npc.maxArmor = 120; npc.armor = 120
        npc.weapons = [WeaponMount(spec: WeaponSpec(
            id: 130, name: "Turret", shieldDamage: 20, armorDamage: 20, reloadSeconds: 0.1,
            projectileSpeed: 2200, range: 5000, accuracyRadians: 0, isBeam: false, isGuided: false,
            turnRate: 0, blastRadius: 0, ammoPerShot: 0, guidance: .turret, isTurret: true))]
        npc.brain = AIBrain(aiType: .warship, govt: 200)
        world.addNPC(npc)

        world.step(1.0 / 30.0)
        XCTAssertEqual(npc.brain?.state, .attacking)
        XCTAssertTrue(world.events.contains {
            if case .weaponFired(let shooterID, _, _, _, _) = $0 { return shooterID == npc.entityID }
            return false
        }, "a turret should fire at a target regardless of hull heading")
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

    func testAuthorityInterceptsPlayerAfterARealHitOnANeutral() {
        // Complement to testAuthorityIgnoresPlayerMerelySelectingANeutral: once
        // the player has actually landed a shot on a non-enemy ship — not merely
        // selected it — the local system authority should step in, the same way
        // it would against an NPC pirate caught mid-attack.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 10, acceleration: 10, turnRate: 3),
                          position: Vec2())
        player.weapons = [WeaponMount(spec: gun())]
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50]), govt(600, classes: [60])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 3000), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        let cop = warship("Cop", govt: 500, at: Vec2(200, 150))
        cop.brain = AIBrain(aiType: .interceptor, govt: 500)
        world.addNPC(cop)
        let neutral = warship("Trader", govt: 600, at: Vec2(0, 150), armed: false)
        neutral.brain = AIBrain(aiType: .wimpyTrader, govt: 600)
        world.addNPC(neutral)

        // The player actually opens fire on the neutral (not a bare selection).
        player.currentTargetID = neutral.entityID
        world.intent.firePrimary = true

        var intervened = false
        for _ in 0..<150 {   // 5 seconds
            world.step(1.0 / 30.0)
            if cop.brain?.state == .attacking, cop.brain?.targetID == World.playerEntityID {
                intervened = true
                break
            }
        }
        XCTAssertTrue(intervened, "once the player actually fires on a neutral, the local authority should intervene")
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

    func testAuthorityIgnoresPlayerMerelySelectingANeutral() {
        // Regression: a police interceptor must NOT attack the player just because
        // the player *selected* (targeted) a neutral ship in the UI. The player's
        // `currentTargetID` reflects a bare selection, not combat, so piracy-police
        // intervention must not read it as aggression (it used to, and jumped an
        // idle, clean player — who then defended, killed the cop, and turned the
        // whole faction hostile).
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        player.maxShield = 100; player.shield = 100; player.maxArmor = 100; player.armor = 100
        let world = World(player: player)
        // 500 (system authority) and 600 (a neutral trader govt) are not enemies.
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50]), govt(600, classes: [60])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 3000), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        let cop = warship("Cop", govt: 500, at: Vec2(300, 0))
        cop.brain = AIBrain(aiType: .interceptor, govt: 500)
        world.addNPC(cop)
        let neutral = warship("Trader", govt: 600, at: Vec2(600, 0), armed: false)
        neutral.brain = AIBrain(aiType: .wimpyTrader, govt: 600)
        world.addNPC(neutral)

        // The player merely selects the neutral — no shots, clean record.
        _ = world.selectTarget(id: neutral.entityID)
        for _ in 0..<150 { world.step(1.0 / 30.0) }     // 5 seconds

        XCTAssertNotEqual(cop.brain?.targetID, World.playerEntityID,
                          "a police interceptor must not attack the player for merely selecting a neutral")
        XCTAssertNotEqual(cop.brain?.state, .attacking,
                          "the cop should stay on its beat, not open fire on an idle clean player")
    }

    func testEscortFollowsLeaderDownWhenItLands() {
        // A fleet escort should dive to land with its leader (fleets land together),
        // not peel off to fly the system solo the instant the leader vanishes.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(90_000, 90_000))
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 4000, spawnRadius: 3000, systemGovt: 500)

        let leader = warship("Leader", govt: 500, at: Vec2(0, 700), armed: false)
        let lbrain = AIBrain(aiType: .wimpyTrader, govt: 500)
        lbrain.state = .landing; lbrain.destSpob = 128      // leader on final approach
        leader.brain = lbrain
        world.addNPC(leader)

        let escort = warship("Escort", govt: 500, at: Vec2(90, 640), armed: false)
        let ebrain = AIBrain(aiType: .wimpyTrader, govt: 500)
        ebrain.leaderID = leader.entityID; ebrain.state = .escorting
        escort.brain = ebrain
        world.addNPC(escort)

        // One step is enough for the escort to notice its leader is landing.
        world.step(1.0 / 30.0)
        XCTAssertEqual(escort.brain?.state, .landing, "the escort should follow its leader down to land")
        XCTAssertEqual(escort.brain?.destSpob, 128, "the escort heads for the same pad as its leader")
    }

    func testEscortFollowsLeaderOutWhenItDeparts() {
        // An escort whose leader jumps out should leave with it, not go solo.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(90_000, 90_000))
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 4000, spawnRadius: 3000, systemGovt: 500)

        let leader = warship("Leader", govt: 500, at: Vec2(0, 0))
        let lbrain = AIBrain(aiType: .warship, govt: 500)
        lbrain.state = .departing
        leader.brain = lbrain
        world.addNPC(leader)

        let escort = warship("Escort", govt: 500, at: Vec2(90, -64))
        let ebrain = AIBrain(aiType: .warship, govt: 500)
        ebrain.leaderID = leader.entityID; ebrain.state = .escorting
        escort.brain = ebrain
        world.addNPC(escort)

        world.step(1.0 / 30.0)
        XCTAssertEqual(escort.brain?.state, .departing, "the escort should leave the system with its departing leader")
        XCTAssertTrue(escort.wantsToDepart, "the escort is flagged to jump out with its leader")
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

    func testPatrolSweepsVariedPointsNotACircle() {
        // A patrol beat should range over the whole system — checking in on planets
        // AND striking out into open space — rather than tracing the planet ring in
        // order (which read as "flying in circles"). Drive many repaths and confirm
        // the waypoints are varied and cover both near-body and deep-space legs.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(90_000, 90_000))          // far — no threat/scan
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 2000), radius: 90, canLand: true),
                     StellarBody(id: 129, position: Vec2(2000, 0), radius: 90, canLand: true),
                     StellarBody(id: 130, position: Vec2(0, -2000), radius: 90, canLand: false)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        let local = warship("Patrol", govt: 500, at: Vec2())
        local.brain = AIBrain(aiType: .warship, govt: 500)
        world.addNPC(local)

        // Snap the ship onto each chosen waypoint so the next step counts it as
        // "arrived" and repaths — this walks the patrol through many legs quickly.
        var waypoints: [Vec2] = []
        for _ in 0..<40 {
            world.step(1.0 / 30.0)
            guard local.brain?.state == .patrolling, let d = local.brain?.destination else { break }
            waypoints.append(d)
            local.position = d
        }

        XCTAssertGreaterThanOrEqual(waypoints.count, 20, "patrol should keep picking fresh legs")
        func minDistToBody(_ p: Vec2) -> Double {
            world.systemContext.bodies.map { ($0.position - p).length }.min() ?? .infinity
        }
        let nearBody = waypoints.filter { minDistToBody($0) < 400 }.count
        let deepSpace = waypoints.filter { minDistToBody($0) > 800 }.count
        XCTAssertGreaterThan(nearBody, 0, "a patrol should check in on planets")
        XCTAssertGreaterThan(deepSpace, 0, "a patrol should also sweep open space, not just hug the planet ring")
        let distinct = Set(waypoints.map { "\(Int($0.x / 50)),\(Int($0.y / 50))" })
        XCTAssertGreaterThanOrEqual(distinct.count, 6, "patrol waypoints should be varied, not one repeated point")
    }

    func testOutboundTraderLeavesInsteadOfLandingAgain() {
        // A trader that lifted off a spaceport outbound (`spawnOutbound`) should head
        // for the edge and jump out — the visible "leaving" half of planet traffic —
        // rather than immediately picking another planet to land on.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(90_000, 90_000))
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 4000, spawnRadius: 3000, systemGovt: 500)

        let trader = warship("Freighter", govt: 500, at: Vec2(0, 900), armed: false)
        let brain = AIBrain(aiType: .wimpyTrader, govt: 500)
        brain.spawnOutbound = true
        trader.brain = brain
        world.addNPC(trader)

        world.step(1.0 / 30.0)
        XCTAssertEqual(trader.brain?.state, .departing, "an outbound trader heads out, it doesn't re-land")
        XCTAssertTrue(trader.wantsToDepart, "an outbound trader is flagged to leave the system")
    }

    func testLocalAuthorityScansThePlayer() {
        // The "piracy police" that scan traffic are *interceptors* (Bible), holding
        // orbit and buzzing a passing ship. An armed authority interceptor with the
        // player close by and non-hostile flies a scan pass and emits a shipScanned
        // event aimed at the player.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 180))                 // within scan-complete range
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 1500), radius: 90, canLand: true)],
            center: Vec2(), jumpRadius: 6000, spawnRadius: 5000, systemGovt: 500)

        let patrol = warship("Patrol", govt: 500, at: Vec2())
        patrol.brain = AIBrain(aiType: .interceptor, govt: 500)
        world.addNPC(patrol)

        world.step(1.0 / 30.0)
        XCTAssertEqual(patrol.brain?.state, .scanning, "an authority interceptor breaks off its orbit to scan a passing ship")
        let scanned = world.events.contains {
            if case let .shipScanned(_, targetID, _) = $0 { return targetID == player.entityID }
            return false
        }
        XCTAssertTrue(scanned, "the scan pass should emit a shipScanned event targeting the player")
        XCTAssertTrue(world.playerScanned, "the player-scan latch should trip so no other ship re-scans this visit")
    }

    func testAuthorityWarshipJumpsOutAfterTourOfDuty() {
        // A local-authority warship with no enemies to fight doesn't police the
        // system forever: after its (randomized) tour of duty it heads for the
        // hyperspace edge and leaves — the turnover that keeps a system's traffic
        // coming and going instead of the same hulls looping in place.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(0, 300))
        let world = World(player: player)
        world.diplomacy = Diplomacy(govts: [govt(500, classes: [50])])   // player not hostile
        world.systemContext = SystemContext(
            bodies: [StellarBody(id: 128, position: Vec2(0, 900), radius: 80, canLand: true)],
            center: Vec2(), jumpRadius: 4000, spawnRadius: 3400, systemGovt: 500)

        let patrol = warship("Patrol", govt: 500, at: Vec2())
        patrol.brain = AIBrain(aiType: .warship, govt: 500)
        world.addNPC(patrol)

        // Step out past the longest possible tour (dutyRemaining ≤ 135s).
        var departed = false
        for _ in 0..<200 {           // 200s of sim time at dt=1s
            world.step(1.0)
            if patrol.wantsToDepart { departed = true; break }
        }
        XCTAssertTrue(departed, "an idle authority warship should eventually jump out")
    }

    func testToroidalWrapFoldsPositionAcrossTheEdge() {
        // Fly off one edge of the finite playfield and reappear on the opposite
        // side (EV Nova's system wrap). A ship past +wrapExtent folds to the far
        // negative side, keeping the system a fixed finite size with no wall.
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(6000, 0))                       // beyond the +x edge
        let world = World(player: player)
        world.systemContext = SystemContext(
            bodies: [], center: Vec2(), jumpRadius: 3000, spawnRadius: 2500,
            wrapExtent: 5000, systemGovt: independentGovt)

        world.step(1.0 / 30.0)
        // fold(6000) with ext 5000: ((6000+5000) mod 10000) − 5000 = −4000.
        XCTAssertEqual(player.position.x, -4000, accuracy: 1, "x should wrap to the opposite edge")
        XCTAssertEqual(player.position.y, 0, accuracy: 1, "the in-bounds axis is untouched")
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

    // MARK: pêrs Aggress/Coward tuning (SESSION_AUDIT_FOLLOWUPS.md §A)

    func testPersCowardLowersRetreatThresholdBelowDefault() {
        // Default warship-retreat threshold is a fixed 25% shields; a pêrs with
        // Coward=60 should flee at 50% shields, where the default would not.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [govt(230, classes: [30], flags1: 0x0010)]) // warshipsRetreat
        let npc = warship("Coward", govt: 230, at: Vec2())
        npc.shield = 40   // 50% of maxShield 80
        let brain = AIBrain(aiType: .warship, govt: 230)
        brain.personCoward = 60
        npc.brain = brain
        world.addNPC(npc)

        world.step(1.0 / 30.0)
        // With no hostile diplomacy configured, a ship that starts fleeing
        // immediately finds no pursuer and proceeds straight to `.departing`
        // (heading for the jump edge) within the same tick — both states
        // indicate the Coward-triggered retreat fired.
        let retreated = npc.brain?.state == .fleeing || npc.brain?.state == .departing
        XCTAssertTrue(retreated, "Coward=60 should retreat at 50% shields, got \(String(describing: npc.brain?.state))")
    }

    func testDefaultRetreatThresholdIgnoresHigherShields() {
        // Same 50% shield fraction, but no personCoward override — the fixed
        // 25% default shouldn't trigger a retreat.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [govt(231, classes: [31], flags1: 0x0010)]) // warshipsRetreat
        let npc = warship("Steady", govt: 231, at: Vec2())
        npc.shield = 40   // 50% of maxShield 80
        npc.brain = AIBrain(aiType: .warship, govt: 231)
        world.addNPC(npc)

        world.step(1.0 / 30.0)
        XCTAssertNotEqual(npc.brain?.state, .fleeing, "50% shields is above the default 25% retreat threshold")
    }

    func testPersAggressionTunesAttackStandoffDistance() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        // Directly north (angle 0, matching this engine's heading convention)
        // so aim error stays near zero and only standoff distance is at play.
        let target = warship("Target", govt: 999, at: Vec2(0, 2_100))
        world.addNPC(target)

        let close = warship("Close", govt: 998, at: Vec2())
        let closeBrain = AIBrain(aiType: .warship, govt: 998)
        closeBrain.personAggression = 1
        closeBrain.state = .attacking
        closeBrain.targetID = target.entityID
        close.brain = closeBrain
        world.addNPC(close)

        let far = warship("Far", govt: 998, at: Vec2())
        let farBrain = AIBrain(aiType: .warship, govt: 998)
        farBrain.personAggression = 3
        farBrain.state = .attacking
        farBrain.targetID = target.entityID
        far.brain = farBrain
        world.addNPC(far)

        // Target sits 2100 out (the 5000-range gun): a close-standoff brain
        // (0.4× range = 2000) treats it as still beyond standoff and thrusts
        // to close in; a far-standoff brain (1.0× range = 5000) treats it as
        // already well inside standoff and eases off the throttle.
        let closeIntent = closeBrain.think(ship: close, world: world, dt: 1.0 / 30.0)
        let farIntent = farBrain.think(ship: far, world: world, dt: 1.0 / 30.0)
        XCTAssertTrue(closeIntent.thrust, "Aggress=1 (close) should still be closing at 2100/5000 range")
        XCTAssertFalse(farIntent.thrust, "Aggress=3 (far) should already consider 2100/5000 range close enough")
    }

    // MARK: carrier-launched fighters escort their (possibly NPC) carrier

    func testCarrierLaunchedFighterHonorsAggressiveEscortOrderNotForcedDefensive() {
        // Regression: the leaderID dispatch used to force `.defensive` on any
        // escort whose leader wasn't the player, silently discarding whatever
        // `escortOrder` was actually set — which neutered `World.launchFighter`
        // setting `.aggressive` on carrier-launched fighters. A wimpy-trader
        // disposition would flee a hostile entirely on its own — proving that
        // if it instead attacks, its `.aggressive` escort order (not its own
        // disposition) is what's driving it, even though its "carrier" here
        // isn't the player and isn't currently targeting anything itself.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                                       position: Vec2(9_000, 9_000)))
        world.diplomacy = Diplomacy(govts: [
            govt(300, classes: [30], enemies: [31]),
            govt(301, classes: [31], enemies: [30]),
        ])
        let carrier = warship("Carrier", govt: 300, at: Vec2())
        world.addNPC(carrier)   // no brain, no currentTargetID — an idle "leader"

        let fighter = warship("Fighter", govt: 300, at: Vec2())
        let brain = AIBrain(aiType: .wimpyTrader, govt: 300)   // would flee on its own disposition
        brain.leaderID = carrier.entityID
        brain.escortOrder = .aggressive
        fighter.brain = brain
        world.addNPC(fighter)

        let hostile = warship("Hostile", govt: 301, at: Vec2(0, 300))
        world.addNPC(hostile)

        world.step(1.0 / 30.0)
        XCTAssertEqual(fighter.brain?.state, .attacking,
                       "an aggressive escort engages even though its wimpy-trader disposition would otherwise flee, "
                       + "and even though its leader is an NPC with no target of its own")
    }

    /// The core of the escort/AI-flight rework: a heavy, sluggish hull that starts
    /// well out of position must decelerate onto its formation slot and *hold* it,
    /// not sail through and wheel around it forever (the "circles its slot" bug).
    func testHeavyEscortSettlesIntoFormationWithoutOrbiting() {
        // Leader = player, sitting still at the origin (angle 0).
        let player = Ship(name: "Lead", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let world = World(player: player)
        // A heavy escort: low acceleration and a slow turn rate — the profile that
        // used to overshoot and orbit. It starts 600 units off to the side.
        let escort = Ship(name: "Heavy", stats: ShipStats(maxSpeed: 300, acceleration: 60, turnRate: 0.8),
                          position: Vec2(600, 0))
        escort.radius = 20
        world.addNPC(escort)
        world.recruitEscort(escort)     // leaderID = player, defensive, slot 0

        // Fly for 25 seconds — ample time to close 600 units and settle.
        for _ in 0..<750 { world.step(1.0 / 30.0) }

        // Slot 0 sits ~96 units from a leader facing "up"; it must be parked near
        // there and nearly stopped relative to the (stationary) leader.
        let slotDist = (escort.position - player.position).length
        XCTAssertLessThan(slotDist, 200,
                          "a heavy escort should hold a formation slot near its leader, not orbit at range (was \(slotDist))")
        XCTAssertLessThan(escort.velocity.length, 40,
                          "a settled escort should be nearly stopped, not circling at speed (was \(escort.velocity.length))")
        XCTAssertEqual(escort.brain?.state, .escorting, "it should still be holding formation")
    }

    /// Formation must hold on the move too: an escort starting behind a leader that
    /// cruises flat-out should reel in and then keep station, matching its velocity —
    /// not trail off the back forever.
    func testEscortKeepsUpWithACruisingLeader() {
        let player = Ship(name: "Lead", stats: ShipStats(maxSpeed: 250, acceleration: 200, turnRate: 3))
        let world = World(player: player)
        let escort = Ship(name: "Wing", stats: ShipStats(maxSpeed: 250, acceleration: 120, turnRate: 1.5),
                          position: Vec2(-100, -400))
        escort.radius = 20
        world.addNPC(escort)
        world.recruitEscort(escort)
        // Player holds full thrust "up" for the whole run (intent persists on world).
        world.intent.thrust = true

        for _ in 0..<900 { world.step(1.0 / 30.0) }     // 30 seconds

        let gap = (escort.position - player.position).length
        XCTAssertLessThan(gap, 280,
                          "escort should keep station with a cruising leader, not trail off (gap \(gap))")
        let relSpeed = (escort.velocity - player.velocity).length
        XCTAssertLessThan(relSpeed, 70,
                          "escort should roughly match the leader's velocity in formation (rel \(relSpeed))")
    }

    /// Anti-jitter: once settled behind a leader cruising in a straight line, an
    /// escort should hold its heading, not twitch its nose every frame chasing a
    /// near-zero error (the "constantly turns to make minor adjustments" report).
    func testSettledEscortHoldsHeadingWithoutConstantTurning() {
        let player = Ship(name: "Lead", stats: ShipStats(maxSpeed: 200, acceleration: 200, turnRate: 3))
        let world = World(player: player)
        let escort = Ship(name: "Wing", stats: ShipStats(maxSpeed: 200, acceleration: 150, turnRate: 2),
                          position: Vec2(80, -70))     // already near its slot
        escort.radius = 20
        world.addNPC(escort)
        world.recruitEscort(escort)
        world.intent.thrust = true                     // leader cruises straight, no turning

        for _ in 0..<600 { world.step(1.0 / 30.0) }    // let it settle

        // Measure total nose rotation over the next second of holding station.
        func shortestDelta(_ a: Double, _ b: Double) -> Double {
            var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d -= 2 * .pi }; if d < -.pi { d += 2 * .pi }
            return d
        }
        var totalTurn = 0.0
        var prev = escort.angle
        for _ in 0..<30 {
            world.step(1.0 / 30.0)
            totalTurn += abs(shortestDelta(prev, escort.angle))
            prev = escort.angle
        }
        XCTAssertLessThan(totalTurn, 0.2,
                          "a settled escort should hold heading, not constantly correct (total turn \(totalTurn) rad over 1s)")
    }
}
