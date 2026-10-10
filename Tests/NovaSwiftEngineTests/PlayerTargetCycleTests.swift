import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// UI-07: the original's target cycle walks ships in arrival order with no
/// wrap and no range limit, and keeps the player's escorts in a list of their
/// own; R picks the nearest ship attacking the squad.
final class PlayerTargetCycleTests: XCTestCase {

    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    private func makeWorld() -> World {
        let world = World(player: Ship(name: "P", stats: stats()))
        world.player.government = 128
        return world
    }

    @discardableResult
    private func addShip(_ world: World, _ name: String, distance: Double, escort: Bool = false) -> Ship {
        let s = Ship(name: name, stats: stats(), position: Vec2(0, distance))
        s.government = 200
        let brain = AIBrain(aiType: .warship, govt: 200)
        if escort { brain.leaderID = World.playerEntityID }
        s.brain = brain
        world.addNPC(s)
        return s
    }

    func testCycleRunsInSpawnOrderThenClears() {
        let world = makeWorld()
        let far = addShip(world, "Far", distance: 5000)
        let near = addShip(world, "Near", distance: 100)
        let mid = addShip(world, "Mid", distance: 900)
        addShip(world, "Escort", distance: 50, escort: true)

        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, far.entityID, "5000 px away is reachable")
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, near.entityID)
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, mid.entityID)
        XCTAssertNil(world.cyclePlayerTarget(), "past the last ship: No Target, no wrap")
        XCTAssertNil(world.player.currentTargetID)
        XCTAssertEqual(world.cyclePlayerTarget()?.entityID, far.entityID, "then it starts over")
    }

    func testSquadCycleTakesOnlyEscorts() {
        let world = makeWorld()
        addShip(world, "Stranger", distance: 100)
        let escort = addShip(world, "Escort", distance: 50, escort: true)
        XCTAssertEqual(world.cyclePlayerTarget(squad: true)?.entityID, escort.entityID)
        XCTAssertNil(world.cyclePlayerTarget(squad: true))
    }

    func testCycleBackward() {
        let world = makeWorld()
        let a = addShip(world, "A", distance: 100)
        let b = addShip(world, "B", distance: 200)
        XCTAssertEqual(world.cyclePlayerTarget(forward: false)?.entityID, b.entityID)
        XCTAssertEqual(world.cyclePlayerTarget(forward: false)?.entityID, a.entityID)
        XCTAssertNil(world.cyclePlayerTarget(forward: false))
    }

    func testNearestHostileMeansAttackingTheSquadWithNoRangeCap() {
        let world = makeWorld()
        let idle = addShip(world, "Idle", distance: 100)
        let attacker = addShip(world, "Attacker", distance: 8000)
        let rec = record(world, attacker)
        rec.state = OriginalAIState.attack
        rec.primary = World.playerEntityID
        XCTAssertEqual(world.selectNearestHostileThreat()?.entityID, attacker.entityID)
        XCTAssertEqual(world.selectNearestEngaged()?.entityID, idle.entityID)
    }

    /// `Ship_IsThreatToPlayerSquad` (0x0040f6d0): any engaged state counts,
    /// but not a coasting ship, one in a disengaged state, or one after a
    /// ship the player doesn't lead directly.
    func testThreatToSquadIsTheOriginalRule() {
        let world = makeWorld()
        let escort = addShip(world, "Escort", distance: 50, escort: true)
        let fighter = addShip(world, "Fighter", distance: 60)
        fighter.brain?.leaderID = escort.entityID
        let npc = addShip(world, "Npc", distance: 400)
        let rec = record(world, npc)
        rec.primary = World.playerEntityID
        rec.state = OriginalAIState.travel
        XCTAssertTrue(world.isThreatToPlayerSquad(npc), "the state need not be attack")
        rec.state = OriginalAIState.escortStation
        XCTAssertFalse(world.isThreatToPlayerSquad(npc), "state 0x0a is disengaged")
        rec.state = OriginalAIState.attack
        rec.maneuverTimer = 5
        XCTAssertFalse(world.isThreatToPlayerSquad(npc), "coasting on the maneuver timer")
        rec.maneuverTimer = 0
        rec.primary = escort.entityID
        XCTAssertTrue(world.isThreatToPlayerSquad(npc))
        rec.primary = fighter.entityID
        XCTAssertFalse(world.isThreatToPlayerSquad(npc), "only one level of the squad")
    }

    private func record(_ world: World, _ ship: Ship) -> OriginalAIShipState {
        world.originalAI.ensureRecord(ship, host: WorldAIHost(world: world, ai: world.originalAI))
    }
}
