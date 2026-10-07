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
                    pay: 40000, shipCount: 1, shipGoal: goal,
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

    func testDisablingOrDestroyingDoesNotCompleteBoardingObjective() {
        let (engine, _) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        engine.missionShipDisabled(missionID: 900)
        engine.missionShipDestroyed(missionID: 900)
        XCTAssertEqual(engine.player.activeMission(900)!.shipObjectivesRemaining, 1)
        XCTAssertFalse(engine.player.activeMission(900)!.cargoPickedUp)
        XCTAssertNil(engine.player.cargo[31])
        engine.playerLanded(onSpob: 286)
        XCTAssertTrue(engine.player.isMissionActive(900))
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

    func testVisitBeforeBoardingDoesNotCountAsTravelDelivery() {
        var spec = sampleMission()
        spec.travelStellar = 300
        spec.cargoDropoff = 0
        let (engine, _) = engine(spec)
        XCTAssertTrue(engine.accept(900))
        engine.playerLanded(onSpob: 300)
        engine.missionShipBoarded(missionID: 900)
        engine.playerLanded(onSpob: 286)
        XCTAssertTrue(engine.player.isMissionActive(900), "cargo needs a travel landing after pickup")
        XCTAssertEqual(engine.player.credits, 0)
        engine.playerLanded(onSpob: 300)
        engine.playerLanded(onSpob: 286)
        XCTAssertFalse(engine.player.isMissionActive(900))
        XCTAssertNil(engine.player.cargo[31])
        XCTAssertEqual(engine.player.credits, 40000)
    }

    func testReturnCannotDeliverCargoMissingFromHold() {
        let (engine, _) = engine(sampleMission())
        XCTAssertTrue(engine.accept(900))
        engine.missionShipBoarded(missionID: 900)
        engine.player.cargo[31] = nil
        engine.playerLanded(onSpob: 286)
        XCTAssertTrue(engine.player.isMissionActive(900))
        XCTAssertEqual(engine.player.credits, 0)
    }
}
