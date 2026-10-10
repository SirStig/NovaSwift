import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Cloaking (oütf ModType 17), cloak scanners (30), and interference-scaled
/// sensor range (sÿst.Interference / ModType 24).
final class CloakTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    // MARK: loadout flag aggregation

    func testLoadoutAggregatesCloakAndScannerFlags() throws {
        var ship = [UInt8](repeating: 0, count: 2000)
        put16(&ship, 12, 40); put16(&ship, 14, 100)   // free mass, armor
        var col = ResourceCollection()
        col.add(Resource(type: NovaType.ship, id: 128, name: "Hull", data: Data(ship)))
        func outfit(_ id: Int, mod: Int, val: Int) -> Resource {
            var b = [UInt8](repeating: 0, count: 1028); put16(&b, 6, mod); put16(&b, 8, val)
            return Resource(type: NovaType.outfit, id: id, name: "O\(id)", data: Data(b))
        }
        col.add(outfit(200, mod: 17, val: 0x0084))   // cloak: 8 fuel/sec + drops shields
        col.add(outfit(201, mod: 30, val: 0x0008))   // cloak scanner: target cloaked
        col.add(outfit(202, mod: 24, val: 20))       // -20 interference
        let lo = try XCTUnwrap(Galaxy(game: NovaGame(col)).loadout(shipID: 128,
                                    extraOutfits: [200: 1, 201: 1, 202: 1]))
        XCTAssertEqual(lo.cloakFlags, 0x0084)
        XCTAssertEqual(lo.cloakScannerFlags, 0x0008)
        XCTAssertEqual(lo.interferenceReduction, 20)
    }

    // MARK: cloak fade + fuel drain

    func testCloakFadesInAndDrainsFuel() {
        // OS-04: 0.75 of 32 a tick → 42.7 ticks to full; the fuel nibble per second.
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0010          // 1 fuel/sec
        player.maxFuel = 100; player.fuel = 100
        player.cloakEngaged = true
        let world = World(player: player)
        for _ in 0..<30 { world.step(1.0 / 30.0) }
        XCTAssertEqual(player.cloakLevel, 30 * 0.75 / 32, accuracy: 1e-9)
        XCTAssertFalse(player.isCloaked, "not hidden until past 24/32 while fading in")
        XCTAssertEqual(player.fuel, 99, accuracy: 0.01, "1 fuel/sec drained")
        for _ in 0..<3 { world.step(1.0 / 30.0) }
        XCTAssertTrue(player.isCloaked, "33 ticks: 24.75/32")
        player.cloakEngaged = false
        for _ in 0..<20 { world.step(1.0 / 30.0) }
        XCTAssertTrue(player.isCloaked, "still hidden until under 8/32 while clearing")
        for _ in 0..<15 { world.step(1.0 / 30.0) }
        XCTAssertFalse(player.isCloaked)
    }

    func testCloakNeedsFuelEvenWithoutAFuelDrain() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0100          // shield drain only
        player.maxFuel = 100; player.fuel = 0
        player.maxShield = 100; player.shield = 100
        player.cloakEngaged = true
        let world = World(player: player)
        world.step(1.0 / 30.0)
        XCTAssertFalse(player.cloakEngaged, "the cloak always needs fuel > 0 (quirk)")
    }

    func testCloakForcedOffWhenFuelRunsOut() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0010
        player.maxFuel = 100; player.fuel = 0.5
        player.cloakEngaged = true
        let world = World(player: player)
        world.step(1.0)
        XCTAssertEqual(player.fuel, 0, accuracy: 0.001)
        world.step(1.0 / 30.0)
        XCTAssertFalse(player.cloakEngaged, "cloak drops when it can't be powered")
    }

    func testShieldDrainLeavesTheLastPointsAndDisabledDropsTheCloak() {
        let npc = Ship(name: "N", stats: stats())
        npc.cloakFlags = 0x0810            // 8 shield/sec, 1 fuel/sec
        npc.maxFuel = 100; npc.fuel = 100
        npc.maxShield = 100; npc.shield = 0.2
        npc.cloakEngaged = true
        let world = World(player: Ship(name: "P", stats: stats()))
        world.addNPC(npc)
        world.step(1.0 / 30.0)
        XCTAssertEqual(npc.shield, 0.2, accuracy: 1e-9, "drain applies only while shields ≥ a tick's 8/30")
        XCTAssertTrue(npc.cloakEngaged, "the shield gate never drops the cloak (quirk)")
        npc.armor = 1
        world.step(1.0 / 30.0)
        XCTAssertFalse(npc.cloakEngaged, "a disabled ship can't hold its cloak")
    }

    func testPlayerShieldsStayZeroedEveryTickWithFlag0004() {
        let player = Ship(name: "P", stats: stats())
        player.cloakFlags = 0x0014
        player.maxFuel = 100; player.fuel = 100
        player.maxShield = 100; player.shield = 100
        player.shieldRechargePerSec = 30
        player.cloakEngaged = true
        let world = World(player: player)
        for _ in 0..<10 { world.step(1.0 / 30.0) }
        XCTAssertEqual(player.shield, 0, accuracy: 1e-9)
    }

    // MARK: detection

    func testCloakedShipEngageableOnlyCloseWithScannerBit0002OrByItsEscorts() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        let target = Ship(name: "T", stats: stats(), position: Vec2(150, 150))
        target.cloakFlags = 0x0010; target.cloakLevel = 1.0; target.cloakEngaged = true
        _ = world.addNPC(target)
        XCTAssertFalse(world.canDetect(target, by: observer))
        observer.cloakScannerFlags = 0x0002
        XCTAssertTrue(world.canDetect(target, by: observer), "within 200 px per axis")
        target.position = Vec2(150, 250)
        XCTAssertFalse(world.canDetect(target, by: observer))
        let escort = Ship(name: "E", stats: stats(), position: Vec2(2000, 0))
        let eb = AIBrain(aiType: .warship, govt: 130); eb.leaderID = target.entityID
        escort.brain = eb
        world.addNPC(escort)
        XCTAssertTrue(world.canDetect(target, by: escort), "its own escorts see it")
        target.cloakLevel = 0; target.cloakEngaged = false
        observer.cloakScannerFlags = 0
        XCTAssertTrue(world.canDetect(target, by: observer))
    }

    func testUntargetableHullNeedsScannerBit0004() {
        // OS-12: shïp Flags2 0x0004.
        let player = Ship(name: "P", stats: stats())
        let world = World(player: player)
        let ghost = Ship(name: "G", stats: stats(), position: Vec2(0, 300))
        ghost.hullFlags2 = 0x0004
        world.addNPC(ghost)
        XCTAssertNil(world.selectNearestTarget(hostileOnly: false))
        XCTAssertNil(world.selectTarget(id: ghost.entityID))
        player.cloakScannerFlags = 0x0004
        XCTAssertEqual(world.selectNearestTarget(hostileOnly: false)?.entityID, ghost.entityID)
    }

    // MARK: area cloak (0x1000) — shared onto formation-mates

    func testAreaCloakSharesLevelWithEscortLackingItsOwnDevice() {
        let world = World(player: Ship(name: "P", stats: stats()))
        let leader = Ship(name: "Leader", stats: stats())
        leader.cloakFlags = 0x1010          // area cloak, 1 fuel/sec
        leader.maxFuel = 100; leader.fuel = 100
        leader.cloakEngaged = true
        world.addNPC(leader)

        let escort = Ship(name: "Escort", stats: stats())
        world.addNPC(escort)
        let escortBrain = AIBrain(aiType: .warship, govt: 100)
        escortBrain.leaderID = leader.entityID
        escort.brain = escortBrain

        for _ in 0..<60 { world.step(1.0) }   // plenty of time to fully fade in
        XCTAssertEqual(leader.cloakLevel, 1.0, accuracy: 0.001)
        XCTAssertEqual(escort.areaCloakLevel, 1.0, accuracy: 0.001,
                       "an escort with no cloak of its own shares its area-cloaking leader's level")
        XCTAssertTrue(escort.isEffectivelyCloaked, "the shared area-cloak level counts as effectively cloaked")
        XCTAssertFalse(escort.isCloaked, "but the escort's own device-level cloak state stays untouched")
    }

    func testAreaCloakDoesNotLeakToUnrelatedShips() {
        let world = World(player: Ship(name: "P", stats: stats()))
        let leader = Ship(name: "Leader", stats: stats())
        leader.cloakFlags = 0x1010
        leader.maxFuel = 100; leader.fuel = 100
        leader.cloakEngaged = true
        world.addNPC(leader)

        let bystander = Ship(name: "Bystander", stats: stats())
        world.addNPC(bystander)   // no leaderID — not in the leader's formation

        for _ in 0..<60 { world.step(1.0) }
        XCTAssertEqual(bystander.areaCloakLevel, 0, "an unrelated ship shares in no one's area cloak")
        XCTAssertFalse(bystander.isEffectivelyCloaked)
    }

    func testCanDetectHonorsAreaCloakOnAnUncloakedEscort() {
        let world = World(player: Ship(name: "P", stats: stats()))
        let leader = Ship(name: "Leader", stats: stats())
        leader.cloakFlags = 0x1010
        leader.maxFuel = 100; leader.fuel = 100
        leader.cloakEngaged = true
        world.addNPC(leader)

        let escort = Ship(name: "Escort", stats: stats())
        world.addNPC(escort)
        let escortBrain = AIBrain(aiType: .warship, govt: 100)
        escortBrain.leaderID = leader.entityID
        escort.brain = escortBrain

        for _ in 0..<60 { world.step(1.0) }
        let observer = Ship(name: "O", stats: stats())
        XCTAssertFalse(world.canDetect(escort, by: observer),
                       "an area-cloaked escort is undetectable just like its cloaking leader")
    }

    // MARK: interference (OS-05)

    /// Interference never shortens sensor range in the original; it only turns
    /// some radar refreshes into static, net of anti-interference outfits.
    func testInterferenceGivesRadarStaticNotShorterRange() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        world.systemInterference = 50
        XCTAssertEqual(world.effectiveSensorRange(1500, for: observer), 1500, accuracy: 0.1)
        XCTAssertEqual(world.radarStaticChance(for: observer), 50)
        world.systemInterference = 100
        XCTAssertEqual(world.radarStaticChance(for: observer), 100)
        world.systemInterference = 50
        observer.interferenceReduction = 50   // anti-interference cancels it
        XCTAssertEqual(world.radarStaticChance(for: observer), 0)
        observer.interferenceReduction = 300  // the outfit sum is clamped to 100 first
        world.systemInterference = 100
        XCTAssertEqual(world.radarStaticChance(for: observer), 0)
    }

    // MARK: murk (sÿst.Murk / ModType 28)

    func testEffectiveMurkNetsObserversMurkModifier() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        world.systemMurk = 60
        XCTAssertEqual(world.effectiveMurk(for: observer), 60)
        observer.murkModifier = 20   // a murk-reducing outfit
        XCTAssertEqual(world.effectiveMurk(for: observer), 40)
    }

    func testEffectiveMurkCapsAtOneHundredButNotBelowZero() {
        let observer = Ship(name: "O", stats: stats())
        let world = World(player: observer)
        world.systemMurk = 90
        observer.murkModifier = -50   // a murk-worsening outfit pushes past the 100 cap
        XCTAssertEqual(world.effectiveMurk(for: observer), 100, "murk is documented 0-100 at the high end")

        world.systemMurk = 0
        observer.murkModifier = 10   // a murk-reducing outfit can push it negative
        XCTAssertEqual(world.effectiveMurk(for: observer), -10, "can still go negative — a distinct \"hides the starfield\" state")
    }
}

final class MurkFogTests: XCTestCase {
    func testLevelFollowsSquaredDistance() {
        XCTAssertEqual(MurkFog.level(murk: 100, dx: 100, dy: 100), 24)
        XCTAssertEqual(MurkFog.level(murk: 100, dx: 200, dy: 0), 31)
        XCTAssertEqual(MurkFog.level(murk: 0, dx: 500, dy: 500), 0)
        XCTAssertEqual(MurkFog.level(murk: 30, dx: 0, dy: 0), 0)
    }
}

final class DebrisPuffTests: XCTestCase {
    func testBackgroundLevelRoundsAndClamps() {
        XCTAssertEqual(MurkFog.backgroundLevel(murk: 0), 0)
        XCTAssertEqual(MurkFog.backgroundLevel(murk: 1), 2)
        XCTAssertEqual(MurkFog.backgroundLevel(murk: 20), 18)
        XCTAssertEqual(MurkFog.backgroundLevel(murk: 100), 29)
    }

    func testPuffFades() {
        var p = DebrisPuff(); p.life = 40
        XCTAssertEqual(p.opacity, 1)
        p.life = 16
        XCTAssertEqual(p.opacity, 0.5)
    }
}
