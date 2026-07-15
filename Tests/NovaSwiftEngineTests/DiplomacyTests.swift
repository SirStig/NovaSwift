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

    func testPlayerHostilityFlags() {
        let always = govt(128, classes: [1], flags1: 0x0004)  // always attacks player
        let never  = govt(129, classes: [2], flags1: 0x0040)  // never attacks player
        let nosy   = govt(130, classes: [3], flags1: 0x0002)  // nosy: attacks criminals
        let dip = Diplomacy(govts: [always, never, nosy])
        XCTAssertTrue(dip.isHostileToPlayer(128))
        XCTAssertFalse(dip.isHostileToPlayer(129))
        XCTAssertFalse(dip.isHostileToPlayer(130))       // clean record → left alone
        dip.recordCrime(against: 130, penalty: 5)         // now a criminal there
        XCTAssertTrue(dip.isCriminal(with: 130))
        XCTAssertTrue(dip.isHostileToPlayer(130))
    }

    func testRecordDisableAppliesDisabPenaltyNotShootPenalty() {
        let a = govt(128, classes: [1], shootPenalty: 999, disablePenalty: 7)
        let dip = Diplomacy(govts: [a])
        dip.recordDisable(of: 128)
        XCTAssertEqual(dip.playerRecord[128], -7)   // DisabPenalty, never the (dead) ShootPenalty
    }

    func testRecordKillAppliesKillPenaltyAndCreditsCombatRating() {
        let a = govt(128, classes: [1], killPenalty: 12)
        let dip = Diplomacy(govts: [a])
        dip.recordKill(of: 128, shipStrength: 40)
        XCTAssertEqual(dip.playerRecord[128], -12)
        XCTAssertEqual(dip.combatRating, 40)
    }

    func testConsumeCombatRatingDeltaResetsAndIsSafeAcrossMultipleCalls() {
        let a = govt(128, classes: [1], killPenalty: 1)
        let dip = Diplomacy(govts: [a])
        dip.recordKill(of: 128, shipStrength: 25)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 25)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 0)   // drained — no double count
        dip.recordKill(of: 128, shipStrength: 10)
        XCTAssertEqual(dip.consumeCombatRatingDelta(), 10)
    }

    func testRecordCrimePropagatesToAlliesAndEnemiesOfVictim() {
        // Victim (128) declares 129 an ally and 130 an enemy.
        let victim = govt(128, classes: [1], allies: [9], enemies: [2])
        let ally = govt(129, classes: [9])
        let enemy = govt(130, classes: [2])
        let bystander = govt(131, classes: [3])
        let dip = Diplomacy(govts: [victim, ally, enemy, bystander])
        dip.recordCrime(against: 128, penalty: 10)
        XCTAssertEqual(dip.playerRecord[128], -10)  // the victim itself
        XCTAssertEqual(dip.playerRecord[129], -5)   // ally: standing worsens too
        XCTAssertEqual(dip.playerRecord[130], 5)    // enemy: standing improves
        XCTAssertNil(dip.playerRecord[131])         // unrelated govt untouched
    }

    func testSeedLegalRecordBulkLoadsPersistedStanding() {
        let a = govt(128, classes: [1])
        let dip = Diplomacy(govts: [a])
        dip.seed(legalRecord: [128: -42])
        XCTAssertEqual(dip.playerRecord[128], -42)
        XCTAssertTrue(dip.isCriminal(with: 128))   // crimeTolerance 0 → any evilness counts
    }

    // MARK: Legal Status spatial decay (EVN wiki: hostile actions against
    // ships felt locally — full strength at the system it happened in,
    // tapering to 0 by a 3-system radius if favorable / 5-system if not)

    private func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
    }

    func testSystemsWithinHopsBFSDistanceAlongAChain() {
        var col = ResourceCollection()
        let ids = Array(500...505)
        for (i, id) in ids.enumerated() {
            var links: [Int] = []
            if i > 0 { links.append(ids[i - 1]) }
            if i < ids.count - 1 { links.append(ids[i + 1]) }
            var b = [UInt8](repeating: 0, count: 428)
            for (j, link) in links.enumerated() { put16(&b, 4 + j * 2, link) }
            col.add(Resource(type: NovaType.syst, id: id, name: "S\(id)", data: Data(b)))
        }
        let game = NovaGame(col)
        let dist = game.systemsWithinHops(of: 500, maxHops: 5)
        XCTAssertEqual(dist[500], 0)
        XCTAssertEqual(dist[501], 1)
        XCTAssertEqual(dist[502], 2)
        XCTAssertEqual(dist[505], 5)
        XCTAssertNil(dist[506])   // doesn't exist / out of range
    }

    func testRecordKillSpreadsTaperedUnfavorablePenaltyOverFiveSystemRadius() {
        var col = ResourceCollection()
        let ids = Array(500...505)
        for (i, id) in ids.enumerated() {
            var links: [Int] = []
            if i > 0 { links.append(ids[i - 1]) }
            if i < ids.count - 1 { links.append(ids[i + 1]) }
            var b = [UInt8](repeating: 0, count: 428)
            for (j, link) in links.enumerated() { put16(&b, 4 + j * 2, link) }
            col.add(Resource(type: NovaType.syst, id: id, name: "S\(id)", data: Data(b)))
        }
        let game = NovaGame(col)
        let a = govt(128, classes: [1], killPenalty: 10)
        let dip = Diplomacy(govts: [a], currentSystemID: 500, game: game)
        dip.recordKill(of: 128, shipStrength: 0)
        // Full penalty at the origin system, same magnitude as before spatial
        // decay existed.
        XCTAssertEqual(dip.playerRecord[128], -10)
        // Tapers linearly to (and through) 0 by hop 5 (5-system radius for an
        // unfavorable swing): -8, -6, -4, -2, then 0 (omitted, not a real key).
        XCTAssertEqual(dip.localSpread[128], [501: -8, 502: -6, 503: -4, 504: -2])
    }

    func testRecordCrimeEnemyBenefitSpreadsOverThreeSystemRadius() {
        var col = ResourceCollection()
        let ids = Array(500...503)
        for (i, id) in ids.enumerated() {
            var links: [Int] = []
            if i > 0 { links.append(ids[i - 1]) }
            if i < ids.count - 1 { links.append(ids[i + 1]) }
            var b = [UInt8](repeating: 0, count: 428)
            for (j, link) in links.enumerated() { put16(&b, 4 + j * 2, link) }
            col.add(Resource(type: NovaType.syst, id: id, name: "S\(id)", data: Data(b)))
        }
        let game = NovaGame(col)
        // 128 is hostile to class 2; 130 is a member of class 2 → 130 benefits
        // (a favorable swing, 3-system radius) when the player hits 128.
        let victim = govt(128, classes: [1], enemies: [2], killPenalty: 10)
        let enemy = govt(130, classes: [2])
        let dip = Diplomacy(govts: [victim, enemy], currentSystemID: 500, game: game)
        dip.recordKill(of: 128, shipStrength: 0)
        XCTAssertEqual(dip.playerRecord[130], 5)   // full half-penalty benefit at origin
        // Tapers to 0 by hop 3: 5*2/3=3, 5*1/3=1, then 0 (omitted).
        XCTAssertEqual(dip.localSpread[130], [501: 3, 502: 1])
    }

    func testRecordCrimeWithNoGameSkipsSpreadButKeepsCurrentSystemPenalty() {
        // No backing `NovaGame` (e.g. a bare unit test) — `systemsWithinHops`
        // can't run, so only the current system is affected, same as `apply`.
        let a = govt(128, classes: [1], killPenalty: 10)
        let dip = Diplomacy(govts: [a], currentSystemID: 500)
        dip.recordKill(of: 128, shipStrength: 0)
        XCTAssertEqual(dip.playerRecord[128], -10)
        XCTAssertTrue(dip.localSpread.isEmpty)
    }

    func testConsumeLocalRecordDeltaDrainsAndIsSafeAcrossMultipleCalls() {
        let a = govt(128, classes: [1], killPenalty: 10)
        let dip = Diplomacy(govts: [a], currentSystemID: 500)
        dip.seed(legalRecord: [128: -3])
        dip.recordKill(of: 128, shipStrength: 0)
        XCTAssertEqual(dip.playerRecord[128], -13)
        XCTAssertEqual(dip.consumeLocalRecordDelta()[128], -10)   // delta since seed, not the absolute value
        XCTAssertNil(dip.consumeLocalRecordDelta()[128])          // drained — no double count
        dip.recordDisable(of: 128)   // disablePenalty defaults to 0 in this helper
        XCTAssertEqual(dip.consumeLocalRecordDelta()[128] ?? 0, 0)
    }
}
