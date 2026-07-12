import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

final class GameDateTests: XCTestCase {
    func testRoundTripJulian() {
        let d = GameDate(day: 15, month: 6, year: 1177)
        XCTAssertEqual(GameDate(julianDay: d.julianDay), d)
    }
    func testAddingDaysCrossesMonths() {
        let d = GameDate(day: 28, month: 2, year: 1177).adding(days: 5)
        XCTAssertEqual(d, GameDate(day: 5, month: 3, year: 1177))
    }
    func testDaysUntilAndOrdering() {
        let a = GameDate(day: 1, month: 1, year: 1177)
        let b = a.adding(days: 100)
        XCTAssertEqual(a.days(until: b), 100)
        XCTAssertTrue(a < b)
    }
}

final class StoryEngineTests: XCTestCase {

    private func engine(_ resources: [Resource],
                        player: PlayerState = PlayerState(shipType: 128, currentSystem: 128))
        -> (StoryEngine, LoggingGameServices) {
        let game = makeGame(resources + [shipResource(id: 128, cargo: 100)])
        let svc = LoggingGameServices()
        let eng = StoryEngine(game: game, player: player, services: svc, seed: 1)
        return (eng, svc)
    }

    // MARK: SET-op execution

    func testApplySetMutatesPlayer() {
        let (eng, svc) = engine([])
        eng.apply(set: "b100 b200 G152 K128 X300")
        XCTAssertTrue(eng.player.isBitSet(100))
        XCTAssertTrue(eng.player.isBitSet(200))
        XCTAssertEqual(eng.player.outfits[152], 1)
        XCTAssertTrue(eng.player.activeRanks.contains(128))
        XCTAssertTrue(eng.player.exploredSystems.contains(300))
        XCTAssertTrue(svc.log.contains { $0.contains("outfit") })
    }

    // MARK: Daily escort fees

    /// A hired escort's daily fee is deducted once per day; a captured escort is
    /// free. Both stay in the wing while the fee is covered.
    func testHiredEscortDailyFeeDeductedCapturedIsFree() {
        var player = PlayerState(shipType: 128, currentSystem: 128)
        player.credits = 1000
        player.registerEscort(shipType: 128, name: "Merc", origin: .hired, hireFee: 500, dailyFee: 50)
        player.registerEscort(shipType: 128, name: "Prize", origin: .captured)
        let (eng, svc) = engine([], player: player)
        eng.advanceDays(3)
        XCTAssertEqual(eng.player.credits, 1000 - 50 * 3)   // only the hired one bills
        XCTAssertEqual(eng.player.escortWing.count, 2)      // both still present
        XCTAssertTrue(svc.log.contains { $0.contains("escortDailyFeeCharged") })
    }

    /// When the balance can't cover a hired escort's fee, that escort "departs
    /// without ceremony" — cheaper escorts are paid first, the unaffordable one
    /// leaves, and a `.escortDeparted` notification fires.
    func testUnaffordableEscortDepartsWithoutCeremony() {
        var player = PlayerState(shipType: 128, currentSystem: 128)
        player.credits = 120
        let cheap = player.registerEscort(shipType: 128, name: "Cheap", origin: .hired, hireFee: 300, dailyFee: 30)
        let pricey = player.registerEscort(shipType: 128, name: "Pricey", origin: .hired, hireFee: 5000, dailyFee: 500)
        let (eng, svc) = engine([], player: player)
        eng.advanceOneDay()
        XCTAssertEqual(eng.player.credits, 90)              // 30 paid, 500 unaffordable
        XCTAssertNotNil(eng.player.escort(id: cheap.id))
        XCTAssertNil(eng.player.escort(id: pricey.id))      // departed
        XCTAssertTrue(svc.log.contains { $0.contains("escortDeparted") })
    }

    // MARK: Domination / daily tribute

