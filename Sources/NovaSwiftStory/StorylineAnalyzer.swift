import Foundation
import NovaSwiftKit

// Reconstructs EV Nova's storylines from the mission control-bit graph and
// reports, for a given pilot, exactly where they are in each campaign and what
// to do next to unlock the following step. This powers the "aftermarket" in-game
// story guide (an EV-Bible-style browser that the original game never had).
//
// It works because the whole story is a graph: each mïsn's AvailBits (a TEST
// expression) declares the bits it needs, and its OnAccept/OnSuccess/OnShipDone
// (SET expressions) declare the bits it flips. Linking "who sets bit N" to "who
// needs bit N" reconstructs the dependency chain — no hand-authored guide needed.

/// Where a pilot stands on one mission.
public enum MissionStatus: String, Codable, Sendable {
    case completed      // already done
    case active         // accepted, in progress
    case available      // eligible to accept right now
    case locked         // prerequisites not yet met
}

/// A bit that is currently preventing a step, plus what would flip it.
public struct BlockingBit: Codable, Sendable, Hashable {
    public let bit: Int
    /// true = the bit must become **set** (it is currently clear);
    /// false = it must become **clear** (it is currently set).
    public let needsSet: Bool
    public let unlockedBy: [UnlockSource]

    public init(bit: Int, needsSet: Bool, unlockedBy: [UnlockSource]) {
        self.bit = bit; self.needsSet = needsSet; self.unlockedBy = unlockedBy
    }
}

/// A mission or cron that would flip a blocking bit into the needed state.
public struct UnlockSource: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case mission, cron }
    public let kind: Kind
    public let id: Int
    public let name: String
    public let hint: String   // e.g. "Complete “Return to Earth”" / "a background event"

    public init(kind: Kind, id: Int, name: String, hint: String) {
        self.kind = kind; self.id = id; self.name = name; self.hint = hint
    }
}

/// One mission's place in a storyline, resolved for a specific pilot.
public struct StorylineStep: Identifiable, Codable, Sendable {
    public var id: Int { missionID }
    public let missionID: Int
    public let displayName: String      // cleaned ("Delivery to Earth")
    public let stepNumber: Int
    public var status: MissionStatus
    public let offeredAt: String        // "Mission Computer at Earth"
    public let objective: String        // "Deliver 5t of cargo to Earth"
    public let reward: String           // "15,000 cr · +Federation standing"
    public let blockers: [BlockingBit]  // populated when status == .locked
    public let synopsis: String         // the offer/briefing text (may be empty)
    /// The government whose standing this step's completion rewards (its
    /// `compRewardGovt`), when it has one — used to color the storyline it
    /// belongs to by that government's real map color. `nil` when the step
    /// carries no reward-government field.
    public let governmentID: Int?

    public init(missionID: Int, displayName: String, stepNumber: Int, status: MissionStatus,
                offeredAt: String, objective: String, reward: String,
                blockers: [BlockingBit], synopsis: String, governmentID: Int? = nil) {
        self.missionID = missionID; self.displayName = displayName; self.stepNumber = stepNumber
        self.status = status; self.offeredAt = offeredAt; self.objective = objective
        self.reward = reward; self.blockers = blockers; self.synopsis = synopsis
        self.governmentID = governmentID
    }
}

/// A reconstructed campaign: an ordered list of steps with progress.
public struct Storyline: Identifiable, Codable, Sendable {
    public var id: String { key }
    public let key: String              // "Vellos"
    public let title: String            // "Vellos" storyline
    public var steps: [StorylineStep]
    public var completedCount: Int
    public var totalCount: Int
    /// The first step that isn't completed — "where you are now".
    public var currentStepID: Int?
    /// This storyline's owning government — the mode of its steps'
    /// `governmentID` (nils excluded from the vote, ties broken by first
    /// appearance). `nil` when no step carries a reward government at all.
    /// A heuristic: a storyline split evenly across two governments, or one
    /// where a plug-in extension outweighs the original steps, picks
    /// whichever is most common, not necessarily "the intended owner".
    public var governmentID: Int?
    /// Which plug-in contributed this storyline (`""` = base game) — the
    /// mode of its steps' underlying mission `sourcePlugin`, same heuristic
    /// as `governmentID`.
    public var pluginID: String

