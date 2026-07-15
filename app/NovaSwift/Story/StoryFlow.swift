import SwiftUI
import NovaSwiftStory

// Turns the reconstructed campaign graph (`StoryMapNode` + `StoryMapEdge`) into a
// single, readable *vertical flow* — a depth-first linearization where a plain
// chain reads as a straight column and genuine branches (a mission whose
// success/refuse/failure lead to different follow-ups, or an `R(...)` 50/50)
// indent one level and carry a label. This is what replaced the old pan/zoom
// node-graph: a `LazyVStack` over these rows virtualizes for free, so a phone
// only ever builds the handful of rows on screen — no Canvas, no per-frame
// layout recompute, no memory spike.
//
// Pure data + one pure function (`buildStoryFlow`), so it's trivially testable
// and never touches SwiftUI state.

/// How a step connects to the one above it in the flow. A `.then` (a plain
/// forward continuation) shows no label so linear chains stay quiet; every
/// other case is a real branch worth calling out.
enum StoryConnector: Hashable {
    case start          // a root — nothing in this campaign leads here
    case then           // linear continuation (primary child of a non-branching step)
    case onSuccess, onAccept, onComplete
    case onRefuse, onFailure, onAbort
    case unlocks        // a control-bit dependency, not a scripted branch
    case random         // one arm of an R(...) 50/50 choice

    /// The pill shown on the row, or `nil` for the two "quiet" connectors.
    var label: String? {
        switch self {
        case .start, .then: return nil
        case .onSuccess:    return "On success"
        case .onAccept:     return "On accept"
        case .onComplete:   return "On completion"
        case .onRefuse:     return "On refuse"
        case .onFailure:    return "On failure"
        case .onAbort:      return "On abort"
        case .unlocks:      return "Unlocks"
        case .random:       return "50/50 chance"
        }
    }

    var tint: Color {
        switch self {
        case .onSuccess, .onAccept, .onComplete: return EVTheme.accent
        case .onRefuse:                           return .orange
        case .onFailure, .onAbort:                return .red
        case .random:                             return Color(red: 0.72, green: 0.55, blue: 0.98)
        case .unlocks, .start, .then:             return .gray
        }
    }

    /// Icon for the connector pill (nil for quiet connectors).
    var symbol: String? {
        switch self {
        case .start, .then:                       return nil
        case .onSuccess, .onAccept, .onComplete:  return "checkmark"
        case .onRefuse:                           return "arrow.uturn.left"
        case .onFailure, .onAbort:                return "xmark"
        case .unlocks:                            return "lock.open"
        case .random:                             return "dice"
        }
    }

    fileprivate static func of(_ edge: StoryMapEdge, primary: Bool, fork: Bool) -> StoryConnector {
        if edge.isRandom { return .random }
        // A single, non-branching forward step reads best as a quiet `.then`;
        // once a step forks, every arm earns its label so the split is legible.
        let quiet = primary && !fork
        switch edge.outcome {
        case .success:  return quiet ? .then : .onSuccess
        case .accept:   return quiet ? .then : .onAccept
        case .shipDone: return quiet ? .then : .onComplete
        case .refuse:   return .onRefuse
        case .failure:  return .onFailure
        case .abort:    return .onAbort
        case .none:     return quiet ? .then : .unlocks
        }
    }
}

/// A `.starts`/`.unlocks` link that leaves the current storyline — rendered as a
/// tappable chip that switches the whole flow to the other campaign, since only
/// one storyline's flow is on screen at a time.
struct CrossLink: Identifiable, Hashable {
    let key: String        // the other storyline's key
    let outgoing: Bool      // true = this step leads into `key`; false = it started from `key`
    var id: String { "\(key)-\(outgoing)" }
}

/// A branch whose target is already shown earlier in the flow (a merge or a
/// loop back) — drawn as a small "→ Step name" chip on the source row instead
/// of duplicating the whole subtree.
struct StoryJump: Identifiable, Hashable {
    let connector: StoryConnector
    let targetID: Int
    let targetName: String
    var id: Int { targetID }
}

/// One row of the vertical flow: a mission node, how deep its branch sits, how
/// it connects to the step above, plus the off-flow references (jumps and
/// cross-campaign links) that hang off it.
struct StoryFlowRow: Identifiable {
    let node: StoryMapNode
    let depth: Int
    let connector: StoryConnector
    let jumps: [StoryJump]
    let crossLinks: [CrossLink]
    let isCurrent: Bool
    var id: Int { node.id }

    var step: StorylineStep { node.step }
}

