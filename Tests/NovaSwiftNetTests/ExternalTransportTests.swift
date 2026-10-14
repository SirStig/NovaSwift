import XCTest
@testable import NovaSwiftNet

/// `ExternalTransport` is pumped by a host frontend (Godot/ENet). These tests play the
/// frontend: drain each node's outgoing queue and feed it to the destination's `receive`.
final class ExternalTransportTests: XCTestCase {

    final class Node {
        let id: Int
        let transport: ExternalTransport
        let session: NetSession
        init(_ id: Int, rules: SessionRules = .fullStakes) {
            self.id = id
            transport = ExternalTransport(localPeerID: id)
            session = NetSession(transport: transport, rules: rules)
        }
    }

    /// Fully connect every pair (what Godot's relayed multiplayer peer reports).
    static func connect(_ nodes: [Node]) {
        for a in nodes { for b in nodes where a.id != b.id {
            a.transport.peerConnected(id: b.id, name: "p\(b.id)")
        } }
    }

    /// One frontend frame: deliver everything queued, repeat until quiescent.
    static func pump(_ nodes: [Node], alive: Set<Int>? = nil) {
        let live = alive ?? Set(nodes.map(\.id))
        for _ in 0..<10 {
            var moved = false
            for n in nodes where live.contains(n.id) {
                for p in n.transport.drainOutgoing() {
                    moved = true
                    let targets = p.to == -1 ? nodes.filter { $0.id != n.id } : nodes.filter { $0.id == p.to }
                    for t in targets where live.contains(t.id) { t.transport.receive(from: n.id, data: p.data) }
                }
            }
            if !moved { break }
        }
    }

    func testPeerIDsAreDecimalStrings() {
        let t = ExternalTransport(localPeerID: 42)
        XCTAssertEqual(t.localPeerID, "42")
        t.peerConnected(id: 7, name: "x"); t.peerConnected(id: 3, name: "y")
        XCTAssertEqual(t.connectedPeers, ["3", "7"])
        XCTAssertEqual(t.peerName(7), "x")
    }

    func testSendAndBroadcastChannelsAndTargets() {
        let t = ExternalTransport(localPeerID: 1)
        t.broadcast(Data([9]), channel: .reliable)                   // nobody connected: dropped
        XCTAssertTrue(t.drainOutgoing().isEmpty)
        t.peerConnected(id: 2, name: "b"); t.peerConnected(id: 3, name: "c")
        t.send(Data([1, 2]), to: "2", channel: .unreliable)
        t.broadcast(Data([3]), channel: .reliable)
        let out = t.drainOutgoing()
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].to, 2); XCTAssertFalse(out[0].reliable); XCTAssertEqual(out[0].data, [1, 2])
        XCTAssertEqual(out[1].to, -1); XCTAssertTrue(out[1].reliable); XCTAssertEqual(out[1].data, [3])
        XCTAssertTrue(t.drainOutgoing().isEmpty)
    }

    func testConnectIsIdempotentAndDisconnectNotifiesOnce() {
        final class D: TransportDelegate {
            var connects = 0, disconnects = 0, bytes: [UInt8] = []
            func transport(_ t: Transport, didReceive data: Data, from peer: PeerID) { bytes = [UInt8](data) }
            func transport(_ t: Transport, peerDidConnect peer: PeerID) { connects += 1 }
            func transport(_ t: Transport, peerDidDisconnect peer: PeerID) { disconnects += 1 }
        }
        let t = ExternalTransport(localPeerID: 1); let d = D(); t.delegate = d
        t.peerConnected(id: 2, name: "b"); t.peerConnected(id: 2, name: "b")
        t.peerConnected(id: 1, name: "self")                          // self ignored
        t.receive(from: 2, data: [5, 6])
        t.peerDisconnected(id: 2); t.peerDisconnected(id: 2)
        XCTAssertEqual(d.connects, 1); XCTAssertEqual(d.disconnects, 1); XCTAssertEqual(d.bytes, [5, 6])
    }

    func testUnreliableOverflowDropsOldestUnreliableOnly() {
        let t = ExternalTransport(localPeerID: 1)
        t.maxQueuedPackets = 3
        t.peerConnected(id: 2, name: "b")
        t.send(Data([0]), to: "2", channel: .reliable)
        for i in 1...4 { t.send(Data([UInt8(i)]), to: "2", channel: .unreliable) }
        let out = t.drainOutgoing()
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out[0].reliable)
        XCTAssertEqual(out.dropFirst().map { $0.data[0] }, [3, 4])
    }

    func testJoinPresenceChatAndRulesOverExternalTransport() {
        let host = Node(1, rules: .safe)
        host.session.providesRules = true
        let guest = Node(2, rules: .safe)
        host.session.broadcastRules(.fullStakes)
        host.session.updateLocalPresence(name: "Host", systemID: 128)
        guest.session.updateLocalPresence(name: "Guest", systemID: 128)

        Self.connect([host, guest]); Self.pump([host, guest])

        XCTAssertEqual(Set(host.session.presence.keys), ["1", "2"])
        XCTAssertEqual(Set(guest.session.presence.keys), ["1", "2"])
        XCTAssertEqual(guest.session.coLocatedPlayers().map(\.playerID), ["1"])
        XCTAssertEqual(guest.session.sessionRules, .fullStakes, "late joiner gets the host's rules")

        guest.session.sendChat("hello")
        Self.pump([host, guest])
        XCTAssertEqual(host.session.chatLog.last?.text, "hello")
        XCTAssertEqual(host.session.chatLog.last?.playerID, "2")
    }

    func testLeaveDropsPresenceAndKickReachesTarget() {
        let host = Node(1); host.session.providesRules = true
        let guest = Node(2, rules: .safe)
        host.session.updateLocalPresence(name: "H", systemID: 1)
        guest.session.updateLocalPresence(name: "G", systemID: 1)
        Self.connect([host, guest]); Self.pump([host, guest])

        var kicked = false
        guest.session.onKicked = { kicked = true }
        host.session.kick("2")
        Self.pump([host, guest])
        XCTAssertTrue(kicked)
        XCTAssertNil(host.session.presence["2"])

        guest.session.updateLocalPresence(name: "G", systemID: 1)
        host.transport.peerDisconnected(id: 2)
        XCTAssertNil(host.session.presence["2"])
    }
}
