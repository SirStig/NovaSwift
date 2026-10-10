import XCTest
import NovaSwiftKit
@testable import NovaSwiftEngine

/// Batch 2 of docs/reverse-engineering/FIDELITY_PLAN.md: weapons and damage
/// against the original (WP-xx, AI-03, OS-07). Weapons are built from real
/// `wëap` bytes, so the original's units (ticks, raw calls, whole degrees)
/// go through the same decode the game data does.
final class OriginalWeaponsTests: XCTestCase {

    private let tick = 1.0 / 30.0

    /// A `wëap` resource with the fields these tests set (Bible offsets).
    private struct Weap {
        var reload = 30, count = 30, mass = 0, energy = 0, guidance = -1, speed = 0
        var accuracy = 0, impact = 0, prox = 0, blast = 0, flags = 0, seeker = 0, decay = 0
        var beamLength = 0, falloff = 0, proxSafety = 0, flags2 = 0, burstCount = 0, burstReload = 0
        var flags3 = 0, durability = 0, turn = 0, ionization = 0, jam = [0, 0, 0, 0]

        func spec(id: Int = 128) -> WeaponSpec {
            var d = [UInt8](repeating: 0, count: 130)
            func w(_ off: Int, _ v: Int) {
                let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
                d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
            }
            w(0, reload); w(2, count); w(4, mass); w(6, energy); w(8, guidance); w(10, speed)
            w(12, -1); w(14, -1); w(16, accuracy); w(18, -1); w(20, impact); w(22, -1)
            w(24, prox); w(26, blast); w(28, flags); w(30, seeker); w(32, -1); w(34, decay)
            w(48, beamLength); w(52, falloff); w(62, 0); w(64, -1); w(70, proxSafety); w(72, flags2)
            w(74, ionization); w(86, -1); w(88, -1); w(90, burstCount); w(92, burstReload)
            for (i, v) in jam.enumerated() { w(94 + i * 2, v) }
            w(102, flags3); w(104, durability); w(106, turn); w(108, -1); w(118, 1)
            return WeaponSpec(WeapRes(Resource(type: NovaType.weapon, id: id, name: "W\(id)", data: Data(d))))
        }
    }

