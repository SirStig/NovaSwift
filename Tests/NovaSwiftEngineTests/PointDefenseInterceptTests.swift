import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// Play-test bug (1.0.0 build 462): "The Chainstorm turret doesn't interact
/// with missiles. The rounds fire but no missiles are destroyed."
///
/// Contact only asked whether the missile's one end-of-step point lay within
/// 6 px of the round's path. The original (callback 0x00438630, paired in
/// `Frame_TickSystems`) overlaps the two sprites' bounding rectangles once per
/// raw call, after everything has moved, and aims a mode-9 round straight at a
/// missile mark (0x0043a310: no lead).
final class PointDefenseInterceptTests: XCTestCase {

    private func makeShip(_ name: String, at pos: Vec2) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi),
                     position: pos)
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        return s
    }

    private func missileSpec(durability: Int = 0) -> WeaponSpec {
        WeaponSpec(id: 140, name: "Missile", shieldDamage: 50, armorDamage: 50,
                   reloadSeconds: 5, projectileSpeed: 400, range: 3000,
                   accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                   blastRadius: 0, ammoPerShot: 0, durability: durability)
    }

    /// A mode-9 point-defense turret firing real rounds, like the Chainstorm.
    private func pdTurret() -> WeaponSpec {
        WeaponSpec(id: 141, name: "PD Turret", shieldDamage: 5, armorDamage: 5,
                   reloadSeconds: 0.1, projectileSpeed: 1500, range: 800,
                   accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 0, isPointDefense: true,
                   guidance: .pointDefense, isTurret: true)
    }

    private func boltSpec() -> WeaponSpec {
        WeaponSpec(id: 142, name: "Bolt", shieldDamage: 5, armorDamage: 5,
                   reloadSeconds: 1, projectileSpeed: 900, range: 900,
                   accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 0)
    }

    /// A shot registered with `world` through its own spawner, then placed:
    /// it started this step at `from` and ended it at `to`.
    @discardableResult
    private func place(_ spec: WeaponSpec, in world: World, from: Vec2, to: Vec2) -> Projectile {
        let p = world.spawnProjectile(spec: spec, muzzle: to, aim: 0, ownerID: -2, ownerGovt: 0,
                                      ownerVelocity: Vec2(), targetID: nil, subDepth: 0)
        p.stepOrigin = from
        p.position = to
        p.velocity = (to - from) * 30
        if spec.isPointDefense {
            p.isPointDefenseRound = true
            p.pointDefenseBite = spec.armorDamage + (spec.shieldDamage / 2).rounded(.down)
        }
        return p
    }

    // MARK: Contact

    func testRoundOverlappingAMissileAtTheRawCallCollides() {
        let world = World(player: makeShip("P", at: Vec2(5000, 5000)))
        let missile = place(missileSpec(), in: world, from: Vec2(0, 130), to: Vec2(0, 104))
        let round = place(pdTurret(), in: world, from: Vec2(0, 70), to: Vec2(0, 100))
        XCTAssertEqual(missile.guidance, .guided)

        world.pointDefenseContacts(rawCalls: 1)

        XCTAssertFalse(missile.alive, "rectangles overlap after the move: the missile dies")
        XCTAssertFalse(round.alive, "the contact spends the round")
        guard case let .explosion(at, _, _, _)? = world.events.last else { return XCTFail("no impact") }
        XCTAssertEqual(at, round.position, "impact effect 0 sits at the round, not the missile")
    }

    func testSecondRawCallOfAStepIsTestedAtItsOwnPositions() {
        // Overlapping only half way through the step: a step holding two raw
        // calls tests there, a step holding one doesn't.
        let mk = { (calls: Int) -> Bool in
            let world = World(player: self.makeShip("P", at: Vec2(5000, 5000)))
            let missile = self.place(self.missileSpec(), in: world, from: Vec2(0, 140), to: Vec2(0, 100))
            _ = self.place(self.pdTurret(), in: world, from: Vec2(0, 80), to: Vec2(0, 160))
            world.pointDefenseContacts(rawCalls: calls)
            return !missile.alive
        }
        XCTAssertTrue(mk(2))
        XCTAssertFalse(mk(1), "shots that pass between raw calls miss, as in the original")
    }

    func testRoundThatMissesByAWideMarginDoesNotCollide() {
        let world = World(player: makeShip("P", at: Vec2(5000, 5000)))
        let missile = place(missileSpec(), in: world, from: Vec2(40, 120), to: Vec2(40, 90))
        let round = place(pdTurret(), in: world, from: Vec2(0, 100), to: Vec2(0, 130))

        world.pointDefenseContacts()

        XCTAssertTrue(missile.alive)
        XCTAssertTrue(round.alive)
    }

    func testDurableMissileLosesTheBiteThenDies() {
        // WP-14: a missile with Durability D takes ceil(D / bite) + 1 contacts.
        let world = World(player: makeShip("P", at: Vec2(5000, 5000)))
        let missile = place(missileSpec(durability: 10), in: world, from: Vec2(0, 100), to: Vec2(0, 100))
        XCTAssertEqual(missile.pdDurability, 10)
        var contacts = 0
        while missile.alive && contacts < 10 {
            let round = place(pdTurret(), in: world, from: Vec2(0, 100), to: Vec2(0, 100))
            round.pointDefenseBite = 7
            world.pointDefenseContacts()
            XCTAssertFalse(round.alive)
            contacts += 1
        }
        XCTAssertEqual(contacts, 3, "10 durability at 7 a round: 10 → 3 → −4 → dies")
    }

    func testRoundOnlyStopsHomingShots() {
        let world = World(player: makeShip("P", at: Vec2(5000, 5000)))
        let bolt = place(boltSpec(), in: world, from: Vec2(0, 100), to: Vec2(0, 100))
        let round = place(pdTurret(), in: world, from: Vec2(0, 100), to: Vec2(0, 100))
        XCTAssertNotEqual(bolt.guidance, .guided)
        world.pointDefenseContacts()
        XCTAssertTrue(bolt.alive, "an unguided shot is not a point-defense mark")
        XCTAssertTrue(round.alive)
    }

    // MARK: End to end

    func testPointDefenseTurretShootsDownAnIncomingMissile() {
        let attacker = makeShip("A", at: Vec2())
        let world = World(player: attacker)
        let defender = makeShip("B", at: Vec2(0, 400))
        let did = world.addNPC(defender)
        defender.weapons = [WeaponMount(spec: pdTurret())]
        attacker.weapons = [WeaponMount(spec: missileSpec())]
        attacker.currentTargetID = did
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        world.intent.firePrimary = false
        XCTAssertTrue(world.projectiles.contains { $0.guidance == .guided && $0.alive }, "the missile launched")

        var roundsFired = 0
        for _ in 0..<90 {
            world.step(1.0 / 30.0)
            roundsFired = max(roundsFired, world.projectiles.filter(\.isPointDefenseRound).count)
            if !world.projectiles.contains(where: { $0.guidance == .guided && $0.alive }) { break }
        }
        XCTAssertGreaterThan(roundsFired, 0, "the turret fired")
        XCTAssertFalse(world.projectiles.contains { $0.guidance == .guided && $0.alive },
                       "point defense must shoot the missile down")
        XCTAssertEqual(defender.shield, 100, "the missile never reached the defender")
        XCTAssertEqual(defender.armor, 100)
    }
}
