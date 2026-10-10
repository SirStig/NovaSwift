import XCTest
import NovaSwiftKit
import NovaSwiftEngine
@testable import NovaSwiftStory

/// Mission and economy rules pinned to the original (MS-25…, EC-27…).
final class MissionsEconomyFidelityTests: XCTestCase {

    private func dudeResource(id: Int, ships: [(Int, Int)], ai: Int = 1, govt: Int = -1) -> Resource {
        var b = [UInt8](repeating: 0, count: 80)
        Bytes.i16(&b, 0, ai)
        Bytes.i16(&b, 2, govt)
        for i in 0..<16 {
            Bytes.i16(&b, 8 + i * 2, i < ships.count ? ships[i].0 : -1)
            Bytes.i16(&b, 40 + i * 2, i < ships.count ? ships[i].1 : 0)
        }
        return Resource(type: NovaType.dude, id: id, name: "Dude \(id)", data: Data(b))
    }

    private func cargoPod(id: Int, tons: Int) -> Resource {
        var b = [UInt8](repeating: 0, count: 1012)
        for pos in [6, 18, 22, 26] { Bytes.i16(&b, pos, -1) }
        Bytes.i16(&b, 6, 2)          // ModType 2: cargo space
        Bytes.i16(&b, 8, tons)
        return Resource(type: NovaType.outfit, id: id, name: "Pod", data: Data(b))
    }

    private func engine(_ resources: [Resource], player: PlayerState = PlayerState(shipType: 128, currentSystem: 128),
                        hold: Int = 100) -> (StoryEngine, LoggingGameServices) {
        let game = makeGame(resources + [shipResource(id: 128, cargo: hold, freeMass: 100)])
        let svc = LoggingGameServices()
        return (StoryEngine(game: game, player: player, services: svc, seed: 7), svc)
    }

    // MARK: Cargo (EC-27, EC-28)

    func testMissionCargoIsNotSellable() {
        let m = MissionSpec(id: 600, cargoType: 0, cargoQty: 10, cargoPickup: 0).resource()
        let (eng, _) = engine([m])
        XCTAssertTrue(eng.accept(600))
        eng.player.cargo[0, default: 0] += 5                 // 5 t bought
        var p = eng.player
        XCTAssertEqual(PilotEconomy.held(p, cargo: 0, game: eng.game), 5)
        let sold = PilotEconomy.sellCargo(&p, id: 0, tons: 100, unitPrice: 10, game: eng.game)
        XCTAssertEqual(sold, 5)
        XCTAssertEqual(p.cargo[0], 10, "the mission's 10 t stay aboard")
    }

    func testCargoPodsCountTowardMissionRoom() {
        let m = MissionSpec(id: 600, cargoType: 0, cargoQty: 35, cargoPickup: 0).resource()
        var player = PlayerState(shipType: 128, currentSystem: 128)
        player.outfits = [700: 2]
        let (eng, _) = engine([m, cargoPod(id: 700, tons: 10)], player: player, hold: 20)
        XCTAssertEqual(eng.cargoCapacity(), 40)
        XCTAssertTrue(eng.accept(600))
    }

    func testAcceptRefusalUsesTheAcceptTexts() {
        var misc = Array(repeating: "", count: 360)
        misc[0x163 - 1] = "no space to accept"
        misc[0x165 - 1] = "no space to load"
        let m = MissionSpec(id: 600, cargoType: 0, cargoQty: 50, cargoPickup: 0).resource()
        let (eng, svc) = engine([m, stringListResource(2002, misc)], hold: 20)
        XCTAssertFalse(eng.accept(600))
        XCTAssertTrue(svc.log.contains { $0.contains("no space to accept") })
    }

    // MARK: Offers (MS-25)

    func testCantRefuseOfferWithoutTextActivatesSilently() {
        let m = MissionSpec(id: 600, flags1: 0x0004).resource()
        let (eng, svc) = engine([m])
        XCTAssertFalse(eng.present(eng.game.mission(600)!))
        XCTAssertNil(svc.lastOffer)
        XCTAssertTrue(eng.player.isMissionActive(600))
    }