    private func ship(_ name: String, at pos: Vec2, govt: Int = -1, shield: Double = 100,
                      armor: Double = 100) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi), position: pos)
        s.maxShield = shield; s.shield = shield; s.maxArmor = armor; s.armor = armor
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        s.government = govt
        return s
    }

    // MARK: WP-01 beams

    func testBeamDamagesOnEveryRawCallOfItsCount() {
        // A Count-10 beam held on a target for one Reload deals 10 hits — one
        // per raw call (OQ B5), not one per Reload.
        let beam = Weap(reload: 60, count: 10, energy: 1, guidance: 0, beamLength: 600).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let target = ship("T", at: Vec2(0, 300), shield: 10_000)
        world.addNPC(target)
        player.weapons = [WeaponMount(spec: beam)]
        world.intent.firePrimary = true
        world.step(tick)
        world.intent.firePrimary = false
        for _ in 0..<40 { world.step(tick) }
        XCTAssertEqual(10_000 - target.shield, 10, accuracy: 1e-9)
    }

    func testBeamCountAboveReloadStacks() {
        // Reload 0 re-queues a record on every raw call: Count 4 overlaps four
        // of them — the original's "machine-gun beam".
        let beam = Weap(reload: 0, count: 4, energy: 1, guidance: 0, beamLength: 600).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let target = ship("T", at: Vec2(0, 300), shield: 100_000)
        world.addNPC(target)
        player.weapons = [WeaponMount(spec: beam)]
        world.intent.firePrimary = true
        for _ in 0..<30 { world.step(tick) }
        let perSecond = 100_000 - target.shield
        XCTAssertGreaterThan(perSecond, 150, "≈ 47.6 records × 4 calls a second")
        XCTAssertLessThan(perSecond, 200)
    }

    // MARK: WP-04 / AI-03

    func testRatingFireRampMatchesTheOriginalThresholds() {
        // Class 0 Strength 2 → 200 / 800 / 1600 / 3200 (0x00414550).
        let ramp = { World.ratingFireRamp(rating: $0, classZeroStrength: 2) }
        XCTAssertEqual(ramp(0), 1.75)
        XCTAssertEqual(ramp(199), 1.75)
        XCTAssertEqual(ramp(200), 1.5)
        XCTAssertEqual(ramp(799), 1.5)
        XCTAssertEqual(ramp(800), 1.25)
        XCTAssertEqual(ramp(1600), 1.1)
        XCTAssertEqual(ramp(3199), 1.1)
        XCTAssertEqual(ramp(3200), 1)
    }

    func testRatingRampStretchesTheReloadButNotTheBurstReload() {
        let gun = Weap(reload: 10, count: 30, mass: 1, speed: 100, burstCount: 2, burstReload: 90).spec()
        let mount = WeaponMount(spec: gun)
        mount.cooldown = 0
        mount.didFire(shots: 1, reloadScale: 1.75)
        XCTAssertEqual(mount.cooldown, 10.0 / 30 * 1.75, accuracy: 1e-9)
        mount.cooldown = 0
        mount.didFire(shots: 1, reloadScale: 1.75)
        XCTAssertEqual(mount.cooldown, 3, accuracy: 1e-9, "the burst reload is not scaled")
    }

    func testNPCFiringAtThePlayerReloadsSlowerAtLowRating() {
        let gun = Weap(reload: 30, count: 100, mass: 1, speed: 1000).spec()
        func interval(targetingPlayer: Bool, rating: Int) -> Double {
            let player = ship("P", at: Vec2(0, 300))
            let world = World(player: player)
            world.playerCombatRating = rating
            let npc = ship("N", at: Vec2(), govt: 140)
            npc.brain = AIBrain(aiType: .warship, govt: 140)
            world.addNPC(npc)
            let other = ship("O", at: Vec2(300, 0), govt: 141)
            world.addNPC(other)
            npc.weapons = [WeaponMount(spec: gun)]
            npc.currentTargetID = targetingPlayer ? 0 : other.entityID
            world.step(tick)   // roster
            npc.weapons[0].cooldown = 0
            npc.currentTargetID = targetingPlayer ? 0 : other.entityID
            world.testFire(npc, primary: true)
            return npc.weapons[0].cooldown
        }
        XCTAssertEqual(interval(targetingPlayer: true, rating: 0), 1.75, accuracy: 1e-9)
        XCTAssertEqual(interval(targetingPlayer: false, rating: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(interval(targetingPlayer: true, rating: 5000), 1, accuracy: 1e-9)
    }

    func testKillsCreditPlayerAndDirectEscortsOnly() {
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let dip = Diplomacy(govts: [])
        world.diplomacy = dip
        let escort = ship("E", at: Vec2(100, 0))
        let eb = AIBrain(aiType: .warship, govt: -1); eb.leaderID = 0
        escort.brain = eb
        world.addNPC(escort)
        let stranger = ship("S", at: Vec2(-100, 0), govt: 150)
        stranger.brain = AIBrain(aiType: .warship, govt: 150)
        world.addNPC(stranger)
        func victim(strength: Double) -> Ship {
            let v = ship("V", at: Vec2(0, 500), govt: 151)
            v.combatStrength = strength
            v.shield = 0
            world.addNPC(v)
            return v
        }
        let a = victim(strength: 30)
        world.applyHit(to: a, shield: 0, armor: 500, ownerID: escort.entityID)
        let b = victim(strength: 3)
        world.applyHit(to: b, shield: 0, armor: 500, ownerID: 0)
        let c = victim(strength: 100)
        world.applyHit(to: c, shield: 0, armor: 500, ownerID: stranger.entityID)
        let d = victim(strength: 100)
        d.spobDefenderOf = 128
        world.applyHit(to: d, shield: 0, armor: 500, ownerID: 0)
        world.step(tick)
        XCTAssertEqual(dip.combatRating, 6 + 1, "escort kill 30 → 6, player kill 3 → 1; no stranger or defender credit")
    }

    // MARK: WP-05 homing

    func testHomingShotFliesStraightThenPursuesAndPassesThroughBystanders() {
        let missile = Weap(reload: 30, count: 300, mass: 10, guidance: 1, speed: 1000, turn: 40).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let target = ship("T", at: Vec2(800, 600))
        world.addNPC(target)
        let bystander = ship("B", at: Vec2(0, 120))
        world.addNPC(bystander)
        player.weapons = [WeaponMount(spec: missile)]
        player.currentTargetID = target.entityID
        world.intent.firePrimary = true
        world.step(tick)
        world.intent.firePrimary = false
        let shot = try! XCTUnwrap(world.projectiles.first)
        for _ in 0..<8 { world.step(tick) }   // age 9 ticks: under 15 raw calls (9.45)
        XCTAssertEqual(shot.facing, 0, accuracy: 1e-9, "no turning before 15 raw calls")
        for _ in 0..<5 { world.step(tick) }
        XCTAssertGreaterThan(shot.facing, 0.1, "then it turns toward the target")
        XCTAssertEqual(bystander.armor, 100, "a homing shot hits only its target")
        XCTAssertEqual(bystander.shield, 100)
    }

    func testHomingShotGoesInertWhenItsTargetDies() {
        let missile = Weap(reload: 30, count: 300, mass: 10, guidance: 1, speed: 300, turn: 40).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let target = ship("T", at: Vec2(0, 2000))
        world.addNPC(target)
        player.weapons = [WeaponMount(spec: missile)]
        player.currentTargetID = target.entityID
        world.intent.firePrimary = true
        world.step(tick)
        world.intent.firePrimary = false
        let shot = try! XCTUnwrap(world.projectiles.first)
        target.armor = 0
        world.step(tick)
        XCTAssertEqual(shot.guidanceState, 998)
        XCTAssertNil(shot.targetID)
    }

    // MARK: WP-06 / WP-07 blasts

    func testPlayerBlastHurtsThePlayerAndSameGovernmentBystanders() {
        // Square, full raw damage, no government gate; the player is spared
        // only by wëap Flags 0x0100.
        func run(flags: Int) -> (player: Double, ally: Double) {
            let rocket = Weap(reload: 30, count: 300, mass: 20, energy: 20, speed: 500, prox: 0,
                              blast: 100, flags: flags).spec()
            let player = ship("P", at: Vec2(), govt: 140)
            let world = World(player: player)
            let target = ship("T", at: Vec2(0, 60), govt: 141)
            world.addNPC(target)
            let ally = ship("A", at: Vec2(90, 60), govt: 140)
            world.addNPC(ally)
            player.weapons = [WeaponMount(spec: rocket)]
            world.intent.firePrimary = true
            world.step(tick)
            world.intent.firePrimary = false
            for _ in 0..<5 { world.step(tick) }
            return (player.shield, ally.shield)
        }
        let plain = run(flags: 0)
        XCTAssertEqual(plain.player, 80, accuracy: 1e-9, "a point-blank rocket's blast hurts its own player")
        XCTAssertEqual(plain.ally, 80, accuracy: 1e-9, "same-government bystander takes full damage (90 px, square)")
        XCTAssertEqual(run(flags: 0x0100).player, 100, accuracy: 1e-9)
    }

    func testExpiryBlastNeedsFlags8000() {
        func run(flags: Int) -> Double {
            let flak = Weap(reload: 30, count: 10, mass: 30, energy: 30, speed: 300, blast: 200,
                            flags: flags).spec()
            let player = ship("P", at: Vec2())
            let world = World(player: player)
            let near = ship("N", at: Vec2(150, 150))
            world.addNPC(near)
            player.weapons = [WeaponMount(spec: flak)]
            world.intent.firePrimary = true
            world.step(tick)
            world.intent.firePrimary = false
            for _ in 0..<20 { world.step(tick) }
            return near.shield
        }
        XCTAssertEqual(run(flags: 0), 100, accuracy: 1e-9, "no area damage at end of life without 0x8000")
        XCTAssertEqual(run(flags: 0x8000), 70, accuracy: 1e-9)
    }

    // MARK: WP-13 death blast

    func testHeavyHullDeathBlastIsNonLethalAndSquare() {
        // 400 t: radius trunc(400 × 0.075 + 50) = 80, damage trunc(400 ×
        // 0.0375 + 25) = 40 to shields and armor; it can't kill or disable.
        let player = ship("P", at: Vec2(5000, 5000))
        let world = World(player: player)
        let dying = ship("D", at: Vec2())
        dying.massTons = 400
        world.addNPC(dying)
        let inside = ship("I", at: Vec2(80, -80), shield: 0)
        world.addNPC(inside)
        let outside = ship("O", at: Vec2(81, 0), shield: 0)
        world.addNPC(outside)
        let frail = ship("F", at: Vec2(0, 40), shield: 0, armor: 100)
        frail.armor = 40
        world.addNPC(frail)
        world.deathBlast(of: dying)
        XCTAssertEqual(inside.armor, 60, accuracy: 1e-9)
        XCTAssertEqual(outside.armor, 100, accuracy: 1e-9)
        XCTAssertFalse(frail.disabled, "left just above the disable line")
        XCTAssertEqual(frail.armor, 100 * 0.3333 + 1, accuracy: 1e-9)
    }

    // MARK: WP-14 point defense

    func testPointDefenseFiresOneBankPerCallAtShotsAimedAtItsSquad() {
        let pd = Weap(reload: 300, count: 10, mass: 5, guidance: 10, beamLength: 800).spec(id: 141)
        let missile = Weap(reload: 30, count: 300, mass: 50, guidance: 1, speed: 300, turn: 10).spec(id: 140)
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        let defender = ship("D", at: Vec2(0, 400), govt: 150)
        world.addNPC(defender)
        let other = ship("O", at: Vec2(0, 900), govt: 151)
        world.addNPC(other)
        defender.weapons = [WeaponMount(spec: pd), WeaponMount(spec: pd)]
        player.weapons = [WeaponMount(spec: missile)]
        player.currentTargetID = other.entityID
        world.intent.firePrimary = true
        world.step(tick)
        world.intent.firePrimary = false
        XCTAssertEqual(defender.weapons.filter { $0.cooldown > 0 }.count, 0,
                       "a missile aimed at another ship is ignored")
        player.currentTargetID = defender.entityID
        player.weapons[0].cooldown = 0
        world.intent.firePrimary = true
        world.step(tick)
        XCTAssertEqual(defender.weapons.filter { $0.cooldown > 0 }.count, 1, "only the first ready bank fires")
    }

    // MARK: WP-16 knockback

    func testImpactPushIsInverseToMass() {
        let world = World(player: ship("P", at: Vec2(5000, 0)))
        let light = ship("L", at: Vec2(0, 100)); light.massTons = 50
        let heavy = ship("H", at: Vec2(0, -100)); heavy.massTons = 200
        world.addNPC(light); world.addNPC(heavy)
        world.applyKnockback(to: light, impact: 4, from: Vec2())
        world.applyKnockback(to: heavy, impact: 4, from: Vec2())
        XCTAssertEqual(light.velocity.length, heavy.velocity.length * 4, accuracy: 1e-9)
        XCTAssertEqual(light.velocity.length, 4.0 / 50 * 30, accuracy: 1e-9, "impact / mass px/tick")
    }

    // MARK: WP-19 / WP-20 / WP-21

    func testShotLivesItsCountInTicks() {
        let still = Weap(reload: 30, count: 45, mass: 1, speed: 0).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        player.weapons = [WeaponMount(spec: still)]
        world.intent.firePrimary = true
        world.step(tick)
        world.intent.firePrimary = false
        XCTAssertEqual(world.projectiles.count, 1)
        for _ in 0..<43 { world.step(tick) }
        XCTAssertEqual(world.projectiles.count, 1, "a Speed-0 shot still lives 45 ticks")
        world.step(tick)
        XCTAssertEqual(world.projectiles.count, 0)
    }

    func testBurstWeaponStartsReloading() {
        let gun = Weap(reload: 2, count: 30, mass: 1, speed: 500, burstCount: 3, burstReload: 60).spec()
        XCTAssertFalse(WeaponMount(spec: gun).ready, "a burst bank starts at BurstReload")
        XCTAssertEqual(WeaponMount(spec: gun).cooldown, 2, accuracy: 1e-9)
    }

    func testExclusiveBankHoldsTheOthersTwoTicksPastItsCooldown() {
        let exclusive = Weap(reload: 30, count: 30, mass: 1, speed: 500, flags3: 0x0020).spec(id: 140)
        let other = Weap(reload: 3, count: 30, mass: 1, speed: 500).spec(id: 141)
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        player.weapons = [WeaponMount(spec: exclusive), WeaponMount(spec: other)]
        world.intent.firePrimary = true
        world.testFire(player, primary: true)
        XCTAssertEqual(world.projectiles.count, 1, "the other bank is held the same call")
        XCTAssertEqual(player.weapons[1].cooldown, player.weapons[0].cooldown + 2.0 / 30, accuracy: 1e-9)
    }

    func testSpreadIsWholeDegrees() {
        let gun = Weap(reload: 0, count: 30, mass: 1, speed: 500, accuracy: 5).spec()
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        player.weapons = [WeaponMount(spec: gun)]
        world.intent.firePrimary = true
        for _ in 0..<10 { world.step(tick) }
        XCTAssertGreaterThan(world.projectiles.count, 10)
        for p in world.projectiles {
            var deg = p.facing * 180 / .pi
            if deg > 180 { deg -= 360 }
            XCTAssertEqual(deg, deg.rounded(), accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(deg), 5)
        }
    }

    // MARK: WP-15 / WP-23 arcs

    func testRearTurretWithNoTargetIsSilentAndHullBlindSpotsHold() {
        let rear = Weap(reload: 30, count: 30, mass: 1, guidance: 8, speed: 500).spec(id: 140)
        let turret = Weap(reload: 30, count: 30, mass: 1, guidance: 4, speed: 500).spec(id: 141)
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        player.weapons = [WeaponMount(spec: rear)]
        world.intent.firePrimary = true
        world.step(tick)
        XCTAssertTrue(world.projectiles.isEmpty, "a rear quadrant gun with no target holds")

        let side = ship("S", at: Vec2(300, 0))
        world.addNPC(side)
        player.weapons = [WeaponMount(spec: turret)]
        player.currentTargetID = side.entityID
        player.hullFlags = 0x2000
        world.step(tick)
        XCTAssertTrue(world.projectiles.isEmpty, "hull Flags 0x2000 blinds turrets to the sides")
        player.hullFlags = 0
        world.step(tick)
        XCTAssertEqual(world.projectiles.count, 1)
    }

    // MARK: WP-26 turret tracking roll

    func testTurretRollPassesThroughLowRatedTargetsUnlessDisabled() {
        // Warship (100) firing at a fighter (80): rolls 81…100 pass — 20 %.
        let world = World(player: ship("P", at: Vec2(5000, 0)))
        let gunner = ship("G", at: Vec2(), govt: 140)
        let fighter = ship("F", at: Vec2(0, 50), govt: 141)
        fighter.turretRating = 80
        world.addNPC(gunner); world.addNPC(fighter)
        let shot = Projectile(position: Vec2(), velocity: Vec2(), life: 1, shieldDamage: 1, armorDamage: 1,
                              blastRadius: 0, ownerID: gunner.entityID, ownerGovt: 140, homing: false,
                              turnRate: 0, speed: 0, targetID: nil)
        var passes = 0
        for roll in 1...100 {
            shot.turretRoll = roll
            if !world.canShotHit(shot, fighter) { passes += 1 }
        }
        XCTAssertEqual(passes, 20)
        fighter.shield = 0; fighter.armor = 10
        shot.turretRoll = 100
        XCTAssertTrue(world.canShotHit(shot, fighter), "a disabled target is never missed")
    }

    // MARK: WP-18 asteroids

    func testPureMassWeaponCannotMine() throws {
        let world = World(player: ship("P", at: Vec2()))
        let rock = try XCTUnwrap(world.testRock(at: Vec2(0, 100), hp: 10))
        world.applyAsteroidHit(rock, shield: 0, armor: 500, shooterID: 0)
        XCTAssertTrue(rock.isAlive)
        world.applyAsteroidHit(rock, shield: 1, armor: 0, tenTimes: true, shooterID: 0)
        XCTAssertTrue(rock.isAlive, "10 → 0 is not below zero")
        world.applyAsteroidHit(rock, shield: 0.5, armor: 0, shooterID: 0)
        XCTAssertFalse(rock.isAlive)
    }

    // MARK: OS-07 repair system

    func testRepairSystemLiftsADisabledShipJustAboveTheLine() {
        let player = ship("P", at: Vec2())
        let world = World(player: player)
        player.hasRepairSystem = true
        player.shield = 0
        player.armor = 40
        world.applyHit(to: player, shield: 0, armor: 20, ownerID: -1)
        XCTAssertTrue(player.disabled)
        for _ in 0..<300 { world.step(tick) }
        XCTAssertTrue(player.disabled, "nothing during the 300-tick window")
        var ticks = 0
        while player.disabled && ticks < 30_000 { world.step(tick); ticks += 1 }
        XCTAssertFalse(player.disabled)
        XCTAssertEqual(player.armor, 100 * 0.3333 + 1, accuracy: 1e-9)
    }
}
