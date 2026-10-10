import XCTest
import NovaSwiftKit
@testable import NovaSwiftEngine

/// Batch 1a of docs/reverse-engineering/FIDELITY_PLAN.md: the flight layer
/// against the original. Golden values marked "oracle" come from running the
/// original's functions under the Unicorn harness (`~/Projects/evnova-re/oracle`),
/// in px/tick; the engine flies px/s, so they're scaled by 30 here.
final class OriginalFlightTests: XCTestCase {

    private let tick = 1.0 / 30.0

    private func ship(speed: Double, accel: Double, turn: Double = .pi) -> Ship {
        Ship(name: "T", stats: ShipStats(maxSpeed: speed, acceleration: accel, turnRate: turn))
    }

    // MARK: FL-22 RNG

    func testNovaRandomMatchesTheOriginalGenerator() {
        // Oracle: NovaRandom_Range 0x004683b0.
        var r = NovaRandom(seed: 1 as UInt32)
        XCTAssertEqual((0..<10).map { _ in r.range(100) }, [25, 23, 67, 4, 71, 85, 55, 3, 18, 1])
        XCTAssertEqual(r.seed, 2_007_237_709)
        r = NovaRandom(seed: 12345 as UInt32)
        XCTAssertEqual((0..<8).map { _ in r.range(32767) },
                       [30486, 11007, 10335, 21947, 10961, 8331, 10285, 32036])
        r = NovaRandom(seed: 0xDEAD_BEEF as UInt32)
        XCTAssertEqual((0..<8).map { _ in r.range(360) }, [246, 109, 96, 79, 215, 223, 174, 12],
                       "a seed above 2³¹ steps exactly as the exe's division-free form")
        r = NovaRandom(seed: 7 as UInt32)
        XCTAssertEqual((0..<6).map { _ in r.range(400) }, [318, 244, 290, 133, 7, 392])
        r = NovaRandom(seed: 42 as UInt32)
        XCTAssertEqual((0..<4).map { _ in r.range(-100) }, [65458, 65468, 65500, 65436],
                       "a negative bound returns the logical shift, as the exe does")
        let before = r.seed
        XCTAssertEqual(r.range(0), 0, "the reseed path's stand-in")
        XCTAssertEqual(r.seed, before)
    }

    // MARK: FL-01 cadence

    func testRawCallCadenceMatchesTheOriginalLoopRate() {
        var cadence = RawCallCadence()
        let perTick = (0..<30).map { _ in cadence.advance(1.0 / 30.0) }
        XCTAssertEqual(perTick.reduce(0, +), 47, "1 s at the 21 ms floor holds 47.6 raw calls")
        XCTAssertTrue(perTick.allSatisfy { $0 == 1 || $0 == 2 })
        let longRun = (0..<3000).map { _ in cadence.advance(1.0 / 30.0) }.reduce(0, +) + 47
        XCTAssertEqual(Double(longRun) / 101, OriginalClock.rawCallsPerSecond, accuracy: 0.02)
    }

    // MARK: FL-02 / FL-03 constants and Strict Play

    func testShuttleFliesAtTheOriginalSpeedAndThrust() {
        // Shuttle: Speed 300, Accel 300 → 3 px/tick (90 px/s) and 0.06 px/tick²
        // (54 px/s²); 0 → top in 50 ticks (1.67 s).
        let stats = ShipStats(speed: 300, acceleration: 300, turnRate: 30)
        XCTAssertEqual(stats.maxSpeed, 90, accuracy: 1e-9)
        XCTAssertEqual(stats.acceleration, 54, accuracy: 1e-9)

        let strict = World(player: Ship(name: "S", stats: stats))
        strict.strictPlay = true
        strict.intent.thrust = true
        for _ in 0..<50 { strict.step(tick) }
        XCTAssertEqual(strict.player.velocity.length, 90, accuracy: 1e-6)
        for _ in 0..<30 { strict.step(tick) }
        XCTAssertEqual(strict.player.velocity.length, 90, accuracy: 1e-6, "strict top speed")

        let relaxed = World(player: Ship(name: "N", stats: stats))
        relaxed.intent.thrust = true
        for _ in 0..<120 { relaxed.step(tick) }
        XCTAssertEqual(relaxed.player.velocity.length, 135, accuracy: 1e-6, "non-strict ×1.5 (0x005757b8)")
        XCTAssertEqual(relaxed.effectiveMaxSpeed(of: relaxed.player), 135, accuracy: 1e-9,
                       "the hyperspace arrival speed carries the bonus")
    }

