import XCTest
@testable import EVNovaKit
@testable import EVNovaEngine

/// End-to-end tests for the ship system: outfit aggregation into an effective
/// loadout, and the live fuel / afterburner / cargo runtime on a `Ship`.
final class ShipSystemTests: XCTestCase {

    // MARK: byte builders

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    /// A minimal, resolvable weapon (unguided, some damage).
    private func weapon(_ id: Int, name: String) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, 30)    // reload
        put16(&b, 2, 60)    // duration
        put16(&b, 4, 10)    // armor damage
        put16(&b, 6, 10)    // shield damage
        put16(&b, 8, -1)    // guidance: unguided
        put16(&b, 10, 100)  // speed
        return Resource(type: NovaType.weapon, id: id, name: name, data: Data(b))
    }

    /// A game with one hull (128), one stat/weapon-granting outfit (200), and two
    /// weapons (128 stock, 129 granted by the outfit).
    private func makeGame() -> NovaGame {
        var col = ResourceCollection()

        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 0, 50)    // cargo
        put16(&ship, 2, 100)   // shield
        put16(&ship, 4, 200)   // accel
        put16(&ship, 6, 300)   // speed
        put16(&ship, 8, 30)    // turn
        put16(&ship, 10, 400)  // fuel (4 jumps)
        put16(&ship, 12, 40)   // free mass
        put16(&ship, 14, 80)   // armor
        put16(&ship, 16, 20)   // shield recharge
        put16(&ship, 42, 4)    // max guns
        put16(&ship, 18, 128); put16(&ship, 26, 1)   // stock weapon 128 ×1
        put16(&ship, 78, 200); put16(&ship, 86, 1)   // preinstalled outfit 200 ×1
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var out = [UInt8](repeating: 0, count: 40)
        put16(&out, 2, 5)                     // mass 5
        put16(&out, 6, 4);  put16(&out, 8, 50)    // shield +50
        put16(&out, 18, 2); put16(&out, 20, 30)   // freeCargo +30
        put16(&out, 22, 15); put16(&out, 24, 37)  // afterburner (fuel 37)
        put16(&out, 26, 1);  put16(&out, 28, 129) // grants weapon 129
        col.add(Resource(type: NovaType.outfit, id: 200, name: "Combat Kit", data: Data(out)))

        col.add(weapon(128, name: "Blaster"))
        col.add(weapon(129, name: "Missile"))
        return NovaGame(col)
    }

    // MARK: loadout aggregation

    func testLoadoutAggregatesOutfits() throws {
        let galaxy = Galaxy(game: makeGame())
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128))

        XCTAssertEqual(lo.maxShield, 150, "base 100 + outfit 50")
        XCTAssertEqual(lo.maxArmor, 80)
        XCTAssertEqual(lo.cargoCapacity, 80, "base 50 + outfit 30")
        XCTAssertEqual(lo.maxFuel, 400)
        XCTAssertEqual(lo.jumpRange, 4)
        XCTAssertNotNil(lo.afterburner, "outfit grants an afterburner")
        XCTAssertEqual(lo.usedMass, 5)
        XCTAssertEqual(lo.massCapacity, 45, "free 40 + used 5")
        XCTAssertEqual(lo.freeMass, 40)
        // Stock weapon 128 + outfit-granted weapon 129.
        XCTAssertEqual(Set(lo.weapons.map(\.id)), [128, 129])
    }

    func testMakeLoadedShipAppliesEverything() throws {
        let galaxy = Galaxy(game: makeGame())
        let ship = try XCTUnwrap(galaxy.makeLoadedShip(128))

        XCTAssertEqual(ship.maxShield, 150)
        XCTAssertEqual(ship.shield, 150, "starts full")
        XCTAssertEqual(ship.maxFuel, 400)
        XCTAssertEqual(ship.fuel, 400)
        XCTAssertEqual(ship.cargoCapacity, 80)
        XCTAssertNotNil(ship.afterburner)
        XCTAssertEqual(ship.weapons.count, 2, "two resolved weapon mounts")
    }

    // MARK: fuel / jumps

    func testHyperspaceFuelConsumption() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        XCTAssertTrue(ship.canJump)
        XCTAssertTrue(ship.consumeJumpFuel())
        XCTAssertEqual(ship.fuel, 300, "one jump costs 100")
        XCTAssertTrue(ship.consumeJumpFuel()); XCTAssertTrue(ship.consumeJumpFuel())
        XCTAssertTrue(ship.consumeJumpFuel())     // 0 left
        XCTAssertFalse(ship.canJump)
        XCTAssertFalse(ship.consumeJumpFuel(), "no fuel → no jump, no spend")
        XCTAssertEqual(ship.fuel, 0)
    }

    // MARK: afterburner

    func testAfterburnerBurnsFuelAndBoosts() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        var intent = ControlIntent()
        intent.thrust = true; intent.afterburner = true
        let before = ship.fuel
        ship.step(1.0, intent: intent, tuning: .default)
        XCTAssertTrue(ship.afterburnerActive)
        XCTAssertEqual(ship.fuel, before - 37, accuracy: 0.001, "afterburner drains fuel")
        // While the burner is still lit (fuel remaining), top speed exceeds the
        // un-boosted maximum. (Run only long enough to accelerate, not drain dry.)
        for _ in 0..<20 { ship.step(0.1, intent: intent, tuning: .default) }
        XCTAssertGreaterThan(ship.fuel, 0, "still burning")
        XCTAssertTrue(ship.afterburnerActive)
        XCTAssertGreaterThan(ship.velocity.length, ship.stats.maxSpeed)
    }

    func testAfterburnerInertWithoutFuel() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        ship.fuel = 0
        var intent = ControlIntent(); intent.thrust = true; intent.afterburner = true
        ship.step(1.0, intent: intent, tuning: .default)
        XCTAssertFalse(ship.afterburnerActive, "no fuel → no burn")
    }

    // MARK: cargo hold

    func testCargoLoadRespectsCapacity() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        XCTAssertEqual(ship.cargoFree, 80)
        XCTAssertEqual(ship.loadCargo(1, tons: 30), 30)
        XCTAssertEqual(ship.cargoUsed, 30)
        XCTAssertEqual(ship.loadCargo(2, tons: 100), 50, "only 50 tons of room left")
        XCTAssertEqual(ship.cargoUsed, 80)
        XCTAssertEqual(ship.loadCargo(3, tons: 10), 0, "hold is full")
        XCTAssertEqual(ship.unloadCargo(1, tons: 10), 10)
        XCTAssertEqual(ship.cargoUsed, 70)
        XCTAssertEqual(ship.unloadCargo(1, tons: 999), 20, "can't remove more than held")
        XCTAssertNil(ship.cargo[1])
    }
}
