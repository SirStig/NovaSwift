import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// The player's target-lock hotkeys: "closest ship" and "closest hostile".
/// Closest-ship also finds boardable hulks; closest-hostile finds combatants.
/// Neither picks a ship out of the player's own fleet — an escort flies in
/// formation and is almost always the nearest ship to you.
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

    func testTargetNearestIncludesLivingHulks() {
        let world = makeWorld()
        let hulk = addShip(world, name: "Hulk", govt: 200, distance: 100)
        hulk.disabled = true
        addShip(world, name: "Live", govt: 200, distance: 500)

        XCTAssertEqual(world.selectNearestTarget(hostileOnly: false)?.entityID, hulk.entityID,
                       "a disabled ship is still a target for boarding")
    }

    func testTargetNearestHostileSkipsDisabledHostiles() {
        let world = makeWorld()
        world.diplomacy = Diplomacy(govts: [govt(128), govt(201, flags1: 0x0004)])
        let hulk = addShip(world, name: "Enemy Hulk", govt: 201, distance: 100)
        hulk.disabled = true
        let enemy = addShip(world, name: "Enemy", govt: 201, distance: 500)

        XCTAssertEqual(world.selectNearestTarget(hostileOnly: true)?.entityID, enemy.entityID,
                       "nearest hostile remains useful for finding ships that can fight")
        enemy.armor = 0
        XCTAssertNil(world.selectNearestTarget(hostileOnly: true))
    }

    func testTargetNearestStillRequiresLivingDetectableInRangeContacts() {
        let world = makeWorld()
        let wreck = addShip(world, name: "Wreck", govt: 200, distance: 50)
        wreck.disabled = true
        wreck.armor = 0
        let hidden = addShip(world, name: "Cloaked Hulk", govt: 200, distance: 100)
        hidden.disabled = true
        hidden.cloakFlags = 0x0010
        hidden.cloakLevel = 1
        let far = addShip(world, name: "Far Hulk", govt: 200, distance: World.targetLockRange + 1)
        far.disabled = true

        XCTAssertNil(world.selectNearestTarget(hostileOnly: false))
        world.player.cloakScannerFlags = 0x0008
        XCTAssertEqual(world.selectNearestTarget(hostileOnly: false)?.entityID, hidden.entityID,
                       "a cloak scanner can expose a boardable hulk")
        hidden.armor = 0
        XCTAssertNil(world.selectNearestTarget(hostileOnly: false), "the remaining hulk is out of range")
        far.position = Vec2(0, World.targetLockRange)
        XCTAssertEqual(world.selectNearestTarget(hostileOnly: false)?.entityID, far.entityID,
                       "the lock range boundary is inclusive")
    }
}
