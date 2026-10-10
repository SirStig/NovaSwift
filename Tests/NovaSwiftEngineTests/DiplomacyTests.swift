import XCTest
@testable import NovaSwiftEngine
import NovaSwiftKit

/// Verifies EV Nova's class-based government relations resolve correctly, using
/// hand-built `gövt` bodies laid out at the real byte offsets (Flags1@2,
/// ShootPenalty@18, Classes@24, Allies@32, Enemies@40).
final class DiplomacyTests: XCTestCase {

    // MARK: crafted gövt bytes

    private func govtData(classes: [Int], allies: [Int] = [], enemies: [Int] = [],
                          flags1: UInt16 = 0, shootPenalty: Int = 1,
                          disablePenalty: Int = 0, killPenalty: Int = 0,
                          crimeTolerance: Int = 0) -> Data {
        var d = [UInt8](repeating: 0, count: 60)
        func putW(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            d[off] = UInt8(u >> 8); d[off + 1] = UInt8(u & 0xff)
        }
        for i in 0..<4 { putW(24 + i * 2, i < classes.count ? classes[i] : -1) }
        for i in 0..<4 { putW(32 + i * 2, i < allies.count ? allies[i] : -1) }
        for i in 0..<4 { putW(40 + i * 2, i < enemies.count ? enemies[i] : -1) }
        putW(2, Int(flags1))
        putW(8, crimeTolerance)
        putW(12, disablePenalty)
        putW(16, killPenalty)
        putW(18, shootPenalty)
        return Data(d)
    }

    private func govt(_ id: Int, classes: [Int], allies: [Int] = [], enemies: [Int] = [],
                      flags1: UInt16 = 0, shootPenalty: Int = 1,
                      disablePenalty: Int = 0, killPenalty: Int = 0,
                      crimeTolerance: Int = 0) -> GovtRes {
        GovtRes(Resource(type: NovaType.govt, id: id, name: "G\(id)",
                         data: govtData(classes: classes, allies: allies, enemies: enemies,
                                        flags1: flags1, shootPenalty: shootPenalty,
                                        disablePenalty: disablePenalty, killPenalty: killPenalty,
                                        crimeTolerance: crimeTolerance)))
    }

    func testDecodedRelations() {
        let g = govt(128, classes: [1, 5], allies: [7], enemies: [2, 3])
        XCTAssertEqual(g.classes, [1, 5])
        XCTAssertEqual(g.allies, [7])
        XCTAssertEqual(g.enemies, [2, 3])
    }

    func testMutualEnemiesByClassIntersection() {
        // A hates class 2; B is a member of class 2 → they're enemies.
        let a = govt(128, classes: [1], enemies: [2])
        let b = govt(129, classes: [2], enemies: [])
        let dip = Diplomacy(govts: [a, b])
        XCTAssertTrue(dip.considersHostile(128, toward: 129))
        XCTAssertFalse(dip.considersHostile(129, toward: 128))
        XCTAssertTrue(dip.areEnemies(128, 129))   // symmetric: either side suffices
        XCTAssertFalse(dip.areEnemies(128, 128))  // never at war with itself
    }

    func testAlliesAreNotEnemies() {
        let a = govt(128, classes: [1], allies: [2])
        let b = govt(129, classes: [2])
        let dip = Diplomacy(govts: [a, b])
        XCTAssertTrue(dip.areAllied(128, 129))
        XCTAssertFalse(dip.areEnemies(128, 129))
    }

    func testXenophobeAttacksNonAllies() {
        let xeno = govt(128, classes: [1], allies: [9], enemies: [], flags1: 0x0001) // xenophobic
        let stranger = govt(129, classes: [2])
        let friend = govt(130, classes: [9])
        let dip = Diplomacy(govts: [xeno, stranger, friend])
        XCTAssertTrue(dip.areEnemies(128, 129))    // attacks the stranger
        XCTAssertFalse(dip.considersHostile(128, toward: 130)) // spares an ally class
    }

    func testIndependentIsPeaceful() {
        let a = govt(128, classes: [1], enemies: [2])
        let dip = Diplomacy(govts: [a])
        // independentGovt has no record → hostile to no one, and unknown govts too.
        XCTAssertFalse(dip.areEnemies(independentGovt, 128))
        XCTAssertFalse(dip.considersHostile(128, toward: independentGovt))
    }

