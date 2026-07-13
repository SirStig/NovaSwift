import XCTest
@testable import NovaSwiftNet

/// The wire envelope must round-trip every case losslessly.
final class MessageCodecTests: XCTestCase {

    private func roundTrip(_ message: NetMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try NetCodec.encode(message)
        let back = try NetCodec.decode(data)
        XCTAssertEqual(message, back, file: file, line: line)
    }

    func testPresenceRoundTrips() throws {
        try roundTrip(.presence(PlayerPresence(playerID: "A", name: "Ari",
                                               currentSystemID: 128, shipTypeHint: 42)))
        // nil shipTypeHint must survive too.
        try roundTrip(.presence(PlayerPresence(playerID: "B", name: "Bo", currentSystemID: 130)))
    }

    func testPresenceRequestRoundTrips() throws {
        try roundTrip(.presenceRequest)
    }

    func testSessionRulesRoundTrips() throws {
        try roundTrip(.sessionRules(.safe))
        try roundTrip(.sessionRules(.fullStakes))
    }

    func testInputRoundTrips() throws {
        var intent = NetIntent()
        intent.thrust = true
        intent.turnRight = true
        intent.desiredHeading = 1.25
        intent.turnScale = 0.5
        try roundTrip(.input(InputFrame(tick: 100, seq: 7, intent: intent)))
    }

    func testSnapshotRoundTrips() throws {
        let ships = [
            ShipNetState(id: 0, name: "Me", x: 1, y: 2, vx: 3, vy: 4,
                         angle: 0.5, shield: 100, armor: 80, control: .local),
            ShipNetState(id: 5, name: "Friend", x: -10, y: 20, vx: 0, vy: 0,
                         angle: 3.14, shield: 50, armor: 40, control: .remote),
            ShipNetState(id: 9, name: "Pirate", x: 0, y: 0, vx: 1, vy: 1,
                         angle: 1, shield: 10, armor: 10, control: .ai),
        ]
        try roundTrip(.snapshot(WorldSnapshot(tick: 200, ackInputSeq: 7, ships: ships)))
    }

    func testChatRoundTrips() throws {
        try roundTrip(.chat(ChatMessage(playerID: "A", senderName: "Ari",
                                        text: "come help me at Sol")))
    }
}