    func testStrictPlayBonusCoversDirectEscortsOnly() {
        let world = World(player: ship(speed: 90, accel: 54))
        let escort = ship(speed: 100, accel: 54)
        let eb = AIBrain(aiType: .interceptor, govt: 128); eb.leaderID = World.playerEntityID
        escort.brain = eb
        let stranger = ship(speed: 100, accel: 54)
        stranger.brain = AIBrain(aiType: .warship, govt: 128)
        world.addNPC(escort)
        world.addNPC(stranger)
        world.step(tick)
        XCTAssertEqual(escort.effectiveMaxSpeed, 150, accuracy: 1e-9)
        XCTAssertEqual(stranger.effectiveMaxSpeed, 100, accuracy: 1e-9)
        world.strictPlay = true
        world.step(tick)
        XCTAssertEqual(escort.effectiveMaxSpeed, 100, accuracy: 1e-9)
    }

    func testThrustSequenceMatchesThePlayerTick() {
        // Oracle, full player tick 0x0044aa70, strict, accel 0.03 / speed 3.0
        // (class floats), heading 30°: each axis grows by its share of 0.06
        // px/tick² until it passes its share of top speed, one step over (FL-18).
        // The original applies a tick's speed caps a tick late, so its first
        // thrusting tick is clamped to 0; this engine's tick n is its tick n + 1.
        let world = World(player: ship(speed: 90, accel: 54))
        world.strictPlay = true
        world.player.angle = 30 * .pi / 180
        world.intent.thrust = true
        for _ in 0..<4 { world.step(tick) }
        XCTAssertEqual(world.player.velocity.x / 30, 0.12, accuracy: 1e-5)
        XCTAssertEqual(world.player.velocity.y / 30, 0.207846, accuracy: 1e-5)
        XCTAssertEqual(world.player.position.x, 0.30, accuracy: 1e-5)
        XCTAssertEqual(world.player.position.y, 0.519615, accuracy: 1e-5)
        for _ in 4..<59 { world.step(tick) }
        XCTAssertEqual(world.player.velocity.x / 30, 1.53, accuracy: 1e-4,
                       "x passes its 1.5 share by one step and is held there")
        XCTAssertEqual(world.player.position.x, 52.019970, accuracy: 1e-3)
        // y lands exactly on its 2.598 share after 50 steps; the original's float32
        // sum sits a hair below it and takes one more step (2.650). Either way the
        // net speed ends at or above top speed.
        XCTAssertGreaterThanOrEqual(world.player.velocity.y / 30, 2.598)
        XCTAssertLessThanOrEqual(world.player.velocity.y / 30, 2.650037 + 1e-4)
        XCTAssertGreaterThan(world.player.velocity.length / 30, 3.0, "a diagonal heading settles above top speed")
        XCTAssertEqual(world.player.position.y, 90.101303, accuracy: 0.5)
    }

    // MARK: FL-08 afterburner

    func testAfterburnerIsItsOwnThrusterWithDecayingCaps() {
        // Oracle (0x00451630 tail, scale 0.63 per call): afterburner alone, from
        // rest, heading up, strict, top 3 px/tick, thrust 0.06: +0.165 px/tick per
        // call up to the 1.8 × 3 = 5.4 bound, then a 5.35–5.51 wobble; burn
        // ModVal 30 × 0.0333 per tick. Released, the caps fall 0.024 per call and
        // the speed rides them down: 4.27 px/tick 48 calls later.
        let p = ship(speed: 90, accel: 54)
        p.maxFuel = 300; p.fuel = 100
        p.afterburner = Afterburner(fuelPerSecond: 30 * 0.0333 * 30)
        let world = World(player: p)
        world.strictPlay = true
        world.intent.afterburner = true
        for _ in 0..<30 { world.step(tick) }
        XCTAssertTrue(p.afterburnerActive)
        XCTAssertEqual(p.velocity.x, 0, accuracy: 1e-9, "no thrust key, still accelerates")
        XCTAssertGreaterThanOrEqual(p.velocity.y / 30, 5.30)
        XCTAssertLessThanOrEqual(p.velocity.y / 30, 5.52)
        XCTAssertEqual(p.fuel, 100 - 30 * 0.999, accuracy: 1e-6)

        world.intent.afterburner = false
        world.step(tick)
        XCTAssertGreaterThan(p.velocity.y / 30, 5.2, "release doesn't snap back to top speed")
        for _ in 1..<30 { world.step(tick) }
        XCTAssertEqual(p.velocity.y / 30, 4.27, accuracy: 0.04, "the caps decay thrust × 0.4 per call")
        for _ in 0..<60 { world.step(tick) }
        XCTAssertEqual(p.velocity.y / 30, 3.0, accuracy: 1e-6, "…down to top speed")
    }

