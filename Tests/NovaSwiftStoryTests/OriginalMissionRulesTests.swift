import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Pins the original's mission, rank, crön and exploration rules (FIDELITY_PLAN
/// Batch 5) on synthetic data.
final class OriginalMissionRulesTests: XCTestCase {

    private func engine(_ resources: [Resource],
                        player: PlayerState = PlayerState(shipType: 128, currentSystem: 128))
        -> (StoryEngine, LoggingGameServices) {
        let hasShip = resources.contains { $0.type == NovaType.ship && $0.id == 128 }
        let game = makeGame(resources + (hasShip ? [] : [shipResource(id: 128, cargo: 100)]))
        let svc = LoggingGameServices()
        return (StoryEngine(game: game, player: player, services: svc, seed: 7), svc)
    }

    private func ship(id: Int, inherentAI: Int = 0, inherentGovt: Int = -1) -> Resource {
        var b = [UInt8](repeating: 0, count: 128)
        Bytes.i16(&b, 0, 100)
        Bytes.i16(&b, 66, inherentAI)
        Bytes.i16(&b, 72, inherentGovt)
        return Resource(type: NovaType.ship, id: id, name: "Ship \(id)", data: Data(b))
    }

    // MARK: MS-03 ranks

    func testDeactivateClearsAPermanentRank() {
        // mïsn 194 runs `L131 K132` on the permanent Vell-os ranks.
        let (eng, _) = engine([rankResource(id: 131, flags: 0x0008), rankResource(id: 132, flags: 0x0008)])
        eng.apply(set: "K131")
        eng.apply(set: "L131 K132")
        XCTAssertEqual(eng.player.activeRanks, [132])
        XCTAssertEqual(eng.player.recentRank, 132)
    }

    func testRankCascadesSparePermanentSiblings() {
        let (eng, _) = engine([
            rankResource(id: 140, weight: 10), rankResource(id: 141, weight: 20, flags: 0x0008),
            rankResource(id: 142, weight: 30, flags: 0x0010),          // clears lower-weight
            rankResource(id: 143, weight: 5, flags: 0x0002),           // deactivation clears all
            rankResource(id: 150, govt: 129, weight: 1),
        ])
        eng.apply(set: "K140 K141 K150 K142")
        XCTAssertEqual(eng.player.activeRanks, [141, 142, 150], "0x0010 drops lower-weight 140, spares permanent 141")
        eng.apply(set: "K143 L143")
        XCTAssertEqual(eng.player.activeRanks, [141, 150], "0x0002 on deactivate clears same-govt non-permanent ranks")
    }

    // MARK: MS-05 the offer lane

    func testEveryEligibleBarMissionIsOfferedInTurn() {
        let (eng, _) = engine([
            MissionSpec(id: 200, availLocation: 1).resource(),
            MissionSpec(id: 201, availLocation: 1).resource(),
        ])
        eng.playerLanded(onSpob: 500)
        let first = eng.nextLaneOffer(at: .bar, spob: 500)
        XCTAssertEqual(first?.id, 200)
        eng.decline(200)
        XCTAssertEqual(eng.nextLaneOffer(at: .bar, spob: 500)?.id, 201, "the next one comes up in the same visit")
        XCTAssertTrue(eng.accept(201))
        XCTAssertNil(eng.nextLaneOffer(at: .bar, spob: 500))
        eng.playerLanded(onSpob: 500)
        XCTAssertNil(eng.nextLaneOffer(at: .bar, spob: 500), "landing at the same stellar keeps refusals")
        eng.playerLanded(onSpob: 501)
        XCTAssertEqual(eng.nextLaneOffer(at: .bar, spob: 501)?.id, 200, "a new stellar rebuilds the lane")
    }

    func testActivationFailedOfferReturnsOnlyAfterAShopVisit() {
        // Emulator result (Q-MS-03): leaving the bar via the main screen
        // doesn't re-offer; opening a shop does.
        let (eng, _) = engine([MissionSpec(id: 200, availLocation: 1, cargoType: 1, cargoQty: 500,
                                           cargoPickup: 0).resource()])
        eng.playerLanded(onSpob: 500)
        _ = eng.nextLaneOffer(at: .mainSpaceport, spob: 500)
        XCTAssertEqual(eng.nextLaneOffer(at: .bar, spob: 500)?.id, 200)
        XCTAssertFalse(eng.accept(200), "500 t can't fit")
        XCTAssertNil(eng.nextLaneOffer(at: .bar, spob: 500))
        XCTAssertNil(eng.nextLaneOffer(at: .bar, spob: 500), "re-entering the bar from the main screen")
        _ = eng.nextLaneOffer(at: .tradeCenter, spob: 500)
        XCTAssertEqual(eng.nextLaneOffer(at: .bar, spob: 500)?.id, 200, "after the trade centre it's back")
    }

