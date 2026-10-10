import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Batch 1b of docs/reverse-engineering/FIDELITY_PLAN.md: the player's hyperjump,
/// travel days, jump outfits and fuel regeneration against the original. Values
/// marked "oracle" come from running the original's functions under the Unicorn
/// harness (`~/Projects/evnova-re/oracle`).
final class OriginalHyperjumpTests: XCTestCase {

    private let tick = 1.0 / 30.0

    // MARK: Fixtures

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    private func hull(_ id: Int, mass: Int = 50, fuelRegen: Int = 0, flags: Int = 0, flags2: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100); put16(&b, 4, 300); put16(&b, 6, 300); put16(&b, 8, 30)
        put16(&b, 10, 300); put16(&b, 14, 100)
        put16(&b, 62, mass); put16(&b, 74, flags); put16(&b, 94, fuelRegen); put16(&b, 98, flags2)
        return Resource(type: NovaType.ship, id: id, name: "Hull \(id)", data: Data(b))
    }

    private func outfit(_ id: Int, _ modType: Int, _ modVal: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 40)
        put16(&b, 6, modType); put16(&b, 8, modVal)
        return Resource(type: NovaType.outfit, id: id, name: "Outfit \(id)", data: Data(b))
    }

    private func galaxy(_ resources: [Resource]) -> Galaxy {
        var col = ResourceCollection()
        for r in resources { col.add(r) }
        return Galaxy(game: NovaGame(col))
    }

    private func player(speed: Double = 300, accel: Double = 300, turn: Double = 30) -> Ship {
        Ship(name: "P", stats: ShipStats(speed: Int(speed), acceleration: Int(accel), turnRate: Int(turn)))
    }

    // MARK: FL-05 travel days

    func testTravelDaysMatchTheOracleTable() {
        // Oracle: Stellar_ComputeHyperspaceTravelDays 0x00465550, read back as the
        // caller's signed short.
        let g = galaxy([hull(128, mass: 50), hull(129, mass: 100), hull(130, mass: 199), hull(131, mass: 200),
                        hull(132, mass: 250),
                        outfit(200, 22, 1), outfit(201, 22, 3), outfit(202, 22, -1), outfit(203, 22, -2),
                        outfit(204, 22, -32768)])
        func days(_ hull: Int, _ owned: [Int: Int]?) -> Int { g.hyperspaceTravelDays(hull: hull, ownedOutfits: owned) }
        XCTAssertEqual(days(128, [:]), 1)
        XCTAssertEqual(days(129, [:]), 2)
        XCTAssertEqual(days(130, [:]), 2)
        XCTAssertEqual(days(131, [:]), 3)
        XCTAssertEqual(days(128, [200: 1]), 2)
        XCTAssertEqual(days(128, [201: 2]), 7)
        XCTAssertEqual(days(128, [202: 1]), 1)
        XCTAssertEqual(days(132, [202: 1]), 2, "a negative ModVal subtracts through the 16-bit wrap")
        XCTAssertEqual(days(132, [203: 1]), 1)
        XCTAssertEqual(days(132, [202: 3]), 1, "floored at 1")
        XCTAssertEqual(days(128, [202: 1, 200: 1]), 1)
        XCTAssertEqual(days(128, [204: 1]), 1)
        XCTAssertEqual(days(132, nil), 3, "an escort's days ignore outfits")
    }

    // MARK: FL-06 jump outfits

    func testFastJumpAndMultiJumpAggregation() throws {
        let g = galaxy([hull(128), hull(129, flags2: 0x0020),
                        outfit(200, 37, 0), outfit(201, 32, 1), outfit(202, 32, 2)])
        let plain = try XCTUnwrap(g.loadout(shipID: 128, includeDefaultItems: false, includeHullWeapons: false))
        XCTAssertFalse(plain.instantJump)
        XCTAssertEqual(plain.maxJumpHops, 1)
        XCTAssertTrue(try XCTUnwrap(g.loadout(shipID: 129)).instantJump, "class Flags2 0x0020")
        XCTAssertTrue(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [200: 1])).instantJump, "ModType 37")
        // Depth 1 + ΣModVal; the fire block crosses depth − 1 systems, at least 1.
        XCTAssertEqual(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [201: 1])).maxJumpHops, 1,
                       "ModVal 1 is an ordinary jump")
        XCTAssertEqual(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [202: 1])).maxJumpHops, 2)
        XCTAssertEqual(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [202: 3])).maxJumpHops, 2,
                       "counted once per outfit type")
        XCTAssertEqual(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [201: 1, 202: 1])).maxJumpHops, 3)
    }

    // MARK: FL-07 fuel regeneration

    func testFuelRegenMatchesTheOracle() throws {
        // Oracle: Ship_ComputeShipFuelRechargeRate 0x00463b30, per tick.
        let g = galaxy([hull(128, fuelRegen: 300, flags: 0x0008), hull(129, fuelRegen: 300), hull(130),
                        outfit(200, 18, 300), outfit(201, 18, -300)])
        func perTick(_ lo: Loadout, player: Bool) -> Double {
            (player ? lo.playerFuelRegenPerSec : lo.fuelRegenPerSec) / 30
        }
        let flagged = try XCTUnwrap(g.loadout(shipID: 128, includeDefaultItems: false))
        XCTAssertEqual(perTick(flagged, player: true), 1.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(flagged.playerFuelRegenPerSec, 0.1, accuracy: 1e-9, "FuelRegen 300 → 0.1 fuel/s")
        let unflagged = try XCTUnwrap(g.loadout(shipID: 129, includeDefaultItems: false))
        XCTAssertEqual(perTick(unflagged, player: true), 0, "the player's hull term needs Flags 0x0008")
        XCTAssertEqual(perTick(unflagged, player: false), 1.0 / 300, accuracy: 1e-9, "NPCs always qualify")
        let scoops = try XCTUnwrap(g.loadout(shipID: 130, extraOutfits: [200: 2], includeDefaultItems: false))
        XCTAssertEqual(perTick(scoops, player: true), 2.0 / 300, accuracy: 1e-9, "count / ModVal")
        let cancel = try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [201: 1], includeDefaultItems: false))
        XCTAssertEqual(perTick(cancel, player: true), 0, accuracy: 1e-9)
        let suck = try XCTUnwrap(g.loadout(shipID: 130, extraOutfits: [201: 1], includeDefaultItems: false))
        XCTAssertEqual(suck.playerFuelRegenPerSec, -0.1, accuracy: 1e-9, "a negative ModVal drains")

        let ship = player()
        ship.maxFuel = 300; ship.fuel = 100; ship.fuelRegenPerSec = -0.1
        let world = World(player: ship)
        for _ in 0..<30 { world.step(tick) }
        XCTAssertEqual(ship.fuel, 99.9, accuracy: 1e-6)
        ship.fuelRegenPerSec = 0.1
        ship.disabled = true
        for _ in 0..<30 { world.step(tick) }
        XCTAssertEqual(ship.fuel, 100, accuracy: 1e-6, "the player's fuel regen has no disabled gate")
    }

    func testFuelCapacityIsClamped() throws {
        let g = galaxy([hull(128), outfit(200, 12, 30000)])
        XCTAssertEqual(try XCTUnwrap(g.loadout(shipID: 128, extraOutfits: [200: 2])).maxFuel, 32000)
    }

    // MARK: FL-04 player hyperjump

    func testCueLengthAndDurationMultiplier() {
        XCTAssertEqual(PlayerHyperjump.cueTicks60(of: NovaSound(sampleRate: 22050, samples: [Float](repeating: 0, count: 134_016))),
                       364, "the shipped Warp up cue")
        XCTAssertEqual(PlayerHyperjump.cueTicks60(of: nil), 350, "the missing-cue fallback")
        XCTAssertEqual(PlayerHyperjump.durationMultiplier(hullFlags: 0), 1.3, accuracy: 1e-12)
        XCTAssertEqual(PlayerHyperjump.durationMultiplier(hullFlags: 0x1), 0.91, accuracy: 1e-12)
        XCTAssertEqual(PlayerHyperjump.durationMultiplier(hullFlags: 0x2), 1.69, accuracy: 1e-12)
        XCTAssertEqual(PlayerHyperjump.durationMultiplier(hullFlags: 0x4), 2.08, accuracy: 1e-12)
        XCTAssertEqual(PlayerHyperjump.durationMultiplier(hullFlags: 0x3), 0.91, accuracy: 1e-12, "bit 0 wins")
    }

    /// Steps the world until the jump fires; returns (brake ticks, spin-up ticks).
    private func flyJump(_ world: World) -> (brake: Int, spinUp: Int) {
        var brake = 0, spinUp = 0
        for _ in 0..<5000 {
            guard let phase = world.playerJump?.phase, phase != .fired else { break }
            if phase == .brake { brake += 1 } else { spinUp += 1 }
            world.step(tick)
        }
        return (brake, spinUp)
    }

    func testSpinUpLastsTheCueAtTheHullMultiplier() {
        for (flags, seconds) in [(0, 4.67), (0x4, 2.92), (0x1, 6.67)] {
            let ship = player()
            let world = World(player: ship)
            world.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364,
                                               multiplier: PlayerHyperjump.durationMultiplier(hullFlags: flags))
            let run = flyJump(world)
            XCTAssertEqual(world.playerJump?.phase, .fired)
            XCTAssertEqual(run.brake, 1, "a ship at rest passes the stop gate on the first tick")
            XCTAssertEqual(Double(run.spinUp) / 30, seconds, accuracy: 0.05, "flags \(flags)")
        }
    }

    func testBrakeTurnsAroundAndStopsBeforeSpinUp() {
        let ship = player()
        ship.velocity = Vec2(0, 135)       // full non-strict speed, heading up
        let world = World(player: ship)
        world.playerJump = PlayerHyperjump(bearing: .pi / 2, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        let run = flyJump(world)
        XCTAssertGreaterThan(run.brake, 30, "a moving ship brakes first")
        XCTAssertEqual(Double(run.spinUp) / 30, 4.67, accuracy: 0.05, "then the full cue-timed spin-up")
        XCTAssertEqual(world.playerJump?.phase, .fired)
    }

    /// Q-EC-11 (0x00401800): a contraband scan of the player is dropped once
    /// the engaged jump is past the tunnel onset; before that it lands.
    func testScansStopOncePastTheTunnelOnset() {
        let world = World(player: player())
        world.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        world.reportScan(scannerID: 5, targetID: World.playerEntityID, at: Vec2())
        XCTAssertTrue(world.playerScanned, "still braking: the scan lands")
        world.playerScanned = false
        while (world.playerJump?.progress ?? 0) <= 0, world.playerJump?.phase != .fired { world.step(tick) }
        world.reportScan(scannerID: 5, targetID: World.playerEntityID, at: Vec2())
        XCTAssertFalse(world.playerScanned)
    }

    func testBrakeEndsBelowTwoPixelsPerTickOnBothAxes() {
        let ship = player()
        ship.angle = .pi                    // already facing retrograde
        ship.velocity = Vec2(0, 90)
        let world = World(player: ship)
        world.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        while world.playerJump?.phase == .brake { world.step(tick) }
        XCTAssertLessThan(abs(ship.velocity.y / 30), 2.5)
        XCTAssertEqual(world.playerJump?.phase, .spinUp)
        // One brake tick: 1 × thrust back, then × 0.99203847.
        let probe = player()
        probe.angle = .pi
        probe.velocity = Vec2(0, 90)
        let w2 = World(player: probe)
        w2.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        w2.step(tick)
        let expected = (3.0 - 0.06) * 0.99203847 * 30   // px/tick − thrust, damped, back to px/s
        XCTAssertEqual(probe.velocity.y, expected, accuracy: 1e-6)
    }

    func testFastJumpSkipsTheBrakeButNotTheSpinUp() {
        let ship = player()
        ship.velocity = Vec2(0, 135)
        let world = World(player: ship)
        world.playerJump = PlayerHyperjump(bearing: 0, fastJump: true, cueTicks60: 364, multiplier: 1.3)
        let run = flyJump(world)
        XCTAssertEqual(run.brake, 1)
        XCTAssertEqual(Double(run.spinUp) / 30, 4.67, accuracy: 0.05)
        XCTAssertGreaterThan(ship.velocity.length, 100, "keeps its momentum: no spin-up damping")
    }

    func testTunnelStepsPositionAtMinProgressFifty() {
        let ship = player()
        let world = World(player: ship)
        world.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        world.step(tick)                                // brake → spin-up
        var lastY = ship.position.y
        var maxStep = 0.0
        var onsetTick: Int?
        for i in 0..<400 where world.playerJump?.phase == .spinUp {
            world.step(tick)
            let step = ship.position.y - lastY
            if step > 0, onsetTick == nil { onsetTick = i }
            maxStep = max(maxStep, step)
            lastY = ship.position.y
        }
        XCTAssertEqual(maxStep, 50, accuracy: 1e-6, "position steps at most 50 px/tick")
        // progress = e60 × 1.3 / 3.64 − 35/1.3 > 0 once e60 > 75.4 (≈ 1.26 s).
        XCTAssertEqual(Double(onsetTick ?? 0) / 30, 75.4 / 60, accuracy: 0.05)
        XCTAssertEqual(ship.velocity.length, 0, accuracy: 1e-9, "the tunnel moves position, not velocity")
    }

    func testDisabledPlayerCollapsesTheJump() {
        let ship = player()
        let world = World(player: ship)
        world.playerJump = PlayerHyperjump(bearing: 0, fastJump: false, cueTicks60: 364, multiplier: 1.3)
        for _ in 0..<90 { world.step(tick) }            // well into the tunnel
        ship.disabled = true
        world.step(tick)
        XCTAssertEqual(world.playerJump?.phase, .collapsed)
        XCTAssertEqual(ship.velocity.length, min(world.playerJump!.progress * 30, ship.effectiveMaxSpeed), accuracy: 1e-6)
    }

    // MARK: FL-13 arrival

    func testArrivalIs1350PixelsOutAtEffectiveTopSpeed() {
        for strict in [false, true] {
            let ship = player()
            ship.angle = 90.4 * .pi / 180
            let world = World(player: ship)
            world.strictPlay = strict
            world.placePlayerAtHyperspaceArrival(bearing: .pi / 2)
            XCTAssertEqual(ship.position.x, -1350, accuracy: 1e-9)
            XCTAssertEqual(ship.position.y, 0, accuracy: 1e-9)
            XCTAssertEqual(ship.velocity.length, strict ? 90 : 135, accuracy: 1e-9)
            XCTAssertEqual(ship.velocity.angle, .pi / 2, accuracy: 1e-9, "along the truncated heading")
        }
    }
}
