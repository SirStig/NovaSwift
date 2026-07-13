import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// Weapons, projectiles, shields-then-hull damage, beams, and death — the
/// substance behind an NPC's "attack".
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

    func testShieldsAbsorbFullyThenHullTakesDamage() {
        let s = makeShip("x", govt: 1, at: Vec2())
        // First hit: shields absorb it, so armor is spared.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 40))
        XCTAssertEqual(s.shield, 40, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 100, accuracy: 1e-9)
        // Second hit empties the shields — but the hull stays pristine: there is
        // no bleed-through on the shield-depleting shot.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 30))
        XCTAssertEqual(s.shield, 0, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 100, accuracy: 1e-9)
        // Only now, with shields already at zero, does armor take damage.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 30))
        XCTAssertEqual(s.shield, 0, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 70, accuracy: 1e-9)
    }

    /// `wëap` Flags 0x0020 — a shield-penetrating weapon damages the hull even
    /// while shields are still up (its energy still chips the shields too).
    func testShieldPenetratingWeaponReachesHullThroughShields() {
        let s = makeShip("x", govt: 1, at: Vec2())
        XCTAssertFalse(s.applyDamage(shield: 20, armor: 30, piercing: true))
        XCTAssertEqual(s.shield, 80, accuracy: 1e-9)   // energy still hits shields
        XCTAssertEqual(s.armor, 70, accuracy: 1e-9)    // mass reaches the hull anyway
    }

    func testProjectileTravelsHitsAndKills() {
        let attacker = makeShip("A", govt: 1, at: Vec2())          // player (entity 0)
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))       // 300px north
        let tid = world.addNPC(target)
        // Already disabled (crossed the 33%-armor threshold earlier): the next
        // hit that zeroes its armor is a real kill, not another disable roll.
        target.disabled = true
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

    // MARK: player death (SESSION_AUDIT_FOLLOWUPS.md §C — escape-pod survival)

    func testPlayerDeathReportsHadEscapePodFlag() {
        let player = makeShip("Player", govt: 0, at: Vec2())
        player.hasEscapePod = true
        player.armor = 0; player.shield = 0
        let world = World(player: player)

        world.step(1.0 / 30.0)
        let reported = world.events.contains {
            if case let .playerDestroyed(hadEscapePod) = $0 { return hadEscapePod }
            return false
        }
        XCTAssertTrue(reported, "a dead player with an escape pod should report hadEscapePod=true")
    }

    func testPlayerDeathWithoutEscapePodReportsFalse() {
        let player = makeShip("Player", govt: 0, at: Vec2())
        player.armor = 0; player.shield = 0
        let world = World(player: player)

        world.step(1.0 / 30.0)
        let reported = world.events.contains {
            if case let .playerDestroyed(hadEscapePod) = $0 { return !hadEscapePod }
            return false
        }
        XCTAssertTrue(reported, "a dead player with no escape pod should report hadEscapePod=false")
    }

    func testPlayerDeathReportsOnlyOnce() {
        let player = makeShip("Player", govt: 0, at: Vec2())
        player.armor = 0; player.shield = 0
        let world = World(player: player)

        world.step(1.0 / 30.0)
        let firstStepEvents = world.drainEvents()
        world.step(1.0 / 30.0)   // armor is still 0 — must not re-report
        let secondStepEvents = world.drainEvents()

        func deathCount(_ events: [WorldEvent]) -> Int {
            events.filter { if case .playerDestroyed = $0 { return true } else { return false } }.count
        }
        XCTAssertEqual(deathCount(firstStepEvents), 1)
        XCTAssertEqual(deathCount(secondStepEvents), 0, "must not re-report on a later step while armor stays at 0")
    }

    func testLivingPlayerNeverReportsDestroyed() {
        let player = makeShip("Player", govt: 0, at: Vec2())   // full armor/shield
        let world = World(player: player)

        world.step(1.0 / 30.0)
        XCTAssertFalse(world.events.contains { if case .playerDestroyed = $0 { return true } else { return false } })
    }

    func testHitCrossingArmorThresholdDisablesNotDestroys() {
        // EV Nova disables a ship the instant its armor crosses a fixed
        // percentage of max armor (33% by default) — deterministically, not by
        // a random roll — and only *then* can a further hit actually kill it.
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))
        _ = world.addNPC(target)
        target.armor = 40; target.maxArmor = 100; target.shield = 0   // 40% — above the 33% floor
        XCTAssertEqual(target.disableArmorFraction, 0.33, accuracy: 1e-9)

        attacker.angle = 0                                             // facing north, toward target
        attacker.weapons = [WeaponMount(spec: gun(armor: 15, beam: true))]  // 40% -> 25%: crosses 33%
        attacker.currentTargetID = target.entityID
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)

        XCTAssertTrue(target.disabled, "crossing the armor threshold disables the ship")
        XCTAssertTrue(target.isAlive, "a disabled ship is a hulk, not a kill")
        XCTAssertTrue(world.npcs.contains { $0 === target }, "the hulk stays in the world")

        // A further hit on the already-disabled hulk is a real kill.
        target.armor = 5
        attacker.weapons[0].cooldown = 0
        world.step(1.0 / 30.0)
        XCTAssertFalse(target.isAlive, "damage after disable actually destroys the hulk")
    }

    func testPointDefenseShootsDownIncomingGuidedProjectile() {
        // Guidance 9/10 (Bible): "fires automatically at incoming guided
        // weapons" — independent of the defender's own currentTargetID.
        let missile = WeaponSpec(id: 140, name: "Missile", shieldDamage: 50, armorDamage: 50,
                                 reloadSeconds: 1, projectileSpeed: 400, range: 3000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                                 blastRadius: 0, ammoPerShot: 0)
        let pd = WeaponSpec(id: 141, name: "Point Defense", shieldDamage: 5, armorDamage: 5,
                            reloadSeconds: 0.1, projectileSpeed: 0, range: 800,
                            accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                            blastRadius: 0, ammoPerShot: 0, isPointDefense: true)

        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let defender = makeShip("B", govt: 2, at: Vec2(0, 400))    // within the PD mount's 800px range
        let did = world.addNPC(defender)
        defender.weapons = [WeaponMount(spec: pd)]
        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = did
        world.intent.firePrimary = true

        world.step(1.0 / 30.0)
        XCTAssertTrue(world.projectiles.isEmpty, "point defense should shoot the incoming missile down")
        XCTAssertEqual(defender.shield, 100, "the intercepted missile never reaches the defender")
    }

    func testPointDefenseIgnoresPDImmuneProjectiles() {
        // wëap.Flags 0x0080 -> vulnerableToPD = false: some guided weapons
        // simply can't be shot down.
        let missile = WeaponSpec(id: 140, name: "Missile", shieldDamage: 50, armorDamage: 50,
                                 reloadSeconds: 1, projectileSpeed: 400, range: 3000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                                 blastRadius: 0, ammoPerShot: 0, vulnerableToPD: false)
        let pd = WeaponSpec(id: 141, name: "Point Defense", shieldDamage: 5, armorDamage: 5,
                            reloadSeconds: 0.1, projectileSpeed: 0, range: 800,
                            accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                            blastRadius: 0, ammoPerShot: 0, isPointDefense: true)

        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let defender = makeShip("B", govt: 2, at: Vec2(0, 400))
        let did = world.addNPC(defender)
        defender.weapons = [WeaponMount(spec: pd)]
        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = did
        world.intent.firePrimary = true

        world.step(1.0 / 30.0)
        XCTAssertFalse(world.projectiles.isEmpty, "a PD-immune missile should survive point defense")
    }

    func testNoFriendlyFire() {
        let attacker = makeShip("A", govt: 5, at: Vec2())
        attacker.government = 5
        let world = World(player: attacker)
        let ally = makeShip("B", govt: 5, at: Vec2(0, 200))         // same government
        ally.government = 5   // makeShip ignores its govt arg; set it so this is genuinely same-govt
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
        XCTAssertTrue(world.events.contains { if case .beam(_, _, _, _, let hit, _) = $0 { return hit } else { return false } })
    }

    // MARK: exit points & beam tracking

    private func exitGun(exitType: WeaponExitType = .gun, beam: Bool = false,
                         loop: Bool = false) -> WeaponSpec {
        WeaponSpec(id: 200, name: "EP", shieldDamage: 1, armorDamage: 1, reloadSeconds: 1,
                   projectileSpeed: 100, range: 200, accuracyRadians: 0, isBeam: beam,
                   isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0,
                   exitType: exitType, loopSound: loop)
    }

    func testMuzzleUsesRotatedExitPoint() {
        let s = makeShip("A", govt: 1, at: Vec2())
        // One gun hardpoint 10px to the right, 20px toward the nose (math coords).
        s.exitPoints = ShipExitPoints(gun: [Vec2(10, 20)], turret: [], guided: [], beam: [])
        s.weapons = [WeaponMount(spec: exitGun())]

        s.angle = 0                                     // facing north (+y)
        var m = s.muzzle(for: s.weapons[0])
        XCTAssertEqual(m.x, 10, accuracy: 1e-6)
        XCTAssertEqual(m.y, 20, accuracy: 1e-6)

        s.angle = .pi / 2                               // turned 90° clockwise → facing +x
        m = s.muzzle(for: s.weapons[0])
        XCTAssertEqual(m.x, 20, accuracy: 1e-6)         // "ahead" is now +x
        XCTAssertEqual(m.y, -10, accuracy: 1e-6)        // "right" is now -y
    }

    func testExitPointZNudgesScreenVertical() {
        let s = makeShip("A", govt: 1, at: Vec2())
        // Gun 3px right, 10 forward, with a +4 z (screen-up) nudge.
        s.exitPoints = ShipExitPoints(gun: [Vec2(3, 10)], turret: [], guided: [], beam: [],
                                      gunZ: [4])
        s.weapons = [WeaponMount(spec: exitGun())]
        s.angle = 0
        let m = s.muzzle(for: s.weapons[0])
        XCTAssertEqual(m.x, 3, accuracy: 1e-6)
        XCTAssertEqual(m.y, 14, accuracy: 1e-6)   // 10 forward + 4 unscaled z
    }

    func testMuzzleIndexesHardpoints() {
        let s = makeShip("A", govt: 1, at: Vec2())
        s.exitPoints = ShipExitPoints(gun: [Vec2(-10, 0), Vec2(10, 0)], turret: [], guided: [], beam: [])
        s.angle = 0
        XCTAssertEqual(s.muzzle(exitType: .gun, index: 0).x, -10, accuracy: 1e-6)
        XCTAssertEqual(s.muzzle(exitType: .gun, index: 1).x, 10, accuracy: 1e-6)
    }

    func testMultipleCopiesStaggerAndCycleBarrels() {
        // One gun *type*, two copies, reload 0.2s → one shot every 0.1s from
        // alternating barrels (not a 2-shot volley every 0.2s).
        let s = makeShip("A", govt: 1, at: Vec2())
        s.exitPoints = ShipExitPoints(gun: [Vec2(-10, 0), Vec2(10, 0)], turret: [], guided: [], beam: [])
        s.angle = 0
        let spec = WeaponSpec(id: 300, name: "G", shieldDamage: 1, armorDamage: 1, reloadSeconds: 0.2,
                              projectileSpeed: 500, range: 500, accuracyRadians: 0, isBeam: false,
                              isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0, exitType: .gun)
        let world = World(player: s)
        s.weapons = [WeaponMount(spec: spec, count: 2)]
        world.intent.firePrimary = true

        world.step(1.0 / 60.0)
        XCTAssertEqual(world.projectiles.count, 1, "a 2-copy group fires one barrel at a time, not a volley")
        XCTAssertEqual(world.projectiles[0].position.x, -10, accuracy: 2, "first shot from the first barrel")

        // Next barrel becomes ready after reload/count = 0.1s.
        for _ in 0..<8 { world.step(1.0 / 60.0) }
        XCTAssertGreaterThanOrEqual(world.projectiles.count, 2, "the group refires after reload/count, not reload")
        XCTAssertTrue(world.projectiles.contains { abs($0.position.x - 10) < 2 },
                      "the second shot leaves the other barrel (+10)")
    }

    func testContinuousBeamStaysWeldedToMovingShip() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        attacker.exitPoints = ShipExitPoints(gun: [], turret: [], guided: [], beam: [Vec2(0, 10)])
        attacker.weapons = [WeaponMount(spec: exitGun(beam: true, loop: true))]
        world.intent.firePrimary = true

        world.step(1.0 / 30.0)
        XCTAssertEqual(world.activeBeams.count, 1, "a held continuous beam yields one live beam")
        XCTAssertEqual(world.activeBeams[0].from.x, 0, accuracy: 1e-6)

        // Teleport the shooter: the beam origin must follow it, not stay put.
        attacker.position = Vec2(500, 0)
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.activeBeams[0].from.x, 500, accuracy: 5, "beam origin tracks the ship")

        // Releasing the trigger tears the beam down.
        world.intent.firePrimary = false
        world.step(1.0 / 30.0)
        XCTAssertTrue(world.activeBeams.isEmpty, "beam ends when the trigger releases")
    }

    // MARK: guidance, turrets, rockets, burst

    func testTurretHoldsFireWithoutTargetAndAimsIndependently() {
        let turret = WeaponSpec(id: 210, name: "Turret", shieldDamage: 10, armorDamage: 10,
                                reloadSeconds: 0.05, projectileSpeed: 500, range: 2000,
                                accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                                blastRadius: 0, ammoPerShot: 0, guidance: .turret, isTurret: true)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        attacker.angle = 0                                      // hull faces +y (north)
        let world = World(player: attacker)
        attacker.weapons = [WeaponMount(spec: turret)]
        world.intent.firePrimary = true

        world.step(1.0 / 30.0)
        XCTAssertTrue(world.projectiles.isEmpty, "a turret with no target holds fire")

        // Target directly behind the ship (south): a turret still engages it.
        let target = makeShip("B", govt: 2, at: Vec2(0, -300))
        attacker.currentTargetID = world.addNPC(target)
        world.step(1.0 / 30.0)
        XCTAssertFalse(world.projectiles.isEmpty, "a turret fires at a target regardless of hull facing")
        XCTAssertLessThan(world.projectiles[0].velocity.y, 0,
                          "the turret shot flies toward the target (south), not along the hull heading (north)")
    }

    func testGuidedMissileHomesOntoTarget() {
        let missile = WeaponSpec(id: 211, name: "Missile", shieldDamage: 40, armorDamage: 40,
                                 reloadSeconds: 1, projectileSpeed: 500, range: 6000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 8,
                                 blastRadius: 0, ammoPerShot: 0, guidance: .guided)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        attacker.angle = 0                                      // launches north
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(350, 450)) // off to the side
        let tid = world.addNPC(target)
        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        world.intent.firePrimary = false                       // just the one missile

        var hit = false
        for _ in 0..<150 {
            world.step(1.0 / 30.0)
            if target.shield < 100 { hit = true; break }
        }
        XCTAssertTrue(hit, "a guided missile launched north curves to hit a target off to the side")
    }

    func testBurstFireCadence() {
        let burst = WeaponSpec(id: 212, name: "Burst", shieldDamage: 5, armorDamage: 5,
                               reloadSeconds: 0.05, projectileSpeed: 500, range: 1000,
                               accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                               blastRadius: 0, ammoPerShot: 0, burstCount: 3, burstReloadSeconds: 2.0)
        let mount = WeaponMount(spec: burst)          // one copy → burst threshold = 3
        XCTAssertEqual(mount.burstShots, 0)
        mount.didFire(shots: 1); XCTAssertEqual(mount.cooldown, 0.05, accuracy: 1e-9)  // shot 1 of burst
        mount.cooldown = 0; mount.didFire(shots: 1); XCTAssertEqual(mount.cooldown, 0.05, accuracy: 1e-9)  // shot 2
        mount.cooldown = 0; mount.didFire(shots: 1); XCTAssertEqual(mount.cooldown, 2.0, accuracy: 1e-9)   // burst spent → long reload
        XCTAssertEqual(mount.burstShots, 0, "the burst counter resets after the long reload")
    }

    // MARK: ionization

    func testWeaponHitAddsIonizationCharge() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 250))
        _ = world.addNPC(target)
        target.ionizeMax = 100

        let ionBeam = WeaponSpec(id: 150, name: "Ion Cannon", shieldDamage: 0, armorDamage: 0,
                                reloadSeconds: 1, projectileSpeed: 0, range: 600,
                                accuracyRadians: 0, isBeam: true, isGuided: false, turnRate: 0,
                                blastRadius: 0, ammoPerShot: 0, ionization: 40)
        attacker.weapons = [WeaponMount(spec: ionBeam)]
        attacker.currentTargetID = target.entityID
        attacker.angle = 0
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)

        XCTAssertEqual(target.ionCharge, 40, accuracy: 1e-9)
        XCTAssertFalse(target.isIonized, "below IonizeMax — not yet fully ionized")
    }

    func testIonizedShipCannotThrustOrTurn() {
        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 100   // fully ionized
        var intent = ControlIntent()
        intent.thrust = true
        intent.turnLeft = true
        s.step(1.0, intent: intent, tuning: .default)
        XCTAssertEqual(s.velocity.length, 0, "a fully-ionized ship can't thrust")
        XCTAssertEqual(s.angle, 0, "a fully-ionized ship can't turn")
    }

    func testIonizationDissipatesOverTime() {
        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 100
        s.deionizePerSec = 30
        s.regen(1.0)
        XCTAssertEqual(s.ionCharge, 70, accuracy: 1e-9)
        XCTAssertFalse(s.isIonized, "charge dropped back below the threshold")
    }

    func testCantFireWhileIonizedWeaponIsBlocked() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        attacker.ionizeMax = 100
        attacker.ionCharge = 100   // fully ionized
        let world = World(player: attacker)
        let target = makeShip("B", govt: 2, at: Vec2(0, 250))
        let tid = world.addNPC(target)

        let missile = WeaponSpec(id: 151, name: "Homing Missile", shieldDamage: 30, armorDamage: 30,
                                 reloadSeconds: 0.1, projectileSpeed: 400, range: 3000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 1,
                                 blastRadius: 0, ammoPerShot: 0, cantFireWhileIonized: true)
        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)

        XCTAssertTrue(world.projectiles.isEmpty, "a Seeker-0x0020 weapon should refuse to fire while its ship is ionized")
    }

    // MARK: Seeker jamming/interference (0x0008/0x0010, SESSION_AUDIT_FOLLOWUPS.md §B)

    /// A minimal `gövt` with `InhJam1-4` set (offset 92, 4×16-bit).
    private func govtWithJamming(id: Int, jamming: [Int]) -> GovtRes {
        var d = [UInt8](repeating: 0, count: 100)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for (i, v) in jamming.prefix(4).enumerated() { putW(92 + i * 2, v) }
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(d)))
    }

    func testTurnsAwayIfJammedEventuallyLosesLockAgainstAHighJamGovt() {
        let missile = WeaponSpec(id: 150, name: "Seeker", shieldDamage: 10, armorDamage: 10,
                                 reloadSeconds: 1, projectileSpeed: 400, range: 30_000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                                 blastRadius: 0, ammoPerShot: 0, turnsAwayIfJammed: true)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithJamming(id: 2, jamming: [100, 0, 0, 0])])
        let target = makeShip("B", govt: 2, at: Vec2(0, 2000))
        target.government = 2
        let tid = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)   // fires the missile
        XCTAssertEqual(world.projectiles.count, 1)

        var lostLock = false
        for _ in 0..<300 {   // up to 10s — a 100%-jammed target should lose lock well before then
            world.step(1.0 / 30.0)
            if world.projectiles.first?.targetID == nil { lostLock = true; break }
        }
        XCTAssertTrue(lostLock, "a fully-jammed government's ship should eventually shake the lock")
    }

    func testTurnsAwayIfJammedNeverTriggersAgainstAnUnjammedGovt() {
        let missile = WeaponSpec(id: 150, name: "Seeker", shieldDamage: 10, armorDamage: 10,
                                 reloadSeconds: 1, projectileSpeed: 400, range: 30_000,
                                 accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                                 blastRadius: 0, ammoPerShot: 0, turnsAwayIfJammed: true)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithJamming(id: 2, jamming: [0, 0, 0, 0])])
        let target = makeShip("B", govt: 2, at: Vec2(0, 2000))
        target.government = 2
        let tid = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.projectiles.count, 1)

        for _ in 0..<120 { world.step(1.0 / 30.0) }
        XCTAssertEqual(world.projectiles.first?.targetID, tid, "zero jamming should never shake the lock")
    }

    func testConfusedByInterferenceSlowsSteeringButNotUnaffectedWeapons() {
        let jammed = WeaponSpec(id: 152, name: "Confused Seeker", shieldDamage: 10, armorDamage: 10,
                                reloadSeconds: 1, projectileSpeed: 400, range: 3000,
                                accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 4,
                                blastRadius: 0, ammoPerShot: 0, confusedByInterference: true)
        let clean = WeaponSpec(id: 153, name: "Clean Seeker", shieldDamage: 10, armorDamage: 10,
                               reloadSeconds: 1, projectileSpeed: 400, range: 3000,
                               accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 4,
                               blastRadius: 0, ammoPerShot: 0)

        // Target well off-axis so the lead angle requires real steering, and
        // moving so the intercept keeps demanding correction frame to frame.
        func fireOneAndMeasureFacingDrift(_ spec: WeaponSpec, interference: Int) -> Double {
            let attacker = makeShip("A", govt: 1, at: Vec2())
            let world = World(player: attacker)
            world.systemInterference = interference
            let target = makeShip("B", govt: 2, at: Vec2(1500, 1500))
            target.velocity = Vec2(0, 200)
            let tid = world.addNPC(target)
            attacker.weapons = [WeaponMount(spec: spec)]
            attacker.currentTargetID = tid
            world.intent.firePrimary = true
            world.step(1.0 / 30.0)
            guard let p = world.projectiles.first else { return 0 }
            let startFacing = p.facing
            for _ in 0..<10 { world.step(1.0 / 30.0) }
            guard let p2 = world.projectiles.first else { return 0 }
            return abs(angleDelta(from: startFacing, to: p2.facing))
        }

        let confusedDrift = fireOneAndMeasureFacingDrift(jammed, interference: 100)
        let cleanDrift = fireOneAndMeasureFacingDrift(clean, interference: 100)
        XCTAssertLessThan(confusedDrift, cleanDrift,
                          "at 100% interference a confused-by-interference seeker should steer less than an unaffected one")
    }

    // MARK: legal-record wiring (disable/kill dent standing, shooting alone does not)

    /// A minimal `gövt` with `DisabPenalty@12`/`KillPenalty@16`/`ShootPenalty@18`
    /// set to distinct, recognizable values so a test can tell which one fired.
    private func govtWithPenalties(id: Int, disablePenalty: Int, killPenalty: Int, shootPenalty: Int) -> GovtRes {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        putW(12, disablePenalty); putW(16, killPenalty); putW(18, shootPenalty)
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(d)))
    }

    func testDisablingAShipDentsLegalRecordViaDisabPenaltyOnly() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithPenalties(id: 2, disablePenalty: 3, killPenalty: 99, shootPenalty: 999)])
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))
        target.government = 2
        _ = world.addNPC(target)
        target.armor = 40; target.maxArmor = 100; target.shield = 0   // just above the 33% disable floor

        attacker.angle = 0
        attacker.weapons = [WeaponMount(spec: gun(armor: 15, beam: true))]  // crosses the disable threshold
        attacker.currentTargetID = target.entityID
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)

        XCTAssertTrue(target.disabled)
        XCTAssertEqual(world.diplomacy?.playerRecord[2], -3, "only DisabPenalty applied, not ShootPenalty")
    }

    func testDestroyingAShipDentsLegalRecordAndCreditsCombatRating() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithPenalties(id: 2, disablePenalty: 1, killPenalty: 8, shootPenalty: 999)])
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))
        target.government = 2
        target.combatStrength = 55
        _ = world.addNPC(target)
        target.disabled = true                       // already a hulk
        target.armor = 5; target.shield = 0           // one more hit finishes it

        attacker.weapons = [WeaponMount(spec: gun())]
        attacker.currentTargetID = target.entityID
        world.intent.firePrimary = true

        var destroyed = false
        for _ in 0..<60 {
            world.step(1.0 / 30.0)
            if world.events.contains(where: { if case .shipDestroyed = $0 { return true } else { return false } }) {
                destroyed = true; break
            }
        }
        XCTAssertTrue(destroyed)
        XCTAssertEqual(world.diplomacy?.playerRecord[2], -8, "KillPenalty applied on the actual kill")
        XCTAssertEqual(world.diplomacy?.combatRating, 55, "combat rating credited with the destroyed ship's strength")
    }

    func testDeadPlayerFreezesStopsAndReleasesBeamLoop() {
        // On death the wreck must stop dead (not fly on under live input, looking
        // alive) and its own continuous-fire beam loop must be released (else it
        // keeps sounding into the menu).
        let player = makeShip("P", govt: 5, at: Vec2())
        player.velocity = Vec2(500, 0)          // was flying
        player.activeBeamLoopMounts = [0]        // holding a beam trigger as it dies
        player.armor = 0; player.shield = 0      // fatal hit landed
        let world = World(player: player)
        world.intent.thrust = true               // input still "held" — must be ignored

        world.step(1.0 / 30.0)

        XCTAssertEqual(player.velocity.length, 0, accuracy: 1e-6,
                       "a dead player's wreck freezes in place, ignoring live input")
        XCTAssertTrue(world.events.contains { if case .playerDestroyed = $0 { return true }; return false },
                      "player death is reported")
        XCTAssertTrue(world.events.contains {
            if case let .beamLoopStop(shooterID, _) = $0 { return shooterID == World.playerEntityID }
            return false
        }, "the player's own beam loop is released on death")
    }
}
