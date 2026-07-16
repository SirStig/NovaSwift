import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// The player's target-lock hotkeys: "closest ship" and "closest hostile".
/// Both exist to find something to *shoot*, so neither ever picks a ship out of
/// the player's own fleet — an escort flies in formation and is almost always
/// the nearest ship to you, which made "target closest" useless in a fight.
final class TargetingTests: XCTestCase {

    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    /// A minimal `gövt`: `flags1` 0x0004 is "always attacks the player".
    private func govt(_ id: Int, flags1: UInt16 = 0) -> GovtRes {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, -1) }   // classes
        for i in 0..<4 { putW(32 + i * 2, -1) }   // allies
        for i in 0..<4 { putW(40 + i * 2, -1) }   // enemies
        putW(2, Int(flags1))
        putW(18, 2)                                // crime tolerance
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(d)))
    }

    private func makeWorld() -> World {
        let world = World(player: Ship(name: "P", stats: stats()))
        world.player.government = 128
        return world
    }

    /// An NPC of `govt` at `distance` px north of the player.
    @discardableResult
    private func addShip(_ world: World, name: String, govt: Int, distance: Double,
                         escortingPlayer: Bool = false) -> Ship {
        let s = Ship(name: name, stats: stats(), position: Vec2(0, distance))
        s.government = govt
        let brain = AIBrain(aiType: .warship, govt: govt)
        if escortingPlayer { brain.leaderID = World.playerEntityID }
        s.brain = brain
        world.addNPC(s)
        return s
    }

    func testTargetNearestSkipsYourOwnEscorts() {
        let world = makeWorld()
        addShip(world, name: "Escort", govt: 128, distance: 100, escortingPlayer: true)
        let stranger = addShip(world, name: "Stranger", govt: 200, distance: 900)

        let locked = world.selectNearestTarget(hostileOnly: false)
        XCTAssertEqual(locked?.entityID, stranger.entityID,
                       "the closer ship is your own escort, so the lock skips past it")
        XCTAssertEqual(world.player.currentTargetID, stranger.entityID)
    }

    func testTargetNearestFindsNothingWhenOnlyYourWingIsAround() {
        let world = makeWorld()
        addShip(world, name: "Escort", govt: 128, distance: 100, escortingPlayer: true)
        XCTAssertNil(world.selectNearestTarget(hostileOnly: false))
        XCTAssertNil(world.player.currentTargetID, "flying with only your wing = nothing to shoot")
    }

    /// A fighter off one of your escort carriers is yours too — the fleet test
    /// follows the whole chain of command, not just the first link.
    func testTargetNearestSkipsFightersFlyingOffYourEscortCarrier() {
        let world = makeWorld()
        let carrier = addShip(world, name: "Carrier", govt: 128, distance: 400, escortingPlayer: true)
        let fighter = addShip(world, name: "Fighter", govt: 128, distance: 60)
        fighter.brain?.leaderID = carrier.entityID
        let stranger = addShip(world, name: "Stranger", govt: 200, distance: 900)

        XCTAssertEqual(world.selectNearestTarget(hostileOnly: false)?.entityID, stranger.entityID)
    }

    func testTargetNearestHostileIgnoresNeutralsAndYourWing() {
        let world = makeWorld()
        world.diplomacy = Diplomacy(govts: [govt(128), govt(200), govt(201, flags1: 0x0004)])

        // A hostile-government mercenary flying for you is not a target...
        addShip(world, name: "Merc", govt: 201, distance: 80, escortingPlayer: true)
        // ...nor is a neutral bystander, however close.
        addShip(world, name: "Neutral", govt: 200, distance: 200)
        let enemy = addShip(world, name: "Enemy", govt: 201, distance: 700)

        let locked = world.selectNearestTarget(hostileOnly: true)
        XCTAssertEqual(locked?.entityID, enemy.entityID,
                       "the only real enemy is the one that isn't neutral and isn't yours")
    }

    func testTargetNearestIgnoresHulksAndOutOfRangeShips() {
        let world = makeWorld()
        let hulk = addShip(world, name: "Hulk", govt: 200, distance: 100)
        hulk.disabled = true
        addShip(world, name: "Far", govt: 200, distance: World.targetLockRange + 500)

        XCTAssertNil(world.selectNearestTarget(hostileOnly: false),
                     "a drifting hulk isn't a target and the only live ship is out of lock range")
    }
}
