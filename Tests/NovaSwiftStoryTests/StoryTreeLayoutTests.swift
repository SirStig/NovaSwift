import XCTest
@testable import NovaSwiftStory

final class StoryTreeLayoutTests: XCTestCase {

    private func step(_ id: Int, _ n: Int) -> StorylineStep {
        StorylineStep(missionID: id, displayName: "Step \(n)", stepNumber: n, status: .locked,
                     offeredAt: "", objective: "", reward: "", blockers: [], synopsis: "")
    }

    func testLinearChainLaysOutAsOneColumnPerStep() {
        let steps = [step(1, 1), step(2, 2), step(3, 3)]
        let edges = [StoryMapEdge(from: 1, to: 2, kind: .unlocks),
                    StoryMapEdge(from: 2, to: 3, kind: .starts, outcome: .success)]
        let nodes = layoutTree(steps: steps, edges: edges)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.column, 0)
        XCTAssertEqual(byID[2]?.column, 1)
        XCTAssertEqual(byID[3]?.column, 2)
        // A plain chain stays a straight line.
        XCTAssertEqual(byID[1]?.row, byID[2]?.row)
        XCTAssertEqual(byID[2]?.row, byID[3]?.row)
    }

    func testBranchingStepFansSiblingsIntoDistinctRows() {
        // Step 1 starts both step 2 and step 3 — same column, different rows.
        let steps = [step(1, 1), step(2, 2), step(3, 3)]
        let edges = [StoryMapEdge(from: 1, to: 2, kind: .starts, outcome: .success),
                    StoryMapEdge(from: 1, to: 3, kind: .starts, outcome: .failure)]
        let nodes = layoutTree(steps: steps, edges: edges)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        XCTAssertEqual(byID[2]?.column, 1)
        XCTAssertEqual(byID[3]?.column, 1)
        XCTAssertNotEqual(byID[2]?.row, byID[3]?.row)
    }

    func testUnreachableCycleStillAppearsAfterConnectedColumns() {
        // Step 1 is the only true root (nothing points at it). Steps 2 and 3
        // point at *each other* only — neither is zero-indegree, and nothing
        // reachable from step 1 leads to them — so BFS from the real roots
        // never reaches them. They should still render (after the deepest
        // connected column) instead of silently vanishing from the map.
        let steps = [step(1, 1), step(2, 2), step(3, 3)]
        let edges = [StoryMapEdge(from: 2, to: 3, kind: .starts, outcome: .success),
                    StoryMapEdge(from: 3, to: 2, kind: .starts, outcome: .failure)]
        let nodes = layoutTree(steps: steps, edges: edges)
        XCTAssertEqual(nodes.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.column, 0)
        XCTAssertGreaterThan(byID[2]?.column ?? -1, byID[1]?.column ?? -1)
        XCTAssertGreaterThan(byID[3]?.column ?? -1, byID[2]?.column ?? -1)
    }

    func testNoEdgesFallsBackToStepNumberOrderInOneRoot() {
        // No internal edges at all: every step is a root, so each gets its
        // own row rather than colliding at row 0.
        let steps = [step(1, 1), step(2, 2)]
        let nodes = layoutTree(steps: steps, edges: [])
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.column, 0)
        XCTAssertNotEqual(byID[1]?.row, byID[2]?.row)
    }

    func testEmptyStepsProducesNoNodes() {
        XCTAssertTrue(layoutTree(steps: [], edges: []).isEmpty)
    }
}
