import XCTest
@testable import NovaSwiftEngine
@testable import NovaSwiftKit

/// AI and combat rules pinned to the original's functions (the AI/combat
/// fidelity sweep): targeting predicates, non-lethal boarding fire, capture,
/// escort orders, ammo and range helpers.
final class AICombatFidelityTests: XCTestCase {

    // MARK: Fixtures

    func govt(_ id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [], flags1: UInt16 = 0,
              maxOdds: Int = 100) -> GovtRes {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, i < allies.count ? allies[i] : -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        putW(2, Int(flags1))
        putW(22, maxOdds)
        return GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)", data: Data(d)))
    }

    func gun(id: Int = 128, range: Double = 600, armor: Double = 10, disablesOnly: Bool = false) -> WeaponSpec {
        var flags = WeaponBehaviorFlags()
        flags.disablesOnly = disablesOnly
        return WeaponSpec(id: id, name: "Gun", shieldDamage: 10, armorDamage: armor, reloadSeconds: 0.5,
                          projectileSpeed: 1500, range: range, accuracyRadians: 0, isBeam: false,
                          isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0, flags: flags)
    }

    func npc(_ name: String, govt: Int, at pos: Vec2, ai: AIType = .warship, armed: Bool = true) -> Ship {
        let s = Ship(name: name, stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30), position: pos)
        s.government = govt
        s.radius = 20
        s.maxShield = 100; s.shield = 100; s.maxArmor = 100; s.armor = 100
        s.shieldRechargePerSec = 0; s.armorRechargePerSec = 0
        s.maxFuel = 300; s.fuel = 300
        s.combatStrength = 10
        s.massTons = 50
        s.crew = 5
        if armed { s.weapons = [WeaponMount(spec: gun())] }
        s.brain = AIBrain(aiType: ai, govt: govt)
        return s
    }

    /// Traders (128) and pirates (129) at war.
    func world() -> World {
        let player = Ship(name: "Player", stats: ShipStats(speed: 300, acceleration: 300, turnRate: 30),
                          position: Vec2(9000, 9000))
        player.maxArmor = 100; player.armor = 100; player.maxShield = 100; player.shield = 100
        let w = World(player: player)
        w.diplomacy = Diplomacy(govts: [
            govt(128, classes: [1], enemies: [2]),
            govt(129, classes: [2], enemies: [1]),
        ])
        return w
    }

    func host(_ w: World) -> WorldAIHost { WorldAIHost(world: w, ai: w.originalAI) }

    func rec(_ w: World, _ s: Ship) -> OriginalAIShipState {
        w.originalAI.ensureRecord(s, host: host(w))
    }

    // MARK: Targeting predicates

    /// 0x0040f780 tests 0x00464a90(ship, player): whether the player can see
    /// the attacker, not the reverse.
    func testKeepPressingAsksWhetherThePlayerSeesTheAttacker() {
        let w = world()
        w.player.position = Vec2(0, 0)
        let pirate = npc("Pirate", govt: 129, at: Vec2(200, 0))
        w.addNPC(pirate)
        let r = rec(w, pirate)
        r.primary = World.playerEntityID
        r.state = OriginalAIState.attack
        XCTAssertTrue(w.originalAI.keepsPressing(pirate, host: host(w)))
        w.originalAI.pressingCache.removeAll()
        r.state = OriginalAIState.gateEmerge
        XCTAssertFalse(w.originalAI.keepsPressing(pirate, host: host(w)),
                       "a ship still emerging from a gate can't be seen, so it isn't pressing")
    }

    /// 0x00410110: a supporter counts as threatened when it is attacking an
    /// enemy of the context ship (0x0040faa0(X, S) = "S attacks X").
    func testSupporterAttackingAnEnemyCountsAsThreatened() {
        let w = world()
        let context = npc("Context", govt: 128, at: Vec2(0, 0))
        let supporter = npc("Supporter", govt: 128, at: Vec2(100, 0))
        let enemy = npc("Enemy", govt: 129, at: Vec2(300, 0))
        for s in [context, supporter, enemy] { w.addNPC(s) }
        _ = rec(w, context); _ = rec(w, enemy)
        let r = rec(w, supporter)
        r.primary = enemy.entityID
        r.state = OriginalAIState.attack
        XCTAssertTrue(w.originalAI.isThreatenedByEnemy(supporter, of: context, host: host(w)))
        r.primary = nil
        r.state = OriginalAIState.idle
        XCTAssertFalse(w.originalAI.isThreatenedByEnemy(supporter, of: context, host: host(w)))
    }
}