    func testAfterburnerBurnsTheLastOwnedOutfitsRateAndNeedsATicksFuel() {
        let p = ship(speed: 90, accel: 54)
        p.maxFuel = 300; p.fuel = 0.5
        p.afterburner = Afterburner(fuelPerSecond: 30)   // 1 fuel per tick
        let world = World(player: p)
        world.intent.afterburner = true
        world.step(tick)
        XCTAssertFalse(p.afterburnerActive, "fuel for less than one tick's burn doesn't light it")
    }

    func testNPCsNeverAfterburn() {
        let world = World(player: ship(speed: 90, accel: 54))
        let npc = ship(speed: 90, accel: 54)
        npc.maxFuel = 300; npc.fuel = 300
        npc.afterburner = Afterburner(fuelPerSecond: 30)
        npc.entityID = 7
        var intent = ControlIntent(); intent.afterburner = true
        npc.step(tick, intent: intent, tuning: world.tuning)
        XCTAssertFalse(npc.afterburnerActive, "the burn rate is 0 for every ship but the player")
    }

    // MARK: FL-09 reverse

    func testReverseTurnsToRetrogradeWithoutChangingSpeed() {
        let world = World(player: ship(speed: 90, accel: 54, turn: 7 * .pi / 6))   // 7°/tick
        world.player.velocity = Vec2(0, 60)
        world.player.angle = 0
        world.intent.reverse = true
        for _ in 0..<40 { world.step(tick) }
        // Turned to within one step of retrograde, where the auto-turn stops.
        XCTAssertLessThanOrEqual(abs(angleDelta(from: world.player.angle, to: .pi)) * 180 / .pi, 7 + 1e-9,
                                 "faces its velocity's reverse")
        XCTAssertEqual(world.player.velocity.length, 60, accuracy: 1e-9, "no thrust, no damping")
    }

    func testReverseBelowTheGateLeavesFaceTargetInCharge() {
        let world = World(player: ship(speed: 90, accel: 54))
        world.player.velocity = Vec2(0, 1)                   // 0.033 px/tick < 0.05
        world.intent.reverse = true
        world.intent.desiredHeading = .pi / 2
        world.step(tick)
        XCTAssertEqual(world.player.angle * 180 / .pi, 6, accuracy: 1e-9)
    }

    // MARK: FL-10 turn truncation