    public init(key: String, title: String, steps: [StorylineStep],
                completedCount: Int, totalCount: Int, currentStepID: Int?,
                governmentID: Int? = nil, pluginID: String = "") {
        self.key = key; self.title = title; self.steps = steps
        self.completedCount = completedCount; self.totalCount = totalCount
        self.currentStepID = currentStepID
        self.governmentID = governmentID; self.pluginID = pluginID
    }

    public var isComplete: Bool { completedCount >= totalCount && totalCount > 0 }
    public var progressFraction: Double {
        totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
    }
}

// MARK: - Story map (graph model)

/// One mission drawn on the story map, plus where it sits in the lane layout.
/// Wraps the fully-resolved `StorylineStep` (status/objective/reward/blockers)
/// and adds the campaign it belongs to and its grid coordinates.
public struct StoryMapNode: Identifiable, Sendable {
    public var id: Int { step.missionID }
    public let step: StorylineStep
    public let storylineKey: String
    /// Which campaign column this node lives in (0-based).
    public let laneIndex: Int
    /// Vertical order within the lane (0 = first step).
    public let rowIndex: Int
    /// Outcomes whose script explicitly ends the story here (an
    /// `.abortMission`/`.failMission` op, with or without a sibling
    /// `.startMission` elsewhere in the same script — see
    /// `StorylineAnalyzer.hasDeadEnd`) rather than continuing to another
    /// mission. Surfaced so a random/outcome branch that terminates doesn't
    /// just silently vanish from the map.
    public let deadEndOutcomes: [StoryMapEdge.Outcome]

    public init(step: StorylineStep, storylineKey: String, laneIndex: Int, rowIndex: Int,
                deadEndOutcomes: [StoryMapEdge.Outcome] = []) {
        self.step = step; self.storylineKey = storylineKey
        self.laneIndex = laneIndex; self.rowIndex = rowIndex
        self.deadEndOutcomes = deadEndOutcomes
    }
}

/// A directed dependency between two mission nodes on the map.
public struct StoryMapEdge: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case unlocks   // `from` sets a control bit that `to` requires
        case starts    // `from` directly starts `to` (an S-op in its script)
    }
    /// Which of a mission's six outcome scripts produced a `.starts` edge —
    /// always `nil` for `.unlocks` edges, which aren't tied to one outcome.
    public enum Outcome: String, Sendable, Hashable {
        case accept, success, failure, refuse, abort, shipDone
    }
    public let from: Int   // mission id
    public let to: Int     // mission id
    public let kind: Kind
    public let outcome: Outcome?
    /// True when this `.starts` edge came from inside an `R(...)` 50/50
    /// choice — the branch is one of two+ random possibilities, not certain.
    public let isRandom: Bool
    /// Distinguishes concurrent branches between the same two missions (e.g.
    /// `onSuccess` and `onFailure` both starting the same follow-up) — two
    /// such edges share `from`/`to`/`kind` but differ in `outcome`.
    public var id: String { "\(from)-\(to)-\(kind.rawValue)-\(outcome?.rawValue ?? "")-\(isRandom)" }

    public init(from: Int, to: Int, kind: Kind, outcome: Outcome? = nil, isRandom: Bool = false) {
        self.from = from; self.to = to; self.kind = kind
        self.outcome = outcome; self.isRandom = isRandom
    }
}

/// One campaign column on the map, with headline progress.
public struct StoryMapLane: Identifiable, Sendable {
    public let key: String
    public let title: String
    public let index: Int
    public let completedCount: Int
    public let totalCount: Int
    public let isComplete: Bool
    /// See `Storyline.governmentID`/`Storyline.pluginID` — carried onto the
    /// lane so the map/sidebar can color and group by them without needing
    /// the full resolved `Storyline` alongside the `StoryMap`.
    public let governmentID: Int?
    public let pluginID: String
    public var id: String { key }

    public init(key: String, title: String, index: Int,
                completedCount: Int, totalCount: Int, isComplete: Bool,
                governmentID: Int? = nil, pluginID: String = "") {
        self.key = key; self.title = title; self.index = index
        self.completedCount = completedCount; self.totalCount = totalCount
        self.isComplete = isComplete
        self.governmentID = governmentID; self.pluginID = pluginID
    }
}

