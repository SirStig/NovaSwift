import XCTest
import EVNovaKit
@testable import EVNovaStory

final class StorylineAnalyzerTests: XCTestCase {

    /// Two tagged missions forming a "Test" storyline where step 1's OnSuccess
    /// sets the bit that step 2's AvailBits requires.
    private func chainGame() -> NovaGame {
        let m1 = MissionSpec(id: 500, name: "Do the first thing; Test1",
                             returnStellar: 128, pay: 1000,
                             onSuccess: "b800").resource()
        let m2 = MissionSpec(id: 501, name: "Do the second thing; Test2",
                             availBits: "b800 & !b801").resource()
        return makeGame([m1, m2, spobResource(id: 128, govt: 128)])
    }

    func testReconstructsStorylineAndOrder() {
        let a = StorylineAnalyzer(game: chainGame())
        let lines = a.storylines(for: PlayerState())
        XCTAssertEqual(lines.count, 1)
        let line = try! XCTUnwrap(lines.first)
        XCTAssertEqual(line.key, "Test")
        XCTAssertEqual(line.steps.map(\.missionID), [500, 501])   // ordered by step number
        XCTAssertEqual(line.totalCount, 2)
    }

    func testLockedStepPointsAtUnlockingMission() {
        let a = StorylineAnalyzer(game: chainGame())
        // Fresh pilot: step 1 available, step 2 locked on b800.
        let lines = a.storylines(for: PlayerState())
        let step2 = try! XCTUnwrap(lines.first?.steps.first { $0.missionID == 501 })
        XCTAssertEqual(step2.status, .locked)
        let blocker = try! XCTUnwrap(step2.blockers.first { $0.bit == 800 })
        XCTAssertTrue(blocker.needsSet)
        // The unlock source is the first mission's completion.
        XCTAssertEqual(blocker.unlockedBy.first?.id, 500)
        XCTAssertEqual(blocker.unlockedBy.first?.kind, .mission)
    }

    func testProgressAfterCompletingFirstStep() {
        let a = StorylineAnalyzer(game: chainGame())
        var player = PlayerState()
        // Simulate having completed step 1: bit set + recorded complete.
        player.setBit(800)
        player.completedMissions.insert(500)
        let lines = a.storylines(for: player)
        let line = try! XCTUnwrap(lines.first)
        XCTAssertEqual(line.completedCount, 1)
        XCTAssertEqual(line.currentStepID, 501)
        let step2 = try! XCTUnwrap(line.steps.first { $0.missionID == 501 })
        XCTAssertEqual(step2.status, .available)     // gate now passes
    }

    func testUntaggedMissionsAreNotStorylines() {
        let generic = MissionSpec(id: 600, name: "Cargo run to nowhere").resource()
        let a = StorylineAnalyzer(game: makeGame([generic]))
        XCTAssertEqual(a.storylines(for: PlayerState()).count, 0)
        XCTAssertEqual(a.untaggedMissionCount, 1)
    }

    func testObjectiveAndRewardText() {
        let m = MissionSpec(id: 700, name: "Haul; Job1", returnStellar: 128,
                            cargoType: 1, cargoQty: 8, cargoPickup: 0, cargoDropoff: 1,
                            pay: 5000).resource()
        // (single tagged step won't form a storyline, so test via brief())
        let a = StorylineAnalyzer(game: makeGame([m, spobResource(id: 128, govt: 128)]))
        let step = try! XCTUnwrap(a.brief(forMission: 700, player: PlayerState()))
        XCTAssertTrue(step.objective.contains("8t"))
        XCTAssertTrue(step.reward.contains("5,000") || step.reward.contains("5000"))
    }
}