    // MARK: MS-06 auto-abort

    func testAutoAbortMissionResolvesOnTheFlightPass() {
        let m = MissionSpec(id: 300, pay: 50000, compRewardGovt: 128, compLegalReward: 10,
                            flags1: 0x0001 | 0x0008, flags2: 0x0002, datePostIncrement: 3,
                            onSuccess: "b10", onAbort: "b11").resource()
        var p = PlayerState(shipType: 128, currentSystem: 128)
        p.fuel = 300
        let (eng, _) = engine([m, govtResource(id: 128, classes: [1]), systemResource(id: 128, govt: 128)],
                              player: p)
        XCTAssertTrue(eng.accept(300))
        XCTAssertTrue(eng.player.isMissionActive(300), "resolves on the next pass, not at accept in flight")
        let day = eng.player.date
        eng.missionFlightPass()
        XCTAssertFalse(eng.player.isMissionActive(300))
        XCTAssertTrue(eng.player.isBitSet(11), "OnAbort runs")
        XCTAssertFalse(eng.player.isBitSet(10), "OnSuccess doesn't")
        XCTAssertEqual(eng.player.credits, 50000, "Flags2 0x0002 pays PayVal")
        XCTAssertEqual(eng.player.fuel, 200, "Flags 0x0008 drains a jump of fuel")
        XCTAssertEqual(day.days(until: eng.player.date), 3, "DatePostInc days pass")
        XCTAssertEqual(eng.player.reputation(atSystem: 128), 0, "the original applies no CompGovt reward here")
    }

    func testAutoAbortAcceptedWhileDockedResolvesAtOnce() {
        let (eng, _) = engine([MissionSpec(id: 301, flags1: 0x0001, onAbort: "b12").resource()])
        eng.playerLanded(onSpob: 500)
        XCTAssertTrue(eng.accept(301))
        XCTAssertFalse(eng.player.isMissionActive(301))
        XCTAssertTrue(eng.player.isBitSet(12))
    }

    // MARK: MS-08 travel leg

    func testCompletionNeedsTheTravelLeg() {
        let (eng, _) = engine([MissionSpec(id: 310, travelStellar: 600, returnStellar: 601, pay: 100).resource()])
        XCTAssertTrue(eng.accept(310))
        eng.playerLanded(onSpob: 601)
        XCTAssertTrue(eng.player.isMissionActive(310), "go to X first")
        eng.playerLanded(onSpob: 600)
        XCTAssertTrue(eng.player.isMissionActive(310))
        eng.playerLanded(onSpob: 601)
        XCTAssertFalse(eng.player.isMissionActive(310))
        XCTAssertEqual(eng.player.credits, 100)
    }

    func testReturnMinusOneMeansTheTravelStellar() {
        let (eng, _) = engine([MissionSpec(id: 311, travelStellar: 600, returnStellar: -1, pay: 100).resource()])
        XCTAssertTrue(eng.accept(311))
        XCTAssertEqual(eng.player.activeMission(311)?.returnSpobID, 600)
        eng.playerLanded(onSpob: 600)
        XCTAssertFalse(eng.player.isMissionActive(311))
        XCTAssertEqual(eng.player.credits, 100)
    }

    // MARK: MS-09 fee

    func testAcceptanceFeeRunsAfterOnAcceptAndClampsAtZero() {
        let (eng, _) = engine([MissionSpec(id: 320, pay: -51000, onAccept: "b1").resource()])
        eng.player.credits = 1500
        XCTAssertTrue(eng.isEligible(eng.game.mission(320)!, at: .missionComputer, spobID: nil))
        eng.player.credits = 999
        XCTAssertFalse(eng.isEligible(eng.game.mission(320)!, at: .missionComputer, spobID: nil),
                       "hidden while the fee is unaffordable")
        XCTAssertTrue(eng.accept(320), "a script start ignores that gate")
        XCTAssertEqual(eng.player.credits, 0, "credits = max(0, credits - fee)")
    }

    // MARK: MS-10 CompGovt

