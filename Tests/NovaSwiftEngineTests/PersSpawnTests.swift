import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// `pêrs` defense and weapon customization layered on a spawned hull.
final class PersSpawnTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    /// A minimal, resolvable weapon (unguided, some damage).
    private func weapon(_ id: Int, name: String) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, 30); put16(&b, 2, 60); put16(&b, 4, 10); put16(&b, 6, 10)
        put16(&b, 8, -1); put16(&b, 10, 100)
        return Resource(type: NovaType.weapon, id: id, name: name, data: Data(b))
    }

    /// A 400-byte `përs` record with only the weapon-array fields set.
    private func pers(weapType: [Int], weapCount: [Int], ammoLoad: [Int] = [0, 0, 0, 0]) -> PersRes {
        var b = [UInt8](repeating: 0, count: 400)
        for i in 0..<4 { put16(&b, 12 + i * 2, weapType[i]) }
        for i in 0..<4 { put16(&b, 20 + i * 2, weapCount[i]) }
        for i in 0..<4 { put16(&b, 28 + i * 2, ammoLoad[i]) }
        return PersRes(Resource(type: NovaType.pers, id: 500, name: "Test", data: Data(b)))
    }

    private func makeGalaxy() -> Galaxy {
        var col = ResourceCollection()
        col.add(weapon(128, name: "Blaster"))
        col.add(weapon(129, name: "Missile"))
        return Galaxy(game: NovaGame(col))
    }

    private func makeSpawner(_ galaxy: Galaxy) -> Spawner {
        Spawner(galaxy: galaxy, table: SpawnTable())
    }

    /// Exercise the public pinned-person spawn path rather than customizing a
    /// ship directly, so both the resource decoder and live initial HP matter.
    private func spawnPerson(shieldMod: Int) throws -> Ship {
        var col = ResourceCollection()
        var hull = [UInt8](repeating: 0, count: 2000)
        put16(&hull, 2, 100)    // shield
        put16(&hull, 14, 80)    // armor
        col.add(Resource(type: NovaType.ship, id: 128, name: "Hull", data: Data(hull)))

        var person = [UInt8](repeating: 0, count: 400)
        put16(&person, 2, -1)       // independent government
        put16(&person, 4, 1)        // trader
        put16(&person, 10, 128)     // hull
        put16(&person, 40, shieldMod)
        col.add(Resource(type: NovaType.pers, id: 500, name: "Captain", data: Data(person)))

        var system = [UInt8](repeating: 0, count: 2000)
        put16(&system, 110, 500)    // guaranteed Person1
        col.add(Resource(type: NovaType.syst, id: 128, name: "System", data: Data(system)))

        let galaxy = Galaxy(game: NovaGame(col))
        let world = World(player: Ship(name: "P", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3)))
        let spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: try XCTUnwrap(galaxy.game.system(128))))
        spawner.populate(world)
        return try XCTUnwrap(world.npcs.first { $0.personID == 500 })
    }

    func testPersonHalfStrengthScalesArmorAndShields() throws {
        let ship = try spawnPerson(shieldMod: 50)
        XCTAssertEqual(ship.maxShield, 50)
        XCTAssertEqual(ship.shield, 50)
        XCTAssertEqual(ship.maxArmor, 40)
        XCTAssertEqual(ship.armor, 40)
    }

    func testPersonStandardStrengthKeepsHullDefenses() throws {
        let ship = try spawnPerson(shieldMod: 100)
        XCTAssertEqual(ship.maxShield, 100)
        XCTAssertEqual(ship.shield, 100)
        XCTAssertEqual(ship.maxArmor, 80)
        XCTAssertEqual(ship.armor, 80)
    }

    func testPersonStrengthMatchesOriginalFloat32Multiplier() throws {
        let ship = try spawnPerson(shieldMod: 130)
        // Original loader: signed ShieldMod / 100 stored as Float32. The
        // ordinary capacity helper multiplies in x87 without rounding the
        // product back to Float32: 80 * 1.2999999523162842 is this exact value.
        XCTAssertEqual(ship.maxArmor, 103.99999618530273)
        XCTAssertEqual(ship.armor, ship.maxArmor)
        XCTAssertEqual(ship.maxShield, 129.99999523162842)
        XCTAssertEqual(ship.shield, ship.maxShield)
    }

    func testPersonTripleStrengthScalesArmorAndShields() throws {
        let ship = try spawnPerson(shieldMod: 300)
        XCTAssertEqual(ship.maxShield, 300)
        XCTAssertEqual(ship.shield, 300)
        XCTAssertEqual(ship.maxArmor, 240)
        XCTAssertEqual(ship.armor, 240)
    }

    func testPersonZeroStrengthLeavesDefensesUnscaled() throws {
        let ship = try spawnPerson(shieldMod: 0)
        XCTAssertEqual(ship.maxShield, 100)
        XCTAssertEqual(ship.shield, 100)
        XCTAssertEqual(ship.maxArmor, 80)
        XCTAssertEqual(ship.armor, 80)
        XCTAssertTrue(ship.isAlive)
    }

    func testPersonNegativeStrengthPreservesNativeInvincibility() throws {
        for modifier in [-1, -32768] {
            let ship = try spawnPerson(shieldMod: modifier)
            XCTAssertEqual(ship.maxShield, 1_000_000)
            XCTAssertEqual(ship.shield, 1_000_000)
            XCTAssertEqual(ship.maxArmor, 80)
            XCTAssertEqual(ship.armor, 80)
            XCTAssertTrue(ship.isAlive)
        }
    }

    func testAddsExtraWeaponMount() {
        let galaxy = makeGalaxy()
        let spawner = makeSpawner(galaxy)
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.weapons = [WeaponMount(spec: galaxy.weaponSpec(128)!, ammo: -1, count: 1)]

        let p = pers(weapType: [129, 0, 0, 0], weapCount: [2, 0, 0, 0], ammoLoad: [40, 0, 0, 0])
        spawner.applyPersonWeapons(p, to: ship)

        XCTAssertEqual(Set(ship.weapons.map(\.spec.id)), [128, 129])
        let missile = try! XCTUnwrap(ship.weapons.first { $0.spec.id == 129 })
        XCTAssertEqual(missile.count, 2)
        XCTAssertEqual(missile.ammo, 40)
    }

    func testMergesIntoExistingMountOfSameWeapon() {
        let galaxy = makeGalaxy()
        let spawner = makeSpawner(galaxy)
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.weapons = [WeaponMount(spec: galaxy.weaponSpec(128)!, ammo: -1, count: 1)]

        let p = pers(weapType: [128, 0, 0, 0], weapCount: [3, 0, 0, 0])
        spawner.applyPersonWeapons(p, to: ship)

        XCTAssertEqual(ship.weapons.count, 1)
        XCTAssertEqual(ship.weapons[0].count, 4, "1 stock + 3 granted, merged into one mount")
    }

    func testNegativeWeapCountRemovesStockCopies() {
        let galaxy = makeGalaxy()
        let spawner = makeSpawner(galaxy)
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.weapons = [WeaponMount(spec: galaxy.weaponSpec(128)!, ammo: -1, count: 3)]

        let p = pers(weapType: [128, 0, 0, 0], weapCount: [-2, 0, 0, 0])
        spawner.applyPersonWeapons(p, to: ship)

        XCTAssertEqual(ship.weapons.count, 1)
        XCTAssertEqual(ship.weapons[0].count, 1, "3 stock - 2 removed = 1 left")
    }

    func testNegativeWeapCountCanFullyRemoveAMount() {
        let galaxy = makeGalaxy()
        let spawner = makeSpawner(galaxy)
        let ship = Ship(name: "S", stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3))
        ship.weapons = [WeaponMount(spec: galaxy.weaponSpec(128)!, ammo: -1, count: 2)]

        let p = pers(weapType: [128, 0, 0, 0], weapCount: [-5, 0, 0, 0])
        spawner.applyPersonWeapons(p, to: ship)

        XCTAssertTrue(ship.weapons.isEmpty, "removing more than stocked drops the mount entirely")
    }
}
