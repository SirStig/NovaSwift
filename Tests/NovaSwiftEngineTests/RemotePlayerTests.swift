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

    // MARK: Network-mirror NPCs (co-op shared world)

    func testNetworkMirrorShipCoastsWithoutBrainOrWarning() {
        let world = makeWorld()
        let mirror = Ship(name: "Pirate", stats: makeRemoteShip().stats, position: Vec2(100, 0))
        let id = world.spawnNetworkMirror(mirror, arrival: .populate)
        mirror.velocity = Vec2(0, 30)

        XCTAssertTrue(mirror.networkMirror)
        XCTAssertNil(mirror.brain)
        XCTAssertNil(mirror.remotePlayer)               // not a player — no nameplate/blip
        XCTAssertTrue(world.remotePlayerShips.isEmpty)  // mirror NPC isn't a "remote player"
        XCTAssertNotEqual(id, World.playerEntityID)

        world.step(1.0)
        // Coasts on its velocity (no intent, no thrust), like dead reckoning.
        XCTAssertEqual(mirror.position.y, 30, accuracy: 1e-9)
        XCTAssertEqual(mirror.velocity.y, 30, accuracy: 1e-9)
    }

    func testSpawningPausedHoldsTheSpawner() {
        // With no spawner attached this just proves the gate is wired; a real
        // Spawner is exercised elsewhere. Here we assert the flag exists and the
        // step doesn't crash / populate.
        let world = makeWorld()
        world.spawningPaused = true
        world.step(1.0)
        XCTAssertTrue(world.npcs.isEmpty)
    }

    func testRemoveAINPCsKeepsMirrorsDropsRealNPCs() {
        let world = makeWorld()
        // A real ambient NPC (has a stats-only ship, no mirror flags).
        let realNPC = Ship(name: "Trader", stats: makeRemoteShip().stats, position: Vec2(300, 0))
        world.addNPC(realNPC, arrival: .populate)
        // A co-op player mirror and an NPC mirror.
        world.spawnRemotePlayer(makeRemoteShip(), info: RemotePlayerInfo(peerID: "p", name: "P"))
        world.spawnNetworkMirror(Ship(name: "Ghost", stats: makeRemoteShip().stats))

        XCTAssertEqual(world.npcs.count, 3)
        world.removeAINPCs()
        // Only the two mirrors survive; the real NPC is gone.
        XCTAssertEqual(world.npcs.count, 2)
        XCTAssertFalse(world.npcs.contains { $0.name == "Trader" })
        XCTAssertTrue(world.npcs.contains { $0.remotePlayer?.peerID == "p" })
        XCTAssertTrue(world.npcs.contains { $0.networkMirror })
    }

    // MARK: PvP gating (SessionRules.allowPvP)

    func testPvPBlockedByDefaultAllowedWhenEnabled() {
        // Two player-controlled ships sharing the co-op government. A projectile
        // one fires at the other only lands when pvpAllowed is set.
        func scenario(pvp: Bool) -> Bool {
            let world = World(player: Ship(name: "A", stats: ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi)))
            world.player.government = 200
            world.pvpAllowed = pvp
            let friend = Ship(name: "B", stats: world.player.stats, position: Vec2(30, 0))
            friend.government = 200                       // same co-op govt
            friend.maxArmor = 100; friend.armor = 100
            world.spawnRemotePlayer(friend, info: RemotePlayerInfo(peerID: "B", name: "B"))
            // A real shot owned by the player (entity 0) heading into the friend.
            let shot = Projectile(position: Vec2(0, 0), velocity: Vec2(600, 0), life: 1,
                                  shieldDamage: 50, armorDamage: 50, blastRadius: 0,
                                  ownerID: 0, ownerGovt: 200, homing: false, turnRate: 0,
                                  speed: 600, targetID: nil)
            world.testInjectProjectile(shot)
            for _ in 0..<10 { world.step(1.0 / 30.0) }
            return friend.shield < 100 || friend.armor < 100   // did the friend take damage?
        }
        XCTAssertFalse(scenario(pvp: false), "with PvP off, players can't damage each other")
        XCTAssertTrue(scenario(pvp: true), "with PvP on, a player's shot hits another player")
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
