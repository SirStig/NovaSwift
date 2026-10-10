import XCTest
@testable import NovaSwiftEngine

/// AI-38 / AI-41: a disabled ship in the player's wing drops out of it at
/// once (`Ship_ApplyDamageToShip` 0x004192d0), remembering what it was; its
/// repair system or the player boarding it brings it back
/// (`Ship_HandleShip` 0x00433050, `Player_HandleBoardTargetCommand` 0x0045a3d0).
final class DisabledEscortTests: XCTestCase {
    private let tick = 1.0 / 30.0

    private func ship(_ name: String, at pos: Vec2, typeID: Int = -1) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi), position: pos)
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        s.shipTypeID = typeID
        return s
    }

    private func worldWithEscort() -> (World, Ship) {
        let world = World(player: ship("P", at: Vec2()))
        let escort = ship("E", at: Vec2(100, 0), typeID: 300)
        escort.brain = AIBrain(aiType: .warship, govt: -1)
        world.addNPC(escort)
        world.recruitEscort(escort)
        return (world, escort)
    }

    func testDisabledEscortLeavesTheWingAtOnce() {
        let (world, escort) = worldWithEscort()
        XCTAssertEqual(world.playerEscorts.count, 1)
        escort.shield = 0
        world.applyHit(to: escort, shield: 0, armor: 80, ownerID: -1)
        XCTAssertTrue(escort.disabled)
        XCTAssertNil(escort.brain?.leaderID)
        XCTAssertEqual(escort.formerWingRole, .escort)
        XCTAssertTrue(world.playerEscorts.isEmpty)
        XCTAssertTrue(world.events.contains {
            if case .escortLeftWingDisabled(let id, _) = $0 { return id == escort.entityID }; return false
        })
    }

    func testRepairSystemBringsAFormerEscortBack() {
        let (world, escort) = worldWithEscort()
        escort.hasRepairSystem = true
        escort.shield = 0
        world.applyHit(to: escort, shield: 0, armor: 80, ownerID: -1)
        var ticks = 0
        while escort.disabled && ticks < 30_000 { world.step(tick); ticks += 1 }
        XCTAssertFalse(escort.disabled)
        XCTAssertEqual(escort.brain?.leaderID, World.playerEntityID)
        XCTAssertNil(escort.formerWingRole)
        XCTAssertEqual(escort.shield, 0, accuracy: 1)
    }

    func testBoardingAFormerEscortRepairsItAndReturnsItsCargo() {
        let (world, escort) = worldWithEscort()
        escort.shield = 0
        world.applyHit(to: escort, shield: 0, armor: 80, ownerID: -1)
        escort.cargo = [2: 7]
        XCTAssertEqual(world.recoverOnBoarding(shipID: escort.entityID), .escortRepaired(cargo: [2: 7]))
        XCTAssertFalse(escort.disabled)
        XCTAssertEqual(escort.armor, 100 * 0.3333 + 1, accuracy: 1e-9)
        XCTAssertEqual(escort.brain?.leaderID, World.playerEntityID)
        XCTAssertTrue(escort.cargo.isEmpty)
    }

    func testAnOrdinaryHulkIsNotRecovered() {
        let world = World(player: ship("P", at: Vec2()))
        let hulk = ship("H", at: Vec2(100, 0), typeID: 300)
        world.addNPC(hulk)
        hulk.disabled = true
        XCTAssertNil(world.recoverOnBoarding(shipID: hulk.entityID))
    }

    /// A hulk of a class the player's bay launches, with room, is captured
    /// straight into the bay; a full bay leaves it to the plunder window.
    func testFighterOfABayClassIsCapturedIntoTheBay() {
        let world = World(player: ship("P", at: Vec2()))
        let bay = Ship.FighterBay(spec: FighterBaySpec(bayWeaponID: 900, fighterShipID: 310,
                                                       capacity: 3, launchIntervalFrames: 30))
        bay.docked = 2
        world.player.fighterBays = [bay]
        let hulk = ship("F", at: Vec2(100, 0), typeID: 310)
        world.addNPC(hulk)
        hulk.disabled = true
        XCTAssertEqual(world.recoverOnBoarding(shipID: hulk.entityID), .fighterCaptured)
        XCTAssertEqual(bay.docked, 3)
        XCTAssertFalse(world.npcs.contains { $0 === hulk })

        let another = ship("F2", at: Vec2(100, 0), typeID: 310)
        world.addNPC(another)
        another.disabled = true
        XCTAssertNil(world.recoverOnBoarding(shipID: another.entityID), "the bay is full")
    }

    /// AI-41: a player's bay fighter carries × 1.333 pools only while it flies
    /// as one (behavior 5); dropping out disabled takes them off, a repair
    /// puts them back.
    func testFighterLosesAndRegainsItsCarriedScale() {
        let world = World(player: ship("P", at: Vec2()))
        let bay = Ship.FighterBay(spec: FighterBaySpec(bayWeaponID: 900, fighterShipID: 310,
                                                       capacity: 3, launchIntervalFrames: 30))
        world.player.fighterBays = [bay]
        let f = ship("F", at: Vec2(100, 0), typeID: 310)
        f.applyCarriedFighterScale()
        f.brain = AIBrain(aiType: .interceptor, govt: -1)
        f.brain?.leaderID = World.playerEntityID
        f.carrierID = World.playerEntityID
        f.hasRepairSystem = true
        world.addNPC(f)
        bay.deployed.insert(f.entityID)
        XCTAssertEqual(f.maxArmor, Double(Float(133.3)), accuracy: 1e-4)
        XCTAssertTrue(world.playerHasEscortRoom, "a fighter is not an escort")

        f.shield = 0
        world.applyHit(to: f, shield: 0, armor: 120, ownerID: -1)
        XCTAssertEqual(f.formerWingRole, .fighter)
        XCTAssertEqual(f.maxArmor, 100)
        XCTAssertNil(f.carrierID)
        XCTAssertFalse(bay.deployed.contains(f.entityID))

        var ticks = 0
        while f.disabled && ticks < 30_000 { world.step(tick); ticks += 1 }
        XCTAssertFalse(f.disabled)
        XCTAssertEqual(f.carrierID, World.playerEntityID)
        XCTAssertEqual(f.maxArmor, Double(Float(133.3)), accuracy: 1e-4)
        XCTAssertEqual(f.brain?.leaderID, World.playerEntityID)
    }
}
