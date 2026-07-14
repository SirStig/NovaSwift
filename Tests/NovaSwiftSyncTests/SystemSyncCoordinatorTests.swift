import XCTest
@testable import NovaSwiftSync
import NovaSwiftEngine
import NovaSwiftNet

/// End-to-end Layer-2 proof: two real engine `World`s, two `NetSession`s over a
/// `LoopbackNetwork`, and two `SystemSyncCoordinator`s — one authority, one
/// client — run a sync loop and we verify the friend's ship actually appears and
/// moves in the other player's world. No app, no GUI: the full co-op loop lives
/// in the package and is unit-tested here.
final class SystemSyncCoordinatorTests: XCTestCase {

    private func combatStats() -> ShipStats {
        ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi)
    }

    func testTwoWorldsSyncPlayersEndToEnd() {
        // Transport + sessions.
        let net = LoopbackNetwork()
        let tA = LoopbackTransport(peerID: "A", network: net)
        let tC = LoopbackTransport(peerID: "C", network: net)
        let sessionA = NetSession(transport: tA)   // authority
        let sessionC = NetSession(transport: tC)   // client
        tA.connect(); tC.connect()

        let coordA = SystemSyncCoordinator(localPlayerID: "A")
        let coordC = SystemSyncCoordinator(localPlayerID: "C")

        // Authority's world: its own player + the client's ship injected (the
        // authority authoritatively simulates the client's ship from its inputs).
        let authorityPlayer = Ship(name: "Authority", stats: combatStats())
        let worldA = World(player: authorityPlayer)
        let clientShipOnAuthority = Ship(name: "Client", stats: combatStats(),
                                         position: Vec2(500, 0))
        worldA.spawnRemotePlayer(clientShipOnAuthority,
                                 info: RemotePlayerInfo(peerID: "C", name: "Client"),
                                 arrival: .populate)

        // Client's world: just its own player, at the same spot it occupies on the
        // authority, so we can compare authoritative vs. predicted tracks.
        let clientPlayer = Ship(name: "Client", stats: combatStats(), position: Vec2(500, 0))
        let worldC = World(player: clientPlayer)

        // Wire the Layer-2 callbacks.
        sessionA.onInput = { frame, peer in coordA.receiveInput(frame, from: peer) }
        sessionC.onSnapshot = { snap, peer in coordC.apply(snap, to: worldC, authorityPeer: peer) }

        // Both players hold thrust (angle 0 → heading +y).
        var authorityIntent = ControlIntent(); authorityIntent.thrust = true
        var clientIntent = ControlIntent(); clientIntent.thrust = true
        worldA.intent = authorityIntent

        let dt = 1.0 / 30.0
        for t in 1...30 {
            let tick = UInt32(t)
            // 1) Client predicts its own ship locally.
            worldC.intent = clientIntent
            worldC.step(dt)
            // 2) Client sends its input to the authority.
            sessionC.sendInput(coordC.input(from: clientIntent, tick: tick, seq: tick), to: "A")
            // 3) Authority applies inputs, steps, broadcasts — client mirrors on receipt.
            coordA.applyInputs(to: worldA)
            worldA.step(dt)
            sessionA.broadcastSnapshot(coordA.snapshot(of: worldA, tick: tick))
        }

        // The friend (authority's player) now exists in the client's world as a
        // remote player, at the authority's broadcast position.
        let mirrors = worldC.remotePlayerShips
        XCTAssertEqual(mirrors.count, 1, "the authority's player should appear once in the client's world")
        let authorityMirror = try! XCTUnwrap(mirrors.first)
        XCTAssertEqual(authorityMirror.name, "Authority")
        XCTAssertEqual(authorityMirror.remotePlayer?.peerID, "A")
        XCTAssertEqual(authorityMirror.position.x, authorityPlayer.position.x, accuracy: 1e-6)
        XCTAssertEqual(authorityMirror.position.y, authorityPlayer.position.y, accuracy: 1e-6)
        XCTAssertGreaterThan(authorityMirror.position.y, 0, "the authority thrusted; its mirror should have moved")

        // The client's ship, simulated authoritatively on the authority from the
        // inputs it streamed, moved under thrust — and tracks the client's own
        // locally-predicted position closely.
        XCTAssertGreaterThan(clientShipOnAuthority.position.y, 0,
                             "the client's inputs should have driven its ship on the authority")
        XCTAssertEqual(clientShipOnAuthority.position.y, clientPlayer.position.y, accuracy: 5.0,
                       "authoritative and predicted client tracks should stay close")
    }

    func testDepartedPlayerMirrorIsRemoved() {
        // A client injects a remote player from a snapshot, then a later snapshot
        // without that player removes the mirror.
        let coord = SystemSyncCoordinator(localPlayerID: "me")
        let world = World(player: Ship(name: "Me", stats: combatStats()))

        let present = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
            ShipNetState(id: 7, playerID: "friend", name: "Friend", x: 10, y: 20,
                         vx: 0, vy: 0, angle: 0, shield: 100, armor: 100, control: .remote),
        ])
        let r1 = coord.apply(present, to: world, authorityPeer: "friend")
        XCTAssertEqual(r1.injected.count, 1)
        XCTAssertEqual(world.remotePlayerShips.count, 1)
        XCTAssertEqual(world.remotePlayerShips.first?.position.x, 10)

        // Update in place — no new injection.
        let moved = WorldSnapshot(tick: 2, ackInputSeq: 0, ships: [
            ShipNetState(id: 7, playerID: "friend", name: "Friend", x: 99, y: 20,
                         vx: 0, vy: 0, angle: 0, shield: 100, armor: 100, control: .remote),
        ])
        let r2 = coord.apply(moved, to: world, authorityPeer: "friend")
        XCTAssertTrue(r2.injected.isEmpty)
        XCTAssertEqual(world.remotePlayerShips.first?.position.x, 99)

        // Empty snapshot — the friend left; mirror removed.
        let gone = WorldSnapshot(tick: 3, ackInputSeq: 0, ships: [])
        let r3 = coord.apply(gone, to: world, authorityPeer: "friend")
        XCTAssertEqual(r3.removed.count, 1)
        XCTAssertTrue(world.remotePlayerShips.isEmpty)
    }

    func testOwnShipInSnapshotIsNotMirrored() {
        // A snapshot that includes our own ship (playerID == localPlayerID) must
        // not inject a mirror of ourselves — we predict our own ship.
        let coord = SystemSyncCoordinator(localPlayerID: "me")
        let world = World(player: Ship(name: "Me", stats: combatStats()))
        let snap = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
            ShipNetState(id: 0, playerID: "me", name: "Me", x: 1, y: 2, vx: 0, vy: 0,
                         angle: 0, shield: 100, armor: 100, control: .remote),
            ShipNetState(id: 3, playerID: nil, name: "Pirate", x: 5, y: 5, vx: 0, vy: 0,
                         angle: 0, shield: 100, armor: 100, control: .ai),
        ])
        coord.apply(snap, to: world, authorityPeer: "auth")
        XCTAssertTrue(world.remotePlayerShips.isEmpty, "neither our own ship nor an NPC should mirror as a remote player")
    }

    func testAuthorityInjectsAndRemovesClientMirrorsFromPresence() {
        // The authority mirrors co-located clients (from presence), simulates them
        // from their inputs, then removes a client's mirror when it leaves.
        let coord = SystemSyncCoordinator(localPlayerID: "A")
        let world = World(player: Ship(name: "A", stats: combatStats()))

        let r1 = coord.syncClients([(id: "B", name: "Bo"), (id: "C", name: "Cy")], into: world)
        XCTAssertEqual(r1.injected.count, 2)
        XCTAssertEqual(Set(world.remotePlayerShips.map { $0.remotePlayer!.peerID }), ["B", "C"])

        // Idempotent — calling again with the same set injects nothing new.
        let r2 = coord.syncClients([(id: "B", name: "Bo"), (id: "C", name: "Cy")], into: world)
        XCTAssertTrue(r2.injected.isEmpty && r2.removed.isEmpty)

        // A client's input drives its mirror under the authority's step.
        var thrust = NetIntent(); thrust.thrust = true
        coord.receiveInput(InputFrame(tick: 1, seq: 1, intent: thrust), from: "B")
        coord.applyInputs(to: world)
        let boShip = world.remotePlayerShips.first { $0.remotePlayer?.peerID == "B" }!
        XCTAssertEqual(world.remoteIntents[boShip.entityID]?.thrust, true)

        // C leaves — its mirror is removed, B stays.
        let r3 = coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertEqual(r3.removed.count, 1)
        XCTAssertEqual(world.remotePlayerShips.map { $0.remotePlayer!.peerID }, ["B"])
    }

    func testClientMirrorsNPCsAndAdoptsAuthoritativeOwnHealth() {
        // A client applies a snapshot carrying its own ship, a friend, and an NPC.
        let coord = SystemSyncCoordinator(localPlayerID: "me")
        let world = World(player: Ship(name: "Me", stats: combatStats()))
        world.player.shield = 100; world.player.armor = 100

        let snap = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
            // Our own ship, as the authority sees it — health is authoritative.
            ShipNetState(id: 0, playerID: "me", shipTypeID: 128, name: "Me",
                         x: 999, y: 999, vx: 0, vy: 0, angle: 0, shield: 40, armor: 55, control: .remote),
            // A friend.
            ShipNetState(id: 5, playerID: "friend", shipTypeID: 129, name: "Bo",
                         x: 10, y: 0, vx: 0, vy: 0, angle: 0, shield: 100, armor: 100, control: .remote),
            // An NPC the authority owns — both players should see it.
            ShipNetState(id: 9, playerID: nil, shipTypeID: 130, name: "Pirate",
                         x: 20, y: 5, vx: 1, vy: 2, angle: 0.5, shield: 80, armor: 90, control: .ai),
        ])
        coord.apply(snap, to: world, authorityPeer: "auth")

        // Own health adopted from the authority; position NOT teleported (predicted).
        XCTAssertEqual(world.player.shield, 40, accuracy: 1e-9)
        XCTAssertEqual(world.player.armor, 55, accuracy: 1e-9)
        XCTAssertNotEqual(world.player.position.x, 999)

        // Friend mirrored as a remote player (nameplate/blip); NPC as a plain mirror.
        XCTAssertEqual(world.remotePlayerShips.map { $0.remotePlayer!.peerID }, ["friend"])
        let npcMirror = world.npcs.first { $0.networkMirror }
        XCTAssertNotNil(npcMirror)
        XCTAssertEqual(npcMirror?.name, "Pirate")
        XCTAssertEqual(npcMirror?.position.x, 20)
        XCTAssertEqual(npcMirror?.armor, 90)
        XCTAssertNil(npcMirror?.remotePlayer)   // an NPC, not a player

        // Next snapshot drops the NPC (destroyed/left) — its mirror is removed.
        let snap2 = WorldSnapshot(tick: 2, ackInputSeq: 0, ships: [
            ShipNetState(id: 5, playerID: "friend", shipTypeID: 129, name: "Bo",
                         x: 12, y: 0, vx: 0, vy: 0, angle: 0, shield: 100, armor: 100, control: .remote),
        ])
        coord.apply(snap2, to: world, authorityPeer: "auth")
        XCTAssertFalse(world.npcs.contains { $0.networkMirror })
        XCTAssertEqual(world.remotePlayerShips.count, 1)
    }

    func testClientEchoesAuthorityShotsSkippingItsOwn() {
        let coord = SystemSyncCoordinator(localPlayerID: "me")
        let world = World(player: Ship(name: "Me", stats: combatStats()))

        // Our own ship is entity 0 on the authority; an enemy NPC is entity 9.
        let snap = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
            ShipNetState(id: 0, playerID: "me", shipTypeID: 128, name: "Me",
                         x: 0, y: 0, vx: 0, vy: 0, angle: 0, shield: 100, armor: 100, control: .remote),
        ], shots: [
            // Our own shot — must NOT be echoed (we fired it locally already).
            ProjectileNetState(ownerID: 0, x: 1, y: 1, vx: 10, vy: 0, facing: 0, life: 2,
                               weaponID: 128, graphicSpinID: nil, spinShots: false, translucentShots: false),
            // An enemy shot — echoed as a visual-only projectile.
            ProjectileNetState(ownerID: 9, x: 5, y: 5, vx: -8, vy: 0, facing: .pi, life: 3,
                               weaponID: 130, graphicSpinID: 500, spinShots: true, translucentShots: false),
        ])
        coord.apply(snap, to: world, authorityPeer: "auth")

        let visual = world.projectiles.filter { $0.visualOnly }
        XCTAssertEqual(visual.count, 1, "only the enemy shot echoes; our own is skipped")
        XCTAssertEqual(visual.first?.ownerID, 9)
        XCTAssertEqual(visual.first?.position.x, 5)
        XCTAssertEqual(visual.first?.weaponID, 130)

        // Next snapshot with no shots clears the echoes.
        let snap2 = WorldSnapshot(tick: 2, ackInputSeq: 0, ships: snap.ships, shots: [])
        coord.apply(snap2, to: world, authorityPeer: "auth")
        XCTAssertTrue(world.projectiles.filter { $0.visualOnly }.isEmpty)
    }

    func testVisualProjectileFliesAndExpiresWithoutDamage() {
        // A visual-only shot moves on its velocity and expires, harming nothing.
        let world = World(player: Ship(name: "Me", stats: combatStats()))
        let target = Ship(name: "T", stats: combatStats(), position: Vec2(10, 0))
        world.addNPC(target, arrival: .populate)
        let armorBefore = target.armor

        world.spawnVisualProjectile(position: Vec2(0, 0), velocity: Vec2(100, 0), facing: 0,
                                    life: 0.05, ownerID: 999, weaponID: 128,
                                    graphicSpinID: nil, spinShots: false, translucentShots: false)
        XCTAssertEqual(world.projectiles.count, 1)

        world.step(0.02)                       // flies through the target's position…
        XCTAssertEqual(target.armor, armorBefore, "a visual shot deals no damage")
        world.step(0.1)                        // …then its life runs out
        XCTAssertTrue(world.projectiles.isEmpty, "expired visual shot is removed")
    }

    func testStaleInputIsDropped() {
        // Authority keeps only the freshest input per client by seq.
        let coord = SystemSyncCoordinator(localPlayerID: "A")
        let world = World(player: Ship(name: "A", stats: combatStats()))
        world.spawnRemotePlayer(Ship(name: "C", stats: combatStats()),
                                info: RemotePlayerInfo(peerID: "C", name: "C"), arrival: .populate)

        var thrust = NetIntent(); thrust.thrust = true
        coord.receiveInput(InputFrame(tick: 5, seq: 5, intent: thrust), from: "C")
        // An older frame (seq 3) with no thrust must not overwrite seq 5.
        coord.receiveInput(InputFrame(tick: 3, seq: 3, intent: NetIntent()), from: "C")

        coord.applyInputs(to: world)
        let mirror = world.remotePlayerShips.first!
        XCTAssertEqual(world.remoteIntents[mirror.entityID]?.thrust, true)
    }
}
