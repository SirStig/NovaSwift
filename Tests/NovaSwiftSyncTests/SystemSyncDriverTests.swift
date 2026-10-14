import XCTest
@testable import NovaSwiftSync
import NovaSwiftEngine
import NovaSwiftNet

/// The Godot path end to end: `ExternalTransport` pumped like the bridge does,
/// `NetSession` + `SystemSyncDriver` per node, real engine `World`s. Proves join,
/// presence, co-located system sync and authority handoff with no app and no sockets.
final class SystemSyncDriverTests: XCTestCase {

    final class Node {
        let id: Int
        let transport: ExternalTransport
        let session: NetSession
        let driver: SystemSyncDriver
        let world: World
        init(_ id: Int, system: Int, x: Double) {
            self.id = id
            transport = ExternalTransport(localPeerID: id)
            session = NetSession(transport: transport, rules: .safe)
            driver = SystemSyncDriver(session: session, localSystemID: system)
            world = World(player: Ship(name: "P\(id)",
                                       stats: ShipStats(maxSpeed: 100, acceleration: 50, turnRate: .pi),
                                       position: Vec2(x, 0)))
            session.onInput = { [driver] f, p in driver.receiveInput(f, from: p) }
            session.onSnapshot = { [driver] s, p in driver.receiveSnapshot(s, from: p) }
            session.updateLocalPresence(name: "P\(id)", systemID: system)
        }
    }

    private func pump(_ nodes: [Node], alive: Set<Int>) {
        for _ in 0..<10 {
            var moved = false
            for n in nodes where alive.contains(n.id) {
                for p in n.transport.drainOutgoing() {
                    moved = true
                    let targets = p.to == -1 ? nodes.filter { $0.id != n.id } : nodes.filter { $0.id == p.to }
                    for t in targets where alive.contains(t.id) { t.transport.receive(from: n.id, data: p.data) }
                }
            }
            if !moved { break }
        }
    }

    private func connect(_ nodes: [Node]) {
        for a in nodes { for b in nodes where a.id != b.id { a.transport.peerConnected(id: b.id, name: "p\(b.id)") } }
    }

    /// One 30 Hz tick on every live node, then deliver the packets.
    private func tick(_ nodes: [Node], alive: Set<Int>) {
        for n in nodes where alive.contains(n.id) {
            n.driver.syncPreStep(world: n.world)
            n.world.step(1.0 / 30.0)
            n.driver.syncPostStep(world: n.world)
        }
        pump(nodes, alive: alive)
    }

    func testCoLocatedSyncAndAuthorityHandoff() {
        let nodes = [Node(1, system: 100, x: 0), Node(2, system: 100, x: 500), Node(3, system: 100, x: -500)]
        var alive: Set<Int> = [1, 2, 3]
        connect(nodes); pump(nodes, alive: alive)

        // Presence converged; smallest id is the authority everywhere.
        for n in nodes {
            XCTAssertEqual(Set(n.session.presence.keys), ["1", "2", "3"])
            XCTAssertEqual(n.driver.currentAuthorityID, "1")
            XCTAssertTrue(n.driver.isSyncingSystem)
        }

        for _ in 0..<20 { tick(nodes, alive: alive) }

        // Authority holds a driven ship for each client; each client mirrors the others.
        XCTAssertEqual(Set(nodes[0].world.remotePlayerShips.compactMap { $0.remotePlayer?.peerID }), ["2", "3"])
        XCTAssertEqual(Set(nodes[1].world.remotePlayerShips.compactMap { $0.remotePlayer?.peerID }), ["1", "3"])
        XCTAssertEqual(Set(nodes[2].world.remotePlayerShips.compactMap { $0.remotePlayer?.peerID }), ["1", "2"])

        // Authority (1) drops: 2 takes over (smallest remaining), 3 re-targets it and keeps 1's... gone.
        alive.remove(1)
        for n in nodes where alive.contains(n.id) { n.transport.peerDisconnected(id: 1) }
        pump(nodes, alive: alive)
        for n in nodes where alive.contains(n.id) { XCTAssertEqual(n.driver.currentAuthorityID, "2") }

        for _ in 0..<20 { tick(nodes, alive: alive) }
        XCTAssertTrue(nodes[1].world.remotePlayerShips.contains { $0.remotePlayer?.peerID == "3" },
                      "new authority drives the remaining client")
        XCTAssertTrue(nodes[2].world.remotePlayerShips.contains { $0.remotePlayer?.peerID == "2" },
                      "client mirrors the new authority's player")

        // Last other player leaves: back to the single-player sim, mirrors cleared.
        alive.remove(3)
        nodes[1].transport.peerDisconnected(id: 3)
        XCTAssertNil(nodes[1].driver.currentAuthorityID)
        nodes[1].driver.syncPreStep(world: nodes[1].world)
        XCTAssertTrue(nodes[1].world.remotePlayerShips.isEmpty)
    }

    func testDifferentSystemsArePresenceOnly() {
        let nodes = [Node(1, system: 100, x: 0), Node(2, system: 200, x: 0)]
        let alive: Set<Int> = [1, 2]
        connect(nodes); pump(nodes, alive: alive)
        for n in nodes {
            XCTAssertEqual(n.session.presence.count, 2)
            XCTAssertNil(n.driver.currentAuthorityID)
        }
        for _ in 0..<5 { tick(nodes, alive: alive) }
        XCTAssertTrue(nodes[0].world.remotePlayerShips.isEmpty)
        XCTAssertTrue(nodes[1].world.remotePlayerShips.isEmpty)

        // Player 2 jumps into 100: now co-located and syncing.
        nodes[1].driver.setLocalSystem(100)
        nodes[1].session.updateLocalPresence(name: "P2", systemID: 100)
        pump(nodes, alive: alive)
        XCTAssertEqual(nodes[0].driver.currentAuthorityID, "1")
        for _ in 0..<10 { tick(nodes, alive: alive) }
        XCTAssertEqual(nodes[1].world.remotePlayerShips.count, 1)
    }
}
