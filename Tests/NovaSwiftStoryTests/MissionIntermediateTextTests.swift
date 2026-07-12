import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// Coverage for the mission lifecycle points that surface a mission's
/// intermediate `dësc` texts and fire `OnShipDone`:
///   • `OnShipDone` bits + `ShipDoneText` when the last special-ship goal is met
///   • `LoadCargoText` at cargo pickup (at-start and at-travel-stellar)
///   • `DropCargoText` at the delivery drop-off (completion path only)
/// plus once-only guards so none of them re-fire.
final class MissionIntermediateTextTests: XCTestCase {

    private func engine(_ resources: [Resource],
                        player: PlayerState = PlayerState(shipType: 128, currentSystem: 128),
                        seed: UInt64 = 1) -> (StoryEngine, LoggingGameServices) {
        let game = makeGame(resources + [shipResource(id: 128, cargo: 100)])
        let svc = LoggingGameServices()
        let eng = StoryEngine(game: game, player: player, services: svc, seed: seed)
        return (eng, svc)
    }

    /// How many logged `showStoryText` lines contain `needle`.
    private func storyTextCount(_ svc: LoggingGameServices, containing needle: String) -> Int {
        svc.log.filter { $0.hasPrefix("text[") && $0.contains(needle) }.count
    }

    // MARK: - GAP 1: OnShipDone

    func testOnShipDoneFiresBitsAndTextWhenLastShipObjectiveMet() {
        // Single destroy objective, no return leg → finishing the ship both fires
        // OnShipDone and (because returnStellar == -1) completes the mission.
        let spec = MissionSpec(id: 200, returnStellar: -1,
                               shipCount: 1, shipGoal: 0,
                               shipDoneText: 5000, onShipDone: "b700").resource()
        let (eng, svc) = engine([spec, descResource(id: 5000, text: "Bounty target destroyed")])
        XCTAssertTrue(eng.accept(200))
        XCTAssertFalse(eng.player.isBitSet(700))

        eng.missionShipDestroyed(missionID: 200)

        XCTAssertTrue(eng.player.isBitSet(700), "OnShipDone bits set when the ship goal completes")
        XCTAssertEqual(storyTextCount(svc, containing: "Bounty target destroyed"), 1,
                       "ShipDoneText surfaced exactly once")
    }

    func testOnShipDoneFiresOnlyOnTransitionToZeroWithMultipleShips() {
        // Two-ship goal: OnShipDone must NOT fire on the first kill, only the
        // second (the transition to 0). A return leg keeps the mission active.
        let spec = MissionSpec(id: 200, returnStellar: 300,
                               shipCount: 2, shipGoal: 0,
                               shipDoneText: 5000, onShipDone: "G500").resource()
        let (eng, svc) = engine([spec, descResource(id: 5000, text: "All targets down")])
        XCTAssertTrue(eng.accept(200))

        eng.missionShipDestroyed(missionID: 200)
        XCTAssertNil(eng.player.outfits[500], "OnShipDone must not fire while ships remain")
        XCTAssertEqual(storyTextCount(svc, containing: "All targets down"), 0)

        eng.missionShipDestroyed(missionID: 200)
        XCTAssertEqual(eng.player.outfits[500], 1, "OnShipDone fires once, on the last kill")
        XCTAssertEqual(storyTextCount(svc, containing: "All targets down"), 1)
        XCTAssertTrue(eng.player.isMissionActive(200), "return leg keeps it active")
    }

    func testOnShipDoneDoesNotRefireOnStrayDecrementAfterZero() {
        // Return leg so the mission stays active at 0; a stray destroy report
        // must not re-run OnShipDone or re-show the text.
        let spec = MissionSpec(id: 200, returnStellar: 300,
                               shipCount: 1, shipGoal: 0,
                               shipDoneText: 5000, onShipDone: "G500").resource()
        let (eng, svc) = engine([spec, descResource(id: 5000, text: "Contract fulfilled")])
        XCTAssertTrue(eng.accept(200))

        eng.missionShipDestroyed(missionID: 200)
        eng.missionShipDestroyed(missionID: 200)   // stray extra report
        eng.missionShipDisabled(missionID: 200)    // and via another channel

        XCTAssertEqual(eng.player.outfits[500], 1, "OnShipDone applied exactly once")
        XCTAssertEqual(storyTextCount(svc, containing: "Contract fulfilled"), 1,
                       "ShipDoneText shown exactly once")
    }

    func testShipDoneTextBelow128IsNotShown() {
        let spec = MissionSpec(id: 200, returnStellar: -1,
                               shipCount: 1, shipGoal: 0,
                               shipDoneText: -1, onShipDone: "b700").resource()
        let (eng, svc) = engine([spec])
        XCTAssertTrue(eng.accept(200))
        eng.missionShipDestroyed(missionID: 200)
        XCTAssertTrue(eng.player.isBitSet(700), "bits still fire without a text id")
        XCTAssertTrue(svc.log.filter { $0.hasPrefix("text[") }.isEmpty,
                      "no story text shown for a <128 ShipDoneText id")
    }

