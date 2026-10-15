import XCTest
@testable import NovaSwiftSync
@testable import NovaSwiftEngine
import NovaSwiftNet

/// Layer-2 sync fixes: faithful client loadouts, death/landing/launch handling, world-swap detection, escort survival,
/// authority-owned NPC health, kill credit, stale input and per-peer snapshots.
final class SyncFixesTests: XCTestCase {

    private func combatStats() -> ShipStats { ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi) }

    private func frame(_ seq: UInt32, loadout: ShipLoadoutNet? = nil, landed: Bool? = nil, life: UInt32? = nil,
                       ack: UInt32? = nil, thrust: Bool = false, pose: ShipPose? = nil) -> InputFrame {
        var i = NetIntent(); i.thrust = thrust
        return InputFrame(tick: seq, seq: seq, intent: i, pose: pose, loadout: loadout, landed: landed,
                          lifeID: life, ackCreditSeq: ack)
    }

    private func loadout(type: Int = -1, shield: Double = 500, armor: Double = 400, rev: UInt32? = 7,
                         curShield: Double? = nil, curArmor: Double? = nil) -> ShipLoadoutNet {
        ShipLoadoutNet(shipTypeID: type, maxShield: shield, maxArmor: armor, shieldRegenPerSec: 20,
                       armorRegenPerSec: 1, weapons: [], shield: curShield, armor: curArmor, rev: rev)
    }

    private func authority() -> (SystemSyncCoordinator, World) {
        (SystemSyncCoordinator(localPlayerID: "A"), World(player: Ship(name: "A", stats: combatStats())))
    }

    private func clientCopy(_ world: World, _ id: String = "B") -> Ship? {
        world.remotePlayerShips.first { $0.remotePlayer?.peerID == id }
    }

    // MARK: 1. Loadout

    func testLoadoutIsAppliedToTheAuthorityCopyAndAcked() {
        let (coord, world) = authority()
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        coord.receiveInput(frame(1, loadout: loadout()), from: "B")
        coord.applyInputs(to: world)
        let bo = clientCopy(world)!
        XCTAssertEqual(bo.maxShield, 500); XCTAssertEqual(bo.maxArmor, 400)
        XCTAssertEqual(bo.shieldRechargePerSec, 20); XCTAssertEqual(bo.armorRechargePerSec, 1)
        let snap = coord.snapshot(for: "B", from: coord.snapshot(of: world, tick: 1))
        XCTAssertEqual(snap.ackLoadoutRev, 7)
        XCTAssertNil(coord.snapshot(for: "C", from: coord.snapshot(of: world, tick: 1)).ackLoadoutRev)
    }

    func testFreshCopyStartsAtTheClientsRealHealthAndNeverReportsMoreThanItsMaxima() {
        let (coord, world) = authority()
        coord.receiveInput(frame(1, loadout: loadout(curShield: 30, curArmor: 120)), from: "B")
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        let bo = clientCopy(world)!
        XCTAssertEqual(bo.shield, 30); XCTAssertEqual(bo.armor, 120)
        bo.shield = 9_999; bo.armor = 9_999       // an overshoot must be clamped on the wire
        let s = coord.snapshot(of: world, tick: 1).ships.first { $0.playerID == "B" }!
        XCTAssertLessThanOrEqual(s.shield, 500); XCTAssertLessThanOrEqual(s.armor, 400)
    }

    func testClientSendsLoadoutOnChangeAndOnRefreshOnly() {
        let coord = SystemSyncCoordinator(localPlayerID: "C")
        var now = 0.0
        coord.clock = { now }
        let ship = Ship(name: "C", stats: combatStats())
        ship.maxShield = 250
        XCTAssertNotNil(coord.input(from: ControlIntent(), tick: 1, seq: 1, ship: ship).loadout)
        now = 0.5
        XCTAssertNil(coord.input(from: ControlIntent(), tick: 2, seq: 2, ship: ship).loadout, "unchanged: not resent")
        ship.shield = 3                                     // health drift alone is not a change
        XCTAssertNil(coord.input(from: ControlIntent(), tick: 3, seq: 3, ship: ship).loadout)
        ship.maxShield = 300                                // an outfit bought: sent at once, new revision
        let changed = coord.input(from: ControlIntent(), tick: 4, seq: 4, ship: ship).loadout
        XCTAssertEqual(changed?.maxShield, 300)
        now = 3
        XCTAssertNotNil(coord.input(from: ControlIntent(), tick: 5, seq: 5, ship: ship).loadout, "~2 s refresh")
    }

    func testShipTypeChangeRebuildsTheCopyKeepingItsPose() {
        let (coord, world) = authority()
        var nextType = 128
        func make(_ id: String, _ name: String) -> Ship {
            let s = Ship(name: name, stats: combatStats()); s.shipTypeID = nextType; return s
        }
        coord.syncClients([(id: "B", name: "Bo")], into: world, makeShip: make, typeOf: { _ in 128 })
        let first = clientCopy(world)!
        first.position = Vec2(50, 60); first.angle = 1
        nextType = 129
        coord.receiveInput(frame(1, loadout: loadout(type: 129)), from: "B")
        let r = coord.syncClients([(id: "B", name: "Bo")], into: world, makeShip: make, typeOf: { _ in 128 })
        XCTAssertEqual(r.injected.count, 1); XCTAssertEqual(r.removed.count, 1)
        XCTAssertEqual(world.remotePlayerShips.count, 1)
        let second = clientCopy(world)!
        XCTAssertEqual(second.shipTypeID, 129)
        XCTAssertEqual(second.position.x, 50); XCTAssertEqual(second.position.y, 60); XCTAssertEqual(second.angle, 1)
        coord.applyInputs(to: world)
        XCTAssertEqual(second.maxShield, 500)
        // Same type again: left alone.
        XCTAssertTrue(coord.syncClients([(id: "B", name: "Bo")], into: world, makeShip: make).injected.isEmpty)
    }

    // MARK: 2. Death

    func testClientDeathPropagatesAndTheCopyIsNotInstantlyRespawned() {
        let (coord, world) = authority()
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        coord.receiveInput(frame(1, life: 1), from: "B")
        let bo = clientCopy(world)!
        bo.armor = 0                                         // the authority's sim killed it
        let dead = coord.snapshot(of: world, tick: 1).ships.first { $0.playerID == "B" }
        XCTAssertEqual(dead?.destroyed, true); XCTAssertEqual(dead?.armor, 0); XCTAssertEqual(dead?.life, 1)

        world.removeShip(entityID: bo.entityID)              // the wreck finished playing out
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertTrue(world.remotePlayerShips.isEmpty, "no instant full-health re-injection")
        XCTAssertEqual(coord.snapshot(of: world, tick: 2).ships.first { $0.playerID == "B" }?.destroyed, true,
                       "the death notice outlives the wreck")
        coord.receiveInput(frame(2, life: 1), from: "B")      // still the dead life
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertTrue(world.remotePlayerShips.isEmpty)

        coord.receiveInput(frame(3, life: 2), from: "B")      // the client respawned
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertNotNil(clientCopy(world))
        XCTAssertNil(coord.snapshot(of: world, tick: 3).ships.first { $0.playerID == "B" }?.destroyed)
    }

    func testClientDiesWhenItsOwnEntryIsDestroyed() {
        let coord = SystemSyncCoordinator(localPlayerID: "B")
        let world = World(player: Ship(name: "B", stats: combatStats()))
        let dead = ShipNetState(id: -1, playerID: "B", name: "B", x: 0, y: 0, vx: 0, vy: 0, angle: 0,
                                shield: 0, armor: 0, control: .remote, destroyed: true, life: 99)
        coord.apply(WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [dead]), to: world, authorityPeer: "A")
        XCTAssertTrue(world.player.isAlive, "a notice from another life must not kill this one")
        var mine = dead; mine.life = 1
        coord.apply(WorldSnapshot(tick: 2, ackInputSeq: 0, ships: [mine]), to: world, authorityPeer: "A")
        XCTAssertFalse(world.player.isAlive)

        let safe = World(player: Ship(name: "B", stats: combatStats()))
        coord.deathReal = false
        coord.apply(WorldSnapshot(tick: 3, ackInputSeq: 0, ships: [mine]), to: safe, authorityPeer: "A")
        XCTAssertTrue(safe.player.isAlive, "death isn't real in this session")
    }

    // MARK: 3. World swap

    private func pair() -> (SystemSyncDriverTests.Node, SystemSyncDriverTests.Node) {
        let a = SystemSyncDriverTests.Node(1, system: 100, x: 0)
        let b = SystemSyncDriverTests.Node(2, system: 100, x: 500)
        for (x, y) in [(a, b), (b, a)] { x.transport.peerConnected(id: y.id, name: "p\(y.id)") }
        for _ in 0..<4 {
            for n in [a, b] { for p in n.transport.drainOutgoing() {
                (n === a ? b : a).transport.receive(from: n.id, data: p.data) } }
        }
        return (a, b)
    }

    func testANewWorldInstanceTriggersAResyncWithoutForceResync() {
        let (_, client) = pair()
        client.driver.syncPreStep(world: client.world)
        let fresh = World(player: Ship(name: "P2", stats: combatStats()))
        fresh.spawnNetworkMirror(Ship(name: "stale", stats: combatStats()))
        client.driver.syncPreStep(world: fresh)
        XCTAssertTrue(fresh.npcs.isEmpty, "stale mirrors of the new world were torn down")
        // Control: the same world again is not resynced.
        fresh.spawnNetworkMirror(Ship(name: "kept", stats: combatStats()))
        client.driver.syncPreStep(world: fresh)
        XCTAssertEqual(fresh.npcs.count, 1)
    }

    // MARK: 4. Escorts and mission ships

    func testRemoveAINPCsKeepsEscortsAndMissionShipsButDropsAmbientTraffic() {
        let world = World(player: Ship(name: "P", stats: combatStats()))
        let trader = Ship(name: "Trader", stats: combatStats())
        let escort = Ship(name: "Escort", stats: combatStats())
        escort.brain = AIBrain(aiType: .warship, govt: 0)
        escort.brain?.leaderID = World.playerEntityID
        let objective = Ship(name: "Objective", stats: combatStats())
        objective.missionID = 5
        for s in [trader, escort, objective] { world.addNPC(s, arrival: .populate) }
        world.removeAINPCs()
        XCTAssertEqual(Set(world.npcs.map(\.name)), ["Escort", "Objective"])
    }

    // MARK: 5. Mirror NPCs and kill credit

    func testHitsOnAMirrorNPCAreVisualOnly() {
        let world = World(player: Ship(name: "P", stats: combatStats()))
        let mirror = Ship(name: "Mirror", stats: combatStats())
        world.spawnNetworkMirror(mirror)
        let real = Ship(name: "Real", stats: combatStats())
        world.addNPC(real, arrival: .populate)
        let armor = mirror.armor
        world.applyHit(to: mirror, shield: 1e6, armor: 1e6, ownerID: World.playerEntityID)
        XCTAssertEqual(mirror.armor, armor); XCTAssertTrue(mirror.isAlive)
        world.applyHit(to: real, shield: 1e6, armor: 1e6, ownerID: World.playerEntityID)
        XCTAssertFalse(real.isAlive)
    }

    private func killVictim(_ world: World, by copy: Ship, mission: Int? = nil) {
        let victim = Ship(name: "Pirate", stats: combatStats())
        victim.government = 200
        victim.missionID = mission
        victim.shipTypeID = 150
        world.addNPC(victim, arrival: .populate)
        world.applyHit(to: victim, shield: 1e6, armor: 1e6, ownerID: copy.entityID)
    }

    func testKillCreditReachesItsOwnerOnlyAndReplaysOnTheClient() {
        let (coord, world) = authority()
        coord.syncClients([(id: "B", name: "Bo"), (id: "C", name: "Cy")], into: world)
        killVictim(world, by: clientCopy(world, "B")!, mission: 9)
        let base = coord.snapshot(of: world, tick: 1)
        let forB = coord.snapshot(for: "B", from: base)
        XCTAssertEqual(forB.credits?.count, 1)
        XCTAssertEqual(forB.credits?.first?.government, 200)
        XCTAssertEqual(forB.credits?.first?.missionID, 9)
        XCTAssertEqual(forB.credits?.first?.disabled, false)
        XCTAssertNil(coord.snapshot(for: "C", from: base).credits, "other players get no credit")

        // The client replays it once, as the engine's own "destroy" goal event.
        let coordB = SystemSyncCoordinator(localPlayerID: "B")
        let wb = World(player: Ship(name: "Bo", stats: combatStats()))
        coordB.apply(forB, to: wb, authorityPeer: "A")
        coordB.apply(forB, to: wb, authorityPeer: "A")                 // resent snapshot: not applied twice
        wb.step(1.0 / 30)
        coordB.flushEffects(into: wb)
        let goals = wb.events.filter {
            if case .missionShipGoalReached(9, _, .destroy, true) = $0 { return true }
            return false
        }
        XCTAssertEqual(goals.count, 1)

        // Acked credits stop being resent.
        let ack = coordB.input(from: ControlIntent(), tick: 1, seq: 1, ship: wb.player).ackCreditSeq
        XCTAssertEqual(ack, 1)
        coord.receiveInput(frame(1, ack: ack), from: "B")
        XCTAssertNil(coord.snapshot(for: "B", from: coord.snapshot(of: world, tick: 2)).credits)
    }

    // MARK: 6. Landing

    func testLandedClientLeavesNoGhostAndReturnsOnLaunch() {
        let (coord, world) = authority()
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertNotNil(clientCopy(world))
        coord.receiveInput(frame(1, landed: true), from: "B")
        let r = coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertEqual(r.removed.count, 1)
        XCTAssertTrue(world.remotePlayerShips.isEmpty)
        XCTAssertNil(coord.snapshot(of: world, tick: 1).ships.first { $0.playerID == "B" })
        coord.receiveInput(frame(2, landed: nil), from: "B")
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        XCTAssertNotNil(clientCopy(world))
    }

    func testClientSendsLandedAndKeepsItsRepairedHealthUntilTheAuthorityAcksTheFreshLoadout() {
        let coord = SystemSyncCoordinator(localPlayerID: "B")
        let world = World(player: Ship(name: "B", stats: combatStats()))
        world.player.maxShield = 100; world.player.maxArmor = 100
        world.player.shield = 100; world.player.armor = 100       // repaired on landing
        XCTAssertEqual(coord.input(from: ControlIntent(), tick: 1, seq: 1, ship: world.player, landed: true).landed, true)

        func snap(ack: UInt32?) -> WorldSnapshot {
            WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [
                ShipNetState(id: 0, playerID: "B", name: "B", x: 0, y: 0, vx: 0, vy: 0, angle: 0,
                             shield: 10, armor: 10, control: .remote)], ackLoadoutRev: ack)
        }
        coord.suspendHealthAdoption = true                          // landed
        coord.apply(snap(ack: nil), to: world, authorityPeer: "A")
        XCTAssertEqual(world.player.armor, 100)

        coord.suspendHealthAdoption = false                         // launched
        coord.beginLaunchHold()
        coord.apply(snap(ack: 0), to: world, authorityPeer: "A")    // the pre-launch copy: ignored
        XCTAssertEqual(world.player.armor, 100)
        let sent = coord.input(from: ControlIntent(), tick: 2, seq: 2, ship: world.player).loadout
        XCTAssertNotNil(sent?.rev)
        coord.apply(snap(ack: sent?.rev.map { $0 - 1 }), to: world, authorityPeer: "A")
        XCTAssertEqual(world.player.armor, 100, "authority hasn't applied the fresh loadout yet")
        coord.apply(snap(ack: sent?.rev), to: world, authorityPeer: "A")
        XCTAssertEqual(world.player.armor, 10, "confirmed: health is authoritative again")
    }

    // MARK: 8. Stale input

    func testStaleInputExpiresToAnEmptyIntent() {
        let (coord, world) = authority()
        var now = 100.0
        coord.clock = { now }
        coord.syncClients([(id: "B", name: "Bo")], into: world)
        coord.receiveInput(frame(1, thrust: true), from: "B")
        coord.applyInputs(to: world)
        let bo = clientCopy(world)!
        XCTAssertEqual(world.remoteIntents[bo.entityID]?.thrust, true)
        now += 0.3
        coord.applyInputs(to: world)
        XCTAssertEqual(world.remoteIntents[bo.entityID]?.thrust, true, "still fresh")
        now += 0.4
        coord.applyInputs(to: world)
        XCTAssertNotEqual(world.remoteIntents[bo.entityID]?.thrust, true, "silent for >0.5 s: coast, no fire")
        coord.receiveInput(frame(2, thrust: true), from: "B")
        coord.applyInputs(to: world)
        XCTAssertEqual(world.remoteIntents[bo.entityID]?.thrust, true, "a new frame revives control")
    }

    // MARK: 9. Snapshots only to co-located peers

    func testSnapshotsGoOnlyToCoLocatedPeers() {
        let n1 = SystemSyncDriverTests.Node(1, system: 100, x: 0)
        let n2 = SystemSyncDriverTests.Node(2, system: 100, x: 500)
        let n3 = SystemSyncDriverTests.Node(3, system: 200, x: 0)
        let nodes = [n1, n2, n3]
        for a in nodes { for b in nodes where a.id != b.id { a.transport.peerConnected(id: b.id, name: "p\(b.id)") } }
        func pump() {
            for _ in 0..<6 { for n in nodes { for p in n.transport.drainOutgoing() {
                let targets = p.to == -1 ? nodes.filter { $0.id != n.id } : nodes.filter { $0.id == p.to }
                for t in targets { t.transport.receive(from: n.id, data: p.data) } } } }
        }
        pump()
        var strays = 0
        n3.driver.onInvalidMessage = { _, _ in strays += 1 }
        var received2 = 0
        let previous = n2.session.onSnapshot
        n2.session.onSnapshot = { s, p in received2 += 1; previous?(s, p) }
        for _ in 0..<10 {
            for n in nodes { n.driver.syncPreStep(world: n.world); n.world.step(1.0 / 30); n.driver.syncPostStep(world: n.world) }
            pump()
        }
        XCTAssertGreaterThan(received2, 0, "the co-located client gets its snapshots")
        XCTAssertEqual(strays, 0, "a peer in another system gets none")
    }

    // MARK: Wire compatibility

    func testOldFormatMessagesStillDecode() throws {
        let intent = #"{"turnLeft":false,"turnRight":false,"thrust":true,"reverse":false,"afterburner":false,"firePrimary":false,"fireSecondary":false,"turnScale":1}"#
        let f = try JSONDecoder().decode(InputFrame.self, from: Data(#"{"tick":1,"seq":2,"intent":\#(intent)}"#.utf8))
        XCTAssertNil(f.loadout); XCTAssertNil(f.landed); XCTAssertNil(f.lifeID); XCTAssertNil(f.ackCreditSeq)
        let ship = #"{"id":3,"shipTypeID":128,"government":0,"name":"S","x":1,"y":2,"vx":0,"vy":0,"angle":0,"shield":5,"armor":6,"control":"ai"}"#
        let snap = try JSONDecoder().decode(WorldSnapshot.self, from: Data(
            #"{"tick":1,"ackInputSeq":0,"ships":[\#(ship)],"shots":[],"beams":[],"effects":[]}"#.utf8))
        XCTAssertNil(snap.credits); XCTAssertNil(snap.ackLoadoutRev); XCTAssertNil(snap.ships[0].destroyed)
        XCTAssertNil(snap.ships[0].life)

        // New fields round-trip.
        let full = InputFrame(tick: 1, seq: 1, intent: NetIntent(), loadout: loadout(), landed: true, lifeID: 4, ackCreditSeq: 2)
        guard case let .input(back) = try NetCodec.decode(try NetCodec.encode(.input(full))) else { return XCTFail() }
        XCTAssertEqual(back, full)
        XCTAssertTrue(NetValidation.valid(back))
        var bad = full; bad.loadout?.maxShield = .nan
        XCTAssertFalse(NetValidation.valid(bad))
    }
}
