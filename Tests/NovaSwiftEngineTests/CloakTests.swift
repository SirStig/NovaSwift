import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Cloaking (oütf ModType 17), cloak scanners (30), and interference-scaled
/// sensor range (sÿst.Interference / ModType 24).
final class CloakTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    // MARK: loadout flag aggregation

    func testLoadoutAggregatesCloakAndScannerFlags() throws {
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 12, 40); put16(&ship, 14, 100)   // free mass, armor
        var col = ResourceCollection()
        col.add(Resource(type: NovaType.ship, id: 128, name: "Hull", data: Data(ship)))
        func outfit(_ id: Int, mod: Int, val: Int) -> Resource {
            var b = [UInt8](repeating: 0, count: 1028); put16(&b, 6, mod); put16(&b, 8, val)
            return Resource(type: NovaType.outfit, id: id, name: "O\(id)", data: Data(b))
        }
        col.add(outfit(200, mod: 17, val: 0x0084))   // cloak: 8 fuel/sec + drops shields
        col.add(outfit(201, mod: 30, val: 0x0008))   // cloak scanner: target cloaked
        col.add(outfit(202, mod: 24, val: 20))       // -20 interference
        let lo = try XCTUnwrap(Galaxy(game: NovaGame(col)).loadout(shipID: 128,
                                    extraOutfits: [200: 1, 201: 1, 202: 1]))
        XCTAssertEqual(lo.cloakFlags, 0x0084)
        XCTAssertEqual(lo.cloakScannerFlags, 0x0008)
        XCTAssertEqual(lo.interferenceReduction, 20)
    }

    // MARK: cloak fade + fuel drain

    func testCloakFadesInAndDrainsFuel() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0010          // 1 fuel/sec
        player.maxFuel = 100; player.fuel = 100
        player.cloakEngaged = true
        let world = World(player: player)
        world.step(1.0)
        XCTAssertGreaterThan(player.cloakLevel, 0, "cloak fades in while engaged")
        XCTAssertEqual(player.fuel, 99, accuracy: 0.01, "1 fuel/sec drained")
    }

    func testCloakForcedOffWhenFuelRunsOut() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0010
        player.maxFuel = 100; player.fuel = 0.5
        player.cloakEngaged = true
        let world = World(player: player)
        world.step(1.0)
        XCTAssertEqual(player.fuel, 0, accuracy: 0.001)
        XCTAssertFalse(player.cloakEngaged, "cloak drops when it can't be powered")
    }

    func testCloakDropsShieldsOnActivation() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0004          // drops shields on activation
        player.maxShield = 100; player.shield = 100
        player.cloakEngaged = true
        let world = World(player: player)
        world.step(0.1)
        XCTAssertEqual(player.shield, 0, accuracy: 0.001)
    }

    // MARK: detection

    func testCloakedShipUndetectableWithoutScanner() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        let target = Ship(name: "T", stats: stats())
        target.cloakFlags = 0x0010; target.cloakLevel = 1.0    // fully cloaked
        _ = world.addNPC(target)
        XCTAssertFalse(world.canDetect(target, by: observer))
        observer.cloakScannerFlags = 0x0008                    // can target cloaked
        XCTAssertTrue(world.canDetect(target, by: observer))
        target.cloakLevel = 0                                  // decloaked
        observer.cloakScannerFlags = 0
        XCTAssertTrue(world.canDetect(target, by: observer))
    }

    // MARK: interference-scaled range

    func testInterferenceShrinksSensorRange() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        world.systemInterference = 50
        XCTAssertEqual(world.effectiveSensorRange(1500, for: observer), 750, accuracy: 0.1)
        world.systemInterference = 100
        XCTAssertEqual(world.effectiveSensorRange(1500, for: observer), 0, accuracy: 0.1, "blackout")
        world.systemInterference = 50
        observer.interferenceReduction = 50   // anti-interference cancels it
        XCTAssertEqual(world.effectiveSensorRange(1500, for: observer), 1500, accuracy: 0.1)
    }
}