    func testOfferButtonLabelsFollowTheOriginal() {
        var labels = Array(repeating: "", count: 60)
        labels[27 - 1] = "Okay"; labels[50 - 1] = "Yes"; labels[51 - 1] = "No"
        let plain = MissionSpec(id: 600).resource()
        let custom = MissionSpec(id: 601, offerAcceptButton: "Sure", offerRefuseButton: "1 no").resource()
        let forced = MissionSpec(id: 602, flags1: 0x0004).resource()
        let (eng, _) = engine([plain, custom, forced, stringListResource(150, labels)])
        XCTAssertEqual(eng.offerButtonLabels(for: eng.game.mission(600)!).accept, "Yes")
        XCTAssertEqual(eng.offerButtonLabels(for: eng.game.mission(600)!).refuse, "No")
        XCTAssertEqual(eng.offerButtonLabels(for: eng.game.mission(601)!).accept, "Sure")
        XCTAssertEqual(eng.offerButtonLabels(for: eng.game.mission(601)!).refuse, "No", "a label not starting a–z is blanked")
        XCTAssertEqual(eng.offerButtonLabels(for: eng.game.mission(602)!).accept, "Okay")
    }

    func testMissionBBSRefusesWithAllSlotsTaken() {
        var misc = Array(repeating: "", count: 360)
        misc[0x15f - 1] = "You're already on"
        misc[0x160 - 1] = "missions."
        misc[0x161 - 1] = "None here."
        let (eng, _) = engine([MissionSpec(id: 600).resource(), stringListResource(2002, misc)])
        XCTAssertNil(eng.missionBBSRefusal(spob: nil))
        for i in 0..<16 { eng.startMission(600); _ = i }
        XCTAssertEqual(eng.missionBBSRefusal(spob: nil), "You're already on 16 missions.")
        let (empty, _) = engine([stringListResource(2002, misc)])
        XCTAssertEqual(empty.missionBBSRefusal(spob: nil), "None here.")
    }

    func testComputerListIsFixedAtLanding() {
        let a = MissionSpec(id: 600, onAccept: "b10").resource()
        let b = MissionSpec(id: 601, availBits: "b10").resource()
        let (eng, _) = engine([a, b, landableSpob(id: 500, govt: -1),
                               systemResource(id: 128, spobs: [500])])
        eng.playerLanded(onSpob: 500)
        XCTAssertEqual(eng.missionComputerList(spob: 500).map(\.id), [600])
        XCTAssertTrue(eng.accept(600))
        XCTAssertEqual(eng.missionComputerList(spob: 500).map(\.id), [], "601 waits for the next landing")
    }

    func testMissionsTakeTheFirstFreeSlot() {
        let (eng, _) = engine([MissionSpec(id: 600).resource(), MissionSpec(id: 601).resource(),
                               MissionSpec(id: 602).resource()])
        XCTAssertTrue(eng.accept(600)); XCTAssertTrue(eng.accept(601))
        eng.abortMission(600)
        XCTAssertTrue(eng.accept(602))
        XCTAssertEqual(eng.activeMissionSummaries().map(\.id), [602, 601])
    }

    // MARK: Special ships (MS-26)

    func testGoallessSpecialShipsSpawn() {
        let m = MissionSpec(id: 600, shipCount: 2, shipGoal: -1, shipDude: 130).resource()
        let (eng, svc) = engine([m, dudeResource(id: 130, ships: [(128, 10)])])
        XCTAssertTrue(eng.accept(600))
        XCTAssertTrue(svc.log.contains { $0.contains("spawn ships") })
        let am = eng.player.activeMission(600)!
        XCTAssertTrue(eng.shipSystemMatches(am, currentSystem: 128), "ShipSyst -1 is the accept system")
    }

