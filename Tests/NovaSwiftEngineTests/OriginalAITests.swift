import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// The original NPC AI (`OriginalAI`, Batch 6): its state transitions over
/// scripted encounters, and the constants and tables it is built from.
final class OriginalAITests: XCTestCase {

    // MARK: Fixtures

    private func govtData(classes: [Int], allies: [Int] = [], enemies: [Int] = [], flags1: UInt16 = 0,
                          flags2: UInt16 = 0, maxOdds: Int = 100, crimeTol: Int = 0, smuggle: Int = 0) -> Data {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, i < allies.count ? allies[i] : -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        putW(2, Int(flags1))
        putW(4, Int(flags2))
        putW(8, crimeTol)
        putW(10, smuggle)
        putW(22, maxOdds)
        return Data(d)
    }

    private func govt(_ id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [], flags1: UInt16 = 0,
                      flags2: UInt16 = 0, maxOdds: Int = 100, smuggle: Int = 0) -> GovtRes {
        GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)",
                         data: govtData(classes: classes, allies: allies, enemies: enemies, flags1: flags1,
                                        flags2: flags2, maxOdds: maxOdds, smuggle: smuggle)))
    }

    private func gun(range: Double = 600, disablesOnly: Bool = false) -> WeaponSpec {
        var flags = WeaponBehaviorFlags()
        flags.disablesOnly = disablesOnly
        return WeaponSpec(id: 128, name: "Gun", shieldDamage: 10, armorDamage: 10, reloadSeconds: 0.5,
                          projectileSpeed: 1500, range: range, accuracyRadians: 0, isBeam: false,
                          isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0, flags: flags)
    }

    private func npc(_ name: String, govt: Int, at pos: Vec2, ai: AIType, armed: Bool = true,
                     strength: Double = 10) -> Ship {
        let s = Ship(name: name, stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30), position: pos)
        s.government = govt
        s.radius = 20
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.maxFuel = 300; s.fuel = 300
        s.combatStrength = strength
        s.massTons = 50
        s.crew = 5
        if armed { s.weapons = [WeaponMount(spec: gun())] }
        s.brain = AIBrain(aiType: ai, govt: govt)
        return s
    }

    /// Traders (128) and pirates (129) at war; a planet at (300, 300).
    private func world(govts: [GovtRes]? = nil, bodies: [StellarBody]? = nil) -> World {
        let player = Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30),
                          position: Vec2(9000, 9000))
        player.maxArmor = 100; player.armor = 100; player.maxShield = 100; player.shield = 100
        let w = World(player: player)
        w.diplomacy = Diplomacy(govts: govts ?? [
            govt(128, classes: [1], enemies: [2]),
            govt(129, classes: [2], enemies: [1]),
        ])
        w.systemContext = SystemContext(bodies: bodies ?? [
            StellarBody(id: 400, position: Vec2(300, 300), radius: 40, canLand: true, government: 128),
        ])
        return w
    }

    private func rec(_ w: World, _ s: Ship) -> OriginalAIShipState {
        w.originalAI.record(for: s.entityID)!
    }

    private func run(_ w: World, _ steps: Int, until done: () -> Bool = { false }) {
        for _ in 0..<steps {
            w.step(1.0 / 30.0)
            if done() { return }
        }
    }

    // MARK: Selection

    func testOriginalAIDrivesBrainedNPCs() {
        let w = world()
        let trader = npc("T", govt: 128, at: Vec2(0, 0), ai: .wimpyTrader)
        w.addNPC(trader)
        run(w, 1)
        XCTAssertNotNil(w.originalAI.record(for: trader.entityID), "the original AI drives brained NPCs")
    }

    // MARK: Traders (AI-19)

    func testWimpyTraderIgnoresAPassingEnemyUntilItIsShot() {
        let w = world()
        let trader = npc("Trader", govt: 128, at: Vec2(-600, -600), ai: .wimpyTrader)
        let pirate = npc("Pirate", govt: 129, at: Vec2(-500, -600), ai: .braveTrader)
        w.addNPC(trader)
        w.addNPC(pirate)
        run(w, 30)
        XCTAssertNotEqual(rec(w, trader).state, OriginalAIState.retreat, "proximity alone never escalates a trader")
        XCTAssertNil(rec(w, trader).primary)

        w.applyHit(to: trader, shield: 10, armor: 0, ownerID: pirate.entityID)
        XCTAssertEqual(rec(w, trader).primary, pirate.entityID)
        run(w, 1)
        XCTAssertEqual(rec(w, trader).state, OriginalAIState.retreat, "once shot, a wimpy trader runs")
    }

    func testBraveTraderFightsBackOnlyInsideThe1251PixelBox() {
        for (gap, expected) in [(1000.0, OriginalAIState.attack), (1300.0, OriginalAIState.retreat)] {
            let w = world()
            let trader = npc("Brave", govt: 128, at: Vec2(-600, 0), ai: .braveTrader)
            let pirate = npc("Pirate", govt: 129, at: Vec2(-600 + gap, 0), ai: .braveTrader)
            w.addNPC(trader)
            w.addNPC(pirate)
            run(w, 2)
            w.applyHit(to: trader, shield: 10, armor: 0, ownerID: pirate.entityID)
            run(w, 1)
            XCTAssertEqual(rec(w, trader).state, expected, "attacker \(gap) px away")
        }
    }

    // MARK: Retreat thresholds (AI-20)

    func testRecordReadsTheSpawnTimeCadenceSeed() {
        // The Spawner seeds the cadence (`Rand(3) XOR 2` for a dude, 2 for a
        // class escort, përs Aggress clamped); the AI reads it, it doesn't draw.
        let w = world()
        let ai = OriginalAI()
        let host = WorldAIHost(world: w, ai: ai)
        for (i, seed) in [0, 2, 3].enumerated() {
            let s = npc("W\(i)", govt: 128, at: Vec2(), ai: .warship)
            s.entityID = 1000 + i
            s.brain?.cadence = seed
            XCTAssertEqual(ai.ensureRecord(s, host: host).cadence, seed)
        }
        for (i, aggress) in [(0, 1), (1, 1), (2, 2), (3, 4), (7, 4)].enumerated() {
            let s = npc("P\(i)", govt: 128, at: Vec2(), ai: .warship)
            s.entityID = 2000 + i
            s.brain?.personAggression = aggress.0
            XCTAssertEqual(ai.ensureRecord(s, host: host).cadence, aggress.1, "përs Aggress \(aggress.0)")
        }
    }

    func testWarshipOfARetreatingGovernmentRunsAtItsCadenceThreshold() {
        let w = world(govts: [govt(128, classes: [1], enemies: [2], flags1: 0x0010),
                              govt(129, classes: [2], enemies: [1])])
        let ship = npc("Warship", govt: 128, at: Vec2(-500, 0), ai: .warship)
        let enemy = npc("Enemy", govt: 129, at: Vec2(-300, 0), ai: .braveTrader, armed: false, strength: 1)
        w.addNPC(ship)
        w.addNPC(enemy)
        run(w, 2)
        let r = rec(w, ship)
        r.cadence = 2
        XCTAssertEqual(r.state, OriginalAIState.attack)
        ship.shield = 16
        run(w, 1)
        XCTAssertEqual(r.state, OriginalAIState.attack, "above 15 % it fights on")
        ship.shield = 14
        run(w, 1)
        XCTAssertEqual(r.state, OriginalAIState.retreat, "below 15 % of max shields it retreats")
    }

    // MARK: Disabled targets (AI-04 via the supervisors)

    func testArmedWarshipKeepsShootingADisabledShipButADisablerGivesUp() {
        for disabler in [false, true] {
            let w = world()
            let ship = npc("Warship", govt: 128, at: Vec2(-500, 0), ai: .warship)
            ship.weapons = [WeaponMount(spec: gun(disablesOnly: disabler))]
            let victim = npc("Victim", govt: 129, at: Vec2(-400, 0), ai: .braveTrader, armed: false, strength: 1)
            w.addNPC(ship)
            w.addNPC(victim)
            run(w, 2)
            XCTAssertEqual(rec(w, ship).primary, victim.entityID)
            victim.armor = 10   // below the disable line
            XCTAssertTrue(victim.disabled)
            run(w, 2)
            if disabler {
                XCTAssertNil(rec(w, ship).primary, "only disabling weapons: it lets the hulk be")
            } else {
                XCTAssertEqual(rec(w, ship).primary, victim.entityID, "a lethal weapon finishes the hulk")
                XCTAssertEqual(rec(w, ship).state, OriginalAIState.attack)
            }
        }
    }

    // MARK: Arrival and departure (AI-22)

    func testJumpInRadiusUsesTheExeBrakeConstant() {
        // AI-12: 1000 + Σ(50 − 1.165k) with the exe's double 1.165, not 1.16.
        XCTAssertEqual(OriginalSpawnRules.jumpInRadius, 2098.004, accuracy: 0.05)
    }

    func testJumpInSlidesAt50PixelsPerTickAndHandsBackAtTopSpeed() {
        let w = world()
        // Placed as the Spawner places a jump-in (AI-12 owns the pose; the AI
        // keeps it).
        let start0 = Vec2(OriginalSpawnRules.jumpInRadius, 0)
        let ship = npc("Arrival", govt: 128, at: start0, ai: .wimpyTrader)
        ship.angle = (Vec2() - start0).angle
        w.addNPC(ship, arrival: .hyperspace)
        run(w, 1)
        let r = rec(w, ship)
        XCTAssertEqual(ship.position.length, OriginalSpawnRules.jumpInRadius, accuracy: 60)
        XCTAssertEqual(r.state, OriginalAIState.arrival)
        XCTAssertEqual(ship.velocity.length / 30, 50, accuracy: 1.5, "a jump-in tears in at 50 px/tick")
        let start = ship.position
        var ticks = 0
        run(w, 200) {
            ticks += 1
            return r.state != OriginalAIState.arrival
        }
        let topSpeedTick = ship.effectiveMaxSpeed / 30
        // The override runs once per raw call: the ship moves |desired| × 0.63
        // and desired eases by 1.165 with no frame scale, so the slide is
        // 0.63 × Σ (50 − 1.165k), about 700 px, not the 1098 px the
        // spawner's own sum assumes.
        var expected = 0.0
        var v = 50.0
        while v > topSpeedTick { expected += v * OriginalClock.rawCallTickScale; v -= 1.165 }
        XCTAssertEqual((ship.position - start).length, expected, accuracy: 60)
        XCTAssertEqual(ship.position.length, 1400, accuracy: 60, "it comes to rest about 1400 px from the centre")
        XCTAssertLessThan(ship.velocity.length / 30, topSpeedTick + 1.165 + 0.01,
                          "it keeps the last raw call's speed, at most one step above top speed")
    }

    /// Regression: a heavy freighter (Leviathan: speed 100, accel 50, turn 10)
    /// jumping into a system with no stellars sat 40 s in departure, because
    /// the arrival slide eased per tick instead of per raw call, ended at the
    /// 1000 px core and drifted inside it. It now brakes outside the core and
    /// spins up in place.
    func testHeavyFreighterArrivingInAnEmptySystemBrakesThenSpinsUpOutsideTheCore() {
        let w = world(bodies: [])
        let start0 = Vec2(0, -OriginalSpawnRules.jumpInRadius)
        let ship = Ship(name: "Leviathan", stats: ShipStats(speed: 100, acceleration: 50, turnRate: 10),
                        position: start0)
        ship.government = 128
        ship.radius = 60
        ship.maxShield = 450; ship.shield = 450; ship.maxArmor = 150; ship.armor = 150
        ship.maxFuel = 800; ship.fuel = 800
        ship.massTons = 10000
        ship.crew = 20
        ship.brain = AIBrain(aiType: .wimpyTrader, govt: 128)
        ship.angle = (Vec2() - start0).angle
        w.addNPC(ship, arrival: .hyperspace)
        var departedAt: Int?
        var enteredCore = false
        for i in 0..<(40 * 30) {
            w.step(1.0 / 30.0)
            if let r = w.originalAI.record(for: ship.entityID), r.mode == OriginalAIMode.departCentre {
                enteredCore = true
            }
            if w.events.contains(where: { if case .shipDeparted(ship.entityID, _, _) = $0 { return true }; return false }) {
                departedAt = i
                break
            }
        }
        XCTAssertFalse(enteredCore, "it never has to thrust out of the 1000 px core")
        XCTAssertNotNil(departedAt, "it leaves")
        XCTAssertLessThan(departedAt ?? .max, 25 * 30, "arrival, brake, spin-up: well under 25 s")
    }

    func testDepartingShipStopsTurnsOutwardAndJumpsAfterTheSpinUp() {
        let w = world()
        let ship = npc("Leaver", govt: 128, at: Vec2(1500, 0), ai: .wimpyTrader)
        ship.velocity = Vec2(0, 150)
        w.addNPC(ship)
        run(w, 1)
        let r = rec(w, ship)
        r.enterDeparture(clock60: w.originalAI.clock60)
        var sawBrake = false, sawSpinUp = false
        var departedAt: Int?
        for i in 0..<600 {
            w.step(1.0 / 30.0)
            if r.mode == OriginalAIMode.brake { sawBrake = true }
            if r.mode == OriginalAIMode.jumpSpinUp { sawSpinUp = true }
            if w.events.contains(where: { if case .shipDeparted(ship.entityID, _, _) = $0 { return true }; return false }) {
                departedAt = i
                break
            }
        }
        XCTAssertTrue(sawBrake, "it brakes first")
        XCTAssertTrue(sawSpinUp, "then spins up pointing away from the centre")
        let at = try? XCTUnwrap(departedAt)
        XCTAssertNotNil(at)
        // The cue (350 ticks at 60 Hz) over the 1.3 multiplier ≈ 4.5 s, plus braking.
        XCTAssertGreaterThan(at ?? 0, 120)
        XCTAssertFalse(w.npcs.contains { $0 === ship }, "it vanishes in place, nowhere near the old edge")
    }

    // MARK: Idle loop (AI-23)

    func testIdleTraderVisitsAStellarStopsCoastsAndJumpsOut() {
        let w = world()
        let trader = npc("Trader", govt: 128, at: Vec2(-200, -200), ai: .wimpyTrader)
        w.addNPC(trader)
        run(w, 1)
        let r = rec(w, trader)
        XCTAssertEqual(r.state, OriginalAIState.travel)
        XCTAssertEqual(r.secondary, .stellar(400))
        run(w, 900) { r.state == OriginalAIState.idle && r.maneuverTimer > 0 }
        XCTAssertEqual(r.jumpDestination, 400, "it stopped at the stellar")
        XCTAssertTrue((300...499).contains(Int(r.maneuverTimer.rounded(.up))), "and coasts 300–499 ticks")
        XCTAssertLessThan((trader.position - Vec2(300, 300)).length, 140)
        XCTAssertLessThan(trader.velocity.length, 1)
        run(w, 520) { r.state == OriginalAIState.departJump }
        XCTAssertEqual(r.state, OriginalAIState.departJump, "then it jumps out; NPCs never land")
    }

    func testTravelPickerSkipsUninhabitedHostileAndFarStellars() {
        let w = world(bodies: [
            StellarBody(id: 400, position: Vec2(300, 300), radius: 40, canLand: false, government: 128),
            StellarBody(id: 401, position: Vec2(-300, 300), radius: 40, canLand: true, government: 129),
            StellarBody(id: 402, position: Vec2(1200, 0), radius: 40, canLand: true, government: 128),
            StellarBody(id: 403, position: Vec2(-5000, 5000), radius: 40, canLand: true, government: 128),
        ])
        let trader = npc("Trader", govt: 128, at: Vec2(), ai: .wimpyTrader)
        w.addNPC(trader)
        let host = WorldAIHost(world: w, ai: w.originalAI)
        for _ in 0..<20 {
            // 400 uninhabited, 401 hostile, 402 at x ≥ 1000; 403 passes the
            // literal x < 1000 && y < 1000 test (map y is −5000).
            XCTAssertEqual(w.originalAI.selectTravelStellar(trader, host: host, strict: false, plainOnly: false), 403)
        }
    }

    // MARK: Interceptors (AI-24)

    func testInterceptorScansNPCsAsWellAsThePlayer() {
        var scanned = Set<Int>()
        for seed in 0..<12 {
            let w = world()
            w.rng = NovaRandom(seed: UInt32(seed * 7919 + 1))
            w.player.position = Vec2(200, 0)
            let cop = npc("Cop", govt: 128, at: Vec2(), ai: .interceptor)
            let trader = npc("Trader", govt: 128, at: Vec2(-200, 0), ai: .wimpyTrader)
            w.addNPC(cop)
            w.addNPC(trader)
            run(w, 1)
            if rec(w, cop).state == OriginalAIState.scanApproach, let p = rec(w, cop).primary { scanned.insert(p) }
        }
        XCTAssertTrue(scanned.contains(World.playerEntityID))
        XCTAssertTrue(scanned.contains { $0 != World.playerEntityID }, "the player is just one candidate")
    }

    // MARK: Combat modes (AI-25)

    func testStandoffHullHoldsAt85PercentOfItsLongestReach() {
        let w = world()
        let ship = npc("Carrier", govt: 128, at: Vec2(0, 0), ai: .warship)
        ship.hullFlags2 = 0x0002
        let enemy = npc("Enemy", govt: 129, at: Vec2(0, 480), ai: .braveTrader, armed: false, strength: 1)
        w.addNPC(ship)
        w.addNPC(enemy)
        run(w, 1)
        let r = rec(w, ship)
        XCTAssertEqual(r.state, OriginalAIState.attack)
        // Range 600 × 0.85 = 510: at 480 px it brakes and holds.
        enemy.position = Vec2(0, 480); ship.position = Vec2()
        run(w, 1)
        XCTAssertEqual(r.mode, OriginalAIMode.combatBrake)
        enemy.position = Vec2(0, 540); ship.position = Vec2()
        run(w, 1)
        XCTAssertEqual(r.mode, OriginalAIMode.strafe)
    }

    // MARK: Escorts (AI-35, AI-36, AI-37, AI-40)

    func testPlayerEscortsDefaultToFormationAndHoldTheirForwardGuns() {
        let w = world()
        w.player.position = Vec2(0, 0)
        let escort = npc("Escort", govt: 128, at: Vec2(100, 0), ai: .warship)
        escort.brain?.leaderID = World.playerEntityID
        let pirate = npc("Pirate", govt: 129, at: Vec2(300, 0), ai: .braveTrader)
        w.addNPC(escort)
        w.addNPC(pirate)
        run(w, 3)
        let r = rec(w, escort)
        XCTAssertEqual(r.behavior, 6)
        XCTAssertEqual(r.escortCommand, OriginalEscortCommand.formation)
        XCTAssertEqual(r.state, OriginalAIState.escortStation)
        XCTAssertFalse(w.events.contains { if case .weaponFired(escort.entityID, _, _, _, _) = $0 { return true }; return false },
                       "a formation escort without turrets never fires")
        w.setPlayerEscortOrder(.defensive)
        XCTAssertEqual(r.playerOrder, OriginalEscortCommand.defend)
    }

    func testEscortGroupOrdersReachOnlyTheirEscortType() {
        let w = world()
        w.player.position = Vec2(0, 0)
        let light = npc("Light", govt: 128, at: Vec2(100, 0), ai: .warship)
        light.massTons = 20                       // EscortType 0: fighter class
        let heavy = npc("Heavy", govt: 128, at: Vec2(-100, 0), ai: .warship)
        heavy.massTons = 500                      // EscortType 2: warship
        for e in [light, heavy] { e.brain?.leaderID = World.playerEntityID; w.addNPC(e) }
        run(w, 2)
        w.originalAI.commandPlayerEscortGroup(category: 0, command: OriginalEscortCommand.hold, world: w)
        XCTAssertEqual(rec(w, light).playerOrder, OriginalEscortCommand.hold)
        XCTAssertEqual(rec(w, heavy).playerOrder, OriginalEscortCommand.formation, "other groups keep their order")
        w.originalAI.commandPlayerEscortGroup(category: nil, command: OriginalEscortCommand.returnToHangar, world: w)
        XCTAssertEqual(rec(w, light).playerOrder, OriginalEscortCommand.formation,
                       "Return to Hangar sends a non-carried escort back to formation")
        XCTAssertEqual(rec(w, heavy).playerOrder, OriginalEscortCommand.formation)
        run(w, 2)
        XCTAssertEqual(rec(w, light).escortCommand, OriginalEscortCommand.formation)
    }

    func testNPCFleetEscortOrderTable() {
        let w = world()
        let leader = npc("Leader", govt: 128, at: Vec2(), ai: .warship)
        w.addNPC(leader)
        run(w, 1)
        let r = rec(w, leader)
        let host = WorldAIHost(world: w, ai: w.originalAI)
        r.state = OriginalAIState.attack
        leader.shield = 20
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [1, 1, 1, 0], "below a third")
        leader.shield = 50
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [1, 2, 1, 0], "below two thirds")
        leader.shield = 100
        r.odds = 0.25
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [2, 2, 2, 0], "full shields, good odds")
        r.odds = 0.9
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [2, 2, 0, 0])
        r.state = OriginalAIState.travel
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [3, 3, 3, 3], "outside combat: return")
        r.behavior = 1
        r.state = OriginalAIState.attack
        leader.shield = 50
        XCTAssertEqual(w.originalAI.escortOrders(r, ship: leader, host: host), [1, 1, 1, 0], "a trader leader")
    }

    func testHeaviestSiblingTakesOverWhenTheLeaderIsLost() {
        let w = world()
        let leader = npc("Leader", govt: 128, at: Vec2(), ai: .warship)
        let light = npc("Light", govt: 128, at: Vec2(50, 0), ai: .warship)
        let heavy = npc("Heavy", govt: 128, at: Vec2(-50, 0), ai: .warship)
        heavy.massTons = 300
        w.addNPC(leader)
        w.addNPC(light)
        w.addNPC(heavy)
        light.brain?.leaderID = leader.entityID
        heavy.brain?.leaderID = leader.entityID
        run(w, 1)
        leader.armor = 0
        run(w, 2)
        XCTAssertNil(heavy.brain?.leaderID, "the heaviest sibling leads now")
        XCTAssertEqual(light.brain?.leaderID, heavy.entityID, "and the rest follow it")
    }

    func testFormationWedgeSlots() {
        XCTAssertEqual(OriginalAI.wedgeSlot(2, spacing: 30, evenCount: true).lateral, -30)
        XCTAssertEqual(OriginalAI.wedgeSlot(3, spacing: 30, evenCount: true).forward, -30)
        XCTAssertEqual(OriginalAI.wedgeSlot(4, spacing: 30, evenCount: true).lateral, 0)
        XCTAssertEqual(OriginalAI.wedgeSlot(4, spacing: 30, evenCount: false).lateral, -60)
        XCTAssertEqual(OriginalAI.wedgeSlot(21, spacing: 30, evenCount: true).forward, -150)
        XCTAssertEqual(OriginalAI.wedgeSlot(22, spacing: 30, evenCount: true).forward, 0, "beyond the table: on the leader")
    }

    // MARK: Dispatcher cadence (AI-18)

    func testUpdatePeriodFollowsTheFrameScale() {
        XCTAssertEqual(OriginalAI.updatePeriod(averageScale: 0.63), 1)
        XCTAssertEqual(OriginalAI.updatePeriod(averageScale: 1.0), 1)
        XCTAssertEqual(OriginalAI.updatePeriod(averageScale: 1.2), 2)
        XCTAssertEqual(OriginalAI.updatePeriod(averageScale: 1.5), 4)
        XCTAssertEqual(OriginalAI.updatePeriod(averageScale: 2.0), 8)
        XCTAssertFalse(OriginalAI.throttles(state: 4, mode: 6, frame: 3, instance: 2, period: 1))
        XCTAssertTrue(OriginalAI.throttles(state: 4, mode: 6, frame: 3, instance: 2, period: 2))
        XCTAssertFalse(OriginalAI.throttles(state: 0, mode: 6, frame: 3, instance: 2, period: 2), "idle never skips")
    }

    func testDisengagedStateReturnsToIdleAboutOnceInAHundredTicks() {
        // No stellars and no fuel: the trader parks instead of leaving.
        let w = world(bodies: [])
        let ship = npc("Ship", govt: 128, at: Vec2(-500, -500), ai: .wimpyTrader)
        ship.fuel = 0
        w.addNPC(ship)
        run(w, 1)
        let r = rec(w, ship)
        XCTAssertEqual(r.state, OriginalAIState.park)
        var dwell: [Int] = []
        for _ in 0..<40 {
            r.state = OriginalAIState.disengaged
            var n = 0
            while r.state == OriginalAIState.disengaged && n < 2000 {
                w.step(1.0 / 30.0)
                n += 1
            }
            dwell.append(n)
        }
        let mean = Double(dwell.reduce(0, +)) / Double(dwell.count)
        XCTAssertTrue((50...200).contains(mean), "mean dwell \(mean) ticks")
    }

    // MARK: Comms (AI-34 / AI-42 rules)

    func testBribeCostIsFlooredToThousandsAndClamped() {
        var rng = NovaRandom(seed: 7 as UInt32)
        for credits in [0, 5_000, 1_000_000, 50_000_000] {
            for _ in 0..<20 {
                let p = OriginalComms.personality(&rng)
                XCTAssertTrue((0.3...1.7).contains(p))
                let cost = OriginalComms.bribeCost(credits: credits, govtFlags: 0, personality: p, rng: &rng)
                XCTAssertTrue((1000...20_000).contains(cost))
                XCTAssertEqual(cost % 1000, 0)
            }
        }
        XCTAssertTrue(OriginalComms.offersBribe(govtFlags: nil, behavior: 3, isDefenseFleet: false))
        XCTAssertTrue(OriginalComms.offersBribe(govtFlags: 0x0200, behavior: 3, isDefenseFleet: false))
        XCTAssertFalse(OriginalComms.offersBribe(govtFlags: 0x0200, behavior: 2, isDefenseFleet: false))
        XCTAssertTrue(OriginalComms.offersBribe(govtFlags: 0x2000, behavior: 1, isDefenseFleet: false))
        XCTAssertFalse(OriginalComms.offersBribe(govtFlags: nil, behavior: 3, isDefenseFleet: true))
    }

    func testAssistanceRepairsADisabledPlayer() {
        let w = world()
        w.player.position = Vec2(0, 0)
        w.player.armor = 10   // disabled
        XCTAssertTrue(w.player.disabled)
        let helper = npc("Helper", govt: 128, at: Vec2(200, 0), ai: .wimpyTrader)
        w.addNPC(helper)
        run(w, 1)
        XCTAssertEqual(w.originalAI.assistanceReply(from: helper, world: w), .helps(repair: true, againstThreat: false))
        w.originalAI.beginAssistance(by: helper, world: w)
        run(w, 900) { !w.player.disabled }
        XCTAssertFalse(w.player.disabled, "the helper closes in and repairs the player above the line")
    }

    /// Regression: a plunder-government warship that disabled the player
    /// closed in and held at 3 px forever — the player has no AI record, so
    /// the victim's boarded latch never set. It now boards (AI-29).
    func testPlundererBoardsADisabledPlayer() {
        let w = world(govts: [govt(128, classes: [1], enemies: [2]),
                              govt(129, classes: [2], enemies: [1], flags1: 0x1000)])
        w.player.position = Vec2(0, 0)
        w.player.crew = 2
        w.player.armor = 5            // disabled
        XCTAssertTrue(w.player.disabled)
        let pirate = npc("Pirate", govt: 129, at: Vec2(300, 0), ai: .warship)
        pirate.crew = 30
        w.addNPC(pirate)
        var boarded = false
        run(w, 60 * 30) {
            boarded = w.events.contains { if case .playerBoarded = $0 { return true }; return false }
            return boarded
        }
        XCTAssertTrue(boarded, "the pirate boards the disabled player")
    }

    // MARK: Comm window (AI-42 / AI-43 / AI-44)

    func testHailRulesFollowTheOriginalHailCommand() {
        let w = world(govts: [govt(128, classes: [1], enemies: [2]),
                              govt(129, classes: [2], enemies: [1]),
                              govt(130, classes: [3], flags1: 0x0400)])
        let trader = npc("T", govt: 128, at: Vec2(300, 0), ai: .wimpyTrader)
        let mute = npc("M", govt: 130, at: Vec2(-300, 0), ai: .wimpyTrader)
        w.addNPC(trader); w.addNPC(mute)
        run(w, 1)
        XCTAssertEqual(w.originalAI.hailCheck(trader, world: w), .open)
        XCTAssertEqual(w.originalAI.hailCheck(mute, world: w), .message(index: 53),
                       "a Flags-0x0400 government gives no response")
        mute.personID = 1200
        XCTAssertEqual(w.originalAI.hailCheck(mute, world: w), .message(index: 53),
                       "a përs aboard does not lift the 0x0400 block")
        rec(w, trader).jumpTimer = 5
        XCTAssertEqual(w.originalAI.hailCheck(trader, world: w), .message(index: 54),
                       "a ship spinning up is entering hyperspace")
        rec(w, trader).jumpTimer = 0
        trader.armor = 1
        XCTAssertTrue(trader.disabled)
        XCTAssertEqual(w.originalAI.hailCheck(trader, world: w), .message(index: 53),
                       "a disabled ship cannot be hailed")
        w.player.cloakLevel = 1
        XCTAssertEqual(w.originalAI.hailCheck(mute, world: w), .beep)
    }

    func testGreedyGovernmentRollsTheBribeTwice() {
        var plain = NovaRandom(seed: 99 as UInt32)
        var greedy = NovaRandom(seed: 99 as UInt32)
        _ = OriginalComms.bribeCost(credits: 2_000_000, govtFlags: 0, personality: 1, rng: &plain)
        let cost = OriginalComms.bribeCost(credits: 2_000_000, govtFlags: 0x8000, personality: 1, rng: &greedy)
        XCTAssertNotEqual(plain.seed, greedy.seed, "Flags 0x8000 draws the ordinary price first, then its own")
        _ = plain.range(200)
        XCTAssertEqual(plain.seed, greedy.seed, "exactly one extra draw")
        XCTAssertTrue((10_000...20_000).contains(cost))
    }

    func testAssistanceAnswersUseTheirOwnLines() {
        let w = world()
        w.player.position = Vec2(0, 0)
        let helper = npc("Helper", govt: 128, at: Vec2(200, 0), ai: .wimpyTrader)
        w.addNPC(helper)
        run(w, 1)
        let r = rec(w, helper)
        r.state = OriginalAIState.idle
        var session = w.originalAI.openComm(with: helper, world: w, playerCredits: 50_000)
        XCTAssertEqual(session.openingPrompt, OriginalComms.Prompt.channelOpen)
        XCTAssertEqual(w.originalAI.pressAssistance(session, ship: helper, world: w),
                       .reply(prompt: OriginalComms.Prompt.notInTrouble), "full fuel, not disabled")
        XCTAssertEqual(w.originalAI.pressGreetings(session, ship: helper, world: w), .greeting)
        r.state = OriginalAIState.park
        XCTAssertEqual(w.originalAI.pressAssistance(session, ship: helper, world: w),
                       .reply(prompt: OriginalComms.Prompt.busy), "a trader not idling is busy")
        r.state = OriginalAIState.idle
        w.player.maxFuel = 300; w.player.fuel = 50
        guard case let .offer(_, price, free, effect) = w.originalAI.pressAssistance(session, ship: helper, world: w) else {
            return XCTFail("low on fuel: the trader names its price")
        }
        XCTAssertEqual(effect, .assist)
        XCTAssertFalse(free)
        XCTAssertEqual(price, session.price)
        XCTAssertEqual(w.originalAI.settle(&session, effect: .assist, paid: true, ship: helper, world: w),
                       OriginalComms.Prompt.onMyWay)
        XCTAssertEqual(r.state, OriginalAIState.refuel)
        XCTAssertEqual(OriginalComms.promptEntry(0x26, variant: 2).list, 3001)
        XCTAssertEqual(OriginalComms.promptEntry(0x26, variant: 2).index, 3)
        XCTAssertEqual(OriginalComms.promptEntry(0x13, variant: 0).index, 96)
    }

    func testMissionAttackerAndRevengePersNeverTakeABribe() {
        let w = world()
        w.player.position = Vec2(0, 0)
        let pirate = npc("Pirate", govt: 129, at: Vec2(150, 0), ai: .warship)
        w.addNPC(pirate)
        run(w, 1)
        let r = rec(w, pirate)
        r.primary = World.playerEntityID
        r.state = OriginalAIState.attack
        w.originalAI.pressingCache.removeAll()
        let session = w.originalAI.openComm(with: pirate, world: w, playerCredits: 100_000)
        XCTAssertTrue(w.originalAI.keepsPressingPlayer(pirate, world: w))
        XCTAssertEqual(session.openingPrompt, OriginalComms.Prompt.whatDoYouWant)
        XCTAssertEqual(w.originalAI.pressGreetings(session, ship: pirate, world: w),
                       .reply(prompt: OriginalComms.Prompt.stopWastingTime))
        pirate.missionID = 200
        pirate.brain?.behaviorOverride = .attackPlayer
        XCTAssertEqual(w.originalAI.pressAssistance(session, ship: pirate, world: w),
                       .reply(prompt: OriginalComms.Prompt.refused), "a ShipBehav-0 mission ship never bargains")
        pirate.missionID = nil
        pirate.brain?.behaviorOverride = .standard
        pirate.personID = OriginalAI.revengePersID
        XCTAssertEqual(w.originalAI.pressAssistance(session, ship: pirate, world: w),
                       .reply(prompt: OriginalComms.Prompt.refused), "the revenge përs is never bribable")
    }

    // MARK: Batch 3 wiring (AI-02, AI-07)

    func testFireRequestArmsOneForwardBankThroughTheSelectors() {
        let w = world()
        let ship = npc("Gunner", govt: 129, at: Vec2(0, 0), ai: .warship)
        let heavy = WeaponSpec(id: 129, name: "Heavy", shieldDamage: 30, armorDamage: 10, reloadSeconds: 0.5,
                               projectileSpeed: 1500, range: 600, accuracyRadians: 0, isBeam: false,
                               isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0,
                               flags: WeaponBehaviorFlags())
        ship.weapons = [WeaponMount(spec: gun()), WeaponMount(spec: heavy)]
        let target = npc("Mark", govt: 128, at: Vec2(0, 200), ai: .wimpyTrader)
        w.addNPC(ship); w.addNPC(target)
        ship.currentTargetID = target.entityID
        let host = WorldAIHost(world: w, ai: w.originalAI)
        var intent = ControlIntent()
        let bank = host.steerFire(ship, [.direct, .guided], intent: &intent)
        XCTAssertEqual(bank, 1, "direct fire picks the most energy damage while shields are up")
        XCTAssertEqual(intent.npcMounts, [1], "one forward bank, not every mount")
        XCTAssertTrue(intent.firePrimary)
        var turretOnly = ControlIntent()
        XCTAssertNil(host.steerFire(ship, [.turret], intent: &turretOnly))
        XCTAssertFalse(turretOnly.firePrimary, "no turret aboard: a turret request fires nothing")
    }

    func testGrudgeNeedsPersFlag0x0001() {
        let w = world()
        let host = WorldAIHost(world: w, ai: w.originalAI)
        let flagged = npc("Flagged", govt: 128, at: Vec2(), ai: .warship)
        flagged.personID = 600; flagged.personFlags = 0x0001
        let plain = npc("Plain", govt: 128, at: Vec2(), ai: .warship)
        plain.personID = 601
        w.addNPC(flagged); w.addNPC(plain)
        w.applyHit(to: flagged, shield: 1, armor: 0, ownerID: World.playerEntityID)
        w.applyHit(to: plain, shield: 1, armor: 0, ownerID: World.playerEntityID)
        XCTAssertTrue(host.holdsGrudge(flagged), "any player hit latches a Flags-0x0001 përs")
        XCTAssertFalse(host.holdsGrudge(plain))
    }

    // MARK: NPC-vs-NPC combat (regression guard for quiet headless runs)

    /// Two warships of governments at war, 500 px apart with the player far
    /// off, must find each other and trade fire within five seconds: the
    /// acquisition → attack → control-mode fire request → AI-02 bank →
    /// `World.fireWeapons` (`npcMounts`) chain with no player involvement.
    func testEnemyWarshipsTradeFireWithinFiveSeconds() {
        for ai in [AIType.warship, .interceptor] {
            let w = world()
            let a = npc("Fed", govt: 128, at: Vec2(-250, 0), ai: ai)
            let b = npc("Pirate", govt: 129, at: Vec2(250, 0), ai: ai)
            w.addNPC(a); w.addNPC(b)
            var shooters = Set<Int>()
            run(w, 150) {
                for e in w.events {
                    if case let .weaponFired(shooter, _, _, _, _) = e { shooters.insert(shooter) }
                }
                return shooters.isSuperset(of: [a.entityID, b.entityID])
            }
            XCTAssertEqual(rec(w, a).primary, b.entityID, "\(ai): acquires the enemy")
            XCTAssertTrue(shooters.contains(a.entityID), "\(ai): govt 128 fires on its enemy")
            XCTAssertTrue(shooters.contains(b.entityID), "\(ai): govt 129 fires on its enemy")
        }
    }
}