    func testSuccessWalksAlliesAndEnemies() {
        let (eng, _) = engine([
            MissionSpec(id: 330, returnStellar: 500, compRewardGovt: 128, compLegalReward: 11).resource(),
            govtResource(id: 128, classes: [1], allies: [2], enemies: [3]),
            govtResource(id: 129, classes: [2]), govtResource(id: 130, classes: [3]),
            govtResource(id: 131, classes: [4]),
            systemResource(id: 300, govt: 128), systemResource(id: 301, govt: 129),
            systemResource(id: 302, govt: 130), systemResource(id: 303, govt: 131),
        ])
        XCTAssertTrue(eng.accept(330))
        eng.playerLanded(onSpob: 500)
        XCTAssertEqual(eng.player.reputation(atSystem: 300), 11)
        XCTAssertEqual(eng.player.reputation(atSystem: 301), 5, "allies +delta/2, truncated")
        XCTAssertEqual(eng.player.reputation(atSystem: 302), -5, "enemies -delta/2, truncated")
        XCTAssertEqual(eng.player.reputation(atSystem: 303), 0, "neutrals untouched")
    }

    func testOnlyAPlayerAbortCostsTheFlags0x0040Reversal() {
        let m = MissionSpec(id: 331, compRewardGovt: 128, compLegalReward: 10, flags1: 0x0040).resource()
        let (eng, _) = engine([m, MissionSpec(id: 332, onAccept: "A331").resource(),
                               govtResource(id: 128, classes: [1]), systemResource(id: 128, govt: 128)])
        XCTAssertTrue(eng.accept(331))
        XCTAssertTrue(eng.accept(332))
        XCTAssertFalse(eng.player.isMissionActive(331), "script A aborted it")
        XCTAssertEqual(eng.player.reputation(atSystem: 128), 0, "script A applies nothing")
    }

    // MARK: MS-11 ship goals

    func testDestroyingADisableTargetFails() {
        let (eng, _) = engine([MissionSpec(id: 340, returnStellar: 500, shipCount: 1, shipGoal: 1, canAbort: false,
                                           onFailure: "b20").resource()])
        XCTAssertTrue(eng.accept(340))
        eng.missionShipDisabled(missionID: 340)
        XCTAssertTrue(eng.player.activeMission(340)!.objectiveComplete ?? false)
        eng.missionShipDestroyed(missionID: 340)
        XCTAssertTrue(eng.player.activeMission(340)!.isFailed, "killing it afterwards still fails")
        XCTAssertTrue(eng.player.isBitSet(20))
    }

    func testDisabledEscortFailsTheMission() {
        let (eng, _) = engine([MissionSpec(id: 341, returnStellar: 500, shipCount: 2, shipGoal: 3, canAbort: false).resource()])
        XCTAssertTrue(eng.accept(341))
        eng.missionShipDisabled(missionID: 341)
        XCTAssertTrue(eng.player.activeMission(341)!.isFailed)
    }

    /// UI-13 (0x0041f330): jettisoning throws out the hold and the cargo of
    /// abortable missions, which fail; a non-abortable mission keeps its cargo.
    func testJettisonTakesAbortableMissionCargoWithIt() {
        let (eng, _) = engine([
            MissionSpec(id: 343, returnStellar: 500, cargoType: 2, cargoQty: 5, cargoPickup: 0).resource(),
            MissionSpec(id: 344, returnStellar: 500, cargoType: 3, cargoQty: 4, cargoPickup: 0, canAbort: false).resource()])
        XCTAssertTrue(eng.accept(343))
        XCTAssertTrue(eng.accept(344))
        eng.player.cargo[2, default: 0] += 7
        eng.player.cargo[0] = 3
        let thrown = eng.jettisonCargo(docked: false)
        XCTAssertEqual(thrown.ordinaryTotal, 10)
        XCTAssertEqual(thrown.total, 15)
        XCTAssertTrue(thrown.missionFailedShown)
        XCTAssertFalse(eng.player.isMissionActive(343))
        XCTAssertTrue(eng.player.isMissionActive(344))
        XCTAssertEqual(eng.player.cargo, [3: 4])
    }

