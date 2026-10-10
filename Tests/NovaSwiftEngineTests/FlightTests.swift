import XCTest
@testable import NovaSwiftEngine

final class FlightTests: XCTestCase {

    private func makeWorld() -> World {
        let stats = ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi) // 180°/s = 6°/tick
        let world = World(player: Ship(name: "Test", stats: stats))
        world.strictPlay = true   // no ×1.5, so top speed is the stat
        return world
    }

    func testThrustAcceleratesAlongHeading() {
        let world = makeWorld() // angle 0 = up → heading (0, 1)
        world.intent.thrust = true
        world.step(1.0)
        XCTAssertEqual(world.player.velocity.x, 0, accuracy: 1e-9)
        XCTAssertEqual(world.player.velocity.y, 50, accuracy: 1e-9) // accel * dt
        XCTAssertEqual(world.player.position.y, 50, accuracy: 1e-9)
    }

    func testSpeedIsClamped() {
        let world = makeWorld()
        world.intent.thrust = true
        for _ in 0..<100 { world.step(1.0) } // would be 5000 without clamp
        XCTAssertLessThanOrEqual(world.player.velocity.length, 100 + 1e-6)
        XCTAssertEqual(world.player.velocity.length, 100, accuracy: 1e-6)
    }

    func testTurnChangesHeadingAndFrame() {
        let world = makeWorld()
        XCTAssertEqual(world.player.spriteFrame, 0) // pointing up
        world.intent.turnRight = true
        world.step(0.5) // 180°/s * 0.5 = 90° clockwise
        XCTAssertEqual(world.player.angle, .pi / 2, accuracy: 1e-9)
        // 90° of 360° over 36 frames = frame 9.
        XCTAssertEqual(world.player.spriteFrame, 9)
    }

    func testInertiaCoastsWithoutThrust() {
        let world = makeWorld()
        world.intent.thrust = true
        world.step(1.0)          // gain velocity
        world.intent.thrust = false
        let vBefore = world.player.velocity.length
        world.step(1.0)          // coast — pure Newtonian, no drag by default
        XCTAssertEqual(world.player.velocity.length, vBefore, accuracy: 1e-9)
        XCTAssertEqual(world.player.position.y, 100, accuracy: 1e-9)
    }

    func testDesiredHeadingRotatesToward() {
        let world = makeWorld() // 6°/tick
        world.intent.desiredHeading = .pi / 2 // aim right (east)
        world.step(0.25) // can turn up to 45°; needs 90°, so partial
        XCTAssertEqual(world.player.angle, .pi / 4, accuracy: 1e-9)
        // The player's auto-turn steps whole turn steps and stops, without
        // snapping, once within one step (0x0044c8d0): 45 → 51 … 81, 87 stays.
        for _ in 0..<30 { world.step(1.0 / 30.0) }
        XCTAssertEqual(world.player.angle * 180 / .pi, 87, accuracy: 1e-9)
    }

    func testDiscreteTurnBeatsDesiredHeading() {
        let world = makeWorld()
        world.intent.desiredHeading = .pi        // aim behind
        world.intent.turnLeft = true             // but also hold left
        world.step(0.5)                          // discrete wins: -90°
        XCTAssertEqual(world.player.angle, -.pi / 2, accuracy: 1e-9)
    }

    func testCombinedMergesSources() {
        var kb = ControlIntent(); kb.thrust = true
        var pad = ControlIntent(); pad.desiredHeading = 1.0; pad.firePrimary = true
        let merged = ControlIntent.combined(kb, pad)
        XCTAssertTrue(merged.thrust)
        XCTAssertTrue(merged.firePrimary)
        XCTAssertEqual(merged.desiredHeading, 1.0)
    }

    func testStatsFromNovaUnits() {
        // FL-02: Speed/100 px/tick, Accel/10000 × 2 px/tick², Maneuver × 0.1
        // deg/tick, at 30 ticks/s.
        let s = ShipStats(speed: 300, acceleration: 500, turnRate: 40)
        XCTAssertEqual(s.maxSpeed, 90, accuracy: 1e-9)
        XCTAssertEqual(s.acceleration, 90, accuracy: 1e-9)
        XCTAssertEqual(s.turnRate, 120 * .pi / 180, accuracy: 1e-12)
    }

    /// Inertialess flight (shïp Flags2 0x40): velocity tracks the nose with no
    /// drift — turning redirects motion instead of leaving a momentum tail.
    func testInertialessShipRedirectsVelocityWithoutDrift() {
        let ship = Ship(name: "I", stats: ShipStats(maxSpeed: 120, acceleration: 300, turnRate: .pi * 2))
        ship.inertialess = true
        let world = World(player: ship)
        world.intent.thrust = true
        for _ in 0..<30 { world.step(1.0 / 30.0) }          // build speed heading "up"
        XCTAssertGreaterThan(ship.velocity.y, 50)           // moving north
        // Swing the nose east; velocity should follow it and the north drift go,
        // each axis steering by at most 4 × thrust per tick (0x0043b020).
        ship.angle = .pi / 2
        for _ in 0..<60 { world.step(1.0 / 30.0) }          // 2s
        XCTAssertGreaterThan(ship.velocity.x, 80, "inertialess ship moves along its new heading")
        XCTAssertEqual(ship.velocity.y, 0, accuracy: 5, "no leftover drift in the old direction")
    }

    /// Default `.formations` scope: a *lone* AI ship (and the player) wrestles
    /// Newtonian momentum — what makes the reverse-and-fire "Monty Python" maneuver
    /// possible — while a ship holding formation flies driftless so it glues to its
    /// slot (the EV Nova escort behavior). Only the hull flag overrides otherwise.
    func testDefaultFlightFliesEveryoneByTheirHull() {
        // FL-11: the original flies an NPC inertialess only with hull Flags2
        // 0x0040; the formation model is the `formationFlying` enhancement.
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        XCTAssertEqual(world.tuning.aiInertialess, .off)
        let escort = Ship(name: "Escort", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let eb = AIBrain(aiType: .interceptor, govt: 500); eb.leaderID = World.playerEntityID
        escort.brain = eb
        XCTAssertFalse(escort.fliesInertialess(world.tuning), "a non-0x40 escort flies Newtonian")

        var e = GameplayEnhancements(); e.formationFlying = true
        XCTAssertTrue(escort.fliesInertialess(FlightTuning(enhancements: e)), "…unless formations are enhanced")
    }

    /// `.formations` scope: only ships flying in formation (a leader-following
    /// escort, or a flagged fleet member such as the flagship) fly driftless — a
    /// lone AI ship still flies Newtonian.
    func testFormationsScopeOnlyCoversFormationFlyers() {
        var tuning = FlightTuning.default
        tuning.aiInertialess = .formations
        let lone = Ship(name: "Lone", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        lone.brain = AIBrain(aiType: .warship, govt: 1)
        XCTAssertFalse(lone.fliesInertialess(tuning), "a lone AI ship stays Newtonian under .formations")

        let escort = Ship(name: "Escort", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let eb = AIBrain(aiType: .interceptor, govt: 1); eb.leaderID = 0
        escort.brain = eb
        XCTAssertTrue(escort.fliesInertialess(tuning), "a ship holding formation on a leader flies driftless")

        let flagship = Ship(name: "Flag", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let fb = AIBrain(aiType: .warship, govt: 1); fb.isFleetMember = true
        flagship.brain = fb
        XCTAssertTrue(flagship.fliesInertialess(tuning), "a flagged fleet member (the lead) flies driftless too")
    }

    /// `.off` scope restores strict "identical physics for player and AI": only a
    /// hull/outfit with the real flag is driftless, brain or no brain.
    func testOffScopeLeavesOnlyHullFlaggedShipsInertialess() {
        var tuning = FlightTuning.default
        tuning.aiInertialess = .off
        let npc = Ship(name: "NPC", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        npc.brain = AIBrain(aiType: .warship, govt: 1)
        XCTAssertFalse(npc.fliesInertialess(tuning), "under .off an AI ship without the hull flag is Newtonian")
        npc.inertialess = true   // the real shïp Flags2 0x0040 flag
        XCTAssertTrue(npc.fliesInertialess(tuning), "the hull flag always wins, whatever the AI scope")
    }

    /// FL-11: an inertialess hull's speed has no idle decay — release the
    /// throttle and it keeps flying where it points; reverse slows it.
    func testInertialessShipKeepsItsSpeedWhenThrustIsReleased() {
        let ship = Ship(name: "I", stats: ShipStats(maxSpeed: 120, acceleration: 100, turnRate: .pi))
        ship.inertialess = true
        let world = World(player: ship)
        world.strictPlay = true
        world.intent.thrust = true
        for _ in 0..<60 { world.step(1.0 / 30.0) }
        XCTAssertEqual(ship.velocity.length, 120, accuracy: 1e-6)
        world.intent = ControlIntent()                      // release everything
        for _ in 0..<120 { world.step(1.0 / 30.0) }         // 4s
        XCTAssertEqual(ship.velocity.length, 120, accuracy: 1e-6, "no idle decay")
        world.intent.reverse = true
        for _ in 0..<30 { world.step(1.0 / 30.0) }          // thrust × 1 s = 100 px/s off
        XCTAssertEqual(ship.velocity.length, 20, accuracy: 1e-6, "reverse bleeds speed by thrust × time")
    }
}
