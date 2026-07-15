import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// The debug suite's **in-game self-tests**: a behavioral test battery you run
/// on-device from the running app. Unlike the static `DebugDiagnostics` sweep
/// (which inspects data and current state), these actually *drive the engine* —
/// each test builds its own throwaway `World`/`Ship`, steps the simulation, and
/// asserts on the outcome. They exercise the real damage model, flight physics,
/// projectile combat, and regen exactly as gameplay does.
///
/// Everything runs against isolated worlds, so a test run never touches the
/// player's live session — safe to fire mid-flight. Adding a test is one entry
/// in the relevant section of `DebugLiveTests`.
struct DebugTestsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [DiagnosticSection] = []
    @State private var hasRun = false

    var body: some View {
        NavigationStack {
            List {
                if hasRun {
                    summaryRow
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.results) { DebugResultRow(result: $0) }
                        }
                    }
                } else {
                    Section {
                        Text("Runs the engine's behavioral test battery — damage, flight physics, projectile combat, and regen — against throwaway worlds. Your live session is never touched.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Self-Tests")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasRun ? "Re-run" : "Run") { run() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !hasRun { run() } }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 720, maxHeight: 900)
        #endif
    }

    private func run() {
        model.audio.play(.uiSelect)
        sections = DebugLiveTests.run()
        hasRun = true
    }

    private var summaryRow: some View {
        let all = sections.flatMap(\.results)
        let fails = all.filter { $0.status == .fail }.count
        let passes = all.filter { $0.status == .pass }.count
        return Section {
            HStack {
                Label("\(passes) passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DiagnosticStatus.pass.color)
                Spacer()
                if fails > 0 {
                    Label("\(fails) failed", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(DiagnosticStatus.fail.color)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
        } header: {
            Text(fails == 0 ? "All \(all.count) tests passed" : "\(fails) of \(all.count) tests failing")
        }
    }
}

/// Shared result row used by both the diagnostics and self-test panels.
struct DebugResultRow: View {
    let result: DiagnosticResult
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.status.symbol)
                .foregroundStyle(result.status.color)
                .font(.system(size: 14)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                if let detail = result.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - The behavioral battery

/// Live engine tests. Each closure builds an isolated simulation, runs it, and
/// returns whether the observed behavior matched — the same green-simulation the
/// unit tests assert, but runnable from inside the shipping app on real hardware.
enum DebugLiveTests {

    static func run() -> [DiagnosticSection] {
        [
            DiagnosticSection(title: "Damage Model", results: [
                check("Shields absorb fully; hull only after shields gone") {
                    let s = makeShip()
                    _ = s.applyDamage(shield: 60, armor: 40)          // shields absorb fully
                    guard close(s.shield, 40), close(s.armor, 100) else {
                        return (false, "After 60/40 hit: shield \(r(s.shield)), armor \(r(s.armor)) (want 40 / 100).")
                    }
                    _ = s.applyDamage(shield: 60, armor: 30)          // shields empty — no bleed into hull
                    guard close(s.shield, 0), close(s.armor, 100) else {
                        return (false, "After depleting hit: shield \(r(s.shield)), armor \(r(s.armor)) (want 0 / 100 — no bleed).")
                    }
                    _ = s.applyDamage(shield: 60, armor: 30)          // shields already 0 — hull takes full
                    let ok = close(s.shield, 0) && close(s.armor, 70)
                    return (ok, "Final shield \(r(s.shield)), armor \(r(s.armor)) (want 0 / 70).")
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
                    let ok = killed && !s.isAlive && close(s.armor, 0)
                    return (ok, "applyDamage returned \(killed), isAlive=\(s.isAlive).")
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

    private static func makeWorld() -> World { World(player: makeShip()) }

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
