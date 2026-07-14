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