    func testAuxShipSystemCodes() {
        let follow = MissionSpec(id: 600, auxShipCount: 2, auxShipDude: 130, auxShipSystem: -1).resource()
        let ret = MissionSpec(id: 601, returnStellar: 500, auxShipCount: 2, auxShipDude: 130, auxShipSystem: -3).resource()
        let (eng, _) = engine([follow, ret, landableSpob(id: 500, govt: -1),
                               systemResource(id: 128, links: [129]), systemResource(id: 129, links: [128], spobs: [500]),
                               dudeResource(id: 130, ships: [(128, 10)])])
        XCTAssertTrue(eng.accept(600)); XCTAssertTrue(eng.accept(601))
        let a = eng.player.activeMission(600)!, r = eng.player.activeMission(601)!
        XCTAssertTrue(eng.auxSystemMatches(a, eng.game.mission(600)!, currentSystem: 129), "-1 follows the player")
        XCTAssertTrue(eng.auxSystemMatches(r, eng.game.mission(601)!, currentSystem: 129), "-3 is the return system")
        XCTAssertFalse(eng.auxSystemMatches(r, eng.game.mission(601)!, currentSystem: 128))
    }

    func testNeighbourShipSystemIsOneSystemFixedAtAccept() {
        let m = MissionSpec(id: 600, shipCount: 1, shipGoal: 0, shipSystem: -5, shipDude: 130).resource()
        let (eng, _) = engine([m, systemResource(id: 128, links: [129, 130, 131]),
                               systemResource(id: 129, links: [128]), systemResource(id: 130, links: [128]),
                               systemResource(id: 131, links: [128]), dudeResource(id: 130, ships: [(128, 10)])])
        XCTAssertTrue(eng.accept(600))
        let am = eng.player.activeMission(600)!
        let matches = [129, 130, 131].filter { eng.shipSystemMatches(am, currentSystem: $0) }
        XCTAssertEqual(matches.count, 1)
    }

    func testFlags0800LocksOneHullAtAccept() {
        let m = MissionSpec(id: 600, shipCount: 4, shipGoal: 0, shipDude: 130, flags1: 0x0800).resource()
        let (eng, _) = engine([m, shipResource(id: 129, cargo: 0, freeMass: 0), shipResource(id: 131, cargo: 0, freeMass: 0),
                               dudeResource(id: 130, ships: [(128, 10), (129, 10), (131, 10)])])
        XCTAssertTrue(eng.accept(600))
        XCTAssertNotNil(eng.player.activeMission(600)?.lockedShipType)
    }

    func testSpecialShipNameUsesTheRolledEntry() {
        let m = MissionSpec(id: 600, shipCount: 1, shipGoal: 0, shipDude: 130, shipNameStrID: 25001).resource()
        let (eng, _) = engine([m, dudeResource(id: 130, ships: [(128, 10)]),
                               stringListResource(25001, ["A", "B", "C", "D"])])
        XCTAssertTrue(eng.accept(600))
        let am = eng.player.activeMission(600)!
        XCTAssertEqual(eng.missionShipName(am, eng.game.mission(600)!),
                       ["A", "B", "C", "D"][am.shipNameEntry! - 1])
    }

    // MARK: Map marks and the Mission Info pane (MS-27)

    func testMapMarksFollowFlags() {
        let shown = MissionSpec(id: 600, travelStellar: 500).resource()
        let hidden = MissionSpec(id: 601, travelStellar: 500, flags1: 0x0002).resource()
        let invisible = MissionSpec(id: 602, travelStellar: 501, flags1: 0x0400).resource()
        let (eng, _) = engine([shown, hidden, invisible, landableSpob(id: 500, govt: -1), landableSpob(id: 501, govt: -1),
                               systemResource(id: 128), systemResource(id: 200, spobs: [500]),
                               systemResource(id: 300, spobs: [501])])
        XCTAssertTrue(eng.accept(600)); XCTAssertTrue(eng.accept(601)); XCTAssertTrue(eng.accept(602))
        let marks = eng.missionDestinations()
        XCTAssertEqual(marks.map(\.systemID), [200, 300])
        XCTAssertEqual(marks.first?.names.count, 1, "the Flags 0x0002 mission puts no mark")
    }

    func testMissionInfoPaneIsQuickBriefOnly() {
        let m = MissionSpec(id: 600, quickBriefText: 7000).resource()
        let bare = MissionSpec(id: 601).resource()
        let (eng, _) = engine([m, bare, descResource(id: 7000, text: "Go there.")])
        XCTAssertTrue(eng.accept(600)); XCTAssertTrue(eng.accept(601))
        let s = eng.activeMissionSummaries()
        XCTAssertEqual(s.first { $0.id == 600 }?.payload, "Go there.")
        XCTAssertEqual(s.first { $0.id == 601 }?.payload, "")
    }

