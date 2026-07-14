import XCTest
@testable import NovaSwiftEngine

/// P2 co-op engine seam: a `World` can host N externally-driven ships, not just
/// the local player. A remote player is a `brain == nil`, `remotePlayer != nil`
/// ship stepped from `World.remoteIntents[entityID]`. These tests pin both the
/// new behavior AND that single-player is completely unchanged when no remote
/// ships exist.
final class RemotePlayerTests: XCTestCase {

    private func makeWorld() -> World {
        // angle 0 = up → heading (0, 1). Matches FlightTests.
        let stats = ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi)
        return World(player: Ship(name: "Local", stats: stats))
    }

    private func makeRemoteShip() -> Ship {
        let stats = ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi)
        return Ship(name: "Friend", stats: stats, position: Vec2(500, 0))
    }

    // MARK: New behavior

    func testRemoteShipStepsFromPublishedIntent() {
        let world = makeWorld()
        let friend = makeRemoteShip()
        let id = world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "p-friend", name: "Friend"),
                                         arrival: .populate)

        // Publish a thrust intent for the friend, exactly as the net layer would.
        world.remoteIntents[id] = { var i = ControlIntent(); i.thrust = true; return i }()

        let y0 = friend.position.y
        world.step(1.0)   // accel 50 along heading (0,1)

        XCTAssertEqual(friend.velocity.y, 50, accuracy: 1e-9)
        XCTAssertGreaterThan(friend.position.y, y0)
        XCTAssertEqual(friend.velocity.x, 0, accuracy: 1e-9)
    }

    func testRemoteShipCoastsWhenNoIntentPublished() {
        // A dropped/late packet = no entry this frame = empty intent (coast),
        // never a stall or a warning.
        let world = makeWorld()
        let friend = makeRemoteShip()
        let id = world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "p", name: "F"),
                                         arrival: .populate)
        friend.velocity = Vec2(0, 20)   // already moving
        world.remoteIntents[id] = nil   // no input this frame

        let before = friend.velocity
        world.step(1.0)
        // No thrust/turn applied — pure coast (no drag by default).
        XCTAssertEqual(friend.velocity.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(friend.velocity.y, before.y, accuracy: 1e-9)
        XCTAssertEqual(friend.position.y, 20, accuracy: 1e-9)
    }

    func testRemoteShipIsNotTheLocalPlayerAndHasNoBrain() {
        let world = makeWorld()
        let friend = makeRemoteShip()
        let id = world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "p-x", name: "X"))
        XCTAssertNotEqual(id, World.playerEntityID)
        XCTAssertFalse(friend.isPlayer)
        XCTAssertNil(friend.brain)
        XCTAssertEqual(friend.remotePlayer, RemotePlayerInfo(peerID: "p-x", name: "X"))
        XCTAssertEqual(world.remotePlayerShips.map(\.entityID), [id])
    }

    func testLocalIntentAndRemoteIntentAreIndependent() {
        // The local player follows `world.intent`; the friend follows
        // `remoteIntents[id]`. They must not cross-drive each other.
        let world = makeWorld()
        let friend = makeRemoteShip()
        let id = world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "p", name: "F"),
                                         arrival: .populate)
        world.intent.thrust = true                       // local thrusts
        world.remoteIntents[id] = ControlIntent()        // friend idle

        world.step(1.0)
        XCTAssertEqual(world.player.velocity.y, 50, accuracy: 1e-9)   // local moved
        XCTAssertEqual(friend.velocity.length, 0, accuracy: 1e-9)     // friend didn't
    }

    func testRemoveShipClearsRemoteIntent() {
        let world = makeWorld()
        let friend = makeRemoteShip()
        let id = world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "p", name: "F"))
        world.remoteIntents[id] = { var i = ControlIntent(); i.thrust = true; return i }()

        world.removeShip(entityID: id)
        XCTAssertNil(world.remoteIntents[id])
        XCTAssertTrue(world.remotePlayerShips.isEmpty)
    }

    // MARK: Single-player is unchanged

    func testNoRemoteShipsMeansEmptyRemoteState() {
        let world = makeWorld()
        world.intent.thrust = true
        world.step(1.0)
        XCTAssertTrue(world.remoteIntents.isEmpty)
        XCTAssertTrue(world.remotePlayerShips.isEmpty)
        // Player still behaves exactly as FlightTests expects.
        XCTAssertEqual(world.player.velocity.y, 50, accuracy: 1e-9)
    }
}
