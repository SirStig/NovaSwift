import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// `pêrs` weapon customization: `WeapType`/`WeapCount`/`AmmoLoad[4]` layered on
/// top of a spawned hull's stock weapons (SESSION_AUDIT_FOLLOWUPS.md §A).
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