    /// rating at 10,000,000 is pinned there.
    func testCombatRatingPointsMatchTheOriginal() {
        let oracle: [(rating: Int, strength: Int, after: Int)] = [
            (0, 3, 1), (0, 4, 1), (0, 5, 1), (0, 6, 1), (0, 9, 1), (0, 10, 2), (0, 14, 2),
            (0, 15, 3), (0, 30, 6), (0, 100, 20), (0, 1000, 200), (99, 30, 105), (5, 12, 7),
            (9_999_990, 100, 10_000_010), (10_000_000, 30, 10_000_000), (12_000_000, 5, 10_000_000),
            (1, -3, 2), (9_000_000, 33, 9_000_006),
        ]
        for row in oracle {
            XCTAssertEqual(CombatRatingRule.fold(row.rating, adding: CombatRatingRule.points(forStrength: row.strength)),
                           row.after, "rating \(row.rating) + strength \(row.strength)")
        }
    }

    func testConsumeCombatRatingDeltaResetsAndIsSafeAcrossMultipleCalls() {
        let a = govt(128, classes: [1], killPenalty: 1)
        let dip = Diplomacy(govts: [a])
        dip.recordKill(of: 128, shipStrength: 25)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 5)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 0)   // drained — no double count
        dip.recordKill(of: 128, shipStrength: 10)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 2)
    }


    // MARK: Per-system legal record (EC-02) and the player-hostility ladder (AI-05)

    /// A one-system map owned by `owner`, the player standing in it.
    private func dip(_ govts: [GovtRes], owner: Int, rep: Int = 0) -> Diplomacy {
        let d = Diplomacy(govts: govts, currentSystemID: 500)
        d.reputationMap = ReputationMap(systems: [.init(id: 500, govt: owner, x: 0, y: 0, links: [])])
        d.seed(reputation: rep == 0 ? [:] : [500: rep])
        return d
    }

    func testRecordDisableAppliesDisabPenaltyNotShootPenalty() {
        let d = dip([govt(128, classes: [1], shootPenalty: 999, disablePenalty: 7)], owner: 128)
        d.recordDisable(of: 128)
        XCTAssertEqual(d.reputationHere, -7)   // DisabPenalty, never the (dead) ShootPenalty
    }

    func testRecordKillAppliesKillPenaltyAndCreditsCombatRating() {
        let d = dip([govt(128, classes: [1], killPenalty: 12)], owner: 128)
        d.recordKill(of: 128, shipStrength: 40)
        XCTAssertEqual(d.reputationHere, -12)
        XCTAssertEqual(d.combatRating, 8, "trunc(40 × 0.2)")
    }

    /// The original skips the flood for a mission ship (0x00466fc0's
    /// mission-slot arm) and for a derelict government (Flags 0x0800).
    func testMissionShipAndDerelictCrimesChangeNothing() {
        let d = dip([govt(128, classes: [1], killPenalty: 12),
                     govt(129, classes: [2], flags1: 0x0800, killPenalty: 12)], owner: 128)
        d.recordKill(of: 128, shipStrength: 1, missionShip: true)
        d.recordKill(of: 129, shipStrength: 1)
        XCTAssertEqual(d.reputation, [:])
    }

    func testSeedAndDrainReputationDelta() {
        let d = dip([govt(128, classes: [1], killPenalty: 10)], owner: 128, rep: -3)
        d.recordKill(of: 128, shipStrength: 0)
        XCTAssertEqual(d.reputationHere, -13)
        XCTAssertEqual(d.consumeReputationDelta(), [500: -10], "delta since seed, not the absolute value")
        XCTAssertEqual(d.consumeReputationDelta(), [:], "drained — no double count")
    }

    /// The ladder of 0x0040e020 against the current system's reputation, with
    /// CrimeTol 100 throughout.
    func testPlayerHostilityLadder() {
        let owner = govt(128, classes: [1], allies: [2], enemies: [3], crimeTolerance: 100)
        let ally = govt(129, classes: [2], crimeTolerance: 100)
        let enemy = govt(130, classes: [3], crimeTolerance: 100)
        let neutral = govt(131, classes: [4], crimeTolerance: 100)
        let nosyNeutral = govt(132, classes: [5], flags1: 0x0002, crimeTolerance: 100)
        let all = [owner, ally, enemy, neutral, nosyNeutral]
        func hostile(_ g: Int, rep: Int, owner o: Int = 128) -> Bool {
            dip(all, owner: o, rep: rep).isHostileToPlayer(g)
        }
        // Owner: rep < −CrimeTol (strict).
        XCTAssertFalse(hostile(128, rep: -100))
        XCTAssertTrue(hostile(128, rep: -101))
        // Allied with the owner: rep < −1.5·CrimeTol.
        XCTAssertFalse(hostile(129, rep: -150))
        XCTAssertTrue(hostile(129, rep: -151))
        // Hostile to the owner: rep > CrimeTol — a good record makes the
        // owner's enemies attack (known bug #132); a bad one does not.
        XCTAssertTrue(hostile(130, rep: 101))
        XCTAssertFalse(hostile(130, rep: 100))
        XCTAssertFalse(hostile(130, rep: -5000))
        // Neutral: only nosy governments, at rep < −2·CrimeTol.
        XCTAssertFalse(hostile(131, rep: -30000))
        XCTAssertFalse(hostile(132, rep: -200))
        XCTAssertTrue(hostile(132, rep: -201))
        // Independent system: nosy only, ×2.
        XCTAssertFalse(hostile(131, rep: -30000, owner: -1))
        XCTAssertTrue(hostile(132, rep: -201, owner: -1))
        XCTAssertFalse(hostile(128, rep: -30000, owner: -1), "a non-nosy owner is quiet away from home")
    }

    func testFlagsBlockOrForceHostility() {
        let never = govt(128, classes: [1], flags1: 0x0040, crimeTolerance: 1)
        let always = govt(129, classes: [2], flags1: 0x0004)
        let d = dip([never, always], owner: 128, rep: -30000)
        XCTAssertFalse(d.isHostileToPlayer(128), "Flags 0x0040 blocks the ladder")
        XCTAssertTrue(d.isHostileToPlayer(129), "Flags 0x0004 attacks on arrival whatever the record")
    }

    /// Xenophobes flag the player everywhere but home, where rep ≥ 1 keeps the peace.
    func testXenophobeOwnSystemNeedsAPositiveRecord() {
        let xeno = govt(128, classes: [1], flags1: 0x0001)
        XCTAssertTrue(dip([xeno], owner: 128, rep: 0).isHostileToPlayer(128))
        XCTAssertFalse(dip([xeno], owner: 128, rep: 1).isHostileToPlayer(128))
        XCTAssertTrue(dip([xeno], owner: -1, rep: 30000).isHostileToPlayer(128))
    }

    func testRankAndScramblerLatchClearTheFlag() {
        let owner = govt(128, classes: [1], crimeTolerance: 10)
        let d = dip([owner], owner: 128, rep: -500)
        XCTAssertTrue(d.isHostileToPlayer(128))
        d.rankProtectedGovts = [128]
        XCTAssertFalse(d.isHostileToPlayer(128))
        d.rankProtectedGovts = []
        let latches = GovernmentLatches()
        d.latches = latches
        latches.latch(scramblerClasses: [1], inhibitorClasses: [], govts: [owner])
        XCTAssertFalse(d.isHostileToPlayer(128), "a scrambler owned once keeps fooling the government")
    }

    /// OS-10: latches set by owning an outfit are never cleared; scrambler
    /// ModVal −1 matches nothing, inhibitor −1 inhibits everyone.
    func testGovernmentLatchesStick() {
        let a = govt(128, classes: [1]), b = govt(129, classes: [2])
        let latches = GovernmentLatches()
        latches.latch(scramblerClasses: [-1], inhibitorClasses: [], govts: [a, b])
        XCTAssertFalse(latches.isScrambled(128))
        latches.latch(scramblerClasses: [2], inhibitorClasses: [1], govts: [a, b])
        XCTAssertTrue(latches.isScrambled(129))
        XCTAssertTrue(latches.isInhibited(128))
        XCTAssertFalse(latches.isInhibited(129))
        latches.latch(scramblerClasses: [], inhibitorClasses: [], govts: [a, b])   // sold: nothing clears
        XCTAssertTrue(latches.isScrambled(129))
        latches.latch(scramblerClasses: [], inhibitorClasses: [-1], govts: [a, b])
        XCTAssertTrue(latches.isInhibited(129))
    }

    func testInherentGovtGrudgeAndStellarBatteries() {
        let owner = govt(128, classes: [1], enemies: [2], crimeTolerance: 100)
        let rival = govt(129, classes: [2])
        let d = dip([owner, rival], owner: 128, rep: 0)
        XCTAssertTrue(d.inherentGovtGrudge(128, playerHullGovt: 129))
        XCTAssertFalse(d.inherentGovtGrudge(128, playerHullGovt: -1))
        // 0x004629e0: a rival hull or rep < −CrimeTol sets the batteries off.
        XCTAssertTrue(d.stellarBatteriesTargetPlayer(stellarGovt: 128, playerHullGovt: 129))
        XCTAssertFalse(d.stellarBatteriesTargetPlayer(stellarGovt: 128, playerHullGovt: -1))
        XCTAssertTrue(dip([owner], owner: 128, rep: -101)
            .stellarBatteriesTargetPlayer(stellarGovt: -1, playerHullGovt: -1),
                      "an independent stellar answers for the system's owner")
    }
}
