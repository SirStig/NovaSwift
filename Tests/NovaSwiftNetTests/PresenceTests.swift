import XCTest
@testable import NovaSwiftNet

/// Layer 1 presence: the always-on who-is-in-which-system view that drives the
/// galaxy-map markers and co-location detection.
final class PresenceTests: XCTestCase {

    /// Build `ids.count` sessions all connected on one loopback switchboard.
    private func makeSessions(_ ids: [String],
                              rules: SessionRules = .fullStakes) -> [NetSession] {
        let net = LoopbackNetwork()
        var transports: [LoopbackTransport] = []
        var sessions: [NetSession] = []
        for id in ids {
            let t = LoopbackTransport(peerID: id, network: net)
            sessions.append(NetSession(transport: t, rules: rules))
            transports.append(t)
        }
        for t in transports { t.connect() }
        return sessions
    }

    func testPresenceConvergesAcrossAllPeers() {
        let s = makeSessions(["A", "B", "C"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[1].updateLocalPresence(name: "Bo", systemID: 200)
        s[2].updateLocalPresence(name: "Cy", systemID: 100)

        for session in s {
            XCTAssertEqual(Set(session.presence.keys), ["A", "B", "C"])
            XCTAssertEqual(session.presence["A"]?.currentSystemID, 100)
            XCTAssertEqual(session.presence["B"]?.currentSystemID, 200)
            XCTAssertEqual(session.presence["C"]?.name, "Cy")
        }
    }

    func testCoLocationDetection() {
        let s = makeSessions(["A", "B", "C"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[1].updateLocalPresence(name: "Bo", systemID: 200)
        s[2].updateLocalPresence(name: "Cy", systemID: 100)

        // A and C share system 100; B is alone in 200.
        XCTAssertEqual(s[0].coLocatedPlayers().map(\.playerID), ["C"])
        XCTAssertEqual(s[2].coLocatedPlayers().map(\.playerID), ["A"])
        XCTAssertTrue(s[1].coLocatedPlayers().isEmpty)
        XCTAssertEqual(s[0].players(inSystem: 100).map(\.playerID), ["A", "C"])
    }

    func testMovingSystemUpdatesCoLocation() {
        let s = makeSessions(["A", "B"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[1].updateLocalPresence(name: "Bo", systemID: 200)
        XCTAssertTrue(s[0].coLocatedPlayers().isEmpty)

        // Bo jumps to Ari's system — the "come help me" moment.
        s[1].updateLocalPresence(name: "Bo", systemID: 100)

        XCTAssertEqual(s[0].coLocatedPlayers().map(\.playerID), ["B"])
        XCTAssertEqual(s[1].coLocatedPlayers().map(\.playerID), ["A"])
    }

    func testLateJoinerConverges() {
        let net = LoopbackNetwork()
        let tA = LoopbackTransport(peerID: "A", network: net)
        let tB = LoopbackTransport(peerID: "B", network: net)
        let sA = NetSession(transport: tA)
        let sB = NetSession(transport: tB)
        tA.connect(); tB.connect()
        sA.updateLocalPresence(name: "Ari", systemID: 100)
        sB.updateLocalPresence(name: "Bo", systemID: 100)

        // C joins after A and B are established.
        let tC = LoopbackTransport(peerID: "C", network: net)
        let sC = NetSession(transport: tC)
        tC.connect()

        // On connect, C should already have learned A and B via presenceRequest.
        XCTAssertEqual(Set(sC.presence.keys), ["A", "B"])

        // Once C announces itself, everyone converges to all three.
        sC.updateLocalPresence(name: "Cy", systemID: 100)
        XCTAssertEqual(Set(sA.presence.keys), ["A", "B", "C"])
        XCTAssertEqual(Set(sB.presence.keys), ["A", "B", "C"])
        XCTAssertEqual(Set(sC.presence.keys), ["A", "B", "C"])
    }

    func testDisconnectRemovesPresence() {
        let net = LoopbackNetwork()
        let tA = LoopbackTransport(peerID: "A", network: net)
        let tB = LoopbackTransport(peerID: "B", network: net)
        let sA = NetSession(transport: tA)
        let sB = NetSession(transport: tB)
        tA.connect(); tB.connect()
        sA.updateLocalPresence(name: "Ari", systemID: 100)
        sB.updateLocalPresence(name: "Bo", systemID: 100)
        XCTAssertEqual(Set(sB.presence.keys), ["A", "B"])

        tA.disconnect()

        XCTAssertEqual(Set(sB.presence.keys), ["B"])
        XCTAssertTrue(sB.coLocatedPlayers().isEmpty)
    }

    func testPresenceChangeCallbackFires() {
        let s = makeSessions(["A", "B"])
        var bChanges = 0
        s[1].onPresenceChanged = { _ in bChanges += 1 }

        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        XCTAssertGreaterThanOrEqual(bChanges, 1)

        // A re-announcing the SAME presence should not spam the callback.
        let before = bChanges
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        XCTAssertEqual(bChanges, before)
    }

    func testRulesPropagateFromHost() {
        let s = makeSessions(["A", "B"], rules: .fullStakes)
        var received: SessionRules?
        s[1].onRulesChanged = { received = $0 }

        s[0].broadcastRules(.safe)

        XCTAssertEqual(s[1].sessionRules, .safe)
        XCTAssertEqual(received, .safe)
    }
}
