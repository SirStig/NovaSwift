import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Fighter bays (`wëap` Guidance 99): loadout extraction and the launch/dock
/// runtime — a carrier deploys fighters in combat and reclaims them.
final class FighterBayTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func ship(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 2, 100); put16(&b, 6, 300); put16(&b, 4, 200); put16(&b, 8, 30)  // shield/speed/accel/turn
        put16(&b, 12, 40); put16(&b, 14, 100)   // free mass, armor
        put16(&b, 10, 400)                        // fuel
        return Resource(type: NovaType.ship, id: id, name: "Ship\(id)", data: Data(b))
    }
    /// A fighter-bay weapon: guidance 99, AmmoType = fighter ship, MaxAmmo = capacity.
    private func bayWeapon(_ id: Int, fighter: Int, capacity: Int, reload: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, reload)          // reload
        put16(&b, 8, 99)              // guidance = carried ship
        put16(&b, 12, fighter)        // AmmoType = fighter ship class
        put16(&b, 108, capacity)      // MaxAmmo = fighters carried
        return Resource(type: NovaType.weapon, id: id, name: "Bay\(id)", data: Data(b))
    }
    private func weaponGrantOutfit(_ id: Int, weapon: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1028)
        put16(&b, 6, 1); put16(&b, 8, weapon)   // ModType 1 (weapon) → weapon id
        return Resource(type: NovaType.outfit, id: id, name: "BayOutfit", data: Data(b))
    }

    private func game() -> NovaGame {
        var col = ResourceCollection()
        col.add(ship(128))                                 // carrier hull
        col.add(ship(144))                                 // fighter hull
        col.add(bayWeapon(149, fighter: 144, capacity: 3, reload: 30))
        col.add(weaponGrantOutfit(200, weapon: 149))       // grants the bay
        return NovaGame(col)
    }

    func testLoadoutExtractsFighterBay() throws {
        let galaxy = Galaxy(game: game())
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128, extraOutfits: [200: 1]))
        XCTAssertEqual(lo.fighterBays.count, 1)
        XCTAssertEqual(lo.fighterBays.first?.fighterShipID, 144)
        XCTAssertEqual(lo.fighterBays.first?.capacity, 3)
        // The bay is NOT a firing weapon mount.
        XCTAssertFalse(lo.weapons.contains { $0.id == 149 })
    }

    func testCarrierLaunchesFightersInCombat() throws {
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil   // no brain → its target won't be re-evaluated away
        XCTAssertEqual(carrier.fighterBays.first?.docked, 3)

        let player = Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let world = World(player: player)
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)

        // A live enemy for the carrier to be "in combat" with.
        let enemy = Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        let enemyID = world.addNPC(enemy)
        carrier.currentTargetID = enemyID

        // Step a couple frames: the bay should deploy a fighter and decrement docked.
        for _ in 0..<3 { world.step(1.0 / 30.0) }

        let fighters = world.npcs.filter { $0.carrierID == carrier.entityID }
        XCTAssertEqual(fighters.count, 1, "one fighter launched")
        XCTAssertEqual(fighters.first?.shipTypeID, 144)
        XCTAssertEqual(carrier.fighterBays.first?.docked, 2, "one fighter spent from the bay")
    }

    func testFightersDockWhenCarrierLeavesCombat() throws {
        let galaxy = Galaxy(game: game())
        let carrier = try XCTUnwrap(galaxy.makeLoadedShip(128, government: 128, extraOutfits: [200: 1]))
        carrier.brain = nil
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        _ = world.addNPC(carrier)
        let enemyID = world.addNPC(Ship(name: "E", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        carrier.currentTargetID = enemyID
        world.step(1.0 / 30.0)
        let fighter = try XCTUnwrap(world.npcs.first { $0.carrierID == carrier.entityID })
        XCTAssertEqual(carrier.fighterBays.first?.docked, 2)

        // Carrier leaves combat → the fighter is recalled; place it on the carrier
        // so it docks immediately.
        carrier.currentTargetID = nil
        fighter.position = carrier.position
        for _ in 0..<3 { world.step(1.0 / 30.0) }
        XCTAssertFalse(world.npcs.contains { $0.entityID == fighter.entityID }, "fighter docked away")
        XCTAssertEqual(carrier.fighterBays.first?.docked, 3, "bay restored on dock")
    }
}
