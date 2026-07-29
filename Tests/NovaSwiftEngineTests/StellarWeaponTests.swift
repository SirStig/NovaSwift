import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Planetary/station defense weapons (`spöb.Weapon`): the spöb decode, target
/// selection (govt enemies, tribute contests, the provoked-only flag), and the
/// firing pass itself — reload cadence, projectiles, and beams.
final class StellarWeaponTests: XCTestCase {

    // MARK: spöb decode

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func put32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 24); b[off + 1] = UInt8((u >> 16) & 0xff)
        b[off + 2] = UInt8((u >> 8) & 0xff); b[off + 3] = UInt8(u & 0xff)
    }

    func testSpobWeaponAndStrengthDecode() {
        var b = [UInt8](repeating: 0, count: 1100)
        put16(&b, 570, 196)      // Weapon @570 (real Earth: Enormous Blaster Turret)
        put32(&b, 572, 3000)     // Strength @572
        // Flags2 is a two-byte `WORV` at **@32** per ResForge's spöb TMPL #520.
        // (@30 is DefCount — writing the flag there, as this test used to, only
        // set a defense-ship count and the assertion below never actually held.)
        put16(&b, 32, 0x0200)    // Flags2: fires only when provoked
        let s = SpobRes(Resource(type: NovaType.spob, id: 128, name: "Earth", data: Data(b)))
        XCTAssertEqual(s.defenseWeaponID, 196)
        XCTAssertEqual(s.strength, 3000)
        XCTAssertFalse(s.isInvulnerable)
        XCTAssertTrue(s.firesWeaponOnlyWhenProvoked)

        var unarmed = [UInt8](repeating: 0, count: 1100)
        put16(&unarmed, 570, -1)
        let u = SpobRes(Resource(type: NovaType.spob, id: 129, name: "Rock", data: Data(unarmed)))
        XCTAssertNil(u.defenseWeaponID)
        XCTAssertTrue(u.isInvulnerable)
    }

    /// The `spöb` fields that had never been decoded: landing fee, gravity,
    /// regeneration time, death explosion, and the three late `Flags2` bits.
    /// Offsets are all from ResForge's `spöb` TMPL #520.
    func testSpobLateFieldsDecode() {
        var b = [UInt8](repeating: 0, count: 1100)
        put32(&b, 564, 250)                  // Landing Fee
        put16(&b, 568, -40)                  // Gravity (negative = pushes away)
        put16(&b, 578, 30)                   // Regenerate Time, days
        put16(&b, 580, 1007)                 // Explosion: bööm 7 + sparks
        put16(&b, 34, 6)                     // Animation Delay
        put16(&b, 36, 3)                     // First Frame Bias
        put16(&b, 32, 0x0040 | 0x0400 | 0x0010)  // starts destroyed | sells any outfit | loops sound
        let s = SpobRes(Resource(type: NovaType.spob, id: 130, name: "Test", data: Data(b)))
        XCTAssertEqual(s.landingFee, 250)
        XCTAssertEqual(s.gravity, -40)
        XCTAssertEqual(s.regenerationDays, 30)
        XCTAssertEqual(s.explosionBoomID, 135)      // 1007 → bööm 7 → 128 + 7
        XCTAssertTrue(s.explosionHasSparks)
        XCTAssertEqual(s.animationDelay, 6)
        XCTAssertEqual(s.frame0Bias, 3)
        XCTAssertTrue(s.isAnimated)
        XCTAssertTrue(s.startsDestroyed)
        XCTAssertTrue(s.buysAnyOutfit)
        XCTAssertTrue(s.loopsAmbientSound)
        XCTAssertFalse(s.picksFramesRandomly)

        // "Never regenerates" is the TMPL's -1, which decodes to nil.
        var never = [UInt8](repeating: 0, count: 1100)
        put16(&never, 578, -1)
        put16(&never, 580, -1)
        let n = SpobRes(Resource(type: NovaType.spob, id: 131, name: "Gone", data: Data(never)))
        XCTAssertNil(n.regenerationDays)
        XCTAssertNil(n.explosionBoomID)
        XCTAssertFalse(n.hasRegenerated(destroyedDayCount: 0, nowDayCount: 10_000))

        // A 30-day timer is back exactly on day 30, not before.
        XCTAssertFalse(s.hasRegenerated(destroyedDayCount: 100, nowDayCount: 129))
        XCTAssertTrue(s.hasRegenerated(destroyedDayCount: 100, nowDayCount: 130))
    }

    // MARK: World fixtures

    private func gun(range: Double = 800, beam: Bool = false, reload: Double = 0.2) -> WeaponSpec {
        WeaponSpec(id: 300, name: "Battery", shieldDamage: 30, armorDamage: 30,
                   reloadSeconds: reload, projectileSpeed: 2000, range: range,
                   accuracyRadians: 0, isBeam: beam, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 0)
    }

    private func makeShip(_ name: String, govt: Int, at pos: Vec2) -> Ship {
        let s = Ship(name: name, stats: ShipStats(maxSpeed: 300, acceleration: 200, turnRate: .pi),
                     position: pos)
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        s.government = govt
        return s
    }

    /// Two governments at war: 128 (class 1, hates class 2) vs 200 (class 2).
    private func warDiplomacy() -> Diplomacy {
        func govt(_ id: Int, myClass: Int, enemyClass: Int) -> GovtRes {
            var b = [UInt8](repeating: 0, count: 200)
            for i in 0..<4 { put16(&b, 24 + i * 2, i == 0 ? myClass : -1) }   // classes
            for i in 0..<4 { put16(&b, 32 + i * 2, -1) }                      // allies
            for i in 0..<4 { put16(&b, 40 + i * 2, i == 0 ? enemyClass : -1) } // enemies
            return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(b)))
        }
        return Diplomacy(govts: [govt(128, myClass: 1, enemyClass: 2),
                                 govt(200, myClass: 2, enemyClass: 1)])
    }

    /// A world whose only stellar (spöb id 1, at the origin) is armed.
    private func armedWorld(weapon: WeaponSpec, spobGovt: Int = 128,
                            provokedOnly: Bool = false,
                            playerAt: Vec2 = Vec2(5000, 5000)) -> World {
        let world = World(player: makeShip("Player", govt: independentGovt, at: playerAt))
        world.diplomacy = warDiplomacy()
        world.systemContext = SystemContext(bodies: [StellarBody(
            id: 1, position: Vec2(), radius: 20, canLand: true, government: spobGovt,
            defenseWeapon: weapon, firesOnlyWhenProvoked: provokedOnly)])
        return world
    }

    private func run(_ world: World, seconds: Double,
                     collect: (WorldEvent) -> Void = { _ in }) {
        let dt = 1.0 / 30.0
        for _ in 0..<Int((seconds / dt).rounded(.up)) {
            world.step(dt)
            for e in world.events { collect(e) }
        }
    }

    // MARK: Firing at government enemies

    func testArmedStellarShootsGovernmentEnemyAndRespectsReload() {
        let world = armedWorld(weapon: gun(reload: 0.5))
        let enemy = makeShip("Raider", govt: 200, at: Vec2(0, 300))
        _ = world.addNPC(enemy)

        var shots = 0
        var shooterID = 0
        run(world, seconds: 1.0) { e in
            if case let .weaponFired(id, _, _, _, weaponID) = e, weaponID == 300 {
                shots += 1; shooterID = id
            }
        }
        XCTAssertGreaterThan(shots, 0, "armed stellar should fire at an enemy of its government")
        XCTAssertLessThanOrEqual(shots, 3, "0.5s reload over 1s ⇒ at most ~2-3 shots, not one per frame")
        XCTAssertEqual(shooterID, World.stellarShooterID(forSpob: 1))
        XCTAssertLessThan(enemy.shield, 100, "planetary fire should actually be hitting")
    }

    func testStellarHoldsFireOnFriendlyAndOutOfRangeShips() {
        let world = armedWorld(weapon: gun(range: 800))
        _ = world.addNPC(makeShip("Local", govt: 128, at: Vec2(0, 300)))       // own govt
        _ = world.addNPC(makeShip("FarFoe", govt: 200, at: Vec2(0, 2000)))     // enemy, out of range

        var shots = 0
        run(world, seconds: 1.0) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertEqual(shots, 0)
    }

    // MARK: Firing at the player

    func testStellarShootsPlayerDuringTributeContestButNotOnceDominated() {
        let world = armedWorld(weapon: gun(), playerAt: Vec2(0, 300))

        var shots = 0
        run(world, seconds: 0.5) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertEqual(shots, 0, "a neutral player parked in range draws no fire")

        // Demand-tribute contest open: the planet defends itself with its gun.
        world.stellarDefenses[1] = StellarDefense(spobID: 1, dudeID: 300, govt: 128,
                                                  waveSize: 0, poolRemaining: 0)
        run(world, seconds: 0.5) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertGreaterThan(shots, 0, "the planet shoots back once the tribute fight is on")

        // Dominated: it's the player's planet now — guns go quiet.
        world.stellarDefenses[1] = nil
        world.dominatedStellars.insert(1)
        shots = 0
        run(world, seconds: 0.5) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertEqual(shots, 0)
    }

    func testProvokedOnlyStellarIgnoresNPCWarsButAnswersProvocation() {
        let world = armedWorld(weapon: gun(), provokedOnly: true, playerAt: Vec2(0, 250))
        _ = world.addNPC(makeShip("Raider", govt: 200, at: Vec2(0, 300)))

        var shots = 0
        run(world, seconds: 0.5) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertEqual(shots, 0, "'fires only when provoked' holds fire on passing wars and a quiet player")

        world.provokedGovernments.insert(128)   // the player attacked this govt's ships
        run(world, seconds: 0.5) { e in
            if case .weaponFired(_, _, _, _, 300) = e { shots += 1 }
        }
        XCTAssertGreaterThan(shots, 0)
    }

    // MARK: Beams

    func testStellarBeamDamagesInstantlyAndRendersAPulse() {
        let world = armedWorld(weapon: gun(beam: true))
        let enemy = makeShip("Raider", govt: 200, at: Vec2(0, 300))
        _ = world.addNPC(enemy)

        world.step(1.0 / 30.0)
        XCTAssertLessThan(enemy.shield, 100, "beam damage lands the frame it fires")
        let beam = world.activeBeams.first
        XCTAssertNotNil(beam)
        XCTAssertEqual(beam?.shooterID, World.stellarShooterID(forSpob: 1))
        XCTAssertEqual(beam?.continuous, false, "stellar beams are pulse flashes")
    }

    // MARK: Destroyable stellars (`spöb.Strength`)

    /// A world with one destroyable stellar at the origin and the player in range.
    private func destroyableWorld(strength: Double, gravity: Int = 0) -> World {
        let world = World(player: makeShip("Player", govt: independentGovt, at: Vec2(0, 200)))
        world.diplomacy = warDiplomacy()
        world.systemContext = SystemContext(bodies: [StellarBody(
            id: 1, position: Vec2(), radius: 20, canLand: true, government: 128,
            strength: strength, explosionBoomID: 135, explosionHasSparks: true,
            regenerationDays: 30, gravity: gravity)])
        return world
    }

    func testDestroyableStellarTakesDamageAndDies() {
        let world = destroyableWorld(strength: 100)
        let body = world.systemContext.bodies[0]

        var damaged: [(Double, Double)] = []
        var destroyed: (id: Int, boom: Int?, sparks: Bool)?
        world.applyStellarHit(body, shield: 30, armor: 30)
        for e in world.events {
            if case let .stellarDamaged(_, armor, maxArmor) = e { damaged.append((armor, maxArmor)) }
        }
        XCTAssertEqual(damaged.first?.0, 40, "combined mass+energy damage comes off one pool")
        XCTAssertEqual(damaged.first?.1, 100)

        // A second hit of the same size finishes it.
        let before = world.events.count
        world.applyStellarHit(body, shield: 30, armor: 30)
        for e in world.events.dropFirst(before) {
            if case let .stellarDestroyed(id, _, boom, sparks) = e { destroyed = (id, boom, sparks) }
        }
        XCTAssertEqual(destroyed?.id, 1)
        XCTAssertEqual(destroyed?.boom, 135, "the stellar's own spöb.Explosion plays")
        XCTAssertEqual(destroyed?.sparks, true)
        XCTAssertTrue(world.stellarsDestroyedThisSession.contains(1))
        XCTAssertTrue(world.destroyableStellars.isEmpty, "a downed stellar stops being a target")
    }

    func testInvulnerableStellarIgnoresFire() {
        let world = destroyableWorld(strength: 0)
        let body = world.systemContext.bodies[0]
        XCTAssertFalse(world.applyStellarHit(body, shield: 9999, armor: 9999))
        XCTAssertTrue(world.stellarsDestroyedThisSession.isEmpty,
                      "Strength 0 is the TMPL's 'Invulnerable' — no amount of fire touches it")
    }

    /// A planet-type weapon (`wëap.Flags2` 0x0400) flies through ships and only
    /// connects with a destroyable stellar.
    func testPlanetTypeWeaponPassesThroughShipsAndHitsTheStellar() {
        var flags = WeaponBehaviorFlags(); flags.isPlanetTypeWeapon = true
        let siegeGun = WeaponSpec(id: 301, name: "Siege Gun", shieldDamage: 40, armorDamage: 40,
                                  reloadSeconds: 0.2, projectileSpeed: 900, range: 2000,
                                  accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                                  blastRadius: 0, ammoPerShot: 0, flags: flags)
        let world = destroyableWorld(strength: 60)
        // A hostile ship parked directly between the player and the planet.
        let shield = makeShip("Blocker", govt: 200, at: Vec2(0, 100))
        _ = world.addNPC(shield)

        world.player.weapons = [WeaponMount(spec: siegeGun)]
        world.player.angle = .pi                     // nose down, toward the origin
        world.intent.firePrimary = true
        run(world, seconds: 1.5)

        XCTAssertEqual(shield.shield, 100, "a planet-type weapon flies straight through ordinary hulls")
        XCTAssertTrue(world.stellarsDestroyedThisSession.contains(1),
                      "…and lands its damage on the destroyable stellar behind them")
    }

    // MARK: Gravity (`spöb.Gravity`)

    func testStellarGravityPullsShipsAndTheImmuneIgnoreIt() {
        let world = destroyableWorld(strength: 0, gravity: 400)
        let drifter = makeShip("Drifter", govt: independentGovt, at: Vec2(0, 200))
        drifter.brain = nil
        _ = world.addNPC(drifter)
        let immune = makeShip("Immune", govt: independentGovt, at: Vec2(0, 200))
        immune.brain = nil
        immune.ignoresGravity = true
        _ = world.addNPC(immune)

        for _ in 0..<30 { world.step(1.0 / 30.0) }
        XCTAssertLessThan(drifter.velocity.y, -1, "positive gravity pulls a ship toward the body")
        XCTAssertEqual(immune.velocity.y, 0, accuracy: 1e-9,
                       "shïp Flags3 0x0010 / oütf ModType 41 make a hull immune")
    }

    func testZeroGravityIsInert() {
        let world = destroyableWorld(strength: 0, gravity: 0)
        let drifter = makeShip("Drifter", govt: independentGovt, at: Vec2(0, 200))
        drifter.brain = nil
        _ = world.addNPC(drifter)
        for _ in 0..<30 { world.step(1.0 / 30.0) }
        XCTAssertEqual(drifter.velocity.length, 0, accuracy: 1e-9,
                       "every base-game stellar has Gravity 0 — it must cost nothing and do nothing")
    }
}
