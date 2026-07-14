import XCTest
@testable import NovaSwiftNet

/// Layer 2 (per-system sim sync) transport plumbing: a client streams its
/// `InputFrame` to the authority, and the authority streams `WorldSnapshot`s
/// back. `NetSession` only carries these on the wire and fires callbacks with the
/// sending peer — the World↔wire mapping and authority selection live app-side.
final class Layer2SyncTests: XCTestCase {

    private func makeSessions(_ ids: [String]) -> [NetSession] {
        let net = LoopbackNetwork()
        var transports: [LoopbackTransport] = []
        var sessions: [NetSession] = []
        for id in ids {
            let t = LoopbackTransport(peerID: id, network: net)
            sessions.append(NetSession(transport: t))
            transports.append(t)
        }
        for t in transports { t.connect() }
        return sessions
    }

    private func thrustFrame(tick: UInt32, seq: UInt32) -> InputFrame {
        var intent = NetIntent()
        intent.thrust = true
        return InputFrame(tick: tick, seq: seq, intent: intent)
    }

    func testInputReachesAuthorityTaggedWithSender() {
        let s = makeSessions(["authority", "client"])
        let authority = s[0], client = s[1]

        var received: [(InputFrame, PeerID)] = []
        authority.onInput = { frame, peer in received.append((frame, peer)) }

        let frame = thrustFrame(tick: 7, seq: 3)
        client.sendInput(frame, to: "authority")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, frame)
        XCTAssertEqual(received.first?.1, "client")     // peer id == player id
        XCTAssertTrue(received.first?.0.intent.thrust == true)
    }

    func testSnapshotReachesClientTaggedWithAuthority() {
        let s = makeSessions(["authority", "client"])
        let authority = s[0], client = s[1]

        var received: [(WorldSnapshot, PeerID)] = []
        client.onSnapshot = { snap, peer in received.append((snap, peer)) }

        let snap = WorldSnapshot(tick: 12, ackInputSeq: 3, ships: [
            ShipNetState(id: 0, name: "Authority", x: 1, y: 2, vx: 0, vy: 0,
                         angle: 0, shield: 100, armor: 100, control: .remote),
            ShipNetState(id: 5, name: "Client", x: 3, y: 4, vx: 0, vy: 0,
                         angle: .pi, shield: 50, armor: 80, control: .local),
        ])
        authority.sendSnapshot(snap, to: "client")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, snap)
        XCTAssertEqual(received.first?.1, "authority")
        XCTAssertEqual(received.first?.0.ships.count, 2)
    }

    func testBroadcastSnapshotReachesAllClientsNotSelf() {
        let s = makeSessions(["authority", "c1", "c2"])
        let authority = s[0]

        var c1: [WorldSnapshot] = [], c2: [WorldSnapshot] = [], selfEcho: [WorldSnapshot] = []
        s[1].onSnapshot = { snap, _ in c1.append(snap) }
        s[2].onSnapshot = { snap, _ in c2.append(snap) }
        authority.onSnapshot = { snap, _ in selfEcho.append(snap) }

        let snap = WorldSnapshot(tick: 1, ackInputSeq: 0, ships: [])
        authority.broadcastSnapshot(snap)

        XCTAssertEqual(c1, [snap])
        XCTAssertEqual(c2, [snap])
        XCTAssertTrue(selfEcho.isEmpty, "an authority shouldn't receive its own broadcast")
    }

    func testInputAndSnapshotRoundTripStream() {
        // A short bidirectional exchange: client sends 3 inputs, authority replies
        // with a snapshot after each — the basic Layer-2 loop shape.
        let s = makeSessions(["authority", "client"])
        let authority = s[0], client = s[1]

        var inputs: [InputFrame] = []
        var snaps: [WorldSnapshot] = []
        authority.onInput = { frame, _ in
            inputs.append(frame)
            authority.sendSnapshot(WorldSnapshot(tick: frame.tick, ackInputSeq: frame.seq, ships: []),
                                   to: "client")
        }
        client.onSnapshot = { snap, _ in snaps.append(snap) }

        for i in 1...3 { client.sendInput(thrustFrame(tick: UInt32(i), seq: UInt32(i)), to: "authority") }

        XCTAssertEqual(inputs.map(\.seq), [1, 2, 3])
        XCTAssertEqual(snaps.map(\.ackInputSeq), [1, 2, 3])
    }
}
