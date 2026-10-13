import Foundation
import NovaSwiftKit
import NovaSwiftEngine

// Shared behavioural engine tests (formerly in the Apple app's DebugTestsView.swift); the Apple
// view and the Godot dev tools both run `DebugLiveTests.run()`.

// MARK: - The behavioral battery

/// Live engine tests. Each closure builds an isolated simulation, runs it, and
/// returns whether the observed behavior matched — the same green-simulation the
/// unit tests assert, but runnable from inside the shipping app on real hardware.
public enum DebugLiveTests {

    public static func run() -> [DiagnosticSection] {
        [
            DiagnosticSection(title: "Damage Model", results: [
                // Original model (`Ship.applyDamage`, World.swift): the hit subtracts from the
                // shield; only once the shield is at/below zero does the same hit land on armor,
                // and the shield is floored at -10% of max. (Earlier revisions of this test
                // asserted a "no bleed" model the engine no longer has.)
                check("Shields absorb first; armor is hit once they break") {
                    let s = makeShip()
                    _ = s.applyDamage(shield: 60, armor: 40)          // shield holds: armor untouched
                    guard close(s.shield, 40), close(s.armor, 100) else {
                        return (false, "After 60/40 hit: shield \(r(s.shield)), armor \(r(s.armor)) (want 40 / 100).")
                    }
                    _ = s.applyDamage(shield: 60, armor: 30)          // breaks the shield: armor takes 30, shield floors at -10
                    guard close(s.shield, -10), close(s.armor, 70) else {
                        return (false, "After breaking hit: shield \(r(s.shield)), armor \(r(s.armor)) (want -10 / 70).")
                    }
                    _ = s.applyDamage(shield: 60, armor: 30)          // shield already gone: armor takes the full hit
                    let ok = close(s.shield, -10) && close(s.armor, 40)
                    return (ok, "Final shield \(r(s.shield)), armor \(r(s.armor)) (want -10 / 40).")
                },
                check("God mode negates all damage") {
                    let s = makeShip(); s.invulnerable = true
                    let killed = s.applyDamage(shield: 10_000, armor: 10_000)
                    let ok = !killed && close(s.shield, 100) && close(s.armor, 100)
                    return (ok, "Lethal hit left shield \(r(s.shield)), armor \(r(s.armor)); killed=\(killed).")
                },
                check("Zeroing armor destroys the ship") {
                    let s = makeShip(); s.shield = 0
                    let killed = s.applyDamage(shield: 0, armor: 200)
                    let ok = killed && !s.isAlive && s.armor <= 0          // armor simply subtracts past zero
                    return (ok, "applyDamage returned \(killed), isAlive=\(s.isAlive), armor \(r(s.armor)).")
                },
            ]),
            DiagnosticSection(title: "Projectile Combat", results: [
                check("Fired shot travels and damages target") {
                    let attacker = makeShip()
                    let world = World(player: attacker)
                    let target = makeShip()
                    target.position = Vec2(0, 300)               // straight ahead (north)
                    let tid = world.addNPC(target)
                    attacker.weapons = [WeaponMount(spec: gun())]
                    world.intent.firePrimary = true
                    var hit = false
                    for _ in 0..<40 {
                        world.step(0.02)
                        if let t = world.ship(id: tid), t.shield < 100 { hit = true; break }
                    }
                    let remaining = world.ship(id: tid)?.shield ?? -1
                    return (hit, hit ? "Target shield fell to \(r(remaining))."
                                     : "Target took no damage in 0.8s of fire.")
                },
            ]),
            DiagnosticSection(title: "Flight Physics", results: [
                check("Thrust accelerates along heading") {
                    let world = makeWorld()                       // angle 0 = +y
                    world.intent.thrust = true
                    world.step(1.0)
                    let v = world.player.velocity
                    let ok = close(v.x, 0) && close(v.y, 50, tol: 0.01)
                    return (ok, "Velocity (\(r(v.x)), \(r(v.y))) after 1s (want 0, 50).")
                },
                check("Speed is clamped to max") {
                    let world = makeWorld()
                    world.intent.thrust = true
                    for _ in 0..<100 { world.step(1.0) }          // would be 5000 unclamped
                    let sp = world.player.velocity.length
                    return (close(sp, 100, tol: 0.01), "Top speed \(r(sp)) (cap 100).")
                },
                check("Turning changes heading") {
                    let world = makeWorld()                       // turnRate π = 180°/s
                    world.intent.turnRight = true
                    world.step(0.5)                              // 90° clockwise
                    let ok = close(world.player.angle, .pi / 2, tol: 0.001)
                    return (ok, "Heading \(r(world.player.angle)) rad (want \(r(.pi/2))).")
                },
                check("Coasts on inertia without thrust") {
                    let world = makeWorld()
                    world.intent.thrust = true; world.step(1.0)
                    let before = world.player.velocity.length
                    world.intent.thrust = false; world.step(1.0)
                    let after = world.player.velocity.length
                    return (close(before, after, tol: 0.01), "Speed \(r(before)) → \(r(after)) coasting.")
                },
            ]),
            DiagnosticSection(title: "Regeneration", results: [
                check("Shields regenerate over time") {
                    let s = makeShip(); s.shieldRechargePerSec = 8; s.shield = 0
                    let world = World(player: s)
                    world.step(1.0)
                    return (close(s.shield, 8, tol: 0.5), "Shield recharged to \(r(s.shield)) in 1s (want ~8).")
                },
                check("Fuel regenerates over time") {
                    let s = makeShip(); s.maxFuel = 300; s.fuel = 100; s.fuelRegenPerSec = 20
                    let world = World(player: s)
                    world.step(1.0)
                    return (s.fuel > 100 && s.fuel <= 300, "Fuel \(r(s.fuel)) after 1s (started 100).")
                },
            ]),
        ]
    }

    // MARK: Builders & assertion helpers

    private static func check(_ name: String, _ block: () -> (Bool, String)) -> DiagnosticResult {
        let (ok, detail) = block()
        return DiagnosticResult(name: name, status: ok ? .pass : .fail, detail: detail)
    }

    private static func makeShip(maxSpeed: Double = 100, accel: Double = 50,
                                 turn: Double = .pi) -> Ship {
        let s = Ship(name: "T", stats: ShipStats(maxSpeed: maxSpeed, acceleration: accel, turnRate: turn))
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.radius = 20
        return s
    }

    private static func makeWorld() -> World {
        let world = World(player: makeShip())
        world.strictPlay = true   // no non-strict ×1.5, so the cap is the stat
        return world
    }

    private static func gun(shield: Double = 50, armor: Double = 50) -> WeaponSpec {
        WeaponSpec(id: 128, name: "Gun", shieldDamage: shield, armorDamage: armor,
                   reloadSeconds: 0.05, projectileSpeed: 2000, range: 4000,
                   accuracyRadians: 0, isBeam: false, isGuided: false, turnRate: 0,
                   blastRadius: 0, ammoPerShot: 0)
    }

    private static func close(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool {
        abs(a - b) <= tol
    }
    /// Round for display.
    private static func r(_ v: Double) -> String { String(format: "%.2f", v) }
}
