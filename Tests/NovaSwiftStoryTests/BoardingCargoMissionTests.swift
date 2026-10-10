import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Synthetic mission bodies exercise special-ship pickup without game data.
final class BoardingCargoMissionTests: XCTestCase {
    private func engine(_ spec: MissionSpec) -> (StoryEngine, LoggingGameServices) {
        let game = makeGame([
            spec.resource(), shipResource(id: 128, cargo: 100),
            descResource(id: 5100, text: "Sample loaded"),
            descResource(id: 5200, text: "Sample delivered")
        ])
        let services = LoggingGameServices()
        let engine = StoryEngine(game: game,
                                 player: PlayerState(shipType: 128, currentSystem: 128),
                                 services: services, seed: 1)
        return (engine, services)
    }

    private func sampleMission(goal: Int = 2) -> MissionSpec {
        MissionSpec(id: 900, returnStellar: 286,
                    cargoType: 31, cargoQty: 1, cargoPickup: 2, cargoDropoff: 1,
                    pay: 40000, shipCount: 1, shipGoal: goal, canAbort: false,
                    loadCargoText: 5100, dropCargoText: 5200,
                    onSuccess: "b700", onShipDone: "b701")
    }

    func testBoardingPicksUpSampleAndReturnDeliversIt() {
        let (engine, services) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertFalse(engine.player.activeMission(900)!.cargoPickedUp)

        engine.playerLanded(onSpob: 286)
        XCTAssertTrue(engine.player.isMissionActive(900), "returning before boarding cannot finish")
        XCTAssertEqual(engine.player.credits, 0)

        engine.missionShipBoarded(missionID: 900)
        XCTAssertEqual(engine.player.cargo[31], 1)
        XCTAssertTrue(engine.player.activeMission(900)!.cargoPickedUp)
        XCTAssertEqual(engine.player.activeMission(900)!.shipObjectivesRemaining, 0)
        XCTAssertTrue(engine.player.isBitSet(701))
        XCTAssertTrue(engine.player.isMissionActive(900), "cargo still has a return leg")
        XCTAssertEqual(services.log.filter { $0.hasPrefix("text[") && $0.contains("Sample loaded") }.count, 1)

        engine.playerLanded(onSpob: 300)
        XCTAssertTrue(engine.player.isMissionActive(900))
        engine.playerLanded(onSpob: 286)
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertEqual(engine.player.credits, 40000)
        XCTAssertTrue(engine.player.isBitSet(700))
        XCTAssertEqual(services.log.filter { $0.hasPrefix("text[") && $0.contains("Sample delivered") }.count, 1)
        engine.playerLanded(onSpob: 286)
        XCTAssertEqual(engine.player.credits, 40000, "delivery pays only once")
    }

    func testDestroyingTheBoardTargetFailsTheMission() {
        // MS-11: destroying a board/rescue target before boarding it fails the
        // mission at once; the failure resolves on landing at the return
        // stellar, with no pay.
        let (engine, _) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        engine.missionShipDisabled(missionID: 900)
        XCTAssertFalse(engine.player.activeMission(900)!.isFailed, "disabling alone is fine")
        engine.missionShipDestroyed(missionID: 900)
        XCTAssertTrue(engine.player.activeMission(900)!.isFailed)
        XCTAssertFalse(engine.player.activeMission(900)!.cargoPickedUp)
        XCTAssertNil(engine.player.cargo[31])
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertEqual(engine.player.credits, 0)
    }

    func testRepeatBoardingUsesResolvedCargoOnce() {
        let (engine, services) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        // Saved randomized/legacy resolution must take precedence over static fields.
        engine.player.activeMissions[0].resolvedCargoType = 4
        engine.player.activeMissions[0].resolvedCargoQty = 3
        engine.player.cargo[4] = 2
        engine.missionShipBoarded(missionID: 900)
        engine.missionShipBoarded(missionID: 900)
        XCTAssertEqual(engine.player.cargo[4], 5)
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(services.log.filter { $0.hasPrefix("text[") && $0.contains("Sample loaded") }.count, 1)
        engine.playerLanded(onSpob: 286)
        XCTAssertEqual(engine.player.cargo[4], 2, "delivery removes only the resolved mission tonnage")
    }

    func testRescueBoardingAlsoPicksUpSpecialShipCargo() {
        let (engine, _) = engine(sampleMission(goal: 5))
        XCTAssertTrue(engine.accept(900))
        engine.missionShipDisabled(missionID: 900)
        XCTAssertEqual(engine.player.activeMission(900)!.shipObjectivesRemaining, 1)
        engine.missionShipBoarded(missionID: 900)
        XCTAssertEqual(engine.player.cargo[31], 1)
        XCTAssertEqual(engine.player.activeMission(900)!.shipObjectivesRemaining, 0)
    }

    func testBoardingDoesNotCountForOtherShipGoals() {
        for goal in [0, 1, 6] {
            let (engine, _) = engine(sampleMission(goal: goal))
            XCTAssertTrue(engine.accept(900))
            engine.missionShipBoarded(missionID: 900)
            XCTAssertEqual(engine.player.activeMission(900)!.shipObjectivesRemaining, 1, "goal \(goal)")
        }
    }

