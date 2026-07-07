import XCTest
@testable import EVNovaEngine

/// Weapons, projectiles, damage bleed-through, beams, and death — the substance
/// behind an NPC's "attack".
final class CombatTests: XCTestCase {

    private func gun(shield: Double = 50, armor: Double = 50, range: Double = 4000,
                     speed: Double = 2000, beam: Bool = false, guided: Bool = false) -> WeaponSpec {
        WeaponSpec(id: 128, name: "Gun", shieldDamage: shield, armorDamage: armor,
                   reloadSeconds: 0.05, projectileSpeed: speed, range: range,
                   accuracyRadians: 0, isBeam: beam, isGuided: guided, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 0)
    }

    private func makeShip(_ name: String, govt: Int, at pos: Vec2) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi),
                     position: pos)
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        return s
    }

    func testShieldSoaksThenArmorBleeds() {
        let s = makeShip("x", govt: 1, at: Vec2())
        // First hit: shields fully absorb the shield-damage, so armor is spared.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 40))
        XCTAssertEqual(s.shield, 40, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 100, accuracy: 1e-9)
        // Second hit: shields drop to 0 having soaked 40/60, so 1/3 of the armor
        // damage bleeds through.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 30))
        XCTAssertEqual(s.shield, 0, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 100 - 10, accuracy: 1e-6)
    }

    func testProjectileTravelsHitsAndKills() {
        let attacker = makeShip("A", govt: 1, at: Vec2())          // player (entity 0)
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))       // 300px north
        let tid = world.addNPC(target)
        target.armor = 20; target.shield = 0                        // one solid hit kills

        attacker.weapons = [WeaponMount(spec: gun())]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true

        var destroyed = false
        for _ in 0..<60 {                                           // up to 1s
            world.step(1.0 / 30.0)
            if world.events.contains(where: { if case .shipDestroyed = $0 { return true } else { return false } }) {
                destroyed = true; break
            }
        }
        XCTAssertTrue(destroyed, "projectile should have reached and destroyed the target")
        XCTAssertTrue(world.npcs.isEmpty, "dead ship is removed from the roster")
    }

    func testNoFriendlyFire() {
        let attacker = makeShip("A", govt: 5, at: Vec2())
        attacker.government = 5
        let world = World(player: attacker)
        let ally = makeShip("B", govt: 5, at: Vec2(0, 200))         // same government
        let tid = world.addNPC(ally)
        attacker.weapons = [WeaponMount(spec: gun())]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        for _ in 0..<60 { world.step(1.0 / 30.0) }
        XCTAssertEqual(ally.shield, 100, accuracy: 1e-6, "same-government ships don't damage each other")
        XCTAssertEqual(ally.armor, 100, accuracy: 1e-6)
    }

    func testBeamIsInstantHit() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 250))
        let tid = world.addNPC(target)
        attacker.weapons = [WeaponMount(spec: gun(range: 600, beam: true))]
        attacker.currentTargetID = tid
        attacker.angle = 0                                          // facing north, toward target
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)                                      // a single frame
        XCTAssertLessThan(target.shield, 100, "beam damages on the same frame it fires")
        XCTAssertTrue(world.events.contains { if case .beam(_, _, let hit) = $0 { return hit } else { return false } })
    }
}
