import XCTest
@testable import EVNovaEngine

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

    func testStatsFromNovaUnits() {
        let s = ShipStats(speed: 300, acceleration: 500, turnRate: 40)
        XCTAssertEqual(s.maxSpeed, 300 * 3.2, accuracy: 1e-9)
        XCTAssertEqual(s.acceleration, 500 * 3.2, accuracy: 1e-9)
        XCTAssertGreaterThan(s.turnRate, 0)
    }
}
