import XCTest
@testable import NovaSwiftNet

/// Host moderation: kick removes a player and tells them to leave; ban also
/// blacklists the id so a rejoin is refused for the rest of the session.
final class ModerationTests: XCTestCase {

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

    func testKickNotifiesTargetAndDropsPresence() {
        let s = makeSessions(["host", "guest"])
        let host = s[0], guest = s[1]
        host.updateLocalPresence(name: "Host", systemID: 1)
        guest.updateLocalPresence(name: "Guest", systemID: 1)

        var kicked = false
        guest.onKicked = { kicked = true }

        XCTAssertNotNil(host.presence["guest"])
        host.kick("guest")

        XCTAssertTrue(kicked, "the kicked player is told to leave")
        XCTAssertNil(host.presence["guest"], "the host drops the kicked player's presence")
    }

    func testBanRefusesRejoinPresence() {
        let s = makeSessions(["host", "guest"])
        let host = s[0], guest = s[1]
        guest.updateLocalPresence(name: "Guest", systemID: 1)
        XCTAssertNotNil(host.presence["guest"])

        host.ban("guest")
        XCTAssertTrue(host.isBanned("guest"))
        XCTAssertNil(host.presence["guest"])

        // A banned player re-announcing is ignored by the host.
        guest.updateLocalPresence(name: "Guest", systemID: 2)
        XCTAssertNil(host.presence["guest"], "a banned player's presence is refused")
    }

    func testCannotKickYourself() {
        let s = makeSessions(["host"])
        s[0].updateLocalPresence(name: "Host", systemID: 1)
        s[0].kick("host")
        XCTAssertNotNil(s[0].presence["host"], "kicking yourself is a no-op")
    }
}
