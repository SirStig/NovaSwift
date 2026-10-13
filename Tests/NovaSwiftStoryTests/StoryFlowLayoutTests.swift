import XCTest
@testable import NovaSwiftStory

final class StoryFlowLayoutTests: XCTestCase {

    private func node(_ id: Int, _ n: Int, _ status: MissionStatus = .locked, lane: String = "L") -> StoryMapNode {
        let step = StorylineStep(missionID: id, displayName: "Step \(n)", stepNumber: n, status: status,
                                 offeredAt: "", objective: "", reward: "", blockers: [], synopsis: "")
        return StoryMapNode(step: step, storylineKey: lane, laneIndex: 0, rowIndex: n - 1)
    }

    func testLinearChainIsOneQuietColumn() {
        let nodes = [node(1, 1), node(2, 2), node(3, 3)]
        let edges = [StoryMapEdge(from: 1, to: 2, kind: .starts, outcome: .success),
                     StoryMapEdge(from: 2, to: 3, kind: .unlocks)]
        let rows = buildStoryFlow(nodes: nodes, edges: edges, crossLinks: [:], currentID: 2)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0])
        XCTAssertEqual(rows[0].connector, .start)
        XCTAssertEqual(rows[1].connector, .then)
        XCTAssertNil(rows[1].connector.label)
        XCTAssertEqual(rows.map(\.isCurrent), [false, true, false])
    }

    func testForkIndentsSecondaryArmsAndLabelsEveryArm() {
        let nodes = [node(1, 1), node(2, 2), node(3, 3), node(4, 4)]
        let edges = [StoryMapEdge(from: 1, to: 3, kind: .starts, outcome: .failure),
                     StoryMapEdge(from: 1, to: 2, kind: .starts, outcome: .success),
                     StoryMapEdge(from: 1, to: 4, kind: .starts, outcome: .refuse)]
        let rows = buildStoryFlow(nodes: nodes, edges: edges, crossLinks: [:], currentID: nil)
        XCTAssertEqual(rows.map(\.id), [1, 2, 4, 3])   // success first, then refuse, then failure
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(rows[1].connector, .onSuccess)
        XCTAssertEqual(rows[2].connector.label, "On refuse")
        XCTAssertEqual(rows[3].connector.label, "On failure")
    }

    func testRandomArmWinsRandomConnector() {
        let nodes = [node(1, 1), node(2, 2)]
        let edges = [StoryMapEdge(from: 1, to: 2, kind: .starts, outcome: .success, isRandom: true)]
        let rows = buildStoryFlow(nodes: nodes, edges: edges, crossLinks: [:], currentID: nil)
        XCTAssertEqual(rows[1].connector.label, "50/50 chance")
    }

    func testMergeBecomesJumpChipNotDuplicateRow() {
        // 1 -> 2 -> 4 and 1 -> 3 -> 4: step 4 is placed once; the second arm jumps to it.
        let nodes = [node(1, 1), node(2, 2), node(3, 3), node(4, 4)]
        let edges = [StoryMapEdge(from: 1, to: 2, kind: .starts, outcome: .success),
                     StoryMapEdge(from: 1, to: 3, kind: .starts, outcome: .failure),
                     StoryMapEdge(from: 2, to: 4, kind: .unlocks),
                     StoryMapEdge(from: 3, to: 4, kind: .unlocks)]
        let rows = buildStoryFlow(nodes: nodes, edges: edges, crossLinks: [:], currentID: nil)
        XCTAssertEqual(rows.count, 4)
        let jumpers = rows.filter { !$0.jumps.isEmpty }
        XCTAssertEqual(jumpers.count, 1)
        XCTAssertEqual(jumpers[0].jumps[0].targetID, 4)
    }

    func testCyclicAndDisconnectedStepsStillAppear() {
        let nodes = [node(1, 1), node(2, 2), node(3, 3)]
        let edges = [StoryMapEdge(from: 2, to: 3, kind: .starts, outcome: .success),
                     StoryMapEdge(from: 3, to: 2, kind: .starts, outcome: .failure)]
        let rows = buildStoryFlow(nodes: nodes, edges: edges, crossLinks: [:], currentID: nil)
        XCTAssertEqual(Set(rows.map(\.id)), [1, 2, 3])
        XCTAssertTrue(buildStoryFlow(nodes: [], edges: [], crossLinks: [:], currentID: nil).isEmpty)
    }

    func testGuideLogicCurrentStepAndCrossLinks() {
        let a1 = node(1, 1, .completed, lane: "A"), a2 = node(2, 2, .active, lane: "A")
        let b1 = node(3, 1, .locked, lane: "B")
        XCTAssertEqual(StoryGuideLogic.currentStepID(in: [a1, a2]), 2)
        XCTAssertNil(StoryGuideLogic.currentStepID(in: [a1]))

        let lanes = [StoryMapLane(key: "A", title: "A", index: 0, completedCount: 1, totalCount: 2,
                                  isComplete: false, governmentID: nil, pluginID: ""),
                     StoryMapLane(key: "B", title: "B", index: 1, completedCount: 0, totalCount: 1,
                                  isComplete: false, governmentID: nil, pluginID: "")]
        let map = StoryMap(lanes: lanes, nodes: [a1, a2, b1],
                           edges: [StoryMapEdge(from: 1, to: 2, kind: .unlocks),
                                   StoryMapEdge(from: 2, to: 3, kind: .starts, outcome: .success)],
                           untaggedCount: 0)
        let links = StoryGuideLogic.crossLinks(in: map)
        XCTAssertEqual(links[2], [CrossLink(key: "B", outgoing: true)])
        XCTAssertEqual(links[3], [CrossLink(key: "A", outgoing: false)])
        let flow = StoryGuideLogic.flow(for: "A", in: map, crossLinks: links)
        XCTAssertEqual(flow.map(\.id), [1, 2])
        XCTAssertEqual(flow[1].isCurrent, true)
        XCTAssertEqual(flow[1].crossLinks.count, 1)
    }
}
