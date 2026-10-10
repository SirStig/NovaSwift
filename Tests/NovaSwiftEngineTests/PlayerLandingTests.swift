import XCTest
@testable import NovaSwiftEngine

/// FL-12 / UI-08: the square envelope, the 0.75 px/tick per-axis gate and the
/// land hint. Play-test bug: a ship parked on Earth right after takeoff read
/// "Slow down to land" forever — the hint blamed speed when the missing step
/// was the first (request) press.
final class PlayerLandingTests: XCTestCase {

    func testEnvelopeAndSpeedMatchTheOriginal() {
        // A 96 px planet: R = round(96 × 1.75) = 168.
        XCTAssertEqual(PlayerLanding.reach(radius: 48), 168)
        XCTAssertTrue(PlayerLanding.inEnvelope(offset: Vec2(160, 160), radius: 48))
        XCTAssertFalse(PlayerLanding.inEnvelope(offset: Vec2(0, 168), radius: 48))
        XCTAssertEqual(PlayerLanding.perAxisSpeedLimit, 22.5, accuracy: 1e-9)
        XCTAssertTrue(PlayerLanding.isSlowEnough(Vec2(22.5, -22.5)))
        XCTAssertFalse(PlayerLanding.isSlowEnough(Vec2(0, 23)))
        XCTAssertTrue(PlayerLanding.isSlowEnough(Vec2()), "parked after takeoff")
    }

    func testParkedShipBeforeClearanceIsAskedToRequestNotToSlowDown() {
        // Stationary on the pad, not yet cleared: the next press is the request.
        XCTAssertEqual(PlayerLanding.prompt(canLandNow: false, slowEnough: true, needsRequest: true, cloaked: false),
                       .request)
        // Cleared and slow: land.
        XCTAssertEqual(PlayerLanding.prompt(canLandNow: true, slowEnough: true, needsRequest: false, cloaked: false),
                       .land)
        // Only real speed reads "slow down".
        XCTAssertEqual(PlayerLanding.prompt(canLandNow: false, slowEnough: false, needsRequest: true, cloaked: false),
                       .slowDown)
        XCTAssertEqual(PlayerLanding.prompt(canLandNow: false, slowEnough: false, needsRequest: false, cloaked: false),
                       .slowDown)
        XCTAssertEqual(PlayerLanding.prompt(canLandNow: false, slowEnough: true, needsRequest: false, cloaked: true),
                       .none)
    }
}
