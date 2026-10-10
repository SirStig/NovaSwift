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
        // WP-12 (`Ship_ApplyDamageToShip` 0x004192d0): energy comes off the
        // shields; once they're at or below zero — this hit included — mass
        // comes off the armor, and the shields bottom out at −10 % of max.
        let s = makeShip("x", govt: 1, at: Vec2())
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 40))
        XCTAssertEqual(s.shield, 40, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 100, accuracy: 1e-9)
        // The hit that breaks the shields lands its mass damage too.
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 30))
        XCTAssertEqual(s.shield, -10, accuracy: 1e-9, "a broken shield floors at −10 % of max")
        XCTAssertEqual(s.armor, 70, accuracy: 1e-9)
        XCTAssertFalse(s.applyDamage(shield: 60, armor: 30))
        XCTAssertEqual(s.shield, -10, accuracy: 1e-9)
        XCTAssertEqual(s.armor, 40, accuracy: 1e-9)
        // A mass-only hit reaches the armor until the shields regenerate past 0.
        s.shield = -5
        s.applyDamage(shield: 0, armor: 10)
        XCTAssertEqual(s.armor, 30, accuracy: 1e-9)
        s.shield = 1
        s.applyDamage(shield: 0, armor: 10)
        XCTAssertEqual(s.armor, 30, accuracy: 1e-9, "positive shields absorb a mass-only hit")
    }

    /// `wëap` Flags 0x0020 — a shield-penetrating weapon applies only its mass
    /// damage, straight to the armor; the shields are untouched (WP-12).
    func testShieldPenetratingWeaponReachesHullThroughShields() {
        let s = makeShip("x", govt: 1, at: Vec2())
        XCTAssertFalse(s.applyDamage(shield: 20, armor: 30, piercing: true))
        XCTAssertEqual(s.shield, 100, accuracy: 1e-9)  // no shield damage at all
        XCTAssertEqual(s.armor, 70, accuracy: 1e-9)
    }

    /// A non-lethal hit (`wëap` Flags2 0x1000) that would take armor to zero
    /// leaves exactly 1 (OQ B6).
    func testNonLethalHitLeavesOneArmor() {
        let s = makeShip("x", govt: 1, at: Vec2())
        s.shield = 0
        s.applyDamage(shield: 0, armor: 500, nonLethal: true)
        XCTAssertEqual(s.armor, 1, accuracy: 1e-9)
        XCTAssertTrue(s.isAlive)
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

    func testPlayerDeathRunsItsSequenceThenReportsTheLossOnce() {
        // OS-02: `.playerDying` at once; `.playerDestroyed` once the
        // death sequence runs out with no eject — exactly once.
        let player = makeShip("Player", govt: 0, at: Vec2())
        player.armor = 0; player.shield = 0
        let world = World(player: player)

        world.step(1.0 / 30.0)
        let first = world.drainEvents()
        XCTAssertTrue(first.contains { if case .playerDying = $0 { return true } else { return false } })
        var losses = 0
        for _ in 0..<120 {
            world.step(1.0 / 30.0)
            losses += world.drainEvents().filter {
                if case .playerDestroyed = $0 { return true } else { return false }
            }.count
        }
        XCTAssertEqual(losses, 1)
    }

    func testLivingPlayerNeverReportsDestroyed() {
        let player = makeShip("Player", govt: 0, at: Vec2())   // full armor/shield
        let world = World(player: player)

        world.step(1.0 / 30.0)
        XCTAssertFalse(world.events.contains { if case .playerDestroyed = $0 { return true } else { return false } })
    }

    func testPlayerUnderSustainedFireDiesDespiteShieldRegen() {
        // Regression for the reported "zero hull/shields but still alive under
        // attack" bug. A player pinned at zero shields by continuous fire used to
        // be immortal: shield regen runs before damage each frame, so a hull gate
        // keyed on "shields were up *before* this shot" read as up every frame
        // (the regen sliver), and the incoming fire never bled into armor. With the
        // gate keyed on shields *after* the shot, the hull takes damage and the
        // player dies. The per-frame `applyDamage` here stands in for the beam; the
        // brisk regen inside `world.step` is exactly what previously hid the hull.
        let player = makeShip("Player", govt: 0, at: Vec2())
        player.shieldRechargePerSec = 40   // brisk regen — the sliver that hid the bug
        let world = World(player: player)

        var died = false
        var sawHullLoss = false
        for _ in 0..<900 {                                             // up to 30s
            player.applyDamage(shield: 20, armor: 20)                  // this frame's incoming fire
            if player.armor < player.maxArmor { sawHullLoss = true }
            world.step(1.0 / 30.0)                                     // regen + death check
            if world.drainEvents().contains(where: { if case .playerDestroyed = $0 { return true } else { return false } }) {
                died = true; break
            }
        }
        XCTAssertTrue(sawHullLoss, "sustained fire must eat into the hull even with shields regenerating")
        XCTAssertTrue(died, "a player held at zero shields under continuous fire should eventually be destroyed")
        XCTAssertLessThanOrEqual(player.armor, 0, "the player is dead with no armor left")
    }

    func testDisableIsDerivedFromArmorNotLatched() {
        // WP-02 (`Ship_IsShipDisabled` 0x004687b0): `armor × 100 < max × 33.333`
        // (10.0 with hull Flags 0x0010), evaluated every time it's asked.
        let world = World(player: makeShip("A", govt: 1, at: Vec2()))
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))
        _ = world.addNPC(target)
        XCTAssertEqual(target.disableArmorFraction, 0.33333, accuracy: 1e-9)
        target.shield = 0
        target.armor = 33.334
        XCTAssertFalse(target.disabled)
        target.armor = 33.332
        XCTAssertTrue(target.disabled)
        target.armor = 34
        XCTAssertFalse(target.disabled, "repairing above the line brings it back")

        // A hit taking it from 40 % to 25 % disables it; the hulk keeps its
        // real armor, and 25 more points of damage destroy it.
        target.armor = 40
        world.applyHit(to: target, shield: 0, armor: 15, ownerID: 0)
        XCTAssertTrue(target.disabled)
        XCTAssertTrue(target.isAlive, "a disabled ship is a hulk, not a kill")
        XCTAssertEqual(target.armor, 25, accuracy: 1e-9, "no 2 % sliver")
        world.applyHit(to: target, shield: 0, armor: 24, ownerID: 0)
        XCTAssertTrue(target.isAlive)
        world.applyHit(to: target, shield: 0, armor: 2, ownerID: 0)
        XCTAssertFalse(target.isAlive)

        // One hit can go straight from healthy to destroyed.
        let other = makeShip("C", govt: 2, at: Vec2(0, 500))
        _ = world.addNPC(other)
        other.shield = 0; other.armor = 50
        world.applyHit(to: other, shield: 0, armor: 60, ownerID: 0)
        XCTAssertFalse(other.isAlive, "50 % → −10 % is a kill, not a disable")
    }

    func testPlayerCanBeDisabled() {
        // WP-03: no player exemption in 0x004687b0. A disabled player gets a
        // 300-tick post-disable window, whole-number armor, and loses its
        // thrust and fire (only face-target turning remains).
        let player = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: player)
        player.shield = 0; player.armor = 40.7
        world.applyHit(to: player, shield: 0, armor: 10, ownerID: -1)
        XCTAssertTrue(player.disabled)
        XCTAssertEqual(player.armor, 30, accuracy: 1e-9, "armor truncated on the transition")
        XCTAssertEqual(player.recentlyHitTicks, 300)
        XCTAssertTrue(world.events.contains { if case .shipDisabled(0, _) = $0 { return true } else { return false } })

        player.weapons = [WeaponMount(spec: gun())]
        world.intent.thrust = true
        world.intent.firePrimary = true
        world.intent.turnLeft = true
        for _ in 0..<15 { world.step(1.0 / 30.0) }
        XCTAssertEqual(player.velocity.length, 0, accuracy: 1e-9, "no thrust while disabled")
        XCTAssertEqual(player.angle, 0, accuracy: 1e-9, "no turn keys while disabled")
        XCTAssertTrue(world.projectiles.isEmpty, "no fire while disabled")
        XCTAssertEqual(player.armor, 30, accuracy: 1e-9, "no regeneration while disabled")
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
                            accuracyRadians: 0, isBeam: true, isGuided: false, turnRate: 0,
                            blastRadius: 0, ammoPerShot: 0, isPointDefense: true,
                            guidance: .pointDefenseBeam)

        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let defender = makeShip("B", govt: 2, at: Vec2(0, 400))    // within the PD beam's 800px
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
        // An NPC's shots pass through its own government's ships.
        let world = World(player: makeShip("P", govt: 1, at: Vec2(5000, 5000)))
        let attacker = makeShip("A", govt: 133, at: Vec2())
        attacker.government = 133
        attacker.brain = AIBrain(aiType: .warship, govt: 133)
        world.addNPC(attacker)
        let ally = makeShip("B", govt: 133, at: Vec2(0, 200))         // same government
        ally.government = 133   // makeShip ignores its govt arg; set it so this is genuinely same-govt
        let tid = world.addNPC(ally)
        attacker.weapons = [WeaponMount(spec: gun())]
        var fired = 0
        for _ in 0..<60 {
            attacker.currentTargetID = tid
            attacker.weapons[0].cooldown = 0
            world.testFire(attacker, primary: true)
            fired += world.projectiles.count
            world.step(1.0 / 30.0)
        }
        XCTAssertGreaterThan(fired, 0)
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
        XCTAssertTrue(world.events.contains { if case .beam(_, _, _, _, let hit, _, _) = $0 { return hit } else { return false } })
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
        world.applyHit(to: target, shield: 0, armor: 0, ownerID: 0, ionization: 40)
        XCTAssertEqual(target.ionCharge, 40, accuracy: 1e-9)
        XCTAssertFalse(target.isIonized, "below IonizeMax — not yet fully ionized")
        for _ in 0..<3 { world.applyHit(to: target, shield: 0, armor: 0, ownerID: 0, ionization: 40) }
        XCTAssertEqual(target.ionCharge, 160, accuracy: 1e-9, "charge accumulates uncapped (WP-11)")
    }

    func testIonizationWeakensThrustAndCoastingTurn() {
        // WP-11: I = min(0.7, charge / capacity). Thrust × (1 − I); the turn
        // × (1 − I) only while not thrusting.
        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 50
        var intent = ControlIntent()
        intent.thrust = true
        intent.turnLeft = true
        s.step(1.0 / 30.0, intent: intent, tuning: .default)
        XCTAssertEqual(s.velocity.length, 200 * 0.5 / 30, accuracy: 1e-9, "50 % charge halves thrust")
        XCTAssertEqual(s.angle, -.pi / 30, accuracy: 1e-9, "turning under thrust is unaffected")

        let c = makeShip("y", govt: 1, at: Vec2())
        c.ionizeMax = 100
        c.ionCharge = 250   // past capacity: intensity stays capped at 0.7
        XCTAssertEqual(c.ionIntensity, 0.7, accuracy: 1e-12)
        var coast = ControlIntent()
        coast.turnLeft = true
        c.step(1.0 / 30.0, intent: coast, tuning: .default)
        // The player's turn then truncates: 6°/tick × 0.3 = 1.8 → 1°.
        XCTAssertEqual(c.angle, -.pi / 180, accuracy: 1e-9, "a coasting turn × 0.3 at ≥ 70 %")
    }

    func testIonizationDragsSpeedTowardTheReducedCap() {
        // The charge drags each axis toward (1 − I) × top speed by 0.025
        // px/tick every tick.
        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 50
        s.deionizePerSec = 0
        s.velocity = Vec2(300, 0)              // top speed 300 → cap 150
        s.deionize(1.0 / 30.0)
        XCTAssertEqual(s.velocity.x, 300 - 0.75, accuracy: 1e-9)
    }

    func testIonizationDissipatesOverTime() {
        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 100
        s.deionizePerSec = 30
        s.deionize(1.0)
        XCTAssertEqual(s.ionCharge, 70, accuracy: 1e-9)
        XCTAssertFalse(s.isIonized, "charge dropped back below the threshold")
    }

    /// A hulk recovers no shields/armor/fuel, but ionization is an externally
    /// applied charge dissipating on its own — it must still fade, or a ship
    /// ionized and then disabled glows (and pulses) at full strength forever.
    func testIonizationDissipatesOnADisabledHulk() {
        let world = World(player: makeShip("P", govt: 1, at: Vec2()))
        let hulk = makeShip("x", govt: 1, at: Vec2(500, 0))
        hulk.ionizeMax = 100
        hulk.ionCharge = 100
        hulk.deionizePerSec = 30
        hulk.ionizeColor = (1, 0, 0)
        hulk.disabled = true
        world.addNPC(hulk)
        world.step(1.0)
        XCTAssertEqual(hulk.ionCharge, 70, accuracy: 1e-9, "a hulk still bleeds off ion charge")
        world.step(3.0)
        XCTAssertEqual(hulk.ionCharge, 0, accuracy: 1e-9)
        XCTAssertNil(hulk.ionizeColor, "the glow clears once the charge is gone")
    }

    /// The loader reads a hull's `Deionize` as charge per 1/30 s tick × 0.01,
    /// and a 0 (most stock hulls) as a full 1.0 per tick — so a 0-Deionize hull
    /// sheds 30 points a second rather than never fading.
    func testDeionizeUsesTheLoaderRate() {
        func hull(deionize: Int) -> ShipRes {
            var b = [UInt8](repeating: 0, count: 1860)
            b[874] = UInt8((deionize >> 8) & 0xFF); b[875] = UInt8(deionize & 0xFF)
            return ShipRes(Resource(type: NovaType.ship, id: 128, data: Data(b)))
        }
        XCTAssertEqual(hull(deionize: 0).deionizePerTick, 1.0)
        XCTAssertEqual(hull(deionize: -5).deionizePerTick, 1.0)
        XCTAssertEqual(hull(deionize: 50).deionizePerTick, 0.5, accuracy: 1e-12)

        let s = makeShip("x", govt: 1, at: Vec2())
        s.ionizeMax = 100
        s.ionCharge = 100
        s.deionizePerSec = hull(deionize: 0).deionizePerTick * 30
        s.ionizeColor = (1, 0, 0)
        s.deionize(100.0 / 30.0)
        XCTAssertEqual(s.ionCharge, 0, accuracy: 1e-9, "a full 100-point charge fades in 100 ticks")
        XCTAssertNil(s.ionizeColor, "and the glow clears with it")
    }

    /// A hulk has no attitude control: it coasts on the momentum it had, on the
    /// heading it had. It must not steer itself.
    func testDisabledHulkDriftsWithoutTurning() {
        let world = World(player: makeShip("P", govt: 1, at: Vec2()))
        let hulk = makeShip("x", govt: 1, at: Vec2(500, 0))
        hulk.disabled = true
        hulk.angle = 1.25
        hulk.velocity = Vec2(40, 0)
        world.addNPC(hulk)
        for _ in 0..<30 { world.step(1.0 / 30.0) }
        XCTAssertEqual(hulk.angle, 1.25, accuracy: 1e-9, "a hulk holds its heading")
        XCTAssertGreaterThan(hulk.position.x, 500, "but it still drifts")
        XCTAssertLessThan(hulk.velocity.length, 40, "bleeding off speed as it goes")
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

    /// A seeker vulnerable to one jammer type, as `wëap.JamVuln1-4` describes.
    private func seeker(vulnerableTo type: Int, percent: Int = 100) -> WeaponSpec {
        var flags = WeaponBehaviorFlags()
        flags.jamVulnerability = (0..<4).map { $0 == type ? percent : 0 }
        return WeaponSpec(id: 150, name: "Seeker", shieldDamage: 10, armorDamage: 10,
                          reloadSeconds: 1, projectileSpeed: 400, range: 30_000,
                          accuracyRadians: 0, isBeam: false, isGuided: true, turnRate: 2,
                          blastRadius: 0, ammoPerShot: 0, turnsAwayIfJammed: true, flags: flags)
    }

    func testJammedSeekerKeepsItsTargetButStopsTurning() {
        // WP-09: a channel jams when `jamScore > 100 − lock`, lock rolled
        // `rand(JamVuln + 1)` at launch. The jam score is the hull's inherent
        // government InhJam plus its jammers. A jammed seeker flies straight
        // (Seeker 0x0010 turns away) but keeps its target.
        let missile = seeker(vulnerableTo: 0)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithJamming(id: 140, jamming: [100, 0, 0, 0])])
        let target = makeShip("B", govt: 2, at: Vec2(1500, 1500))
        target.inherentJamGovt = 140
        XCTAssertEqual(world.jamScores(of: target), [100, 0, 0, 0])
        let tid = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        world.intent.firePrimary = false
        let shot = try! XCTUnwrap(world.projectiles.first)
        XCTAssertGreaterThan(shot.jamLocks[0], 0, "a nonzero lock roll (1 in 101 rolls 0)")
        let start = shot.facing
        for _ in 0..<60 { world.step(1.0 / 30.0) }
        XCTAssertEqual(shot.targetID, tid, "the jammed seeker keeps its target")
        // Turning away: the heading moves *away* from the target's bearing.
        XCTAssertLessThan(angleDelta(from: start, to: shot.facing), 0,
                          "Seeker 0x0010 turns away from a target off to its right")
    }

    func testTurnsAwayIfJammedNeverTriggersAgainstAnUnjammedGovt() {
        let missile = seeker(vulnerableTo: 0)
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithJamming(id: 140, jamming: [0, 0, 0, 0])])
        let target = makeShip("B", govt: 2, at: Vec2(0, 2000))
        target.inherentJamGovt = 140
        let tid = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.projectiles.count, 1)

        for _ in 0..<120 { world.step(1.0 / 30.0) }
        XCTAssertEqual(world.projectiles.first?.targetID, tid, "zero jamming should never shake the lock")
    }

    /// The point of decoding `wëap.JamVuln1-4`: jamming is **per type**. A target
    /// running a type-2 jammer at full strength is no defence at all against a
    /// seeker that only answers to type 1 — which the old model (all four
    /// strengths summed into one scalar, clamped 0-100) got exactly backwards.
    func testJammingOfTheWrongTypeNeverShakesTheLock() {
        let missile = seeker(vulnerableTo: 0)      // vulnerable to jam type 1 only
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        // Type 2 jammer, maxed — and three more types the seeker ignores.
        world.diplomacy = Diplomacy(govts: [govtWithJamming(id: 140, jamming: [0, 100, 100, 100])])
        let target = makeShip("B", govt: 2, at: Vec2(0, 2000))
        target.inherentJamGovt = 140
        let tid = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: missile)]
        attacker.currentTargetID = tid
        world.intent.firePrimary = true
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.projectiles.count, 1)

        for _ in 0..<300 { world.step(1.0 / 30.0) }
        XCTAssertEqual(world.projectiles.first?.targetID, tid,
                       "300% of the wrong jammer types must not touch a type-1 seeker")
    }

    /// A ship's own `oütf` ModType 33-36 jammers stack onto its government's
    /// inherent `InhJam1-4`, per type.
    func testShipJammersStackOntoGovernmentJammingPerType() {
        let ship = makeShip("B", govt: 2, at: Vec2())
        ship.jamming = [40, 0, 0, 0]
        let combined = ship.combinedJamming(govtJamming: [30, 90, 0, 0])
        XCTAssertEqual(combined, [70, 90, 0, 0])

        // And each type is clamped, so a heavily-jammed government plus a fitted
        // jammer can't exceed certainty on that type.
        ship.jamming = [80, 0, 0, 0]
        XCTAssertEqual(ship.combinedJamming(govtJamming: [50, 0, 0, 0]), [100, 0, 0, 0])
    }

    /// `WeaponBehaviorFlags.jamChance` combines the matched types as independent
    /// trials — several partial jammers stack toward, but never past, certainty.
    func testJamChanceCombinesMatchedTypesIndependently() {
        var flags = WeaponBehaviorFlags()
        flags.jamVulnerability = [50, 50, 0, 0]
        // 50% strength × 50% vulnerability = 25% per type; union of two = 43.75%.
        XCTAssertEqual(flags.jamChance(against: [50, 50, 0, 0]), 0.4375, accuracy: 1e-9)
        // A type the weapon ignores contributes nothing.
        XCTAssertEqual(flags.jamChance(against: [0, 0, 100, 100]), 0, accuracy: 1e-9)
        // Full jammer strength is still capped by the weapon's own vulnerability.
        XCTAssertEqual(flags.jamChance(against: [100, 0, 0, 0]), 0.5, accuracy: 1e-9)
        // Full strength against full vulnerability is certain.
        var total = WeaponBehaviorFlags()
        total.jamVulnerability = [100, 0, 0, 0]
        XCTAssertEqual(total.jamChance(against: [100, 0, 0, 0]), 1, accuracy: 1e-9)
    }

    /// Turret blind arcs (`wëap.Flags` 0x1000/0x2000/0x4000) tile the circle:
    /// front and rear are ±45° cones, the sides are everything between.
    func testTurretBlindArcs() {
        var front = WeaponBehaviorFlags(); front.turretBlindFront = true
        XCTAssertFalse(front.turretCanBear(relativeBearing: 0))
        XCTAssertTrue(front.turretCanBear(relativeBearing: .pi / 2))
        XCTAssertTrue(front.turretCanBear(relativeBearing: .pi))

        var rear = WeaponBehaviorFlags(); rear.turretBlindRear = true
        XCTAssertTrue(rear.turretCanBear(relativeBearing: 0))
        XCTAssertFalse(rear.turretCanBear(relativeBearing: .pi))
        XCTAssertFalse(rear.turretCanBear(relativeBearing: -.pi))

        var sides = WeaponBehaviorFlags(); sides.turretBlindSides = true
        XCTAssertTrue(sides.turretCanBear(relativeBearing: 0))
        XCTAssertFalse(sides.turretCanBear(relativeBearing: .pi / 2))
        XCTAssertFalse(sides.turretCanBear(relativeBearing: -.pi / 2))

        // No flags: bears everywhere.
        XCTAssertTrue(WeaponBehaviorFlags().turretCanBear(relativeBearing: .pi / 2))
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
        world.diplomacy = Diplomacy(govts: [govtWithPenalties(id: 2, disablePenalty: 3, killPenalty: 99, shootPenalty: 999)],
                                    currentSystemID: 500)
        world.diplomacy?.reputationMap = ReputationMap(systems: [.init(id: 500, govt: 2, x: 0, y: 0, links: [])])
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
        XCTAssertEqual(world.diplomacy?.reputationHere, -3, "only DisabPenalty applied, not ShootPenalty")
    }

    func testDestroyingAShipDentsLegalRecordAndCreditsCombatRating() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        world.diplomacy = Diplomacy(govts: [govtWithPenalties(id: 2, disablePenalty: 1, killPenalty: 8, shootPenalty: 999)],
                                    currentSystemID: 500)
        world.diplomacy?.reputationMap = ReputationMap(systems: [.init(id: 500, govt: 2, x: 0, y: 0, links: [])])
        let target = makeShip("B", govt: 2, at: Vec2(0, 300))
        target.government = 2
        target.combatStrength = 55
        _ = world.addNPC(target)
        target.armor = 5; target.shield = 0           // a hulk; one more hit finishes it

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
        XCTAssertEqual(world.diplomacy?.reputationHere, -8, "KillPenalty applied on the actual kill")
        XCTAssertEqual(world.diplomacy?.combatRating, 11, "trunc(55 × 0.2) rating points (WP-04)")
    }

    // MARK: whole-government provocation (independent of legal-record threshold)

    /// Hitting one ship of a government must immediately provoke every OTHER
    /// same-government ship present in the system too, and mark the
    /// government reinforcement-eligible via `World.provokedGovernments` —
    /// without needing to cross `Diplomacy.isHostileToPlayer`'s legal-record
    /// (CrimeTol) threshold at all. Ratings/penalties (covered by the
    /// `testDisabling.../testDestroying...` tests above) must stay untouched
    /// by mere provocation.
    func testHittingOneGovernmentShipProvokesAllOthersInSystem() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        // A govt with a sky-high CrimeTolerance: shooting one ship can never
        // cross the legal-record threshold on its own.
        // Real resource-defined governments are id >= 128 (the same
        // convention `Spawner.governmentUnderAttackAndOutmatched`'s `>= 128`
        // guard uses) — use one here so the propagation guard doesn't reject it.
        world.diplomacy = Diplomacy(govts: [govtWithPenalties(id: 128, disablePenalty: 1,
                                                               killPenalty: 1, shootPenalty: 0)])
        let hit = makeShip("Hit", govt: 128, at: Vec2(0, 300))
        hit.government = 128
        hit.brain = AIBrain(aiType: .warship, govt: 128)
        let bystander = makeShip("Bystander", govt: 128, at: Vec2(500, 500))
        bystander.government = 128
        bystander.brain = AIBrain(aiType: .warship, govt: 128)
        _ = world.addNPC(hit)
        _ = world.addNPC(bystander)

        // A single, non-disabling, non-lethal graze — well short of any
        // rating-affecting outcome.
        attacker.weapons = [WeaponMount(spec: gun(shield: 1, armor: 0))]
        attacker.currentTargetID = hit.entityID
        world.intent.firePrimary = true
        for _ in 0..<60 where !world.events.contains(where: { if case .shieldHit = $0 { return true }; return false }) {
            world.step(1.0 / 30.0)
        }

        XCTAssertFalse(world.diplomacy!.isHostileToPlayer(128),
                       "legal-record threshold must not have been crossed by a mere graze")
        XCTAssertTrue(world.provokedGovernments.contains(128),
                      "the government is provoked immediately, independent of the legal-record gate")
        XCTAssertEqual(hit.brain?.provokedByPlayer, true, "the directly-hit ship is provoked")
        XCTAssertEqual(bystander.brain?.provokedByPlayer, true,
                       "every OTHER same-government ship in the system becomes hostile immediately too")
        XCTAssertEqual(world.diplomacy?.reputation ?? [:], [:],
                       "mere provocation must not dent the legal record — only disable/kill/board do")
    }

    /// `independentGovt` (-1) and any below-128 placeholder government id
    /// aren't real organized "sides" — mirroring the same `>= 128` guard
    /// `Spawner.governmentUnderAttackAndOutmatched` already uses for
    /// reinforcement eligibility, a hit against such a ship must not be
    /// recorded as a provoked government (there's nothing coherent to
    /// reinforce or rally).
    func testIndependentGovernmentIsNeverMarkedProvoked() {
        let attacker = makeShip("A", govt: 1, at: Vec2())
        let world = World(player: attacker)
        let target = makeShip("B", govt: independentGovt, at: Vec2(0, 300))
        target.government = independentGovt
        target.brain = AIBrain(aiType: .warship, govt: independentGovt)
        _ = world.addNPC(target)

        attacker.weapons = [WeaponMount(spec: gun(shield: 1, armor: 0))]
        attacker.currentTargetID = target.entityID
        world.intent.firePrimary = true
        for _ in 0..<60 where !world.events.contains(where: { if case .shieldHit = $0 { return true }; return false }) {
            world.step(1.0 / 30.0)
        }

        XCTAssertTrue(target.brain?.provokedByPlayer == true,
                     "the directly-hit ship itself is still provoked (existing per-ship behavior)")
        XCTAssertFalse(world.provokedGovernments.contains(independentGovt),
                       "independentGovt has no organized side to add to provokedGovernments")
        XCTAssertTrue(world.provokedGovernments.isEmpty)
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
        XCTAssertTrue(world.events.contains { if case .playerDying = $0 { return true }; return false },
                      "player death is reported")
        XCTAssertTrue(world.events.contains {
            if case let .beamLoopStop(shooterID, _) = $0 { return shooterID == World.playerEntityID }
            return false
        }, "the player's own beam loop is released on death")
    }
}