/// The whole reconstructed campaign graph for one pilot: every storyline as a
/// lane of mission nodes, with the dependency edges that link "what unlocks
/// what" (including across campaigns). Powers the full-screen Story Map.
public struct StoryMap: Sendable {
    public let lanes: [StoryMapLane]
    public let nodes: [StoryMapNode]
    public let edges: [StoryMapEdge]
    /// One-off (untagged) jobs that aren't part of any campaign — shown as a count.
    public let untaggedCount: Int

    public init(lanes: [StoryMapLane], nodes: [StoryMapNode], edges: [StoryMapEdge],
                untaggedCount: Int) {
        self.lanes = lanes; self.nodes = nodes; self.edges = edges
        self.untaggedCount = untaggedCount
    }

    public var isEmpty: Bool { nodes.isEmpty }
    /// Tallest lane (most steps) — the map's row extent.
    public var maxRows: Int { nodes.map(\.rowIndex).max().map { $0 + 1 } ?? 0 }
}

public final class StorylineAnalyzer {
    private let game: NovaGame

    /// bit → sources that SET it / that CLEAR it (missions via OnSuccess/OnAccept/
    /// OnShipDone, crons via OnStart/OnEnd). Precomputed once.
    private var setters: [Int: [UnlockSource]] = [:]
    private var clearers: [Int: [UnlockSource]] = [:]

    public init(game: NovaGame) {
        self.game = game
        indexBitSources()
    }

    // MARK: Public API

