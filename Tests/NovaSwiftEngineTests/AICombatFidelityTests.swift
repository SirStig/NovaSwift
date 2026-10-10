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

    /// 0x00410110 (argument order as shipped, confirmed by the caller
    /// investigation): an enemy of the context ship attacking the supporter
    /// counts it as threatened.
    func testSupporterAttackedByAnEnemyCountsAsThreatened() {
        let w = world()
        let context = npc("Context", govt: 128, at: Vec2(0, 0))
        let supporter = npc("Supporter", govt: 128, at: Vec2(100, 0))
        let enemy = npc("Enemy", govt: 129, at: Vec2(300, 0))
        for s in [context, supporter, enemy] { w.addNPC(s) }
        _ = rec(w, context); _ = rec(w, supporter)
        let r = rec(w, enemy)
        r.primary = supporter.entityID
        r.state = OriginalAIState.attack
        XCTAssertTrue(w.originalAI.isThreatenedByEnemy(supporter, of: context, host: host(w)))
        r.primary = nil
        r.state = OriginalAIState.idle
        XCTAssertFalse(w.originalAI.isThreatenedByEnemy(supporter, of: context, host: host(w)))
    }

    // MARK: Sweep leftovers

    /// D-2: a led NPC in velocity-match flies Newtonian; unled stays inertialess.
    func testLedInertialessShipInVelocityMatchFliesNewtonian() {
        let w = world()
        let leader = npc("Leader", govt: 128, at: Vec2(0, 0))
        let escort = npc("Escort", govt: 128, at: Vec2(100, 0))
        escort.inertialess = true
        w.addNPC(leader); w.addNPC(escort)
        escort.velocityMatchLed = false
        XCTAssertTrue(escort.isInertialessNow)
        escort.velocityMatchLed = true
        XCTAssertFalse(escort.isInertialessNow)
    }

    /// D-4: engaging then disengaging the player's cloak emits one event each.
    func testPlayerCloakToggleEmitsOneEventEachWay() {
        let w = world()
        w.player.cloakFlags = 1
        w.player.maxFuel = 300; w.player.fuel = 300
        func changes() -> [Bool] {
            w.drainEvents().compactMap { e -> Bool? in
                if case let .playerCloakChanged(engaging) = e { return engaging } else { return nil }
            }
        }
        w.togglePlayerCloak()
        w.step(1.0 / 30.0)
        var seen = changes()
        w.togglePlayerCloak()
        w.step(1.0 / 30.0)
        seen += changes()
        XCTAssertEqual(seen, [true, false])
    }

    /// C-2: a negative shän compress reads as 100.
    func testNegativeCompressReadsAsNone() {
        var d = [UInt8](repeating: 0, count: 200)
        d[136] = 0xff; d[137] = 0xce   // -50
        let shan = ShanRes(Resource(type: NovaType.shan, id: 128, name: "S", data: Data(d)))
        XCTAssertEqual(shan.upCompress.x, 100)
    }

    /// B-7: a miner aims ahead of a moving rock by dist / raw Speed ticks of
    /// relative velocity, and straight at it with no active bank.
    func testMinerLeadsAMovingRock() {
        let miner = npc("Miner", govt: 128, at: Vec2(0, 0))
        var spec = gun()
        spec = WeaponSpec(id: 128, name: "Slow", shieldDamage: 1, armorDamage: 1, reloadSeconds: 0.5,
                          projectileSpeed: 90, range: 2000, accuracyRadians: 0, isBeam: false,
                          isGuided: false, turnRate: 0, blastRadius: 0, ammoPerShot: 0)
        miner.weapons = [WeaponMount(spec: spec)]
        let rock = (position: Vec2(0, 1000), velocity: Vec2(600, 0))   // 20 px/tick sideways
        let straight = OriginalAI.rockLeadBearingDeg(ship: miner, rock: rock, bank: nil)
        let led = OriginalAI.rockLeadBearingDeg(ship: miner, rock: rock, bank: 0)
        XCTAssertEqual(straight, 0, accuracy: 0.5)
        XCTAssertGreaterThan(led, 2)
        XCTAssertLessThan(led, 5)
    }

    // MARK: Disable-only fire (A1)

    /// 0x004192d0: a boarder's hit on its own target leaves armor at 1; the
    /// same hit from an attacking ship destroys.
    func testBoarderHitOnItsTargetIsNonLethal() {
        for (state, survives) in [(OriginalAIState.board, true), (OriginalAIState.attack, false)] {
            let w = world()
            let pirate = npc("Pirate", govt: 129, at: Vec2(0, 0))
            let trader = npc("Trader", govt: 128, at: Vec2(100, 0))
            w.addNPC(pirate); w.addNPC(trader)
            let r = rec(w, pirate)
            r.state = state
            r.primary = trader.entityID
            trader.shield = 0
            trader.armor = 2
            w.applyHit(to: trader, shield: 0, armor: 50, ownerID: pirate.entityID)
            XCTAssertEqual(trader.isAlive, survives, "state \(state)")
            if survives { XCTAssertEqual(trader.armor, 1) }
        }
    }

    /// The squad leader's boarding state covers its escorts' hits too.
    func testEscortOfABoardingLeaderFiresNonLethal() {
        let w = world()
        let leader = npc("Leader", govt: 129, at: Vec2(0, 0))
        let wing = npc("Wing", govt: 129, at: Vec2(30, 0))
        let trader = npc("Trader", govt: 128, at: Vec2(100, 0))
        for s in [leader, wing, trader] { w.addNPC(s) }
        wing.brain?.leaderID = leader.entityID
        rec(w, leader).state = OriginalAIState.board
        let r = rec(w, wing)
        r.state = OriginalAIState.attack
        r.primary = trader.entityID
        trader.shield = 0; trader.armor = 2
        w.applyHit(to: trader, shield: 0, armor: 50, ownerID: wing.entityID)
        XCTAssertEqual(trader.armor, 1)
    }

    /// 0x0041fd30: a shot from an NPC locked on (state 4, control 0x0F) a
    /// target that isn't disabled carries the non-lethal byte; once the
    /// target is disabled the lock no longer marks it.
    func testLockedOnShotsCarryTheNonLethalByte() {
        let w = world()
        let pirate = npc("Pirate", govt: 129, at: Vec2(0, 0))
        let trader = npc("Trader", govt: 128, at: Vec2(0, 200))
        w.addNPC(pirate); w.addNPC(trader)
        let r = rec(w, pirate)
        r.state = OriginalAIState.attack
        r.mode = OriginalAIMode.boardHold
        r.primary = trader.entityID
        pirate.currentTargetID = trader.entityID
        let shot = w.spawnProjectile(spec: gun(), muzzle: pirate.position, aim: 0, ownerID: pirate.entityID,
                                     ownerGovt: 129, ownerVelocity: Vec2(), targetID: nil, subDepth: 0,
                                     shooter: pirate)
        XCTAssertTrue(shot.nonLethal)
        trader.armor = 10
        let late = w.spawnProjectile(spec: gun(), muzzle: pirate.position, aim: 0, ownerID: pirate.entityID,
                                     ownerGovt: 129, ownerVelocity: Vec2(), targetID: nil, subDepth: 0,
                                     shooter: pirate)
        XCTAssertFalse(late.nonLethal, "the target is already disabled")
        r.mode = OriginalAIMode.pursuit
        trader.armor = 100
        let plain = w.spawnProjectile(spec: gun(), muzzle: pirate.position, aim: 0, ownerID: pirate.entityID,
                                      ownerGovt: 129, ownerVelocity: Vec2(), targetID: nil, subDepth: 0,
                                      shooter: pirate)
        XCTAssertFalse(plain.nonLethal)
    }
}