    // MARK: - GAP 2: LoadCargoText

    func testLoadCargoTextShownAtStartPickup() {
        let spec = MissionSpec(id: 200, cargoType: 0, cargoQty: 5,
                               cargoPickup: 0, loadCargoText: 5100).resource()
        let (eng, svc) = engine([spec, descResource(id: 5100, text: "Cargo loaded aboard")])
        XCTAssertTrue(eng.accept(200))
        XCTAssertEqual(eng.player.cargo[0], 5, "cargo picked up at start")
        XCTAssertEqual(storyTextCount(svc, containing: "Cargo loaded aboard"), 1,
                       "LoadCargoText shown at the at-start pickup")
    }

    func testLoadCargoTextShownAtTravelStellarPickupOnceOnly() {
        let spec = MissionSpec(id: 200, travelStellar: 300, returnStellar: 400,
                               cargoType: 0, cargoQty: 5,
                               cargoPickup: 1, cargoDropoff: 1,
                               loadCargoText: 5100).resource()
        let (eng, svc) = engine([spec, descResource(id: 5100, text: "Freight taken on")])
        XCTAssertTrue(eng.accept(200))
        XCTAssertNil(eng.player.cargo[0], "no cargo until the travel stellar")
        XCTAssertEqual(storyTextCount(svc, containing: "Freight taken on"), 0)

        eng.playerLanded(onSpob: 300)
        XCTAssertEqual(eng.player.cargo[0], 5, "cargo loaded at the travel stellar")
        XCTAssertEqual(storyTextCount(svc, containing: "Freight taken on"), 1,
                       "LoadCargoText shown at the travel-stellar pickup")

        // Land at the travel stellar again — already picked up, must not re-show.
        eng.playerLanded(onSpob: 300)
        XCTAssertEqual(eng.player.cargo[0], 5, "cargo not double-added")
        XCTAssertEqual(storyTextCount(svc, containing: "Freight taken on"), 1,
                       "LoadCargoText shown once per pickup, not on every landing")
    }

    // MARK: - GAP 2: DropCargoText

    func testDropCargoTextShownAtDeliveryDropoff() {
        // Pick up at start, deliver at the return stellar; completing there is
        // the drop-off moment.
        let spec = MissionSpec(id: 200, returnStellar: 400,
                               cargoType: 0, cargoQty: 5,
                               cargoPickup: 0, cargoDropoff: 1,
                               dropCargoText: 5200).resource()
        let (eng, svc) = engine([spec, descResource(id: 5200, text: "Delivery complete")])
        XCTAssertTrue(eng.accept(200))
        XCTAssertEqual(eng.player.cargo[0], 5)

        eng.playerLanded(onSpob: 400)   // arrive at the return stellar → completes
        XCTAssertFalse(eng.player.isMissionActive(200), "delivered and completed")
        XCTAssertNil(eng.player.cargo[0], "cargo dropped from the hold")
        XCTAssertEqual(storyTextCount(svc, containing: "Delivery complete"), 1,
                       "DropCargoText shown at the drop-off")
    }

    func testDropCargoTextNotShownOnAbort() {
        let spec = MissionSpec(id: 200, returnStellar: 400,
                               cargoType: 0, cargoQty: 5,
                               cargoPickup: 0, cargoDropoff: 1,
                               dropCargoText: 5200).resource()
        let (eng, svc) = engine([spec, descResource(id: 5200, text: "Delivery complete")])
        XCTAssertTrue(eng.accept(200))
        eng.abortMission(200)
        XCTAssertNil(eng.player.cargo[0], "cargo jettisoned on abort")
        XCTAssertEqual(storyTextCount(svc, containing: "Delivery complete"), 0,
                       "DropCargoText must NOT show on an abort release")
    }

    func testDropCargoTextNotShownOnFailure() {
        let spec = MissionSpec(id: 200, returnStellar: 400,
                               cargoType: 0, cargoQty: 5,
                               cargoPickup: 0, cargoDropoff: 1,
                               canAbort: false, dropCargoText: 5200).resource()
        let (eng, svc) = engine([spec, descResource(id: 5200, text: "Delivery complete")])
        XCTAssertTrue(eng.accept(200))
        eng.failMission(200)
        XCTAssertNil(eng.player.cargo[0], "cargo lost on failure")
        XCTAssertEqual(storyTextCount(svc, containing: "Delivery complete"), 0,
                       "DropCargoText must NOT show on a fail release")
    }
}
