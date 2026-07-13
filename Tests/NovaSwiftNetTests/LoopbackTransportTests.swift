import XCTest
@testable import NovaSwiftNet

/// Records raw transport callbacks for assertions.
private final class RecordingDelegate: TransportDelegate {
    var received: [(data: Data, from: PeerID)] = []
    var connected: [PeerID] = []
    var disconnected: [PeerID] = []

    func transport(_ transport: Transport, didReceive data: Data, from peer: PeerID) {
        received.append((data, peer))
    }
    func transport(_ transport: Transport, peerDidConnect peer: PeerID) {
        connected.append(peer)
    }
    func transport(_ transport: Transport, peerDidDisconnect peer: PeerID) {
        disconnected.append(peer)
    }
}

final class LoopbackTransportTests: XCTestCase {

    func testConnectAnnouncesBothDirections() {
        let net = LoopbackNetwork()
        let a = LoopbackTransport(peerID: "A", network: net)
        let b = LoopbackTransport(peerID: "B", network: net)
        let da = RecordingDelegate(); a.delegate = da
        let db = RecordingDelegate(); b.delegate = db

        a.connect()
        b.connect()

        XCTAssertEqual(da.connected, ["B"])
        XCTAssertEqual(db.connected, ["A"])
        XCTAssertEqual(Set(a.connectedPeers), ["B"])
        XCTAssertEqual(Set(b.connectedPeers), ["A"])
    }

    func testDirectSendReachesOnlyTarget() {
        let net = LoopbackNetwork()
        let a = LoopbackTransport(peerID: "A", network: net)
        let b = LoopbackTransport(peerID: "B", network: net)
        let c = LoopbackTransport(peerID: "C", network: net)
        let db = RecordingDelegate(); b.delegate = db
        let dc = RecordingDelegate(); c.delegate = dc
        a.delegate = RecordingDelegate()
        a.connect(); b.connect(); c.connect()

        let payload = Data("hi".utf8)
        a.send(payload, to: "B", channel: .reliable)

        XCTAssertEqual(db.received.count, 1)
        XCTAssertEqual(db.received.first?.from, "A")
        XCTAssertEqual(db.received.first?.data, payload)
        XCTAssertTrue(dc.received.isEmpty)
    }

    func testBroadcastReachesAllOthers() {
        let net = LoopbackNetwork()
        let a = LoopbackTransport(peerID: "A", network: net)
        let b = LoopbackTransport(peerID: "B", network: net)
        let c = LoopbackTransport(peerID: "C", network: net)
        let da = RecordingDelegate(); a.delegate = da
        let db = RecordingDelegate(); b.delegate = db
        let dc = RecordingDelegate(); c.delegate = dc
        a.connect(); b.connect(); c.connect()

        a.broadcast(Data("all".utf8), channel: .unreliable)

        XCTAssertEqual(db.received.count, 1)
        XCTAssertEqual(dc.received.count, 1)
        XCTAssertTrue(da.received.isEmpty) // never echoes to self
    }

    func testDisconnectNotifiesRemaining() {
        let net = LoopbackNetwork()
        let a = LoopbackTransport(peerID: "A", network: net)
        let b = LoopbackTransport(peerID: "B", network: net)
        let da = RecordingDelegate(); a.delegate = da
        let db = RecordingDelegate(); b.delegate = db
        a.connect(); b.connect()

        a.disconnect()

        XCTAssertEqual(db.disconnected, ["A"])
        XCTAssertEqual(b.connectedPeers, [])
    }
}