    /// A spöb with tribute@10, techLevel@12, and an OnDominate NCB set expr@54.
    private func tributeSpob(id: Int, tribute: Int, techLevel: Int, onDominate: String = "") -> Resource {
        var b = [UInt8](repeating: 0, count: 600)
        func i16(_ off: Int, _ v: Int) {
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v)); b[off] = UInt8(u >> 8); b[off + 1] = UInt8(u & 0xff)
        }
        i16(10, tribute); i16(12, techLevel)
        for (i, byte) in Array(onDominate.utf8).prefix(255).enumerated() { b[54 + i] = byte }
        return Resource(type: NovaType.spob, id: id, name: "World\(id)", data: Data(b))
    }

    func testDominatingFiresOnDominateAndPaysDailyTribute() {
        let (eng, _) = engine([tributeSpob(id: 400, tribute: 500, techLevel: 5, onDominate: "b777")])
        eng.player.credits = 0
        eng.dominateStellar(400)
        XCTAssertTrue(eng.player.hasDominated(400))
        XCTAssertTrue(eng.player.isBitSet(777), "OnDominate control bits fire on conquest")

        eng.advanceDays(3)
        XCTAssertEqual(eng.player.credits, 1500, "500 cr/day × 3 days auto-added, not collected by landing")
    }

    func testDefaultTributeIsThousandTimesTechLevel() {
        let (eng, _) = engine([tributeSpob(id: 401, tribute: 0, techLevel: 6)])
        eng.player.credits = 0
        eng.dominateStellar(401)
        eng.advanceOneDay()
        XCTAssertEqual(eng.player.credits, 6000, "-1/0 tribute defaults to 1000 × techLevel")
    }

    func testReleasingStellarStopsTributeAndFiresOnRelease() {
        let (eng, _) = engine([tributeSpob(id: 402, tribute: 1000, techLevel: 5)])
        eng.dominateStellar(402)
        eng.player.credits = 0
        eng.releaseStellar(402)
        XCTAssertFalse(eng.player.hasDominated(402))
        eng.advanceDays(5)
        XCTAssertEqual(eng.player.credits, 0, "a released stellar pays no tribute")
    }

    // MARK: Availability

    func testEligibilityRespectsBitsAndState() {
        let m = MissionSpec(id: 200, availBits: "!b50").resource()
        let (eng, _) = engine([m])
        XCTAssertTrue(eng.isEligible(eng.game.mission(200)!, at: .missionComputer, spobID: nil))
        eng.apply(set: "b50")
        XCTAssertFalse(eng.isEligible(eng.game.mission(200)!, at: .missionComputer, spobID: nil))
    }

    func testCompletedMissionNotOfferedAgain() {
        let m = MissionSpec(id: 201, availRandom: 100).resource()
        let (eng, _) = engine([m])
        eng.player.completedMissions.insert(201)
        XCTAssertEqual(eng.missionsOffered(at: .missionComputer, spob: nil).count, 0)
    }

    // MARK: Cargo delivery lifecycle

    func testCargoDeliveryCompletion() {
        // Deliver cargo picked up at start, dropped off at return stellar 500.
        let m = MissionSpec(id: 300, returnStellar: 500,
                            cargoType: 1, cargoQty: 5, cargoPickup: 0, cargoDropoff: 1,
                            pay: 15000, onSuccess: "b350").resource()
        let (eng, svc) = engine([m, spobResource(id: 500, govt: 128)])

        XCTAssertTrue(eng.accept(300))
        XCTAssertTrue(eng.player.isMissionActive(300))
        XCTAssertEqual(eng.player.cargo[1], 5)               // cargo loaded at start

        // Landing anywhere else doesn't complete it.
        eng.playerLanded(onSpob: 128)
        XCTAssertTrue(eng.player.isMissionActive(300))

        // Landing at the return stellar completes it: pay + bit + cargo cleared.
        eng.playerLanded(onSpob: 500)
        XCTAssertFalse(eng.player.isMissionActive(300))
        XCTAssertTrue(eng.player.completedMissions.contains(300))
        XCTAssertEqual(eng.player.credits, 15000)
        XCTAssertTrue(eng.player.isBitSet(350))
        XCTAssertNil(eng.player.cargo[1])                    // cargo delivered
        XCTAssertTrue(svc.log.contains { $0.contains("notify missionCompleted") })
    }

    // MARK: Combat-objective lifecycle

    func testDestroyObjectiveCompletesWithoutReturn() {
        // Destroy 2 ships, no return leg (returnStellar = -1).
        let m = MissionSpec(id: 400, returnStellar: -1, pay: 5000,
                            shipCount: 2, shipGoal: 0 /* destroy */,
                            onSuccess: "b900").resource()
        let (eng, svc) = engine([m])
        XCTAssertTrue(eng.accept(400))
        XCTAssertTrue(svc.log.contains { $0.contains("spawn ships") })

        eng.missionShipDestroyed(missionID: 400)            // 1 of 2
        XCTAssertTrue(eng.player.isMissionActive(400))
        eng.missionShipDestroyed(missionID: 400)            // 2 of 2 → complete
        XCTAssertFalse(eng.player.isMissionActive(400))
        XCTAssertTrue(eng.player.completedMissions.contains(400))
        XCTAssertTrue(eng.player.isBitSet(900))
        XCTAssertEqual(eng.player.credits, 5000)
    }

    // MARK: Refuse / abort

    func testRefuseAppliesOnRefuse() {
        let m = MissionSpec(id: 410, onRefuse: "b77").resource()
        let (eng, _) = engine([m])
        eng.decline(410)
        XCTAssertTrue(eng.player.isBitSet(77))
        XCTAssertFalse(eng.player.isMissionActive(410))
    }

    func testAbortAppliesOnAbortAndClearsCargo() {
        let m = MissionSpec(id: 420, cargoType: 3, cargoQty: 4, cargoPickup: 0,
                            onAbort: "b88").resource()
        let (eng, _) = engine([m])
        eng.accept(420)
        XCTAssertEqual(eng.player.cargo[3], 4)
        eng.abortMission(420)
        XCTAssertFalse(eng.player.isMissionActive(420))
        XCTAssertTrue(eng.player.isBitSet(88))
        XCTAssertNil(eng.player.cargo[3])
    }

    // MARK: Deadlines

    func testDeadlineFailure() {
        let m = MissionSpec(id: 430, returnStellar: 500, timeLimit: 10,
                            canAbort: false, onFailure: "b66").resource()
        let (eng, _) = engine([m, spobResource(id: 500, govt: 128)])
        eng.accept(430)
        eng.advanceDays(9)
        XCTAssertTrue(eng.player.isMissionActive(430))
        eng.advanceDays(2)                                   // now past day 10
        XCTAssertFalse(eng.player.isMissionActive(430))
        XCTAssertTrue(eng.player.failedMissions.contains(430))
        XCTAssertTrue(eng.player.isBitSet(66))
    }

    // MARK: Cron events

    func testCronStartsAndEnds() {
        // Active window covers the start date; enable when b1 set and not yet
        // finished (!b501); 5-day duration. onEnd sets b501, making it one-shot.
        let c = CronSpec(id: 128, firstYear: 1177, lastYear: 1177, random: 100,
                         duration: 5, enableOn: "b1 & !b501", onStart: "b500", onEnd: "b501")
            .resource()
        var player = PlayerState(date: GameDate(day: 1, month: 6, year: 1177))
        player.setBit(1)
        let (eng, _) = engine([c], player: player)

        eng.advanceOneDay()                                  // cron starts
        XCTAssertTrue(eng.player.isBitSet(500))
        XCTAssertFalse(eng.player.isBitSet(501))
        XCTAssertTrue(eng.player.cronRuntime[128]?.isActive ?? false)

        eng.advanceDays(6)                                   // duration elapses
        XCTAssertTrue(eng.player.isBitSet(501))
        XCTAssertFalse(eng.player.cronRuntime[128]?.isActive ?? true)
    }

    func testCronBlockedByEnableTest() {
        let c = CronSpec(id: 129, firstYear: 1177, lastYear: 1177,
                         enableOn: "b1", onStart: "b500").resource()
        let player = PlayerState(date: GameDate(day: 1, month: 6, year: 1177))
        let (eng, _) = engine([c], player: player)         // b1 never set
        eng.advanceDays(10)
        XCTAssertFalse(eng.player.isBitSet(500))
    }

    // MARK: Ranks & salary

    func testRankSalaryPaidDaily() {
        var b = [UInt8](repeating: 0, count: 152)
        Bytes.i16(&b, 2, 128)          // govt
        Bytes.i32(&b, 6, 200)          // salary 200/day
        let rank = Resource(type: NovaType.rank, id: 128, name: "Cmdr", data: Data(b))
        let (eng, _) = engine([rank])
        eng.apply(set: "K128")
        eng.advanceDays(3)
        XCTAssertEqual(eng.player.credits, 600)
    }

    // MARK: Mission destination resolution (`concreteStellar`)

    func testConcreteStellarResolvesFixedIDPassthrough() {
        let (eng, _) = engine([])
        XCTAssertEqual(eng.concreteStellar(500, salt: 0), 500, "128...2175 is a literal spob id")
    }

    func testConcreteStellarResolvesGovtScopedSelectorNotAsLiteralID() {
        // Regression: codes >= 128 that aren't literal ids (govt/class/random
        // selectors) used to be treated as a literal spob id, so a mission's
        // random destination resolved to a bogus lookup (silently rendering
        // as the "your destination" placeholder) instead of a real spob.
        // 10000+g selects "any stellar of government g" (g = code - 10000 + 128).
        let spob = spobResource(id: 500, govt: 128)
        let (eng, _) = engine([spob])
        XCTAssertEqual(eng.concreteStellar(10000, salt: 0), 500,
                       "a govt-scoped selector code must resolve via StellarMatch, not pass through as a literal id")
    }

    func testConcreteStellarReturnsNilForNoDestination() {
        let (eng, _) = engine([])
        XCTAssertNil(eng.concreteStellar(-1, salt: 0))
    }

    // MARK: Mission-accept cargo-space gating (show-but-disable vs. hide)

    func testMissionComputerKeepsCargoShortMissionVisibleButNotAcceptable() {
        // The Mission BBS (.missionComputer) should still show a mission the
        // player can't currently fit — just not let them accept it.
        let m = MissionSpec(id: 600, availLocation: 0 /* missionComputer */,
                            cargoType: 1, cargoQty: 500, cargoPickup: 0, flags2: 0x0001).resource()
        let (eng, _) = engine([m])
        XCTAssertTrue(eng.isEligible(eng.game.mission(600)!, at: .missionComputer, spobID: nil),
                      "still offered/browsable even without enough cargo space")
        XCTAssertFalse(eng.canAccept(eng.game.mission(600)!), "but not acceptable")
        XCTAssertFalse(eng.accept(600), "accept() itself refuses when there isn't enough room")
        XCTAssertFalse(eng.player.isMissionActive(600))
    }

    func testOtherLocationsHideCargoShortMissionEntirely() {
        // Bar/trade-center/shipyard/outfitter/pers-ship offers are one-at-a-time
        // ad-hoc offers, not a browsable board — those should never come up at
        // all if the cargo wouldn't fit.
        let m = MissionSpec(id: 601, availLocation: 1 /* bar */,
                            cargoType: 1, cargoQty: 500, cargoPickup: 0, flags2: 0x0001).resource()
        let (eng, _) = engine([m])
        XCTAssertFalse(eng.isEligible(eng.game.mission(601)!, at: .bar, spobID: nil),
                       "a bar offer the player can't fit should never be offered")
    }

    func testCanAcceptTrueWhenNoCargoSpaceFlagOrEnoughRoom() {
        let noFlag = MissionSpec(id: 602, cargoType: 1, cargoQty: 500, cargoPickup: 0).resource()
        let fits = MissionSpec(id: 603, cargoType: 1, cargoQty: 1, cargoPickup: 0, flags2: 0x0001).resource()
        let (eng, _) = engine([noFlag, fits])
        XCTAssertTrue(eng.canAccept(eng.game.mission(602)!), "flag not set — no cargo gate at all")
        XCTAssertTrue(eng.canAccept(eng.game.mission(603)!), "1 ton needed, plenty of room free")
    }

    // MARK: Save/restore

    func testPlayerStateCodableRoundTrip() throws {
        var p = PlayerState(pilotName: "Ari", shipType: 128, credits: 999)
        p.setBit(42); p.activeRanks.insert(7)
        p.activeMissions.append(ActiveMission(missionID: 5, acceptedDate: p.date,
                                              deadline: nil, cargoPickedUp: true,
                                              shipObjectivesRemaining: 0))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PlayerState.self, from: data)
        XCTAssertEqual(back.pilotName, "Ari")
        XCTAssertEqual(back.credits, 999)
        XCTAssertTrue(back.isBitSet(42))
        XCTAssertEqual(back.activeMissions.first?.missionID, 5)
    }
}