    /// All storylines with per-step status resolved for `player`, ordered with
    /// in-progress campaigns first.
    public func storylines(for player: PlayerState) -> [Storyline] {
        let engine = StoryEngine(game: game, player: player)
        var result: [Storyline] = []
        for (key, missions) in groupedByStoryline() {
            let ordered = missions.sorted { storyTag($0.name).step < storyTag($1.name).step }
            var steps: [StorylineStep] = []
            for m in ordered {
                steps.append(makeStep(m, player: player, engine: engine))
            }
            let done = steps.filter { $0.status == .completed }.count
            let current = steps.first { $0.status != .completed }?.missionID
            let govt = Self.mode(steps.compactMap(\.governmentID))
            let plugin = Self.mode(ordered.map(\.sourcePlugin).filter { !$0.isEmpty }) ?? ""
            result.append(Storyline(key: key, title: key, steps: steps,
                                    completedCount: done, totalCount: steps.count,
                                    currentStepID: current,
                                    governmentID: govt, pluginID: plugin))
        }
        // In-progress first, then not-started, then finished; alphabetical within.
        return result.sorted { a, b in
            func rank(_ s: Storyline) -> Int {
                if s.isComplete { return 2 }
                if s.completedCount > 0 { return 0 }
                return 1
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.key < b.key
        }
    }

    /// A resolved brief for any single mission (used by the pilot's active-mission
    /// list, which may include untagged one-off jobs).
    public func brief(forMission id: Int, player: PlayerState) -> StorylineStep? {
        guard let m = game.mission(id) else { return nil }
        let engine = StoryEngine(game: game, player: player)
        return makeStep(m, player: player, engine: engine)
    }

    /// The number of missions with no storyline tag (generic bar/computer jobs).
    public var untaggedMissionCount: Int {
        game.missions().filter { storyTag($0.name).key == nil }.count
    }

    /// The whole campaign graph resolved for `player`: lanes (one per storyline),
    /// nodes (every tagged mission with live status), and the dependency edges
    /// between them. Edges come from two sources — a mission that **sets** a
    /// control bit another mission **requires** (`.unlocks`), and a mission that
    /// **directly starts** another via an S-op in one of its six outcome
    /// scripts (`.starts`, tagged with which outcome and whether it came from
    /// an `R(...)` random choice). Only links between missions that are both
    /// on the map are drawn, so the graph stays a readable campaign map
    /// rather than the full 500-mission tangle.
    public func storyMap(for player: PlayerState) -> StoryMap {
        let lines = storylines(for: player)
        var lanes: [StoryMapLane] = []
        var onMap = Set<Int>()
        for (laneIndex, line) in lines.enumerated() {
            lanes.append(StoryMapLane(key: line.key, title: line.title, index: laneIndex,
                                      completedCount: line.completedCount,
                                      totalCount: line.totalCount, isComplete: line.isComplete,
                                      governmentID: line.governmentID, pluginID: line.pluginID))
            for step in line.steps { onMap.insert(step.missionID) }
        }

        // `.starts`: every outcome script that directly launches another
        // on-map mission, including nested inside an `R(...)` random choice
        // (flagged `isRandom`). A direct script link beats an incidental
        // `.unlocks` bit dependency between the same ordered pair, so
        // `.unlocks` edges below skip any pair already linked here.
        var startPairs = Set<String>()
        var edges: [String: StoryMapEdge] = [:]
        var deadEnds: [Int: [StoryMapEdge.Outcome]] = [:]
        for missionID in onMap {
            guard let m = game.mission(missionID) else { continue }
            let scripts: [(String, StoryMapEdge.Outcome)] = [
                (m.onAccept, .accept), (m.onRefuse, .refuse), (m.onSuccess, .success),
                (m.onFailure, .failure), (m.onAbort, .abort), (m.onShipDone, .shipDone)]
            for (expr, outcome) in scripts {
                let ops = NCBSet.parse(expr)
                for (target, isRandom) in Self.flattenStartMissions(ops)
                        where target != m.id && onMap.contains(target) {
                    let e = StoryMapEdge(from: m.id, to: target, kind: .starts,
                                         outcome: outcome, isRandom: isRandom)
                    edges[e.id] = e
                    startPairs.insert("\(m.id)-\(target)")
                }
                // An abort/fail op — even one arm of a random choice whose
                // other arm starts a follow-up — means this outcome may end
                // the story here; worth surfacing rather than silently
                // dropping that branch from the map.
                if Self.hasDeadEnd(ops) { deadEnds[m.id, default: []].append(outcome) }
            }
        }

        // `.unlocks`: whoever sets a bit this mission needs → this mission.
        for missionID in onMap {
            guard let m = game.mission(missionID) else { continue }
            for ref in NCBTest(m.availBits).referencedBits where !ref.negated {
                let sources = (setters[ref.bit] ?? []).filter { $0.kind == .mission }
                for src in sources.prefix(3) {
                    guard src.id != m.id, onMap.contains(src.id),
                          !startPairs.contains("\(src.id)-\(m.id)") else { continue }
                    let e = StoryMapEdge(from: src.id, to: m.id, kind: .unlocks)
                    edges[e.id] = e
                }
            }
        }

        var nodes: [StoryMapNode] = []
        for (laneIndex, line) in lines.enumerated() {
            for (rowIndex, step) in line.steps.enumerated() {
                nodes.append(StoryMapNode(step: step, storylineKey: line.key,
                                          laneIndex: laneIndex, rowIndex: rowIndex,
                                          deadEndOutcomes: deadEnds[step.missionID] ?? []))
            }
        }

        return StoryMap(lanes: lanes, nodes: nodes,
                        edges: Array(edges.values), untaggedCount: untaggedMissionCount)
    }

    // MARK: Branch parsing helpers

    /// Every `.startMission` target in `ops`, recursively unwrapping
    /// `.random` choices (each choice may itself contain a `.startMission`),
    /// noting whether the target came from inside one of those 50/50 picks.
    private static func flattenStartMissions(_ ops: [NCBSetOp], random: Bool = false) -> [(target: Int, isRandom: Bool)] {
        var out: [(target: Int, isRandom: Bool)] = []
        for op in ops {
            switch op {
            case .startMission(let target): out.append((target, random))
            case .random(let inner): out.append(contentsOf: flattenStartMissions(inner, random: true))
            default: break
            }
        }
        return out
    }

    /// True if `ops` (recursively through `.random`) contains an
    /// `.abortMission`/`.failMission` op — an explicit "the story ends here"
    /// signal for that outcome, even when a *different* random branch of the
    /// same script also starts a follow-up mission.
    private static func hasDeadEnd(_ ops: [NCBSetOp]) -> Bool {
        for op in ops {
            switch op {
            case .abortMission, .failMission: return true
            case .random(let inner): if hasDeadEnd(inner) { return true }
            default: break
            }
        }
        return false
    }

    /// The most frequent value in `values` (ties broken by first
    /// appearance), or `nil` for an empty input — used to pick a
    /// storyline's representative government/plug-in across its steps.
    fileprivate static func mode<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        var order: [T] = []
        for v in values {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        var best = order[0]
        var bestCount = counts[best] ?? 0
        for v in order.dropFirst() where (counts[v] ?? 0) > bestCount {
            best = v; bestCount = counts[v] ?? 0
        }
        return best
    }

    // MARK: Step construction

    private func makeStep(_ m: MissionRes, player: PlayerState, engine: StoryEngine) -> StorylineStep {
        let status = statusOf(m, player: player, engine: engine)
        let blockers = status == .locked ? blockingBits(for: m, player: player) : []
        return StorylineStep(
            missionID: m.id,
            displayName: cleanName(m.name),
            stepNumber: storyTag(m.name).step,
            status: status,
            offeredAt: describeOffer(m),
            objective: describeObjective(m),
            reward: describeReward(m),
            blockers: blockers,
            synopsis: briefingText(for: m),
            governmentID: m.compRewardGovt >= 128 ? m.compRewardGovt : nil)
    }

    private func statusOf(_ m: MissionRes, player: PlayerState, engine: StoryEngine) -> MissionStatus {
        if player.completedMissions.contains(m.id) { return .completed }
        if player.isMissionActive(m.id) { return .active }
        // Eligible = gate passes and record/rating met (ignore offer location so
        // the guide can say "available — go here"); random chance excluded.
        if player.combatRating >= m.availRating,
           NCBTest(m.availBits).evaluate(player) {
            return .available
        }
        return .locked
    }

    /// The referenced bits whose current value blocks the gate, each annotated
    /// with what would flip it. Heuristic but accurate for the conjunctive gates
    /// that storyline steps use.
    private func blockingBits(for m: MissionRes, player: PlayerState) -> [BlockingBit] {
        var seen = Set<Int>()
        var out: [BlockingBit] = []
        for ref in NCBTest(m.availBits).referencedBits {
            let currentlySet = player.isBitSet(ref.bit)
            // Wrong polarity → this bit is (part of) what's blocking.
            let blocking = ref.negated ? currentlySet : !currentlySet
            guard blocking, seen.insert(ref.bit).inserted else { continue }
            let needsSet = !ref.negated
            let sources = (needsSet ? setters[ref.bit] : clearers[ref.bit]) ?? []
            // Don't point at the mission itself or already-done sources uselessly.
            let useful = sources.filter { !($0.kind == .mission && $0.id == m.id) }
            out.append(BlockingBit(bit: ref.bit, needsSet: needsSet,
                                   unlockedBy: Array(useful.prefix(4))))
        }
        return out
    }

    // MARK: Bit-source index

    private func indexBitSources() {
        func add(_ expr: String, _ src: UnlockSource) {
            for op in NCBSet.parse(expr) {
                switch op {
                case .setBit(let n): setters[n, default: []].append(src)
                case .clearBit(let n): clearers[n, default: []].append(src)
                case .toggleBit(let n):
                    setters[n, default: []].append(src); clearers[n, default: []].append(src)
                default: break
                }
            }
        }
        for m in game.missions() {
            let src = UnlockSource(kind: .mission, id: m.id, name: cleanName(m.name),
                                   hint: "Complete “\(cleanName(m.name))”")
            add(m.onSuccess, src)
            add(m.onShipDone, src)
            add(m.onAccept, UnlockSource(kind: .mission, id: m.id, name: cleanName(m.name),
                                         hint: "Accept “\(cleanName(m.name))”"))
        }
        for c in game.crons() {
            let src = UnlockSource(kind: .cron, id: c.id, name: c.name.isEmpty ? "event #\(c.id)" : c.name,
                                   hint: "a background event\(c.name.isEmpty ? "" : " (\(c.name))")")
            add(c.onStart, src)
            add(c.onEnd, src)
        }
    }

    // MARK: Storyline grouping (by the "; NameN" tag EV Nova uses)

    private func groupedByStoryline() -> [String: [MissionRes]] {
        var groups: [String: [MissionRes]] = [:]
        for m in game.missions() {
            if let key = storyTag(m.name).key {
                groups[key, default: []].append(m)
            }
        }
        // Only keep real campaigns (2+ tagged steps); single tags are one-offs.
        return groups.filter { $0.value.count >= 2 }
    }

    /// Parse EV Nova's "Visible Name; TagN" convention → (storyline key, step).
    /// e.g. "Return to Earth for Training; Vellos3" → ("Vellos", 3).
    private func storyTag(_ name: String) -> (key: String?, step: Int) {
        guard let semi = name.lastIndex(of: ";") else { return (nil, 0) }
        let tag = name[name.index(after: semi)...].trimmingCharacters(in: .whitespaces)
        // Split trailing digits off the tag.
        let chars = Array(tag)
        var i = chars.count
        while i > 0, chars[i - 1].isNumber { i -= 1 }
        guard i < chars.count, i > 0 else { return (nil, 0) }
        let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
        let step = Int(String(chars[i...])) ?? 0
        return key.isEmpty ? (nil, 0) : (key, step)
    }

    private func cleanName(_ name: String) -> String { name.novaDisplayName }

    // MARK: Human-readable field descriptions

    private func describeOffer(_ m: MissionRes) -> String {
        let loc: String
        switch m.availLocation {
        case .missionComputer: loc = "Mission Computer"
        case .bar: loc = "Spaceport Bar"
        case .persShip: loc = "hailing a ship"
        case .mainSpaceport: loc = "Spaceport"
        case .tradeCenter: loc = "Trade Center"
        case .shipyard: loc = "Shipyard"
        case .outfitter: loc = "Outfitter"
        case .unknown: loc = "somewhere"
        }
        return "\(loc) at \(describeStellar(m.availStellar))"
    }

    private func describeObjective(_ m: MissionRes) -> String {
        var parts: [String] = []
        if m.cargoQty != 0 {
            let where_ = m.cargoDropoff == .atReturnStellar ? describeStellar(m.returnStellar)
                                                            : describeStellar(m.travelStellar)
            parts.append("Deliver \(abs(m.cargoQty))t of cargo to \(where_)")
        } else if m.travelStellar != -1 {
            parts.append("Travel to \(describeStellar(m.travelStellar))")
        }
        if m.hasShipObjective {
            let verb: String
            switch m.shipGoal {
            case .destroy: verb = "Destroy"
            case .disable: verb = "Disable"
            case .board: verb = "Board"
            case .escort: verb = "Escort"
            case .observe: verb = "Observe"
            case .rescue: verb = "Rescue"
            case .chaseOff: verb = "Drive off"
            case .none: verb = "Deal with"
            }
            parts.append("\(verb) \(m.shipCount) ship\(m.shipCount == 1 ? "" : "s")")
        }
        if parts.isEmpty, m.returnStellar >= 128 {
            parts.append("Report to \(describeStellar(m.returnStellar))")
        }
        return parts.isEmpty ? "See mission briefing" : parts.joined(separator: ", then ")
    }

    private func describeReward(_ m: MissionRes) -> String {
        var parts: [String] = []
        if m.pay > 0 { parts.append("\(formatted(m.pay)) cr") }
        else if m.pay < 0 { parts.append("costs \(formatted(-m.pay)) cr") }
        if m.compRewardGovt >= 128 {
            let g = game.govt(m.compRewardGovt)?.name ?? "govt #\(m.compRewardGovt)"
            parts.append("\(m.compLegalReward >= 0 ? "+" : "")standing with \(g)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func describeStellar(_ code: Int) -> String {
        switch code {
        case -1: return "any inhabited world"
        case -2: return "an inhabited world"
        case -3: return "an uninhabited world"
        case -4: return "the starting world"
        case 128...2175: return game.spob(code)?.name ?? "planet #\(code)"
        case 9999: return "an independent world"
        default:
            if code >= 10128, code <= 10255 {
                return "a \(game.govt(code - 10000)?.name ?? "govt")-controlled world"
            }
            return "a designated world"
        }
    }

    private func briefingText(for m: MissionRes) -> String {
        if m.briefText >= 128 {
            let t = game.descText(m.briefText)
            if !t.isEmpty { return t }
        }
        return game.descText(m.offerTextID)
    }

    private func formatted(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
