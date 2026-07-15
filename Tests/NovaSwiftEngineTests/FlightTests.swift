import XCTest
@testable import NovaSwiftEngine

final class FlightTests: XCTestCase {

    private func makeWorld() -> World {
        let stats = ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi) // 180°/s
        return World(player: Ship(name: "Test", stats: stats))
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
        let world = makeWorld() // turnRate = π rad/s (180°/s)
        world.intent.desiredHeading = .pi / 2 // aim right (east)
        world.step(0.25) // can turn up to 45°; needs 90°, so partial
        XCTAssertEqual(world.player.angle, .pi / 4, accuracy: 1e-9)
        world.step(1.0) // plenty to finish
        XCTAssertEqual(world.player.angle, .pi / 2, accuracy: 1e-9)
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
        // Raw stat -> px/sec(²) goes through `FlightTuning.default`'s
        // speed/accel scale (currently 0.55, calibrated against the
        // original's flight feel — see `FlightTuning`'s doc comment), not a
        // 1:1 passthrough.
        let s = ShipStats(speed: 300, acceleration: 500, turnRate: 40)
        XCTAssertEqual(s.maxSpeed, 300 * FlightTuning.default.speedScale, accuracy: 1e-9)
        XCTAssertEqual(s.acceleration, 500 * FlightTuning.default.accelScale, accuracy: 1e-9)
        XCTAssertGreaterThan(s.turnRate, 0)
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
        // Command an east heading; velocity should swing east and the north drift decay.
        world.intent.desiredHeading = .pi / 2
        for _ in 0..<60 { world.step(1.0 / 30.0) }          // 2s
        XCTAssertGreaterThan(ship.velocity.x, 80, "inertialess ship moves along its new heading")
        XCTAssertEqual(ship.velocity.y, 0, accuracy: 5, "no leftover drift in the old direction")
    }

    /// EV Nova's NPC AI flies driftless: every AI-brained ship flies the
    /// inertialess model by default (`FlightTuning.aiInertialess == .all`), while
    /// the player keeps authentic Newtonian flight unless their own hull sets the
    /// flag — the player/AI asymmetry the original had.
    func testAIShipsFlyInertialessByDefaultAndPlayerDoesNot() {
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        let npc = Ship(name: "NPC", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        npc.brain = AIBrain(aiType: .warship, govt: 500)
        XCTAssertTrue(npc.fliesInertialess(world.tuning), "an AI ship flies driftless by default")
        XCTAssertFalse(world.player.fliesInertialess(world.tuning), "the player keeps Newtonian flight")
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

    /// Inertialess hulls have no momentum: release the throttle and they bleed to a
    /// stop rather than coasting forever like an inertial ship.
    func testInertialessShipCoastsToStopWhenIdle() {
        let ship = Ship(name: "I", stats: ShipStats(maxSpeed: 120, acceleration: 100, turnRate: .pi))
        ship.inertialess = true
        let world = World(player: ship)
        world.intent.thrust = true
        for _ in 0..<40 { world.step(1.0 / 30.0) }
        XCTAssertGreaterThan(ship.velocity.length, 50)
        world.intent = ControlIntent()                      // release everything
        for _ in 0..<120 { world.step(1.0 / 30.0) }         // 4s
        XCTAssertLessThan(ship.velocity.length, 1, "inertialess ship should coast to a stop, not glide on")
    }
}
