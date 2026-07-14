import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// End-to-end tests for the ship system: outfit aggregation into an effective
/// loadout, and the live fuel / afterburner / cargo runtime on a `Ship`.
final class ShipSystemTests: XCTestCase {

    // MARK: byte builders

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    /// A minimal, resolvable weapon (unguided, some damage).
    private func weapon(_ id: Int, name: String) -> Resource {
        var b = [UInt8](repeating: 0, count: 130)
        put16(&b, 0, 30)    // reload
        put16(&b, 2, 60)    // duration
        put16(&b, 4, 10)    // armor damage
        put16(&b, 6, 10)    // shield damage
        put16(&b, 8, -1)    // guidance: unguided
        put16(&b, 10, 100)  // speed
        return Resource(type: NovaType.weapon, id: id, name: name, data: Data(b))
    }

    /// A game with one hull (128), one stat/weapon-granting outfit (200), and two
    /// weapons (128 stock, 129 granted by the outfit).
    private func makeGame() -> NovaGame {
        var col = ResourceCollection()

        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 0, 50)    // cargo
        put16(&ship, 2, 100)   // shield
        put16(&ship, 4, 200)   // accel
        put16(&ship, 6, 300)   // speed
        put16(&ship, 8, 30)    // turn
        put16(&ship, 10, 400)  // fuel (4 jumps)
        put16(&ship, 12, 40)   // free mass
        put16(&ship, 14, 80)   // armor
        put16(&ship, 16, 20)   // shield recharge
        put16(&ship, 42, 4)    // max guns
        put16(&ship, 18, 128); put16(&ship, 26, 1)   // stock weapon 128 ×1
        put16(&ship, 78, 200); put16(&ship, 86, 1)   // preinstalled outfit 200 ×1
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var out = [UInt8](repeating: 0, count: 40)
        put16(&out, 2, 5)                     // mass 5
        put16(&out, 6, 4);  put16(&out, 8, 50)    // shield +50
        put16(&out, 18, 2); put16(&out, 20, 30)   // freeCargo +30
        put16(&out, 22, 15); put16(&out, 24, 37)  // afterburner (fuel 37)
        put16(&out, 26, 1);  put16(&out, 28, 129) // grants weapon 129
        col.add(Resource(type: NovaType.outfit, id: 200, name: "Combat Kit", data: Data(out)))