    // MARK: NCB and crön (MS-28)

    func testNCBTestWithLeadingWhitespaceIsFalse() {
        var p = PlayerState()
        p.setBit(1)
        XCTAssertTrue(NCBTest("b1").evaluate(p))
        XCTAssertFalse(NCBTest(" b1").evaluate(p))
        XCTAssertTrue(NCBTest("").evaluate(p))
    }

    func testCronContributesOnlyAfterItsHoldoff() {
        var rt = CronRuntime(cronID: 128)
        rt.active = true
        rt.holdoff = 3
        XCTAssertFalse(rt.contributes)
        rt.holdoff = 0
        XCTAssertTrue(rt.contributes)
    }

    // MARK: Player Info (MS-29)

    func testJettisonNeedsOrdinaryOrAbortableMissionCargo() {
        let locked = MissionSpec(id: 600, cargoType: 0, cargoQty: 5, cargoPickup: 0, canAbort: false).resource()
        let (eng, _) = engine([locked])
        XCTAssertTrue(eng.accept(600))
        let pages = PlayerInfoPages(game: eng.game, player: eng.player)
        XCTAssertTrue(pages.hasCargo)
        XCTAssertFalse(pages.canJettison, "a non-abortable mission's cargo alone can't be jettisoned")
    }

    // MARK: Pilot names (EC-30)

    func testNicknameAndShipNameFillTheirWildcards() {
        var p = PlayerState(pilotName: "Jane Doe", shipName: "Rocinante")
        p.nickname = "Ace"
        let game = makeGame([])
        XCTAssertEqual(MissionText.resolve("<PNN>/<PSN>", fields: nil, player: p, game: game), "Ace/Rocinante")
        p.nickname = nil
        XCTAssertEqual(MissionText.resolve("<PNN>", fields: nil, player: p, game: game), "Jane Doe")
    }

    // MARK: Shipyard list (EC-29)

    func testShipyardListRunsByDispWeightWithFlags3Suppression() {
        func hull(_ id: Int, weight: Int, flags3: Int = 0) -> Resource {
            var b = [UInt8](repeating: 0, count: 1860)
            Bytes.i16(&b, 46, 0)            // TechLevel 0 is eligible
            Bytes.i16(&b, 60, weight)
            Bytes.i16(&b, 1830, flags3)
            return Resource(type: NovaType.ship, id: id, name: "Ship \(id)", data: Data(b))
        }
        let game = makeGame([hull(129, weight: 90, flags3: 0x4000), hull(130, weight: 90), hull(131, weight: 50),
                             landableSpob(id: 500, govt: -1)])
        let list = game.shipyardList(at: game.spob(500)!, hire: false, stocked: { _ in true },
                                     availabilityPasses: { _ in true }, requirePasses: { _ in true })
        XCTAssertEqual(list.map(\.id), [129, 131])
    }

    // MARK: Trade strip (EC-31)

    func testTradeStripShowsOwnAndEscortFreeSpace() {
        var misc = Array(repeating: "", count: 400)
        misc[0] = "ton"; misc[1] = "tons"
        misc[0x16c - 1] = "Free"; misc[0x16d - 1] = "ship"; misc[0x16e - 1] = "escorts"
        let game = makeGame([stringListResource(2002, misc)])
        var p = PlayerState()
        p.cargo = [0: 30]
        let s = LandedServices.tradeStatus(state: p, game: game, shipCapacity: 20, fleetCapacity: 120, junkRows: [])
        XCTAssertEqual(s, "Free ship: 20 tons\rFree escorts: 90 tons")
    }

    // MARK: dësc flags

    func testDescMovieFlagsDecodeAfterTheMovieName() {
        var b = Array("Text".utf8) + [0, 0x00, 0x80]
        var movie = Array("Clip.mov".utf8); movie += Array(repeating: 0, count: 32 - movie.count)
        b += movie + [0x00, 0x01]
        let d = DescRes(Resource(type: NovaType.desc, id: 128, name: "", data: Data(b)))
        XCTAssertEqual(d.movieFilename, "Clip.mov")
        XCTAssertTrue(d.moviePlaysAfterText)
    }
}