    func testReturnBeforeTravelPickupCannotCompleteCargoMission() {
        let spec = MissionSpec(id: 900, travelStellar: 300, returnStellar: 286,
                               cargoType: 1, cargoQty: 5, cargoPickup: 1, cargoDropoff: 1,
                               pay: 100)
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        engine.playerLanded(onSpob: 286)
        XCTAssertTrue(engine.player.isMissionActive(900))
        XCTAssertEqual(engine.player.credits, 0)
        engine.playerLanded(onSpob: 300)
        engine.playerLanded(onSpob: 300)
        XCTAssertEqual(engine.player.cargo[1], 5)
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[1])
        XCTAssertEqual(engine.player.credits, 100)
    }

    func testBoardingWithoutReturnWaitsForTravelDelivery() {
        var spec = sampleMission()
        spec.returnStellar = -1
        spec.travelStellar = 300
        spec.cargoDropoff = 0
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        engine.missionShipBoarded(missionID: 900)
        XCTAssertTrue(engine.player.isMissionActive(900), "ship objective alone does not deliver cargo")
        XCTAssertEqual(engine.player.cargo[31], 1)
        engine.playerLanded(onSpob: 300)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(engine.player.credits, 40000)
    }

    func testAtStartCargoStillDeliversAtTravelStellar() {
        let spec = MissionSpec(id: 900, travelStellar: 300,
                               cargoType: 2, cargoQty: 5, cargoPickup: 0, cargoDropoff: 0,
                               pay: 100)
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        XCTAssertEqual(engine.player.cargo[2], 5)
        engine.missionShipBoarded(missionID: 900)
        XCTAssertEqual(engine.player.cargo[2], 5)
        engine.playerLanded(onSpob: 300)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[2])
        XCTAssertEqual(engine.player.credits, 100)
    }

    func testVisitBeforeBoardingStillCountsAsTheTravelLeg() {
        // The original latches the travel leg on any landing at the travel
        // stellar when its pickup isn't there (0x004438d0), and success needs
        // only that latch and the objective — so the boarded cargo, never
        // dropped at the travel stellar, simply leaves with the mission.
        var spec = sampleMission()
        spec.travelStellar = 300
        spec.cargoDropoff = 0
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        engine.playerLanded(onSpob: 300)
        engine.missionShipBoarded(missionID: 900)
        XCTAssertEqual(engine.player.cargo[31], 1)
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(engine.player.credits, 40000)
    }

    func testReturnDeliversEvenIfCargoLeftHold() {
        let (engine, _) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        engine.missionShipBoarded(missionID: 900)
        engine.player.cargo[31] = nil
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900), "pickup is required, keeping it in the hold is not")
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(engine.player.credits, 40000)
    }

    func testNoCargoMissionWithPickupModesCompletesWithoutPhantomCargo() {
        // Stock story missions often pair CargoType -1 / CargoQty -1 ("no cargo")
        // with real pickup/dropoff modes. abs(-1) must not become a ton of -1.
        for pickup in [0, 1, 2] {
            let spec = MissionSpec(id: 900, travelStellar: 300, returnStellar: 286,
                                   cargoType: -1, cargoQty: -1, cargoPickup: pickup, cargoDropoff: 1,
                                   pay: 100, shipCount: pickup == 2 ? 1 : 0, shipGoal: pickup == 2 ? 2 : -1,
                                   flags2: 0x0001)
            let (engine, _) = engine(spec)
            XCTAssertTrue(engine.accept(900), "pickup \(pickup)")
            XCTAssertNil(engine.player.activeMission(900)!.resolvedCargoType)
            XCTAssertNil(engine.player.activeMission(900)!.resolvedCargoQty)
            engine.playerLanded(onSpob: 300)
            if pickup == 2 { engine.missionShipBoarded(missionID: 900) }
            XCTAssertNil(engine.player.cargo[-1], "pickup \(pickup)")
            engine.player.cargo.removeAll()
            engine.playerLanded(onSpob: 286)
            XCTAssertFalse(engine.player.isMissionActive(900), "pickup \(pickup)")
            XCTAssertNil(engine.player.cargo[-1], "pickup \(pickup)")
            XCTAssertEqual(engine.player.credits, 100, "pickup \(pickup)")
        }
    }

    func testLegacyPhantomCargoIsStrippedAndDoesNotBlock() {
        let spec = MissionSpec(id: 900, returnStellar: 286,
                               cargoType: -1, cargoQty: -1, cargoPickup: 0, cargoDropoff: 1, pay: 100)
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        // Older builds froze -1/1 at accept and loaded one phantom ton.
        engine.player.activeMissions[0].resolvedCargoType = -1
        engine.player.activeMissions[0].resolvedCargoQty = 1
        engine.player.cargo[-1] = 1
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[-1])
        XCTAssertEqual(engine.player.credits, 100)
    }

    func testLegacyBoardedShipWithoutPickupStillCompletesOnReturn() {
        let (engine, _) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        // Older builds counted the board goal on disable without loading cargo,
        // and saved no runtime latches.
        engine.player.activeMissions[0].shipObjectivesRemaining = 0
        engine.player.activeMissions[0].serial = nil
        engine.player.activeMissions[0].objectiveComplete = nil
        XCTAssertFalse(engine.player.activeMission(900)!.cargoPickedUp)
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(engine.player.credits, 40000)
    }
}