        col.add(weapon(128, name: "Blaster"))
        col.add(weapon(129, name: "Missile"))
        return NovaGame(col)
    }

    // MARK: loadout aggregation

    func testLoadoutAggregatesOutfits() throws {
        let galaxy = Galaxy(game: makeGame())
        let lo = try XCTUnwrap(galaxy.loadout(shipID: 128))

        XCTAssertEqual(lo.maxShield, 150, "base 100 + outfit 50")
        XCTAssertEqual(lo.maxArmor, 80)
        XCTAssertEqual(lo.cargoCapacity, 80, "base 50 + outfit 30")
        XCTAssertEqual(lo.maxFuel, 400)
        XCTAssertEqual(lo.jumpRange, 4)
        XCTAssertNotNil(lo.afterburner, "outfit grants an afterburner")
        XCTAssertEqual(lo.usedMass, 5)
        XCTAssertEqual(lo.massCapacity, 45, "free 40 + used 5")
        XCTAssertEqual(lo.freeMass, 40)
        // Stock weapon 128 + outfit-granted weapon 129.
        XCTAssertEqual(Set(lo.weapons.map(\.id)), [128, 129])
    }

    func testJumpOutfitsAggregateHopsAndInstantJump() throws {
        // A hull carrying a multi-jump drive (ModType 32, +2 hops) and an
        // instant-jump outfit (ModType 37) reports both on its loadout.
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300)                          // speed
        put16(&ship, 10, 400)                         // fuel
        put16(&ship, 12, 40)                          // free mass
        put16(&ship, 78, 201); put16(&ship, 86, 1)    // preinstalled jump outfit 201 ×1
        col.add(Resource(type: NovaType.ship, id: 128, name: "Runner", data: Data(ship)))

        var out = [UInt8](repeating: 0, count: 40)
        put16(&out, 6, 32);  put16(&out, 8, 2)        // multiJump +2 hops
        put16(&out, 18, 37); put16(&out, 20, 0)       // fastJump (instant; value ignored)
        col.add(Resource(type: NovaType.outfit, id: 201, name: "Jump Organ", data: Data(out)))

        let lo = try XCTUnwrap(Galaxy(game: NovaGame(col)).loadout(shipID: 128))
        XCTAssertEqual(lo.maxJumpHops, 3, "base 1 + multiJump 2")
        XCTAssertTrue(lo.instantJump, "a fastJump outfit makes jumps instant")

        // A plain hull with no jump outfits keeps the single-hop, slow-jump default.
        var plain = [UInt8](repeating: 0, count: 2000)
        put16(&plain, 6, 300); put16(&plain, 10, 400); put16(&plain, 12, 40)
        var col2 = ResourceCollection()
        col2.add(Resource(type: NovaType.ship, id: 128, name: "Plain", data: Data(plain)))
        let lo2 = try XCTUnwrap(Galaxy(game: NovaGame(col2)).loadout(shipID: 128))
        XCTAssertEqual(lo2.maxJumpHops, 1)
        XCTAssertFalse(lo2.instantJump)
    }

    func testMakeLoadedShipAppliesEverything() throws {
        let galaxy = Galaxy(game: makeGame())
        let ship = try XCTUnwrap(galaxy.makeLoadedShip(128))

        XCTAssertEqual(ship.maxShield, 150)
        XCTAssertEqual(ship.shield, 150, "starts full")
        XCTAssertEqual(ship.maxFuel, 400)
        XCTAssertEqual(ship.fuel, 400)
        XCTAssertEqual(ship.cargoCapacity, 80)
        XCTAssertNotNil(ship.afterburner)
        XCTAssertEqual(ship.weapons.count, 2, "two resolved weapon mounts")
    }

    /// Regression: a weapon that tracks ammo (`wëap.MaxAmmo` > 0) but is only
    /// ever granted via an outfit — never baked into the hull's own `s.weapons`
    /// — with no ammo-granting outfit installed, computes `Loadout.weapons`'
    /// ammo as 0 (nothing bought yet). `makeLoadedShip` used to coerce that 0
    /// to -1 ("unlimited"), which let the weapon fire forever with no ammo at
    /// all and never decremented. It must come up empty and unable to fire
    /// instead.
    func testAmmoWeaponWithNothingBoughtStartsEmptyNotUnlimited() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 78, 300); put16(&ship, 86, 1)   // preinstalled launcher outfit 300 ×1
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var out = [UInt8](repeating: 0, count: 40)
        put16(&out, 26, 1); put16(&out, 28, 400)     // grants weapon 400
        col.add(Resource(type: NovaType.outfit, id: 300, name: "Missile Launcher", data: Data(out)))

        var wep = [UInt8](repeating: 0, count: 130)
        put16(&wep, 0, 30); put16(&wep, 4, 10); put16(&wep, 6, 10); put16(&wep, 8, -1); put16(&wep, 10, 100)
        put16(&wep, 108, 8)   // MaxAmmo 8 — this weapon tracks ammo
        col.add(Resource(type: NovaType.weapon, id: 400, name: "Missile", data: Data(wep)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        let mount = try XCTUnwrap(ship2.weapons.first { $0.spec.id == 400 })
        XCTAssertEqual(mount.ammo, 0, "no ammo outfit bought — should be empty, not unlimited")
        XCTAssertFalse(mount.ready, "an ammo weapon with zero ammo can't fire")
    }

    /// The positive counterpart: with an ammo-granting outfit (`ModType 3`,
    /// value = the weapon id) installed too, the mount starts with that many
    /// rounds — confirming the fix above didn't break the normal path.
    func testAmmoWeaponWithAmmoBoughtStartsLoaded() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 78, 300); put16(&ship, 86, 1)   // launcher outfit 300 ×1
        put16(&ship, 80, 301); put16(&ship, 88, 5)   // ammo outfit 301 ×5
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var launcher = [UInt8](repeating: 0, count: 40)
        put16(&launcher, 26, 1); put16(&launcher, 28, 400)   // grants weapon 400
        col.add(Resource(type: NovaType.outfit, id: 300, name: "Missile Launcher", data: Data(launcher)))

        var ammo = [UInt8](repeating: 0, count: 40)
        put16(&ammo, 26, 3); put16(&ammo, 28, 400)   // ammunition for weapon 400
        col.add(Resource(type: NovaType.outfit, id: 301, name: "Missile", data: Data(ammo)))

        var wep = [UInt8](repeating: 0, count: 130)
        put16(&wep, 0, 30); put16(&wep, 4, 10); put16(&wep, 6, 10); put16(&wep, 8, -1); put16(&wep, 10, 100)
        put16(&wep, 12, 272)  // AmmoType 272 → 128+272 = 400 (its own id — self-pooled)
        put16(&wep, 108, 8)   // MaxAmmo 8
        col.add(Resource(type: NovaType.weapon, id: 400, name: "Missile", data: Data(wep)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        let mount = try XCTUnwrap(ship2.weapons.first { $0.spec.id == 400 })
        XCTAssertEqual(mount.ammo, 5, "5 ammo outfits owned, 1 each")
        XCTAssertTrue(mount.ready)
    }

    /// Regression: buying only an ammunition outfit (`ModType 3`) for a weapon
    /// id the ship has no launcher for at all — no hull-baked `s.weapons` entry,
    /// no owned `.weapon`-granting outfit — must not fabricate a firing weapon
    /// mount for that id. Nothing in `canBuyOutfit`/`ItemLocking` stops a player
    /// from buying ammo without the launcher (verified against real game data:
    /// launcher/ammo pairs share identical `Require` bits with no ownership
    /// dependency between them), so this is an ordinary reachable purchase, not
    /// a contrived edge case — ammo alone must stay inert cargo, not a weapon.
    func testAmmoWithNoLauncherDoesNotMaterializeAPhantomWeapon() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 78, 301); put16(&ship, 86, 5)   // ammo outfit 301 ×5 — no launcher owned
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var ammo = [UInt8](repeating: 0, count: 40)
        put16(&ammo, 26, 3); put16(&ammo, 28, 400)   // ammunition for weapon 400
        col.add(Resource(type: NovaType.outfit, id: 301, name: "Missile", data: Data(ammo)))

        var wep = [UInt8](repeating: 0, count: 130)
        put16(&wep, 0, 30); put16(&wep, 4, 10); put16(&wep, 6, 10); put16(&wep, 8, -1); put16(&wep, 10, 100)
        put16(&wep, 108, 8)   // MaxAmmo 8
        col.add(Resource(type: NovaType.weapon, id: 400, name: "Missile", data: Data(wep)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        XCTAssertNil(ship2.weapons.first { $0.spec.id == 400 },
                     "ammo with no launcher must not create a weapon mount")
        XCTAssertTrue(ship2.weapons.isEmpty)
    }

    /// Regression: `MaxAmmo == 0` is a documented, common real-data setting
    /// ("Set to 0 or -1 if you want the ammo quantity to be constrained by
    /// the oütf resource's Max field instead" — Nova Bible) — it must NOT be
    /// read as "this weapon carries no ammo." The Bible's actual signal for
    /// that is `AmmoType` (-1 = "ignored, unlimited ammo"; 0-255 = draws from
    /// that ammo pool). A weapon with `AmmoType >= 0` must track finite ammo
    /// even with `MaxAmmo == 0` — exactly the shape of the real "IR Missile"
    /// (wëap #134: MaxAmmo 0, AmmoType 6), which this regressed from.
    func testAmmoTypeNotMaxAmmoDeterminesAmmoTracking() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 78, 300); put16(&ship, 86, 1)   // launcher outfit 300 ×1
        put16(&ship, 80, 301); put16(&ship, 88, 3)   // ammo outfit 301 ×3
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var launcher = [UInt8](repeating: 0, count: 40)
        put16(&launcher, 26, 1); put16(&launcher, 28, 400)   // grants weapon 400
        col.add(Resource(type: NovaType.outfit, id: 300, name: "Missile Launcher", data: Data(launcher)))

        var ammo = [UInt8](repeating: 0, count: 40)
        put16(&ammo, 26, 3); put16(&ammo, 28, 400)   // ammunition for weapon 400
        col.add(Resource(type: NovaType.outfit, id: 301, name: "Missile", data: Data(ammo)))

        var wep = [UInt8](repeating: 0, count: 130)
        put16(&wep, 0, 30); put16(&wep, 4, 10); put16(&wep, 6, 10); put16(&wep, 8, -1); put16(&wep, 10, 100)
        put16(&wep, 12, 272)   // AmmoType 272 → 128+272 = 400 (its own id — self-pooled)
        put16(&wep, 108, 0)    // MaxAmmo 0 — deliberately "unset" per the Bible's documented meaning
        col.add(Resource(type: NovaType.weapon, id: 400, name: "Missile", data: Data(wep)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        let mount = try XCTUnwrap(ship2.weapons.first { $0.spec.id == 400 })
        XCTAssertEqual(mount.ammo, 3, "MaxAmmo == 0 must not force unlimited ammo when AmmoType tracks a pool")
        XCTAssertTrue(mount.ready)
    }

    /// The counterpart: `AmmoType == -1` (the Bible's explicit "unlimited")
    /// always yields unlimited ammo, regardless of `MaxAmmo`.
    func testAmmoTypeMinusOneIsAlwaysUnlimited() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 18, 128); put16(&ship, 26, 1)   // stock weapon 128 ×1
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var wep = [UInt8](repeating: 0, count: 130)
        put16(&wep, 0, 30); put16(&wep, 4, 10); put16(&wep, 6, 10); put16(&wep, 8, -1); put16(&wep, 10, 100)
        put16(&wep, 12, -1)     // AmmoType -1 — unlimited
        put16(&wep, 108, 50)    // MaxAmmo set anyway — must still be ignored
        col.add(Resource(type: NovaType.weapon, id: 128, name: "Blaster", data: Data(wep)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        let mount = try XCTUnwrap(ship2.weapons.first { $0.spec.id == 128 })
        XCTAssertEqual(mount.ammo, -1, "AmmoType -1 is unlimited regardless of MaxAmmo")
        XCTAssertTrue(mount.ready)
    }

    /// Regression: two *different* wëap mounts (e.g. a fixed-mount "Raven
    /// Rocket" and a turreted "Raven Turret") can share one ammo pool by
    /// declaring the same `AmmoType`, per the Bible: AmmoType "draws ammo
    /// from this type of weapon" — a 0-based index needing +128 to become
    /// the real wëap id it names. Real data: wëap #138 "Raven Rocket" and
    /// #139 "Raven Turret" both have `AmmoType 10` (→ 128+10 = 138), while
    /// the "Raven Rocket" ammo outfit's `.ammunition` modifier names #138
    /// directly. A player who owns only the *turret* variant (#139) and the
    /// ammo must still see that ammo attached — matching only `byID[wid]`
    /// (as if a weapon's pool were always its own id) missed this and left
    /// the turret showing 0 ammo forever.
    func testSharedAmmoPoolAcrossMountVariants() throws {
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 6, 300); put16(&ship, 10, 400); put16(&ship, 12, 40)
        put16(&ship, 78, 300); put16(&ship, 86, 2)   // turret outfit 300 ×2 — no pod owned
        put16(&ship, 80, 301); put16(&ship, 88, 15)  // ammo outfit 301 ×15
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))

        var turretOutfit = [UInt8](repeating: 0, count: 40)
        put16(&turretOutfit, 26, 1); put16(&turretOutfit, 28, 401)   // grants weapon 401 (turret variant)
        col.add(Resource(type: NovaType.outfit, id: 300, name: "Raven Rocket Turret", data: Data(turretOutfit)))

        var ammoOutfit = [UInt8](repeating: 0, count: 40)
        put16(&ammoOutfit, 26, 3); put16(&ammoOutfit, 28, 400)   // .ammunition names weapon 400 (the pod variant, unowned)
        col.add(Resource(type: NovaType.outfit, id: 301, name: "Raven Rocket", data: Data(ammoOutfit)))

        // Pod variant (400) — never owned/mounted, just the ammo's nominal target.
        var pod = [UInt8](repeating: 0, count: 130)
        put16(&pod, 0, 15); put16(&pod, 4, 12); put16(&pod, 6, 8); put16(&pod, 8, -1); put16(&pod, 10, 1500)
        put16(&pod, 12, 272)   // AmmoType 272 → 128+272 = 400 (its own id)
        col.add(Resource(type: NovaType.weapon, id: 400, name: "Raven Rocket", data: Data(pod)))

        // Turret variant (401) — owned/mounted, shares the pod's ammo pool.
        var turretWeapon = [UInt8](repeating: 0, count: 130)
        put16(&turretWeapon, 0, 20); put16(&turretWeapon, 4, 12); put16(&turretWeapon, 6, 6); put16(&turretWeapon, 8, -1); put16(&turretWeapon, 10, 1300)
        put16(&turretWeapon, 12, 272)   // AmmoType 272 → 128+272 = 400 (the pod's id, NOT its own 401)
        col.add(Resource(type: NovaType.weapon, id: 401, name: "Raven Turret", data: Data(turretWeapon)))

        let ship2 = try XCTUnwrap(Galaxy(game: NovaGame(col)).makeLoadedShip(128))
        let mount = try XCTUnwrap(ship2.weapons.first { $0.spec.id == 401 })
        XCTAssertEqual(mount.count, 2)
        XCTAssertEqual(mount.ammo, 15, "the turret must draw from the pod's ammo pool despite the id mismatch")
        XCTAssertTrue(mount.ready)
        XCTAssertNil(ship2.weapons.first { $0.spec.id == 400 }, "the pod variant itself was never owned")
    }

    func testSkillVarJittersAccelAndTurnByRoll() throws {
        // shïp.SkillVar (Bible): "up to X% slower or faster than stock" —
        // applied to acceleration and turn rate together via one per-instance
        // roll, and only when a roll is actually supplied.
        var col = ResourceCollection()
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 4, 200)   // accel
        put16(&ship, 6, 300)   // speed
        put16(&ship, 8, 30)    // turn
        put16(&ship, 96, 20)   // SkillVar: 20%
        col.add(Resource(type: NovaType.ship, id: 128, name: "Fighter", data: Data(ship)))
        let galaxy = Galaxy(game: NovaGame(col))

        let stock = try XCTUnwrap(galaxy.makeShip(128))
        XCTAssertEqual(stock.stats.acceleration, 200, "no roll supplied -> no jitter")

        let ace = try XCTUnwrap(galaxy.makeShip(128, skillRoll: 1.0))
        XCTAssertEqual(ace.stats.acceleration, 240, accuracy: 1e-9, "+20% at roll = 1.0")
        XCTAssertEqual(ace.stats.turnRate, stock.stats.turnRate * 1.2, accuracy: 1e-9)

        let rookie = try XCTUnwrap(galaxy.makeShip(128, skillRoll: -1.0))
        XCTAssertEqual(rookie.stats.acceleration, 160, accuracy: 1e-9, "-20% at roll = -1.0")
        XCTAssertEqual(rookie.stats.maxSpeed, stock.stats.maxSpeed, "SkillVar doesn't touch top speed")
    }

    // MARK: fuel / jumps

    func testHyperspaceFuelConsumption() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        XCTAssertTrue(ship.canJump)
        XCTAssertTrue(ship.consumeJumpFuel())
        XCTAssertEqual(ship.fuel, 300, "one jump costs 100")
        XCTAssertTrue(ship.consumeJumpFuel()); XCTAssertTrue(ship.consumeJumpFuel())
        XCTAssertTrue(ship.consumeJumpFuel())     // 0 left
        XCTAssertFalse(ship.canJump)
        XCTAssertFalse(ship.consumeJumpFuel(), "no fuel → no jump, no spend")
        XCTAssertEqual(ship.fuel, 0)
    }

    // MARK: afterburner

    func testAfterburnerBurnsFuelAndBoosts() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        var intent = ControlIntent()
        intent.thrust = true; intent.afterburner = true
        let before = ship.fuel
        ship.step(1.0, intent: intent, tuning: .default)
        XCTAssertTrue(ship.afterburnerActive)
        XCTAssertEqual(ship.fuel, before - 37, accuracy: 0.001, "afterburner drains fuel")
        // While the burner is still lit (fuel remaining), top speed exceeds the
        // un-boosted maximum. (Run only long enough to accelerate, not drain dry.)
        for _ in 0..<20 { ship.step(0.1, intent: intent, tuning: .default) }
        XCTAssertGreaterThan(ship.fuel, 0, "still burning")
        XCTAssertTrue(ship.afterburnerActive)
        XCTAssertGreaterThan(ship.velocity.length, ship.stats.maxSpeed)
    }

    func testAfterburnerInertWithoutFuel() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        ship.fuel = 0
        var intent = ControlIntent(); intent.thrust = true; intent.afterburner = true
        ship.step(1.0, intent: intent, tuning: .default)
        XCTAssertFalse(ship.afterburnerActive, "no fuel → no burn")
    }

    // MARK: cargo hold

    func testCargoLoadRespectsCapacity() throws {
        let ship = try XCTUnwrap(Galaxy(game: makeGame()).makeLoadedShip(128))
        XCTAssertEqual(ship.cargoFree, 80)
        XCTAssertEqual(ship.loadCargo(1, tons: 30), 30)
        XCTAssertEqual(ship.cargoUsed, 30)
        XCTAssertEqual(ship.loadCargo(2, tons: 100), 50, "only 50 tons of room left")
        XCTAssertEqual(ship.cargoUsed, 80)
        XCTAssertEqual(ship.loadCargo(3, tons: 10), 0, "hold is full")
        XCTAssertEqual(ship.unloadCargo(1, tons: 10), 10)
        XCTAssertEqual(ship.cargoUsed, 70)
        XCTAssertEqual(ship.unloadCargo(1, tons: 999), 20, "can't remove more than held")
        XCTAssertNil(ship.cargo[1])
    }
}
