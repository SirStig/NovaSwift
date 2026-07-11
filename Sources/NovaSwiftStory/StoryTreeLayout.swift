import Foundation

// Lays out a single storyline as a branching tree instead of the flat lane/row
// grid `StoryMapNode` uses when every storyline shares one canvas. Pure logic,
// no game state — trivially unit-testable, same spirit as NCBExpression.swift.

/// One mission positioned in a single storyline's branch tree: `column` = how
/// many `.starts`/`.unlocks` hops from a root (a step nothing else in this
/// storyline points at), `row` = its vertical slot within that column.
public struct StoryTreeNode: Identifiable, Sendable {
    public let step: StorylineStep
    public let column: Int
    public let row: Int
    public var id: Int { step.missionID }

    public init(step: StorylineStep, column: Int, row: Int) {
        self.step = step; self.column = column; self.row = row
    }
}

/// Lays out one storyline's steps as a branching tree from `edges` (`.starts`
/// and `.unlocks`, restricted to pairs where both ends are in `steps` — a
/// cross-storyline link is the caller's concern, not this layout's).
///
/// - `column` is the longest-path depth from a root (a step nothing else in
///   this storyline points at, or the lowest `stepNumber` if the subgraph has
///   no internal edges at all). A step unreachable from every root — cut off
///   from the rest of the graph — chains after the deepest column found, in
///   step-number order, so it still renders somewhere instead of vanishing.
/// - `row` is assigned column by column: a child prefers its first parent's
///   row when that slot is free in its own column, otherwise the next free
///   row — a plain chain lays out as a straight line, and only genuine
///   siblings (a mission with more than one follow-up) fan out vertically.
public func layoutTree(steps: [StorylineStep], edges: [StoryMapEdge]) -> [StoryTreeNode] {
    guard !steps.isEmpty else { return [] }
    let ids = Set(steps.map(\.missionID))
    let ordered = steps.sorted { $0.stepNumber < $1.stepNumber }

    var childrenOf: [Int: [Int]] = [:]
    var indegree: [Int: Int] = [:]
    for e in edges where e.from != e.to && ids.contains(e.from) && ids.contains(e.to) {
        childrenOf[e.from, default: []].append(e.to)
        indegree[e.to, default: 0] += 1
    }

    var roots = ordered.filter { (indegree[$0.missionID] ?? 0) == 0 }
    if roots.isEmpty, let first = ordered.first { roots = [first] }

    // BFS layering: column = longest path from any root.
    var column: [Int: Int] = [:]
    var queue: [Int] = []
    for r in roots { column[r.missionID] = 0; queue.append(r.missionID) }
    var qi = 0
    while qi < queue.count {
        let id = queue[qi]; qi += 1
        for child in childrenOf[id] ?? [] {
            let candidate = (column[id] ?? 0) + 1
            if candidate > (column[child] ?? -1) {
                column[child] = candidate
                queue.append(child)
            }
        }
    }
    var nextFallbackColumn = (column.values.max() ?? -1) + 1
    for step in ordered where column[step.missionID] == nil {
        column[step.missionID] = nextFallbackColumn
        nextFallbackColumn += 1
    }

    // A child's row prefers its first-seen parent's row, so a simple chain
    // stays a straight horizontal line.
    var parentOf: [Int: Int] = [:]
    for (from, children) in childrenOf {
        for child in children where parentOf[child] == nil { parentOf[child] = from }
    }
    var row: [Int: Int] = [:]
    var usedRowsByColumn: [Int: Set<Int>] = [:]
    let byColumn = Dictionary(grouping: ordered) { column[$0.missionID] ?? 0 }
    for col in byColumn.keys.sorted() {
        for step in (byColumn[col] ?? []).sorted(by: { $0.stepNumber < $1.stepNumber }) {
            var candidate = parentOf[step.missionID].flatMap { row[$0] } ?? 0
            var used = usedRowsByColumn[col, default: []]
            while used.contains(candidate) { candidate += 1 }
            row[step.missionID] = candidate
            used.insert(candidate)
            usedRowsByColumn[col] = used
        }
    }

    return ordered.map { step in
        StoryTreeNode(step: step, column: column[step.missionID] ?? 0, row: row[step.missionID] ?? 0)
    }
}
