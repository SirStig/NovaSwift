import XCTest
import NovaSwiftKit
@testable import NovaSwiftStory

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

    // MARK: Story map (graph)

    func testStoryMapBuildsLaneNodesAndUnlockEdge() {
        let a = StorylineAnalyzer(game: chainGame())
        let map = a.storyMap(for: PlayerState())
        XCTAssertEqual(map.lanes.count, 1)
        XCTAssertEqual(map.lanes.first?.key, "Test")
        XCTAssertEqual(map.nodes.count, 2)
        // Both nodes share lane 0, laid out in step order.
        XCTAssertEqual(map.nodes.map(\.laneIndex), [0, 0])
        XCTAssertEqual(map.nodes.map(\.rowIndex), [0, 1])
        // Step 1 sets b800 which step 2 requires → an unlocks edge 500 → 501.
        let edge = try! XCTUnwrap(map.edges.first { $0.from == 500 && $0.to == 501 })
        XCTAssertEqual(edge.kind, .unlocks)
    }

    func testStoryMapStartsEdgeFromScript() {
        // m1 directly starts m2 via an S-op; both tagged into one storyline.
        let m1 = MissionSpec(id: 510, name: "Kickoff; Chain1", onSuccess: "S511").resource()
        let m2 = MissionSpec(id: 511, name: "Payoff; Chain2", availBits: "b900").resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, spobResource(id: 128, govt: 128)]))
        let map = a.storyMap(for: PlayerState())
        let edge = try! XCTUnwrap(map.edges.first { $0.from == 510 && $0.to == 511 })
        // A direct start beats an incidental bit dependency for the same pair.
        XCTAssertEqual(edge.kind, .starts)
    }

    func testStoryMapEmptyWithoutStorylines() {
        let generic = MissionSpec(id: 620, name: "Cargo run to nowhere").resource()
        let a = StorylineAnalyzer(game: makeGame([generic]))
        let map = a.storyMap(for: PlayerState())
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(map.untaggedCount, 1)
    }

    // MARK: Branching (outcome-tagged edges, random choices, dead ends)

    func testStoryMapBranchesBySuccessAndFailureOutcome() {
        // Same mission's onSuccess and onFailure each start a *different*
        // follow-up — two distinct `.starts` edges, not collapsed into one.
        let m1 = MissionSpec(id: 510, name: "Kickoff; Branch1",
                             onSuccess: "S511", onFailure: "S512").resource()
        let m2 = MissionSpec(id: 511, name: "Success path; Branch2").resource()
        let m3 = MissionSpec(id: 512, name: "Failure path; Branch3").resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, m3, spobResource(id: 128, govt: 128)]))
        let map = a.storyMap(for: PlayerState())
        let successEdge = try! XCTUnwrap(map.edges.first { $0.from == 510 && $0.to == 511 })
        let failureEdge = try! XCTUnwrap(map.edges.first { $0.from == 510 && $0.to == 512 })
        XCTAssertEqual(successEdge.kind, .starts)
        XCTAssertEqual(successEdge.outcome, .success)
        XCTAssertEqual(failureEdge.outcome, .failure)
        XCTAssertNotEqual(successEdge.id, failureEdge.id)
    }

    func testStoryMapRandomStartIsFlagged() {
        // R(...) 50/50 choice: both arms are real edges, both flagged random.
        let m1 = MissionSpec(id: 520, name: "Coinflip; Rand1",
                             onSuccess: "R(S521 S522)").resource()
        let m2 = MissionSpec(id: 521, name: "Heads; Rand2").resource()
        let m3 = MissionSpec(id: 522, name: "Tails; Rand3").resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, m3, spobResource(id: 128, govt: 128)]))
        let map = a.storyMap(for: PlayerState())
        let toHeads = try! XCTUnwrap(map.edges.first { $0.from == 520 && $0.to == 521 })
        let toTails = try! XCTUnwrap(map.edges.first { $0.from == 520 && $0.to == 522 })
        XCTAssertTrue(toHeads.isRandom)
        XCTAssertTrue(toTails.isRandom)
    }

    func testStoryMapRandomDeadEndIsRecorded() {
        // R(continue, abort): the continuing arm is a real edge; the abort
        // arm should still surface as a dead end for that outcome instead of
        // silently vanishing.
        let m1 = MissionSpec(id: 530, name: "Risky; Dead1",
                             onSuccess: "R(S531 A999)").resource()
        let m2 = MissionSpec(id: 531, name: "Continues; Dead2").resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, spobResource(id: 128, govt: 128)]))
        let map = a.storyMap(for: PlayerState())
        XCTAssertTrue(map.edges.contains { $0.from == 530 && $0.to == 531 && $0.outcome == .success })
        let node = try! XCTUnwrap(map.nodes.first { $0.id == 530 })
        XCTAssertTrue(node.deadEndOutcomes.contains(.success))
    }

    func testStoryMapPlainAbortWithNoStartIsDeadEnd() {
        let m1 = MissionSpec(id: 540, name: "Grim; Dead1", onFailure: "A128").resource()
        let m2 = MissionSpec(id: 541, name: "Only other step; Dead2").resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, spobResource(id: 128, govt: 128)]))
        let map = a.storyMap(for: PlayerState())
        let node = try! XCTUnwrap(map.nodes.first { $0.id == 540 })
        XCTAssertEqual(node.deadEndOutcomes, [.failure])
    }

    // MARK: Government / plug-in provenance

    func testStorylineGovernmentIDIsModeAcrossSteps() {
        let m1 = MissionSpec(id: 550, name: "First; Govt1", compRewardGovt: 128).resource()
        let m2 = MissionSpec(id: 551, name: "Second; Govt2", compRewardGovt: 128).resource()
        let m3 = MissionSpec(id: 552, name: "Third; Govt3", compRewardGovt: 129).resource()
        let a = StorylineAnalyzer(game: makeGame([m1, m2, m3, spobResource(id: 128, govt: 128)]))
        let line = try! XCTUnwrap(a.storylines(for: PlayerState()).first)
        XCTAssertEqual(line.governmentID, 128)   // 128 appears twice, 129 once
    }

    func testStorylinePluginIDFromResourceProvenance() {
        var base = ResourceCollection()
        base.add(spobResource(id: 128, govt: 128))
        var pluginCol = ResourceCollection()
        pluginCol.add(MissionSpec(id: 560, name: "Add-on step 1; Addon1").resource())
        pluginCol.add(MissionSpec(id: 561, name: "Add-on step 2; Addon2").resource())
        base.overlay(pluginCol, tag: "MyPlugin")

        let game = NovaGame(base)
        XCTAssertEqual(game.mission(560)?.sourcePlugin, "MyPlugin")
        let a = StorylineAnalyzer(game: game)
        let line = try! XCTUnwrap(a.storylines(for: PlayerState()).first { $0.key == "Addon" })
        XCTAssertEqual(line.pluginID, "MyPlugin")
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
