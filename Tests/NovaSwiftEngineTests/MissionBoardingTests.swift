import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

final class MissionBoardingTests: XCTestCase {
    private func stats() -> ShipStats {
        ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)
    }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        let word = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
        bytes[offset] = UInt8(word >> 8)
        bytes[offset + 1] = UInt8(word & 0xff)
    }

    /// The Take Sample mission's important resource properties: a Wraith hull
    /// supplied by a dude whose government starts its ships disabled.
    private func derelictMissionWorld(count: Int = 1) -> (World, [Int]) {
        var hull = [UInt8](repeating: 0, count: 2000)
        put16(&hull, 2, 675)
        put16(&hull, 12, 40)
        put16(&hull, 14, 675)
        var government = [UInt8](repeating: 0, count: 200)
        put16(&government, 2, 0x0c80) // starts disabled; cannot be hailed
        var dude = [UInt8](repeating: 0, count: 88)
        put16(&dude, 0, AIType.braveTrader.rawValue)
        put16(&dude, 2, 159)
        put16(&dude, 8, 185)
        put16(&dude, 40, 100)
        var resources = ResourceCollection()
        resources.add(Resource(type: NovaType.ship, id: 185, name: "Wraith (Adult)", data: Data(hull)))
        resources.add(Resource(type: NovaType.govt, id: 159, name: "Wraith", data: Data(government)))
        resources.add(Resource(type: NovaType.dude, id: 186, name: "Wraith", data: Data(dude)))
        let world = World(player: Ship(name: "Player", stats: stats()))
        world.galaxy = Galaxy(game: NovaGame(resources))
        let ids = world.spawnMissionShips(missionID: 155, dudeID: 186, count: count,
                                          goal: .board, arrival: .populate)
        _ = world.drainEvents()
        return (world, ids)
    }

    private func missionTarget(in world: World, goal: MissionShipGoal, disabled: Bool = false) -> Ship {
        let target = Ship(name: "Target", stats: stats())
        target.shield = 0
        target.maxArmor = 100
        target.armor = disabled ? 2 : 100
        target.disabled = disabled
        target.missionID = 42
        target.missionShipGoal = goal
        world.addNPC(target)
        _ = world.drainEvents()
        return target
    }

    private func reachedGoals(_ events: [WorldEvent]) -> [(mission: Int, entity: Int, goal: MissionShipGoal)] {
        events.compactMap {
            guard case let .missionShipGoalReached(mission, entity, goal, _) = $0 else { return nil }
            return (mission, entity, goal)
        }
    }

    func testBoardingGovernmentDerelictCompletesItsBoardGoalOnce() throws {
        let (world, ids) = derelictMissionWorld()
        XCTAssertEqual(ids.count, 1)
        let target = try XCTUnwrap(world.ship(id: try XCTUnwrap(ids.first)))
        XCTAssertTrue(target.disabled)
        XCTAssertTrue(target.isAlive)
        XCTAssertEqual(target.armor, 13.5, accuracy: 0.001)
        XCTAssertNotNil(world.board(shipID: target.entityID))
        let goals = reachedGoals(world.drainEvents())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.mission, 155)
        XCTAssertEqual(goals.first?.entity, target.entityID)
        XCTAssertEqual(goals.first?.goal, .board)

        XCTAssertNotNil(world.board(shipID: target.entityID), "plunder may be reopened")
        XCTAssertTrue(reachedGoals(world.drainEvents()).isEmpty,
                      "reopening the same hulk cannot satisfy another ship's objective")
        XCTAssertEqual(target.missionID, 155)
        XCTAssertEqual(target.missionShipGoal, .board, "retain the ship's mission metadata")
    }

    func testTwoBoardingTargetsEachReportOneGoal() throws {
        let (world, ids) = derelictMissionWorld(count: 2)
        XCTAssertEqual(ids.count, 2)
        for id in ids {
            XCTAssertNotNil(world.board(shipID: id))
            XCTAssertNotNil(world.board(shipID: id))
        }
        let goals = reachedGoals(world.drainEvents())
        XCTAssertEqual(goals.count, 2)
        XCTAssertEqual(Set(goals.map(\.entity)), Set(ids))
    }

    func testDisablingBoardTargetDoesNotCompleteUntilItIsBoarded() {
        let world = World(player: Ship(name: "Player", stats: stats()))
        let target = missionTarget(in: world, goal: .board)
        world.applyHit(to: target, shield: 0, armor: 80, ownerID: World.playerEntityID)
        XCTAssertTrue(target.disabled)
        XCTAssertTrue(reachedGoals(world.drainEvents()).isEmpty,
                      "disabling a ship is only the prerequisite for boarding it")
        XCTAssertNotNil(world.board(shipID: target.entityID))
        XCTAssertEqual(reachedGoals(world.drainEvents()).first?.goal, .board)
    }

    func testDisableGoalCompletesOnDisableAndDoesNotReportAgainOnBoard() {
        let world = World(player: Ship(name: "Player", stats: stats()))
        let target = missionTarget(in: world, goal: .disable)
        world.applyHit(to: target, shield: 0, armor: 80, ownerID: World.playerEntityID)
        let goals = reachedGoals(world.drainEvents())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.goal, .disable)
        XCTAssertNotNil(world.board(shipID: target.entityID))
        XCTAssertTrue(reachedGoals(world.drainEvents()).isEmpty)
    }

    func testRescueGoalReportsOnceOnBoardAndRemainsExemptFromBoardingCleanup() {
        let world = World(player: Ship(name: "Player", stats: stats()))
        let target = missionTarget(in: world, goal: .rescue, disabled: true)
        XCTAssertNotNil(world.board(shipID: target.entityID))
        XCTAssertNotNil(world.board(shipID: target.entityID))
        let goals = reachedGoals(world.drainEvents())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.goal, .rescue)
        world.finishBoardingWithoutCapture(shipID: target.entityID)
        XCTAssertTrue(target.isAlive, "rescuing a ship must not destroy it when plunder closes")
        XCTAssertEqual(target.missionShipGoal, .rescue)
    }

    func testDisablingRescueTargetDoesNotReportBoardingGoal() {
        let world = World(player: Ship(name: "Player", stats: stats()))
        let target = missionTarget(in: world, goal: .rescue)
        world.applyHit(to: target, shield: 0, armor: 80, ownerID: World.playerEntityID)
        XCTAssertTrue(target.disabled)
        XCTAssertTrue(reachedGoals(world.drainEvents()).isEmpty)
        XCTAssertNotNil(world.board(shipID: target.entityID))
        XCTAssertEqual(reachedGoals(world.drainEvents()).first?.goal, .rescue)
    }

    func testLiveOrDestroyedTargetCannotCompleteBoardingGoal() {
        let world = World(player: Ship(name: "Player", stats: stats()))
        let target = missionTarget(in: world, goal: .board)
        XCTAssertNil(world.board(shipID: target.entityID))
        target.disabled = true
        target.armor = 0
        XCTAssertNil(world.board(shipID: target.entityID))
        XCTAssertTrue(reachedGoals(world.drainEvents()).isEmpty)
    }
}