    /// 0x00440bf0 gates the ship release on CanAbort, and the release
    /// (0x00440aa0) also clears the slot: an abortable mission that fails in
    /// flight is gone at once — OnFailure runs once, its cargo leaves the hold
    /// and its ships are released — with no landing resolution.
    func testAbortableQuickFailReleasesShipsAndDropsTheMission() {
        let (eng, svc) = engine([MissionSpec(id: 342, returnStellar: 500, cargoType: 2, cargoQty: 5, cargoPickup: 0,
                                             shipCount: 2, shipGoal: 3, onFailure: "b21").resource()])
        XCTAssertTrue(eng.accept(342))
        XCTAssertEqual(eng.player.cargo[2], 5)
        eng.missionShipDisabled(missionID: 342)
        XCTAssertFalse(eng.player.isMissionActive(342))
        XCTAssertNil(eng.player.cargo[2])
        XCTAssertTrue(eng.player.isBitSet(21))
        XCTAssertTrue(svc.log.contains("release ships of mission #342"))
    }

    func testChaseOffCountsShipsThatLeave() {
        let (eng, _) = engine([MissionSpec(id: 342, returnStellar: 500, shipCount: 2, shipGoal: 6,
                                           onShipDone: "b21").resource()])
        XCTAssertTrue(eng.accept(342))
        eng.missionShipLeft(missionID: 342)
        XCTAssertFalse(eng.player.isBitSet(21))
        eng.missionShipDestroyed(missionID: 342)
        XCTAssertTrue(eng.player.isBitSet(21), "jumped out + destroyed >= target")
    }

    // MARK: MS-12 pickups recheck the hold

    func testTravelPickupWaitsForRoom() {
        let (eng, _) = engine([MissionSpec(id: 350, travelStellar: 600, returnStellar: 601,
                                           cargoType: 2, cargoQty: 30, cargoPickup: 1, cargoDropoff: 1).resource()])
        XCTAssertTrue(eng.accept(350))
        eng.player.cargo[0] = 90
        eng.playerLanded(onSpob: 600)
        XCTAssertFalse(eng.player.activeMission(350)!.cargoPickedUp, "no room: no pickup")
        XCTAssertFalse(eng.player.activeMission(350)!.visitedTravelStellar, "and no travel leg")
        eng.player.cargo[0] = nil
        eng.playerLanded(onSpob: 600)
        XCTAssertEqual(eng.player.cargo[2], 30)
    }

    // MARK: MS-14 crön

    func testCronMonthDayWindowAppliesEveryYear() {
        let c = CronSpec(id: 400, firstDay: 1, firstMonth: 9, firstYear: -1,
                         lastDay: 30, lastMonth: 12, lastYear: -1, random: 100, duration: 1,
                         onStart: "b30").resource()
        let (eng, _) = engine([c], player: PlayerState(date: GameDate(day: 30, month: 6, year: 1180)))
        eng.advanceDays(1)
        XCTAssertFalse(eng.player.isBitSet(30), "July is outside 1 Sep – 30 Dec")
        eng.player.date = GameDate(day: 31, month: 8, year: 1181)
        eng.advanceDays(1)
        XCTAssertTrue(eng.player.isBitSet(30), "1 Sep of any year")
    }

    func testZeroDurationCronRunsOnEndTwice() {
        let c = CronSpec(id: 401, random: 100, duration: 0, onStart: "G500", onEnd: "G501").resource()
        let (eng, _) = engine([c])
        eng.advanceDays(1)
        XCTAssertEqual(eng.player.outfits[500], 1)
        XCTAssertEqual(eng.player.outfits[501], 1, "OnStart and OnEnd the same day")
        eng.advanceDays(1)
        XCTAssertEqual(eng.player.outfits[501], 2, "and OnEnd again the next")
        XCTAssertFalse(eng.player.cronRuntime[401]!.isActive)
    }

    func testPostHoldoffWithoutPreHoldoffNeverDeactivates() {
        // crön 184/185/192: the post-end wait reads PreHoldoff (0).
        let c = CronSpec(id: 402, random: 100, duration: 1, postHoldoff: 5, onStart: "G500", onEnd: "G501").resource()
        let (eng, _) = engine([c])
        eng.advanceDays(10)
        XCTAssertEqual(eng.player.outfits[500], 1, "it fires once per game")
        XCTAssertTrue(eng.player.cronRuntime[402]!.isActive)
        XCTAssertGreaterThan(eng.player.outfits[501] ?? 0, 2, "and reruns OnEnd every day")
    }

    // MARK: MS-15 random destinations

    func testRandomDestinationSkipsNeighbouringSystems() {
        let (eng, _) = engine([
            systemResource(id: 300, links: [301], spobs: [500]),
            systemResource(id: 301, links: [300, 302], spobs: [501]),
            systemResource(id: 302, links: [301], spobs: [502]),
            landableSpob(id: 500, govt: 128), landableSpob(id: 501, govt: 128), landableSpob(id: 502, govt: 128),
        ])
        for _ in 0..<20 {
            XCTAssertEqual(eng.selectStellar(locator: 10000, reference: 500, excluded: nil), 502,
                           "not the offering system, not one jump away")
        }
    }