/// Depth-first linearization of one storyline's subgraph into flow rows.
///
/// - `nodes`      : the steps that belong to this storyline.
/// - `edges`      : the *internal* edges (both ends in `nodes`).
/// - `crossLinks` : cross-campaign chips per node id (computed over the whole map).
/// - `currentID`  : the "you are here" step (first not-completed), highlighted.
///
/// The first child of a step continues the column at the same depth; further
/// children fan out one level deeper. A child edge whose target was already
/// emitted becomes a `StoryJump` chip on the source row rather than a duplicate
/// subtree, so merges and loops don't blow the layout up.
func buildStoryFlow(nodes: [StoryMapNode],
                    edges: [StoryMapEdge],
                    crossLinks: [Int: [CrossLink]],
                    currentID: Int?) -> [StoryFlowRow] {
    guard !nodes.isEmpty else { return [] }
    let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let ids = Set(nodes.map(\.id))

    var outgoing: [Int: [StoryMapEdge]] = [:]
    var indegree: [Int: Int] = [:]
    for e in edges where e.from != e.to && ids.contains(e.from) && ids.contains(e.to) {
        outgoing[e.from, default: []].append(e)
        indegree[e.to, default: 0] += 1
    }
    // Order each step's children so the "main line" (accept/success/unlocks)
    // lays out first and stays on the spine, with refuse/fail/abort/random arms
    // fanning out after — ties broken by the target's authored step number.
    func rank(_ e: StoryMapEdge) -> Int {
        if e.isRandom { return 5 }
        switch e.outcome {
        case .accept, .success, .shipDone: return 0
        case .none:                        return 1   // .unlocks
        case .refuse:                      return 2
        case .failure, .abort:             return 3
        }
    }
    for id in outgoing.keys {
        outgoing[id]?.sort { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            let (sa, sb) = (byID[a.to]?.step.stepNumber ?? 0, byID[b.to]?.step.stepNumber ?? 0)
            return sa < sb
        }
    }

    var roots = nodes.filter { (indegree[$0.id] ?? 0) == 0 }
        .sorted { $0.step.stepNumber < $1.step.stepNumber }
    if roots.isEmpty, let first = nodes.min(by: { $0.step.stepNumber < $1.step.stepNumber }) {
        roots = [first]   // a fully-cyclic subgraph still needs a starting point
    }

    var rows: [StoryFlowRow] = []
    var visited = Set<Int>()

    // Recursion depth is bounded by the storyline's longest path (campaigns are
    // tens of steps, not thousands), so a simple recursive walk is safe here.
    func layout(_ node: StoryMapNode, depth: Int, connector: StoryConnector) {
        let rowIndex = rows.count
        rows.append(StoryFlowRow(node: node, depth: depth, connector: connector,
                                 jumps: [], crossLinks: crossLinks[node.id] ?? [],
                                 isCurrent: node.id == currentID))

        // Split children into tree edges (laid out below) and jumps (targets
        // already placed). Claim tree targets up front so two arms to the same
        // step don't both try to own it.
        var treeEdges: [StoryMapEdge] = []
        var jumps: [StoryJump] = []
        for e in outgoing[node.id] ?? [] {
            if visited.contains(e.to) {
                let conn = StoryConnector.of(e, primary: false, fork: true)
                jumps.append(StoryJump(connector: conn, targetID: e.to,
                                       targetName: byID[e.to]?.step.displayName ?? "Step \(e.to)"))
            } else {
                visited.insert(e.to)
                treeEdges.append(e)
            }
        }
        rows[rowIndex] = StoryFlowRow(node: node, depth: depth, connector: connector,
                                      jumps: jumps, crossLinks: crossLinks[node.id] ?? [],
                                      isCurrent: node.id == currentID)

        let fork = treeEdges.count > 1
        for (i, e) in treeEdges.enumerated() {
            guard let child = byID[e.to] else { continue }
            let primary = i == 0
            layout(child, depth: primary ? depth : depth + 1,
                   connector: StoryConnector.of(e, primary: primary, fork: fork))
        }
    }

    for root in roots where !visited.contains(root.id) {
        visited.insert(root.id)
        layout(root, depth: 0, connector: .start)
    }
    // Any step cut off from every root still deserves a place — chain the
    // leftovers on in authored order rather than dropping them.
    for node in nodes.sorted(by: { $0.step.stepNumber < $1.step.stepNumber })
    where !visited.contains(node.id) {
        visited.insert(node.id)
        layout(node, depth: 0, connector: .start)
    }
    return rows
}
