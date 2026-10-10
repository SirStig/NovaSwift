import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// Mission special ships in the original AI: ShipBehav 2 (0x004053c0) and
/// boarding a mission ship (0x0045a3d0 → 0x00415dc0).
final class MissionShipBehaviorTests: XCTestCase {

    private func govt(_ id: Int, classes: [Int], enemies: [Int] = []) -> GovtRes {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        putW(22, 100)
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(d)))
    }

    private func weapon(planet: Bool, beam: Bool = false) -> WeaponSpec {
        var flags = WeaponBehaviorFlags()
        flags.isPlanetTypeWeapon = planet
        return WeaponSpec(id: 128, name: "Gun", shieldDamage: 10, armorDamage: 10, reloadSeconds: 0.5,
                          projectileSpeed: 1500, range: 600, accuracyRadians: 0, isBeam: beam,
                          isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0, flags: flags)
    }

    private func ship(_ name: String, govt: Int, at pos: Vec2, ai: AIType) -> Ship {
        let s = Ship(name: name, stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30), position: pos)
        s.government = govt
        s.radius = 20
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.maxFuel = 300; s.fuel = 300
        s.massTons = 50; s.crew = 5
        s.brain = AIBrain(aiType: ai, govt: govt)
        return s
    }

    private func world(bodies: [StellarBody]) -> World {
        let player = Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30),
                          position: Vec2(9000, 9000))
        player.maxArmor = 100; player.armor = 100; player.maxShield = 100; player.shield = 100
        let w = World(player: player)
        w.diplomacy = Diplomacy(govts: [govt(128, classes: [1], enemies: [2]), govt(129, classes: [2], enemies: [1])])
        w.systemContext = SystemContext(bodies: bodies)
        return w
    }

    func testShipBehav2AttacksTheHostileDestroyableStellar() {
        let w = world(bodies: [
            StellarBody(id: 400, position: Vec2(300, 300), radius: 40, canLand: true, government: 129),
            StellarBody(id: 401, position: Vec2(-300, 300), radius: 40, canLand: true, government: 129, strength: 500),
            StellarBody(id: 402, position: Vec2(300, -300), radius: 40, canLand: true, government: 128, strength: 500),
        ])
        let s = ship("Raider", govt: 128, at: Vec2(0, 0), ai: .wimpyTrader)
        s.weapons = [WeaponMount(spec: weapon(planet: true))]
        s.brain?.behaviorOverride = .attackStellars
        s.missionID = 600
        w.addNPC(s)
        for _ in 0..<5 { w.step(1.0 / 30.0) }
        let rec = w.originalAI.record(for: s.entityID)!
        XCTAssertEqual(rec.state, OriginalAIState.stellarAttack)
        XCTAssertEqual(rec.secondary, .stellar(401), "the indestructible and the friendly stellars are skipped")
    }

    func testShipBehav2WithoutAPlanetWeaponStandsDown() {
        let w = world(bodies: [
            StellarBody(id: 401, position: Vec2(-300, 300), radius: 40, canLand: true, government: 129, strength: 500),
        ])
        let s = ship("Raider", govt: 128, at: Vec2(0, 0), ai: .wimpyTrader)
        s.weapons = [WeaponMount(spec: weapon(planet: true, beam: true))]
        s.brain?.behaviorOverride = .attackStellars
        s.missionID = 600
        w.addNPC(s)
        for _ in 0..<5 { w.step(1.0 / 30.0) }
        XCTAssertNotEqual(w.originalAI.record(for: s.entityID)?.state, OriginalAIState.stellarAttack)
    }
}