    func testHostileLocatorPicksEnemies() {
        let (eng, _) = engine([
            govtResource(id: 128, classes: [1], enemies: [3]), govtResource(id: 130, classes: [3]),
            govtResource(id: 129, classes: [2]),
            systemResource(id: 300, spobs: [500]), systemResource(id: 301, spobs: [501]),
            landableSpob(id: 500, govt: 129), landableSpob(id: 501, govt: 130),
        ])
        XCTAssertEqual(eng.selectStellar(locator: 25000, reference: nil, excluded: nil), 501)
    }

    // MARK: MS-16 wildcards

    func testCargoQuantityWildcardMatchesTheRolledTonnage() {
        let (eng, _) = engine([
            MissionSpec(id: 360, cargoType: 1, cargoQty: -10, cargoPickup: 0, pay: 12345).resource(),
            stringListResource(4001, ["Food", "Industrial"]),
        ])
        let m = eng.game.mission(360)!
        let offered = eng.resolveMissionText("<CQ> tons of <CT> for <PAY> credits", for: m)
        XCTAssertTrue(eng.accept(360))
        XCTAssertEqual(offered, "\(eng.player.cargo[1]!) tons of Industrial for 12,345 credits")
        XCTAssertTrue((5...14).contains(eng.player.cargo[1]!), "MS-19: -10 rolls 5…14")
    }

    func testUnresolvableTagsReadError() {
        let (eng, _) = engine([MissionSpec(id: 361).resource()])
        let text = eng.resolveMissionText("<DST> <SN> <OSN>", for: eng.game.mission(361)!)
        XCTAssertEqual(text, "[Error] [Error] [Error]")
    }

    // MARK: MS-17 / MS-24 gates

    func testNegativeAvailRecordWantsACriminal() {
        let (eng, _) = engine([MissionSpec(id: 370, availRecord: -1).resource(),
                               systemResource(id: 128, govt: 128)])
        XCTAssertFalse(eng.isEligible(eng.game.mission(370)!, at: .missionComputer, spobID: nil))
        eng.player.systemReputation = [128: -5]
        XCTAssertTrue(eng.isEligible(eng.game.mission(370)!, at: .missionComputer, spobID: nil))
    }

    func testSixteenMissionSlots() {
        let (eng, _) = engine([MissionSpec(id: 371).resource()])
        for _ in 0..<16 { eng.startMission(371) }
        XCTAssertEqual(eng.player.activeMissions.count, 16, "S opens a second slot of an active mission")
        eng.startMission(371)
        XCTAssertEqual(eng.player.activeMissions.count, 16, "the 17th fails silently")
    }

    func testShipTypeBands() {
        let (eng, _) = engine([ship(id: 128, inherentAI: 4, inherentGovt: 130)])
        XCTAssertTrue(eng.shipTypeMatches(128))
        XCTAssertFalse(eng.shipTypeMatches(896))
        XCTAssertFalse(eng.shipTypeMatches(1128))
        XCTAssertTrue(eng.shipTypeMatches(1896))
        XCTAssertTrue(eng.shipTypeMatches(2130), "inherent govt 130")
        XCTAssertFalse(eng.shipTypeMatches(2131))
        XCTAssertFalse(eng.shipTypeMatches(3130))
        XCTAssertTrue(eng.shipTypeMatches(3131))
        XCTAssertTrue(eng.shipTypeMatches(4000), "anything else passes")
    }

    func testFlags0x2000And0x4000TestTheHullsAI() {
        let (eng, _) = engine([ship(id: 128, inherentAI: 4),
                               MissionSpec(id: 372, flags1: 0x2000).resource(),
                               MissionSpec(id: 373, flags1: 0x4000).resource()])
        XCTAssertTrue(eng.isEligible(eng.game.mission(372)!, at: .missionComputer, spobID: nil))
        XCTAssertFalse(eng.isEligible(eng.game.mission(373)!, at: .missionComputer, spobID: nil))
    }

    // MARK: MS-18 script ops

