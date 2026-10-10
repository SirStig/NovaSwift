import XCTest
@testable import NovaSwiftEngine

/// AI-12: the player's escorts follow the player out of a gate
/// (`Stellar_HandleStellarEntryAndExit` 0x00457580) — on the gate, on the
/// player's heading, held inside for `Rand(20) + 15` ticks, then sliding out.
final class EscortGateArrivalTests: XCTestCase {
    func testEscortHoldsInsideTheGateThenSlidesOut() {
        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3),
                          position: Vec2(500, 500), angle: 1.0)
        let w = World(player: player)
        w.systemContext = SystemContext(bodies: [
            StellarBody(id: 700, position: Vec2(500.6, 500.4), radius: 40, canLand: false, isHypergate: true),
        ])
        let escort = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        escort.maxArmor = 100; escort.armor = 100; escort.maxFuel = 300; escort.fuel = 300
        escort.brain = AIBrain(aiType: .warship, govt: -1)
        w.addEscortEmergingWithPlayer(escort, gateID: 700)
        w.recruitEscort(escort)
        XCTAssertEqual(escort.position, Vec2(500, 500))
        XCTAssertEqual(escort.angle, 1.0)
        w.step(1.0 / 30.0)
        let rec = w.originalAI.record(for: escort.entityID)!
        XCTAssertEqual(rec.state, OriginalAIState.gateEmerge)
        XCTAssertTrue((13.0...34.0).contains(rec.maneuverTimer), "hold \(rec.maneuverTimer), not 60")
        XCTAssertEqual(rec.desiredSpeed, -15, "attached to the player")
        for _ in 0..<40 { w.step(1.0 / 30.0) }
        XCTAssertNotEqual(rec.state, OriginalAIState.gateEmerge, "out of the gate after the hold")
    }
}