    func testPlayerTurnStepTruncatesToWholeDegrees() {
        // Oracle (player_turn_rate.py through the real 0x00463e70 + player tick).
        func step(_ maneuver: Int, bonus: Int = 0) -> Int {
            ShipStats(speed: 300, acceleration: 300, turnRate: maneuver, turnBonus: bonus).playerTurnDegPerTick
        }
        for m in 1...19 { XCTAssertEqual(step(m), 1, "Maneuver \(m)") }
        for m in 20...29 { XCTAssertEqual(step(m), 2, "Maneuver \(m)") }
        for m in 30...39 { XCTAssertEqual(step(m), 3) }
        for m in 40...49 { XCTAssertEqual(step(m), 4) }
        for m in 50...59 { XCTAssertEqual(step(m), 5) }
        XCTAssertEqual(step(60), 6)
        XCTAssertEqual(step(75), 7)
        XCTAssertEqual(step(99), 9)
        XCTAssertEqual(step(150), 15)
        XCTAssertEqual(step(20, bonus: 50), 2, "a ModType-9 +0.5° on Maneuver 20 is truncated away")
        XCTAssertEqual(step(20, bonus: 100), 3)
        XCTAssertEqual(step(25, bonus: 2 * 25), 3, "2.5 + 0.5 = 3.0")
        XCTAssertEqual(step(5, bonus: -100), 1, "floored back to 1")
        XCTAssertEqual(step(5, bonus: -1000), 1)

        let world = World(player: Ship(name: "M", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 25)))
        world.intent.turnRight = true
        world.step(tick)
        XCTAssertEqual(world.player.angle * 180 / .pi, 2, accuracy: 1e-9, "Maneuver 25 turns 2°/tick")
    }

    func testNPCsTurnUnrounded() {
        let stats = ShipStats(speed: 300, acceleration: 300, turnRate: 25)
        XCTAssertEqual(stats.turnRate * 180 / .pi / 30, 2.5, accuracy: 1e-12)
        XCTAssertEqual(ShipStats(speed: 300, acceleration: 300, turnRate: 5).turnRate * 180 / .pi / 30, 0.5,
                       accuracy: 1e-12, "an NPC hull below Maneuver 10 isn't floored")
    }

    // MARK: FL-11 inertialess

    func testInertialessVelocitySteersByFourTimesThrustPerAxis() {
        let p = ship(speed: 90, accel: 54)
        p.inertialess = true
        let world = World(player: p)
        world.strictPlay = true
        world.intent.thrust = true
        for _ in 0..<60 { world.step(tick) }
        XCTAssertEqual(p.velocity.y, 90, accuracy: 1e-6)
        world.intent = ControlIntent()
        p.angle = .pi / 2
        world.step(tick)
        // Each axis moves toward heading × speed by at most 4 × 0.06 px/tick.
        XCTAssertEqual(p.velocity.x, 4 * 54 * tick, accuracy: 1e-9)
        XCTAssertEqual(p.velocity.y, 90 - 4 * 54 * tick, accuracy: 1e-9)
    }

    // MARK: FL-15 velocity match

    func testVelocityMatchedNPCFliesAtAThird() {
        let npc = ship(speed: 90, accel: 54)
        npc.entityID = 9
        npc.velocityMatchTargetID = 3
        XCTAssertEqual(npc.effectiveMaxSpeed, 90 * 0.333, accuracy: 1e-9)
        XCTAssertEqual(npc.effectiveAcceleration, 54 * 0.333 / 2, accuracy: 1e-9,
                       "×0.333 instead of ×2.0: a sixth of normal thrust")
    }

    // MARK: FL-17 disabled drift

    func testDisabledHulkDampsPerRawCall() {
        let world = World(player: ship(speed: 90, accel: 54))
        let hulk = ship(speed: 90, accel: 54)
        hulk.velocity = Vec2(100, 0)
        hulk.disabled = true
        world.addNPC(hulk)
        for _ in 0..<30 { world.step(tick) }
        XCTAssertEqual(hulk.velocity.x, 100 * pow(0.995, 47), accuracy: 1e-9,
                       "× 0.995 per 21 ms call: 78.8 % a second")
    }

    // MARK: FL-19 crash immunity

    func testOnlyThePlayersStellarResistOutfitSurvivesADeadlyStellar() {
        let world = World(player: ship(speed: 90, accel: 54))
        world.player.position = Vec2(0, 5)
        world.player.radius = 10
        world.player.hasStellarResistOutfit = true
        world.systemContext = SystemContext(bodies: [StellarBody(id: 1, position: Vec2(), radius: 40,
                                                                 canLand: false, isDeadly: true)])
        let npc = ship(speed: 90, accel: 54)
        npc.position = Vec2(5, 0); npc.radius = 10
        npc.hasStellarResistOutfit = true
        let flagged = ship(speed: 90, accel: 54)
        flagged.position = Vec2(-5, 0); flagged.radius = 10
        flagged.hullShieldsStellars = true
        world.addNPC(npc)
        world.addNPC(flagged)
        world.step(tick)
        XCTAssertTrue(world.player.isAlive, "ModType 42 shields the player")
        XCTAssertFalse(npc.isAlive, "…but not an NPC")
        XCTAssertTrue(flagged.isAlive, "shïp Flags3 0x0020 shields any hull")
    }

    // MARK: FL-16 / OS-11 asteroid field

    private func asteroidGame(yield: Int = 0, fragCount: Int = 0) -> NovaGame {
        var col = ResourceCollection()
        var roid = [UInt8](repeating: 0, count: 24)
        func put(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            roid[off] = UInt8(u >> 8); roid[off + 1] = UInt8(u & 0xff)
        }
        put(0, 10)          // strength
        put(2, 100)         // spin rate
        put(4, 2)           // yield type
        put(6, yield)       // yield qty
        put(14, 128)        // frag types
        put(16, -1)
        put(18, fragCount)
        col.add(Resource(type: NovaType.roid, id: 128, name: "Rock", data: Data(roid)))
        return NovaGame(col)
    }

    private func asteroidWorld(count: Int, yield: Int = 0, fragCount: Int = 0) -> World {
        let world = World(player: ship(speed: 90, accel: 54))
        world.galaxy = Galaxy(game: asteroidGame(yield: yield, fragCount: fragCount))
        world.populateAsteroids(typeIDs: [128], count: count)
        return world
    }

    func testAsteroidFieldIsAPoolOfSixteenAroundThePlayer() {
        let world = asteroidWorld(count: 40)
        world.player.position = Vec2(7000, -3000)
        world.step(tick)
        XCTAssertEqual(world.asteroids.count, 16, "min(count, 16) rocks")
        for rock in world.asteroids {
            let d = rock.position - world.player.position
            XCTAssertLessThanOrEqual(abs(d.x), (320 + 128) / 2 + 3)
            XCTAssertLessThanOrEqual(abs(d.y), (300 + 128) / 2 + 3)
            XCTAssertLessThanOrEqual(abs(rock.velocity.x), 60)
            XCTAssertLessThanOrEqual(abs(rock.velocity.y), 60)
        }
        XCTAssertTrue(world.asteroids.contains { $0.velocity.length > 0 }, "rocks drift")
        XCTAssertTrue(world.asteroids.contains { $0.angularVelocityDegPerSec < 0 }
                      && world.asteroids.contains { $0.angularVelocityDegPerSec > 0 }, "either spin direction")

        // Fly far away: the field drops behind and refills around the player.
        world.player.position = Vec2(-40000, 20000)
        for _ in 0..<30 { world.step(tick) }
        XCTAssertEqual(world.asteroids.count, 16)
        for rock in world.asteroids {
            XCTAssertLessThan((rock.position - world.player.position).length, 1000,
                              "the field travels with the player")
        }
    }

    func testDestroyedRockLeavesResourceBoxesForTheScoop() {
        let world = asteroidWorld(count: 1, yield: 3)
        world.step(tick)
        let rock = try! XCTUnwrap(world.asteroids.first)
        world.applyAsteroidHit(rock, shield: 100, armor: 100, shooterID: 0)
        XCTAssertFalse(world.events.contains { if case .asteroidMined = $0 { return true } else { return false } },
                       "nothing is credited on the kill")
        let boxes = world.freeflightObjects.count
        XCTAssertGreaterThanOrEqual(boxes, 1, "trunc((50…150) × 3 × 0.01) boxes")
        XCTAssertLessThanOrEqual(boxes, 4)

        // No scoop: flying through collects nothing.
        world.player.radius = 2000
        world.step(tick)
        XCTAssertEqual(world.freeflightObjects.count, boxes)

        world.player.hasMiningScoop = true
        world.step(tick)
        let mined = world.events.compactMap { e -> Int? in
            if case let .asteroidMined(type, quantity, _) = e { XCTAssertEqual(type, 2); return quantity }
            return nil
        }
        XCTAssertEqual(mined, Array(repeating: 1, count: boxes), "one ton per box")
        XCTAssertTrue(world.freeflightObjects.isEmpty)
    }

    /// UI-13: jettisoned pods (spïn 500) drift behind the ship for 180–269
    /// ticks and carry nothing, so a scoop passes through them.
    func testJettisonedPodsAreScenery() {
        let world = asteroidWorld(count: 0)
        world.spawnJettisonedPods(from: world.player, count: 3)
        XCTAssertEqual(world.freeflightObjects.count, 3)
        XCTAssertTrue(world.freeflightObjects.allSatisfy { $0.spriteSet == 0 && $0.cargoType < 0 })
        XCTAssertTrue(world.freeflightObjects.allSatisfy { $0.lifeRemaining * 30 >= 180 && $0.lifeRemaining * 30 < 270 })
        world.player.hasMiningScoop = true
        world.player.radius = 2000
        world.step(tick)
        XCTAssertEqual(world.freeflightObjects.count, 3)
        XCTAssertFalse(world.events.contains { if case .asteroidMined = $0 { return true } else { return false } })
    }

    func testAFullHoldLeavesBoxesFlying() {
        let world = asteroidWorld(count: 1, yield: 3)
        world.step(tick)
        world.applyAsteroidHit(world.asteroids[0], shield: 100, armor: 100, shooterID: 0)
        world.player.hasMiningScoop = true
        world.player.radius = 2000
        world.playerHoldHasRoom = { false }
        let boxes = world.freeflightObjects.count
        world.step(tick)
        XCTAssertEqual(world.freeflightObjects.count, boxes)
    }

    func testFragCountOfOneYieldsNoFragments() {
        let world = asteroidWorld(count: 1, fragCount: 1)
        world.step(tick)
        world.applyAsteroidHit(world.asteroids[0], shield: 100, armor: 100, shooterID: 0)
        world.step(tick)
        XCTAssertTrue(world.asteroids.allSatisfy { $0.isAlive })
        XCTAssertLessThanOrEqual(world.asteroids.count, 1,
                                 "range(1) + 1/2 = 0 fragments; only the field's refill may reappear")
    }

    // MARK: Real data

    private func stockGame() throws -> NovaGame {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = GameLibrary.discoverResourceFiles(in: repo.appendingPathComponent("data/base"))
        guard !files.isEmpty else { throw XCTSkip("No stock data under data/base") }
        return NovaGame(try GameLibrary.merge(baseFiles: files))
    }

    func testStockHullsFlyAtTheOriginalScales() throws {
        let game = try stockGame()
        let galaxy = Galaxy(game: game)
        let hull = try XCTUnwrap(game.ships().first)
        let ship = try XCTUnwrap(galaxy.makeLoadedShip(hull.id, includeDefaultItems: false, includeHullWeapons: false))
        XCTAssertEqual(ship.stats.maxSpeed, Double(hull.speed) * 0.30, accuracy: 1e-9)
        XCTAssertEqual(ship.stats.acceleration, Double(hull.acceleration) * 0.18, accuracy: 1e-9)
        XCTAssertEqual(ship.stats.playerTurnDegPerTick, max(1, hull.turnRate / 10))

        // A turret's ModType-9 penalty is in hundredths of a degree: −2 on a
        // stock hull doesn't move its whole-degree step.
        let turret = try XCTUnwrap(game.outfits().first { o in
            o.modifiers.contains { $0.type == .turnRate && $0.value < 0 && $0.value > -10 }
        })
        let fitted = try XCTUnwrap(galaxy.makeLoadedShip(hull.id, extraOutfits: [turret.id: 1],
                                                         includeDefaultItems: false, includeHullWeapons: false))
        if hull.turnRate % 10 != 0 {
            XCTAssertEqual(fitted.stats.playerTurnDegPerTick, ship.stats.playerTurnDegPerTick)
        }
    }

    func testStockAsteroidSystemKeepsTheSixteenRockPool() throws {
        let game = try stockGame()
        guard let sys = game.systems().first(where: { $0.asteroidCount > 0 && !$0.asteroidTypeIDs.isEmpty }) else {
            throw XCTSkip("No asteroid system in the stock data")
        }
        let galaxy = Galaxy(game: game)
        let world = World(player: ship(speed: 90, accel: 54))
        world.galaxy = galaxy
        world.populateAsteroids(typeIDs: sys.asteroidTypeIDs, count: sys.asteroidCount)
        for _ in 0..<90 { world.step(tick) }
        XCTAssertEqual(world.asteroids.count, min(sys.asteroidCount, 16))
        XCTAssertTrue(world.asteroids.allSatisfy { sys.asteroidTypeIDs.contains($0.roidTypeID) })
    }
}