    func testFOnlyLatchesTheFailure() {
        let (eng, _) = engine([MissionSpec(id: 380, returnStellar: 500, onFailure: "b40").resource()])
        XCTAssertTrue(eng.accept(380))
        eng.apply(set: "F380")
        XCTAssertTrue(eng.player.activeMission(380)!.isFailed)
        XCTAssertFalse(eng.player.isBitSet(40), "OnFailure waits for the return landing")
        eng.playerLanded(onSpob: 500)
        XCTAssertTrue(eng.player.isBitSet(40))
        XCTAssertFalse(eng.player.isMissionActive(380))
    }

    func testTRenamesWithTheOldName() {
        let (eng, _) = engine([stringListResource(500, ["*, the Second"])])
        eng.player.shipName = "Rose"
        eng.apply(set: "T500")
        XCTAssertEqual(eng.player.shipName, "Rose, the Second")
    }

    func testQShowsInFlightAndWaitsForLaunchWhenLanded() {
        let (eng, svc) = engine([stringListResource(500, ["Get out!"])])
        eng.apply(set: "Q500")
        XCTAssertTrue(svc.log.contains("overlay: Get out!"))
        eng.playerLanded(onSpob: 600)
        eng.apply(set: "Q500")
        XCTAssertTrue(svc.log.contains("close spaceport screen"))
        XCTAssertEqual(eng.playerLaunched(), "Get out!")
    }

    // MARK: MS-20 news

    func testLocalNewsBeatsIndependent() {
        let (eng, _) = engine([
            CronSpec(id: 410, random: 100, duration: 5, independentNews: 600).resource(),
            CronSpec(id: 411, random: 100, duration: 5, newsGovts: [128], govtNewsStrs: [601]).resource(),
            stringListResource(600, ["independent"]), stringListResource(601, ["local"]),
        ])
        eng.advanceDays(1)
        XCTAssertEqual(eng.stationNews(forGovt: 128), ["local"])
        XCTAssertEqual(eng.stationNews(forGovt: 129), ["independent"], "411 has no allied slot here")
    }

    // MARK: MS-23 salary

    func testSalaryClampsCreditsAtZero() {
        let (eng, _) = engine([rankResource(id: 140, salary: -100)])
        eng.apply(set: "K140")
        eng.player.credits = 50
        eng.advanceDays(1)
        XCTAssertEqual(eng.player.credits, 0)
    }

    // MARK: UI-04 / OS-14 exploration

    func testMapRevealIsAFirstComeDepthFirstFlood() {
        // 300 links 301 then 302; 301 links 302; 302 links 303. A 2-jump map
        // reaches 302 first through 301 (depth 2), so 303 — two jumps away
        // through 302 directly — is never reached.
        var col = ResourceCollection()
        col.add(systemResource(id: 300, links: [301, 302]))
        col.add(systemResource(id: 301, links: [302]))
        col.add(systemResource(id: 302, links: [303]))
        col.add(systemResource(id: 303))
        let game = NovaGame(col)
        XCTAssertEqual(game.mapRevealOrder(modVal: 2, from: 300), [300, 301, 302])
    }

    func testNebulaOnExploreRunsOnceOnArrival() {
        var b = [UInt8](repeating: 0, count: 534)
        Bytes.i16(&b, 0, 0); Bytes.i16(&b, 2, 0); Bytes.i16(&b, 4, 100); Bytes.i16(&b, 6, 100)
        Bytes.cstr(&b, 263, "b500")
        let neb = Resource(type: NovaType.nebula, id: 128, name: "Fog", data: Data(b))
        let (eng, _) = engine([neb, systemResource(id: 300, x: 50, y: 50), systemResource(id: 301, x: 500, y: 50)])
        eng.playerJumped(toSystem: 301)
        XCTAssertFalse(eng.player.isBitSet(500))
        eng.playerJumped(toSystem: 300)
        XCTAssertTrue(eng.player.isBitSet(500))
        eng.player.clearBit(500)
        eng.playerJumped(toSystem: 300)
        XCTAssertFalse(eng.player.isBitSet(500), "once per game")
    }

    // MARK: Saves

    func testOlderSaveDecodesWithTheNewRuntime() throws {
        var p = PlayerState(shipType: 128, currentSystem: 128)
        p.activeMissions.append(ActiveMission(missionID: 5, acceptedDate: p.date, deadline: nil,
                                              cargoPickedUp: false, shipObjectivesRemaining: 0))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        for key in ["storyRandomState", "missionOffers", "landedSystems", "exploredNebulae"] {
            json[key] = nil
        }
        let back = try JSONDecoder().decode(PlayerState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.missionOffers)
        XCTAssertFalse(back.activeMissions[0].isFailed)
    }
}
