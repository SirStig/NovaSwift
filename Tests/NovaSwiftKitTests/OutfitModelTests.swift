import XCTest
@testable import NovaSwiftKit

/// Byte-level decode tests for the outfit (`oütf`) and the expanded ship (`shïp`)
/// resources — the data half of the ship system. Offsets are asserted against the
/// novaparse reference layout.
final class OutfitModelTests: XCTestCase {

    /// Write a signed 16-bit big-endian value into a byte buffer.
    private func put16(_ buf: inout [UInt8], _ off: Int, _ val: Int) {
        let v = UInt16(bitPattern: Int16(truncatingIfNeeded: val))
        buf[off] = UInt8(v >> 8); buf[off + 1] = UInt8(v & 0xff)
    }
    private func put32(_ buf: inout [UInt8], _ off: Int, _ val: Int) {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: val))
        buf[off] = UInt8((v >> 24) & 0xff); buf[off + 1] = UInt8((v >> 16) & 0xff)
        buf[off + 2] = UInt8((v >> 8) & 0xff); buf[off + 3] = UInt8(v & 0xff)
    }

    func testOutfitDecodesModifiers() {
        var b = [UInt8](repeating: 0, count: 40)
        put16(&b, 0, 5)          // displayWeight
        put16(&b, 2, 10)         // mass
        put16(&b, 4, 3)          // techLevel
        put16(&b, 6, 4);  put16(&b, 8, 50)    // mod1: shield +50
        put16(&b, 10, 8)         // max installable
        put32(&b, 14, 250_000)   // cost
        put16(&b, 18, 8); put16(&b, 20, 20)   // mod2: speed +20
        put16(&b, 22, 15); put16(&b, 24, 37)  // mod3: afterburner (fuel 37)
        let o = OutfRes(Resource(type: NovaType.outfit, id: 200, name: "Test Kit", data: Data(b)))

        XCTAssertEqual(o.mass, 10)
        XCTAssertEqual(o.techLevel, 3)
        XCTAssertEqual(o.maxInstallable, 8)
        XCTAssertEqual(o.cost, 250_000)
        XCTAssertEqual(o.value(of: .shield), 50)
        XCTAssertEqual(o.value(of: .speed), 20)
        XCTAssertTrue(o.has(.afterburner))
        XCTAssertFalse(o.has(.armor))
    }

    func testOutfitGrantsWeaponAndAmmo() {
        var b = [UInt8](repeating: 0, count: 40)
        put16(&b, 6, 1);  put16(&b, 8, 128)   // grants weapon 128
        put16(&b, 18, 3); put16(&b, 20, 129)  // ammunition for weapon 129
        let o = OutfRes(Resource(type: NovaType.outfit, id: 201, data: Data(b)))
        XCTAssertEqual(o.grantedWeapons, [128])
        XCTAssertEqual(o.ammoFor, [129])
    }

    func testShipDecodesFullStats() {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 0, 50)    // cargo
        put16(&b, 2, 100)   // shield
        put16(&b, 4, 300)   // accel
        put16(&b, 6, 350)   // speed
        put16(&b, 8, 30)    // turn
        put16(&b, 10, 400)  // fuel capacity
        put16(&b, 12, 40)   // free mass
        put16(&b, 14, 80)   // armor
        put16(&b, 16, 20)   // shield recharge
        put16(&b, 42, 4)    // max guns
        put16(&b, 44, 2)    // max turrets
        put16(&b, 62, 25)   // mass
        put16(&b, 68, 3)    // crew
        // Stock weapon 128 ×2, and preinstalled outfit 200 ×1.
        put16(&b, 18, 128); put16(&b, 26, 2)
        put16(&b, 78, 200); put16(&b, 86, 1)
        let s = ShipRes(Resource(type: NovaType.ship, id: 128, name: "Testship", data: Data(b)))

        XCTAssertEqual(s.cargoSpace, 50)
        XCTAssertEqual(s.shield, 100)
        XCTAssertEqual(s.speed, 350)
        XCTAssertEqual(s.fuelCapacity, 400)
        XCTAssertEqual(s.freeMass, 40)
        XCTAssertEqual(s.armor, 80)
        XCTAssertEqual(s.maxGuns, 4)
        XCTAssertEqual(s.maxTurrets, 2)
        XCTAssertEqual(s.crew, 3)
        XCTAssertEqual(s.weapons.count, 1)
        XCTAssertEqual(s.weapons.first?.id, 128)
        XCTAssertEqual(s.weapons.first?.count, 2)
        XCTAssertEqual(s.outfits.first?.id, 200)
    }
}
