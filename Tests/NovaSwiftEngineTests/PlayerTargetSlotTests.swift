import XCTest
@testable import NovaSwiftEngine

/// UI-07 closing pass: the target cycle follows the original's ship-table slots, and skips a ship
/// holding in a hypergate (AI state 0x15).
final class PlayerTargetSlotTests: XCTestCase {

    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    private func makeWorld() -> World {
        let world = World(player: Ship(name: "P", stats: stats()))
        world.player.government = 128
        return world
    }

    @discardableResult
    private func addShip(_ world: World, _ name: String) -> Ship {
        let s = Ship(name: name, stats: stats(), position: Vec2(0, 100))
        s.government = 200
        s.brain = AIBrain(aiType: .warship, govt: 200)
        world.addNPC(s)
        return s
    }

    func testSlotsFillFromOne() {
        let world = makeWorld()
        XCTAssertEqual([addShip(world, "A"), addShip(world, "B"), addShip(world, "C")].map(\.slot), [1, 2, 3])
    }

    func testAFreedSlotIsReusedAndTheCycleFollowsSlotOrder() {
        let world = makeWorld()
        let a = addShip(world, "A")
        let b = addShip(world, "B")
        let c = addShip(world, "C")
        // B leaves; the next arrival takes slot 2 and so cycles between A and C although it spawned last.
        world.removeShip(entityID: b.entityID)
        let d = addShip(world, "D")
        XCTAssertEqual(d.slot, 2, "Ship_AllocateShipSlotInSystem takes the lowest free slot")
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, a.entityID)
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, d.entityID, "slot 2 comes before slot 3")
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, c.entityID)
        XCTAssertNil(world.cyclePlayerTarget())
        // And backwards from the end.
        XCTAssertEqual(world.cyclePlayerTarget(forward: false)?.entityID, c.entityID)
        XCTAssertEqual(world.cyclePlayerTarget(forward: false)?.entityID, d.entityID)
    }

    func testAShipEmergingFromAGateIsNotCyclable() {
        let world = makeWorld()
        let a = addShip(world, "A")
        let hidden = addShip(world, "Gate")
        let c = addShip(world, "C")
        let rec = world.originalAI.ensureRecord(hidden, host: WorldAIHost(world: world, ai: world.originalAI))
        rec.state = OriginalAIState.gateEmerge
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, a.entityID)
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, c.entityID, "state 0x15 is skipped")
        XCTAssertNil(world.cyclePlayerTarget())
        // Alt-R skips it too (0x00462850).
        hidden.position = Vec2(0, 1)
        XCTAssertNotEqual(world.selectNearestEngaged()?.entityID, hidden.entityID)
    }
}
