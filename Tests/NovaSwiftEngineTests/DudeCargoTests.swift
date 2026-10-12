import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// `düde.Booty`: a spawned NPC's hold is filled with whatever commodities its
/// dude class carries, so boarding loot isn't usually empty
/// (SESSION_AUDIT_FOLLOWUPS.md §C).
final class DudeCargoTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    /// A `düde` with only `Booty` (flags @4) set — no ship table needed since
    /// these tests call `rollDudeCargo` directly.
    private func dude(booty: Int) -> DudeRes {
        var b = [UInt8](repeating: 0, count: 80)
        put16(&b, 4, booty)
        return DudeRes(Resource(type: NovaType.dude, id: 300, name: "Trader", data: Data(b)))
    }

    private func makeSpawner() -> Spawner {
        Spawner(galaxy: Galaxy(game: NovaGame(ResourceCollection())), table: SpawnTable())
    }

    func testCarriesFlaggedCommoditiesOnly() {
        let spawner = makeSpawner()
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.cargoCapacity = 100
        // 0x0001 food, 0x0010 metal — everything else unset.
        spawner.rollDudeCargo(dude(booty: 0x0011), into: ship, world: World(player: ship))

        XCTAssertGreaterThan(ship.cargo[Commodity.food.rawValue] ?? 0, 0)
        XCTAssertGreaterThan(ship.cargo[Commodity.metal.rawValue] ?? 0, 0)
        XCTAssertNil(ship.cargo[Commodity.industrial.rawValue])
        XCTAssertNil(ship.cargo[Commodity.medical.rawValue])
        XCTAssertNil(ship.cargo[Commodity.luxury.rawValue])
        XCTAssertNil(ship.cargo[Commodity.equipment.rawValue])
    }

    func testZeroBootyCarriesNothing() {
        let spawner = makeSpawner()
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.cargoCapacity = 100
        spawner.rollDudeCargo(dude(booty: 0), into: ship, world: World(player: ship))
        XCTAssertTrue(ship.cargo.isEmpty, "Booty 0x0000 means repelled while boarding — no loot at all")
    }

    func testNoCargoCapacityCarriesNothing() {
        let spawner = makeSpawner()
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.cargoCapacity = 0   // a fighter/warship with no hold
        spawner.rollDudeCargo(dude(booty: 0x0001), into: ship, world: World(player: ship))
        XCTAssertTrue(ship.cargo.isEmpty)
    }

    func testTotalCargoNeverExceedsCapacity() {
        let spawner = makeSpawner()
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.cargoCapacity = 50
        // All six commodity bits.
        spawner.rollDudeCargo(dude(booty: 0x003F), into: ship, world: World(player: ship))
        let total = ship.cargo.values.reduce(0, +)
        XCTAssertLessThanOrEqual(total, ship.cargoCapacity)
        XCTAssertEqual(ship.cargo.count, 6)
    }
}
