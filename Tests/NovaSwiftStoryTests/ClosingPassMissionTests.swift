import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

/// 2026-10-13 closing pass: the two mission-side corners the decompile read turned up.
///  • `<DL>` for a mission without a time limit reads whatever its slot last held
///    (`Mission_ActivateMissionAtSlot` 0x0043f100 writes the slot's date only when TimeLimit > 0,
///    `NovaText_FormatLongDateString` via 0x004444f0).
///  • `Mission_HandleMissionOrSurrenderShipReaction` (0x00443c60) resolves an auto-abort mission
///    even when its OnShipDone script already aborted it (`Mission_ResolveMisnSlot` 0x00447d90), so
///    OnAbort runs a second time.
final class ClosingPassMissionTests: XCTestCase {

    private func engine(_ resources: [Resource]) -> StoryEngine {
        let game = makeGame(resources + [shipResource(id: 128, cargo: 100)])
        return StoryEngine(game: game, player: PlayerState(shipType: 128, currentSystem: 128),
                           services: LoggingGameServices(), seed: 3)
    }

    func testNoTimeLimitMissionShowsThePreviousOccupantsDeadline() {
        let eng = engine([MissionSpec(id: 400, timeLimit: 5).resource(),
                          MissionSpec(id: 401, timeLimit: -1).resource()])
        let deadline = eng.player.date.adding(days: 5)
        XCTAssertTrue(eng.accept(400))
        XCTAssertEqual(eng.player.activeMission(400)?.slot, 0)
        eng.abortMission(400)
        XCTAssertTrue(eng.accept(401))
        XCTAssertEqual(eng.player.activeMission(401)?.slot, 0, "it takes the freed slot")
        guard let m = eng.game.mission(401) else { return XCTFail("missing mission") }
        let text = eng.resolveMissionText("<DL>", for: m)
        XCTAssertEqual(text, MissionText.longDate(deadline, game: eng.game),
                       "the stale slot date, not the zero date")
    }

    func testNoTimeLimitMissionInAFreshSlotPrintsTheZeroDate() {
        let eng = engine([MissionSpec(id: 401, timeLimit: -1).resource()])
        XCTAssertTrue(eng.accept(401))
        guard let m = eng.game.mission(401) else { return XCTFail("missing mission") }
        XCTAssertEqual(eng.resolveMissionText("<DL>", for: m), MissionText.longDate(nil, game: eng.game))
    }

    func testOnAbortRunsTwiceWhenOnShipDoneAbortsAnAutoAbortMission() {
        // Destroy goal, return leg so the mission is still active when the ship goes down;
        // Flags 0x0001 auto-abort; OnShipDone aborts its own mission (`A200`).
        let spec = MissionSpec(id: 200, returnStellar: 300, shipCount: 1, shipGoal: 0,
                               flags1: 0x0001, onAbort: "G500", onShipDone: "A200").resource()
        let eng = engine([spec])
        XCTAssertTrue(eng.accept(200))
        eng.missionShipDestroyed(missionID: 200)
        XCTAssertFalse(eng.player.isMissionActive(200))
        XCTAssertEqual(eng.player.outfits[500], 2, "the A op's OnAbort, then Mission_ResolveMisnSlot's")
    }

    func testOnAbortRunsOnceWhenOnShipDoneDoesNotAbort() {
        let spec = MissionSpec(id: 200, returnStellar: 300, shipCount: 1, shipGoal: 0,
                               flags1: 0x0001, onAbort: "G500").resource()
        let eng = engine([spec])
        XCTAssertTrue(eng.accept(200))
        eng.missionShipDestroyed(missionID: 200)
        XCTAssertFalse(eng.player.isMissionActive(200))
        XCTAssertEqual(eng.player.outfits[500], 1)
    }
}
