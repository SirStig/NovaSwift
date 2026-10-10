import XCTest
@testable import NovaSwiftKit
@testable import NovaSwiftEngine

/// Planetary domination — Demand Tribute: `spöb` field decode, the combat-rating
/// laugh gate, defense-wave launch/relaunch, and surrender.
final class DominationTests: XCTestCase {

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }
    private func stats() -> ShipStats { ShipStats(maxSpeed: 300, acceleration: 200, turnRate: 3) }

    private func ship(_ id: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 2000)
        put16(&b, 12, 40); put16(&b, 14, 120)   // free mass, armor
        return Resource(type: NovaType.ship, id: id, name: "Hull", data: Data(b))
    }
    private func dude(_ id: Int, govt: Int, ship: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 88)
        put16(&b, 0, AIType.warship.rawValue); put16(&b, 2, govt)
        put16(&b, 8, ship); put16(&b, 40, 100)
        return Resource(type: NovaType.dude, id: id, name: "Def\(id)", data: Data(b))
    }
    private func govt(_ id: Int, killPenalty: Int = 0) -> Resource {
        var b = [UInt8](repeating: 0, count: 200)
        put16(&b, 16, killPenalty)
        for i in 0..<4 { put16(&b, 24 + i * 2, i == 0 ? 1 : -1) }
        for i in 0..<4 { put16(&b, 32 + i * 2, -1) }
        for i in 0..<4 { put16(&b, 40 + i * 2, -1) }
        return Resource(type: NovaType.govt, id: id, name: "Govt\(id)", data: Data(b))
    }
    /// A `spöb` with just the domination fields set.
    private func spob(_ id: Int, tribute: Int, govt: Int, defenseDude: Int,
                      defenseCount: Int, techLevel: Int = 5) -> Resource {
        var b = [UInt8](repeating: 0, count: 600)
        put16(&b, 10, tribute)
        put16(&b, 12, techLevel)
        put16(&b, 20, govt)
        put16(&b, 28, defenseDude)
        put16(&b, 30, defenseCount)
        return Resource(type: NovaType.spob, id: id, name: "World\(id)", data: Data(b))
    }

    // MARK: spöb decode

    func testDefCountDecimalDecoding() {
        func decode(_ raw: Int) -> (total: Int, wave: Int) {
            let s = SpobRes(spob(200, tribute: 0, govt: 128, defenseDude: 300, defenseCount: raw))
            return (s.defenseTotal, s.defenseWaveSize)
        }
        XCTAssertEqual(decode(1082).total, 8);  XCTAssertEqual(decode(1082).wave, 2)   // Bible example
        XCTAssertEqual(decode(2005).total, 100); XCTAssertEqual(decode(2005).wave, 5)  // Bible example
        XCTAssertEqual(decode(7006).total, 600); XCTAssertEqual(decode(7006).wave, 6)  // real Earth
        let small = decode(8)                                                          // ≤1000 = all at once
        XCTAssertEqual(small.total, 8); XCTAssertEqual(small.wave, 8)
    }

    func testTributeDefaultAndExplicit() {
        let explicit = SpobRes(spob(200, tribute: 2500, govt: 128, defenseDude: 300, defenseCount: 8, techLevel: 4))
        XCTAssertEqual(explicit.dailyTributeAmount, 2500)
        let deflt = SpobRes(spob(201, tribute: 0, govt: 128, defenseDude: 300, defenseCount: 8, techLevel: 4))
        XCTAssertEqual(deflt.dailyTributeAmount, 4000, "-1/0 tribute defaults to 1000 × techLevel")
    }

    // MARK: engine flow

    private func makeWorld(defenseCount: Int) -> (World, Galaxy, Int) {
        var col = ResourceCollection()
        let spobID = 128
        col.add(ship(128)); col.add(govt(128))
        col.add(dude(300, govt: 128, ship: 128))
        col.add(spob(spobID, tribute: 500, govt: 128, defenseDude: 300, defenseCount: defenseCount))
        let galaxy = Galaxy(game: NovaGame(col))
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        world.systemContext = SystemContext(bodies: [
            StellarBody(id: spobID, position: Vec2(200, 0), radius: 40, canLand: true, government: 128)
        ])
        return (world, galaxy, spobID)
    }

    /// AI-15: the garrison persists across visits — leaving with 3 of 10
    /// defenders killed and coming back finds 7.
    func testGarrisonSurvivorsAreCreditedBackAcrossVisits() {
        let (world, _, spobID) = makeWorld(defenseCount: 10)
        world.playerCombatRating = 20_000
        _ = world.demandTribute(spobID: spobID)
        let defenders = world.npcs.filter { $0.spobDefenderOf == spobID }
        XCTAssertEqual(defenders.count, 10)
        for d in defenders.prefix(3) { d.armor = 0 }
        world.step(1.0 / 30.0)
        let snapshot = world.garrisonSnapshot()
        XCTAssertEqual(snapshot[spobID] ?? nil, 7)
        // Next visit: a fresh world seeded from the save.
        let (again, _, _) = makeWorld(defenseCount: 10)
        again.playerCombatRating = 20_000
        again.stellarGarrisons = [spobID: 7]
        XCTAssertEqual(again.demandTribute(spobID: spobID), .defending(launched: 7))
        // Release reseeds it.
        again.releaseStellar(spobID: spobID)
        XCTAssertEqual(again.garrisonSnapshot()[spobID] ?? 0, nil)
    }

    /// EC-16: a flat combat-rating gate of 12,800 (0x00480030).
    func testDemandLaughsBelowCombatRating() {
        let (world, _, spobID) = makeWorld(defenseCount: 8)
        world.playerCombatRating = 12_799
        let outcome = world.demandTribute(spobID: spobID)
        XCTAssertEqual(outcome, .refused(.combatRatingTooLow(required: 12_800)))
        XCTAssertTrue(world.npcs.isEmpty, "a laughed-off demand launches no defenders")
    }

    /// EC-16: a stellar with nothing to fight submits to the first demand.
    func testUndefendedWorldIsDominatedOnTheFirstDemand() {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(govt(128))
        col.add(spob(128, tribute: 500, govt: 128, defenseDude: -1, defenseCount: 0))
        let galaxy = Galaxy(game: NovaGame(col))
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.systemContext = SystemContext(bodies: [
            StellarBody(id: 128, position: Vec2(200, 0), radius: 40, canLand: true, government: 128)])
        world.playerCombatRating = 100000
        XCTAssertEqual(world.demandTribute(spobID: 128, firstPressInWindow: false), .stillDefending,
                       "only the first press in a comm window can win it")
        XCTAssertEqual(world.demandTribute(spobID: 128), .dominated)
    }

    /// EC-16: every demand is a crime — a record that still meets MinStatus
    /// drops to MinStatus − 1, then the kill penalty applies, even when the
    /// demand is laughed off.
    func testEveryDemandCostsStanding() {
        var col = ResourceCollection()
        col.add(ship(128)); col.add(govt(128, killPenalty: 20))
        var b = [UInt8](spob(128, tribute: 500, govt: 128, defenseDude: -1, defenseCount: 0).data)
        put16(&b, 22, 5)                                         // MinStatus
        col.add(Resource(type: NovaType.spob, id: 128, name: "World", data: Data(b)))
        let galaxy = Galaxy(game: NovaGame(col))
        let world = World(player: Ship(name: "P", stats: stats()))
        world.galaxy = galaxy
        world.diplomacy = galaxy.makeDiplomacy()
        world.diplomacy?.reputationMap = ReputationMap(systems: [.init(id: 500, govt: 128, x: 0, y: 0, links: [])])
        world.diplomacy?.currentSystemID = 500
        world.diplomacy?.seed(reputation: [500: 40])
        world.systemContext = SystemContext(bodies: [
            StellarBody(id: 128, position: Vec2(200, 0), radius: 40, canLand: true, government: 128)])
        world.playerCombatRating = 0
        XCTAssertEqual(world.demandTribute(spobID: 128), .refused(.combatRatingTooLow(required: 12_800)))
        XCTAssertEqual(world.diplomacy?.reputationHere, 4 - 20)
        world.playerCombatRating = 12_800
        XCTAssertEqual(world.demandTribute(spobID: 128), .dominated)
        XCTAssertEqual(world.diplomacy?.reputationHere, 4 - 20 * 7, "one flood, then five more on domination")
    }

    func testAlreadyDominatedRefused() {
        let (world, _, spobID) = makeWorld(defenseCount: 8)
        world.dominatedStellars = [spobID]
        XCTAssertEqual(world.demandTribute(spobID: spobID), .refused(.alreadyDominated))
    }

    func testDemandLaunchesDefendersThenDominatesWhenCleared() {
        let (world, _, spobID) = makeWorld(defenseCount: 1082)   // total 8, waves of 2
        world.playerCombatRating = 12_800

        let first = world.demandTribute(spobID: spobID)
        XCTAssertEqual(first, .defending(launched: 2), "the first demand scrambles a wave of two")
        XCTAssertEqual(world.liveDefenders(of: spobID), 2)
        XCTAssertTrue(world.npcs.allSatisfy { $0.spobDefenderOf == spobID },
                      "launched ships are tagged as this stellar's defenders")

        // Simulate the player defeating every wave; the world relaunches until
        // the pool of 8 is spent, then the next demand wins.
        var dominated = false
        var totalDefeated = 0
        for _ in 0..<400 {
            for npc in world.npcs where npc.spobDefenderOf == spobID && npc.isAlive {
                npc.armor = 0; totalDefeated += 1
            }
            world.step(1.0 / 30.0)
            if world.liveDefenders(of: spobID) == 0 {
                if case .dominated = world.demandTribute(spobID: spobID) { dominated = true; break }
            }
        }
        XCTAssertTrue(dominated, "clearing all defenders and demanding again dominates the planet")
        XCTAssertEqual(totalDefeated, 8, "exactly the DefCount pool of 8 defenders were launched")
        XCTAssertTrue(world.dominatedStellars.contains(spobID))
        XCTAssertNil(world.demandTribute(spobID: spobID).launchedCountForTest,
                     "a dominated planet no longer fights")
    }

    func testTrickleReplacesIndividualLossesOneForOne() {
        let (world, _, spobID) = makeWorld(defenseCount: 1082)   // total 8, up to 2 at a time
        world.playerCombatRating = 12_800
        XCTAssertEqual(world.demandTribute(spobID: spobID), .defending(launched: 2))
        XCTAssertEqual(world.liveDefenders(of: spobID), 2)

        // Destroy exactly ONE defender, not the whole field. The old wave logic
        // only refilled once the field was fully cleared; the trickle sends a
        // single replacement the very next tick, holding the concurrent count.
        world.npcs.first { $0.spobDefenderOf == spobID && $0.isAlive }!.armor = 0
        XCTAssertEqual(world.liveDefenders(of: spobID), 1, "one down, one still up")
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.liveDefenders(of: spobID), 2,
                       "the single loss draws exactly one replacement, back up to the wave size")
    }

    /// AI-15: the original counts every defender slot still active, so a
    /// disabled hulk keeps its place in the wave and draws no replacement.
    func testDisabledDefenderStillHoldsItsSlot() {
        let (world, _, spobID) = makeWorld(defenseCount: 1082)   // total 8, up to 2 at a time
        world.playerCombatRating = 12_800
        XCTAssertEqual(world.demandTribute(spobID: spobID), .defending(launched: 2))

        let victim = world.npcs.first { $0.spobDefenderOf == spobID && $0.isAlive }!
        victim.disabled = true
        XCTAssertEqual(world.liveDefenders(of: spobID), 2, "the disabled hulk still counts")
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.npcs.filter { $0.spobDefenderOf == spobID }.count, 2, "no replacement for a hulk")
    }

    /// AI-15: with the pool spent, a field of disabled hulks still blocks the
    /// surrender; destroying them yields the stellar.
    func testDisabledHulksBlockSurrenderUntilDestroyed() {
        let (world, _, spobID) = makeWorld(defenseCount: 8)   // total 8, all 8 at once (≤1000)
        world.playerCombatRating = 12_800
        XCTAssertEqual(world.demandTribute(spobID: spobID), .defending(launched: 8),
                       "a small fleet scrambles its whole count at once")

        for npc in world.npcs where npc.spobDefenderOf == spobID { npc.disabled = true }
        world.step(1.0 / 30.0)
        XCTAssertEqual(world.liveDefenders(of: spobID), 8)
        if case .dominated = world.demandTribute(spobID: spobID) {
            return XCTFail("disabled hulks still defend the stellar")
        }

        for npc in world.npcs where npc.spobDefenderOf == spobID { npc.armor = 0 }
        world.step(1.0 / 30.0)
        guard case .dominated = world.demandTribute(spobID: spobID) else {
            return XCTFail("with the pool spent and the hulks destroyed the stellar should surrender")
        }
        XCTAssertTrue(world.dominatedStellars.contains(spobID))
    }
}

private extension TributeOutcome {
    /// Test helper: the launched count if this outcome is `.defending`, else nil.
    var launchedCountForTest: Int? { if case .defending(let n) = self { return n }; return nil }
}
