import XCTest
@testable import NovaSwiftNet

/// Session-wide chat: delivered to every peer over the reliable channel,
/// independent of co-location, with a retained history that renders the sender's
/// name even after they leave.
final class ChatTests: XCTestCase {

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

    func testChatReachesAllPeersAndSelf() {
        let s = makeSessions(["A", "B", "C"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[1].updateLocalPresence(name: "Bo", systemID: 200)
        s[2].updateLocalPresence(name: "Cy", systemID: 300)

        s[0].sendChat("hello everyone")

        // Sender sees it in its own log immediately...
        XCTAssertEqual(s[0].chatLog.map(\.text), ["hello everyone"])
        // ...and it reaches peers in different systems (session-wide, not local).
        XCTAssertEqual(s[1].chatLog.count, 1)
        XCTAssertEqual(s[2].chatLog.count, 1)
        XCTAssertEqual(s[1].chatLog.first?.senderName, "Ari")
        XCTAssertEqual(s[1].chatLog.first?.playerID, "A")
    }

    func testChatOrderingAcrossSenders() {
        let s = makeSessions(["A", "B"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[1].updateLocalPresence(name: "Bo", systemID: 100)

        s[0].sendChat("one")
        s[1].sendChat("two")
        s[0].sendChat("three")

        let expected = ["one", "two", "three"]
        XCTAssertEqual(s[0].chatLog.map(\.text), expected)
        XCTAssertEqual(s[1].chatLog.map(\.text), expected)
        XCTAssertEqual(s[0].chatLog.map(\.senderName), ["Ari", "Bo", "Ari"])
    }

    func testOnChatCallbackFiresForSentAndReceived() {
        let s = makeSessions(["A", "B"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        var aSeen: [String] = []
        var bSeen: [String] = []
        s[0].onChat = { aSeen.append($0.text) }
        s[1].onChat = { bSeen.append($0.text) }

        s[0].sendChat("ping")

        XCTAssertEqual(aSeen, ["ping"]) // fires for locally-sent too
        XCTAssertEqual(bSeen, ["ping"])
    }

    func testBlankChatIsIgnored() {
        let s = makeSessions(["A", "B"])
        s[0].updateLocalPresence(name: "Ari", systemID: 100)
        s[0].sendChat("   \n  ")
        XCTAssertTrue(s[0].chatLog.isEmpty)
        XCTAssertTrue(s[1].chatLog.isEmpty)
    }

    func testHistorySurvivesSenderDisconnect() {
        let net = LoopbackNetwork()
        let tA = LoopbackTransport(peerID: "A", network: net)
        let tB = LoopbackTransport(peerID: "B", network: net)
        let sA = NetSession(transport: tA)
        let sB = NetSession(transport: tB)
        tA.connect(); tB.connect()
        sA.updateLocalPresence(name: "Ari", systemID: 100)
        sB.updateLocalPresence(name: "Bo", systemID: 100)

        sA.sendChat("bye")
        tA.disconnect()

        // A's presence is gone, but the message still renders "Ari".
        XCTAssertNil(sB.presence["A"])
        XCTAssertEqual(sB.chatLog.first?.senderName, "Ari")
        XCTAssertEqual(sB.chatLog.first?.text, "bye")
    }

    func testLocalDisplayNameFallsBackToID() {
        let s = makeSessions(["A", "B"])
        // A never announced presence → name defaults to its id in chat.
        s[0].sendChat("no presence yet")
        XCTAssertEqual(s[1].chatLog.first?.senderName, "A")
    }
}
