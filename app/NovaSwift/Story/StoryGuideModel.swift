import Foundation
import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

// View-model backing the in-game Story Guide. It turns the story engine's
// reconstructed campaign graph into display-ready values for the unified flow
// UI, builds that graph *off the main thread* (the fix for the iPhone stall/
// crash on open), and memoizes each storyline's linearized flow so switching
// campaigns and scrolling never recompute anything. A `.sample` factory lets the
// SwiftUI views render in Xcode Previews without loading any (copyrighted) data.

/// A view-friendly snapshot of the pilot (kept for the guide's header + any
/// caller that wants pilot context; the authentic 4-tab pilot dialog owns the
/// full dossier).
struct PilotSummary: Sendable {
    var name: String
    var credits: Int
    var combatRating: Int
    var shipName: String
    var currentSystem: String
    var date: String
    var ranks: [String]
    var relations: [Relation]
    var activeMissions: [MissionBrief]

    struct Relation: Identifiable, Sendable { let id = UUID(); let govt: String; let standing: Int }
    struct MissionBrief: Identifiable, Sendable {
        let id: Int; let name: String; let objective: String; let reward: String
        var canAbort: Bool = true
    }

    static let empty = PilotSummary(name: "", credits: 0, combatRating: 0, shipName: "",
                                    currentSystem: "", date: "", ranks: [], relations: [],
                                    activeMissions: [])
}

/// Carries the results of one background build back to the main actor.
private struct StoryBuild: Sendable {
    let map: StoryMap
    let pilot: PilotSummary
}

/// Wraps a non-`Sendable` value for a hop across an actor boundary. Used only
/// for `NovaGame` (a struct whose one reference member is an internally
/// lock-guarded cache — the same object the sprite pipeline already touches off
/// the main thread) and the `StorylineAnalyzer` we build from it and reuse.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Holds the analyzer so the (one-time, expensive) bit-source indexing is paid
/// once and reused across refreshes, while still living entirely off the main
/// actor. `@unchecked` because `StorylineAnalyzer` isn't `Sendable`; it's only
/// ever touched inside the detached build task, never concurrently.
private final class AnalyzerHolder: @unchecked Sendable {
    let analyzer: StorylineAnalyzer
    init(game: NovaGame) { analyzer = StorylineAnalyzer(game: game) }
}

@MainActor
final class StoryGuideModel: ObservableObject {
    /// The reconstructed campaign graph for the current pilot. Empty until the
    /// first background build lands (see `isLoading`).
    @Published private(set) var storyMap: StoryMap = StoryMap(lanes: [], nodes: [], edges: [], untaggedCount: 0)
    @Published private(set) var pilot: PilotSummary = .empty
    /// True while a background build is in flight — drives the loading state so
    /// opening the guide never blocks the main thread.
    @Published private(set) var isLoading: Bool = false
    /// Government colors, built once (they don't depend on pilot state).
    @Published private(set) var governmentPalette: GovernmentPalette?

    private let game: NovaGame?
    private let gameBox: UncheckedBox<NovaGame>?
    private var player: PlayerState
    private var analyzerHolder: AnalyzerHolder?
    /// Bumped on every refresh so a stale background build (superseded by a
    /// newer one) can't clobber fresher results when it finally returns.
    private var buildToken = 0
    private let plugins: [PluginBundle]

    // MARK: Memoized per-storyline flow
    //
    // The linearized flow + cross-links for a storyline are pure functions of
    // the (immutable, per-build) `storyMap`, so they're computed once on first
    // request and cached — scrolling and re-selecting never rebuild them.
    private var flowCache: [String: [StoryFlowRow]] = [:]
    private var crossLinkCache: [Int: [CrossLink]]?

    /// Build from a live game + pilot. Kicks off the first (background) build.
    init(game: NovaGame, player: PlayerState, plugins: [PluginBundle] = []) {
        self.game = game
        self.gameBox = UncheckedBox(game)
        self.player = player
        self.plugins = plugins
        self.governmentPalette = GovernmentPalette(game: game)
        rebuild()
    }

    /// Sample data for previews / when no game is loaded — built synchronously
    /// from a synthesized map, no background work.
    private init(sample: Bool) {
        self.game = nil
        self.gameBox = nil
        self.player = PlayerState()
        self.plugins = []
        self.governmentPalette = nil
        self.pilot = StoryGuideModel.samplePilot
        self.storyMap = StoryGuideModel.synthesizeMap(from: StoryGuideModel.sampleStorylines,
                                                      untagged: 537)
        self.isLoading = false
    }

    static var sample: StoryGuideModel { StoryGuideModel(sample: true) }

    // MARK: Refresh

    /// Recompute everything from a new pilot state (call after the game mutates
    /// the pilot). Runs off the main thread; the UI shows its loading state
    /// until the fresh graph lands.
    func update(player: PlayerState) { self.player = player; rebuild() }

    /// Launch a background build of the campaign graph. The heavy work —
    /// analyzer indexing and script parsing — runs on a detached task; only the
    /// finished (`Sendable`) results cross back to the main actor.
    private func rebuild() {
        guard let gameBox else { return }   // sample model has no game
        buildToken += 1
        let token = buildToken
        isLoading = true
        let existing = analyzerHolder
        let p = player

        Task { [weak self] in
            let (holder, build) = await Task.detached(priority: .userInitiated) { () -> (AnalyzerHolder, StoryBuild) in
                let holder = existing ?? AnalyzerHolder(game: gameBox.value)
                let analyzer = holder.analyzer
                let map = analyzer.storyMap(for: p)
                let pilot = StoryGuideModel.buildPilotSummary(game: gameBox.value, analyzer: analyzer, player: p)
                return (holder, StoryBuild(map: map, pilot: pilot))
            }.value

            guard let self, token == self.buildToken else { return }   // superseded — drop
            self.analyzerHolder = holder
            self.storyMap = build.map
            self.pilot = build.pilot
            self.flowCache.removeAll()
            self.crossLinkCache = nil
            self.isLoading = false
        }
    }

    // MARK: Flow (memoized)

    /// The linearized vertical flow for one storyline, built once and cached.
    func flow(for key: String) -> [StoryFlowRow] {
        if let cached = flowCache[key] { return cached }
        let nodes = storyMap.nodes.filter { $0.storylineKey == key }
        let ids = Set(nodes.map(\.id))
        let internalEdges = storyMap.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        let rows = buildStoryFlow(nodes: nodes, edges: internalEdges,
                                  crossLinks: crossLinks(), currentID: currentStepID(in: nodes))
        flowCache[key] = rows
        return rows
    }

    /// The "you are here" step for a lane: its first not-completed step in
    /// authored order (nil once the campaign is finished).
    func currentStepID(forKey key: String) -> Int? {
        currentStepID(in: storyMap.nodes.filter { $0.storylineKey == key })
    }

    private func currentStepID(in nodes: [StoryMapNode]) -> Int? {
        nodes.filter { $0.step.status != .completed }
            .min(by: { $0.rowIndex < $1.rowIndex })?.id
    }

    /// Cross-campaign links per node id, computed once over the whole map.
    private func crossLinks() -> [Int: [CrossLink]] {
        if let cached = crossLinkCache { return cached }
        let byID = Dictionary(storyMap.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Int: [CrossLink]] = [:]
        for edge in storyMap.edges {
            guard let from = byID[edge.from], let to = byID[edge.to],
                  from.storylineKey != to.storylineKey else { continue }
            out[from.id, default: []].append(CrossLink(key: to.storylineKey, outgoing: true))
            out[to.id, default: []].append(CrossLink(key: from.storylineKey, outgoing: false))
        }
        crossLinkCache = out
        return out
    }

    // MARK: Display helpers

    /// Display name for a `StoryMapLane.pluginID` — `""` is the base game; an
    /// unrecognized id falls back to the raw id (still its plug-in folder name).
    func pluginLabel(_ id: String) -> String {
        id.isEmpty ? "Base Game" : (plugins.first { $0.id == id }?.name ?? id)
    }

    /// A lane/step's government color, or the shared neutral gray.
    func governmentColor(_ governmentID: Int?) -> Color {
        guard let governmentID else { return GovernmentPalette.independent }
        return governmentPalette?.color(for: governmentID) ?? GovernmentPalette.independent
    }

    func governmentName(_ governmentID: Int?) -> String? {
        guard let governmentID else { return nil }
        return game?.govt(governmentID)?.name
    }

    // MARK: Pilot summary (built in the background)

    private nonisolated static func buildPilotSummary(game: NovaGame, analyzer: StorylineAnalyzer,
                                                      player: PlayerState) -> PilotSummary {
        let ranks = player.activeRanks.compactMap { game.rank($0)?.conversationName }
            .filter { !$0.isEmpty }.sorted()
        let relations = player.legalRecord
            .filter { $0.value != 0 }
            .map { PilotSummary.Relation(govt: game.govt($0.key)?.name ?? "Govt #\($0.key)", standing: $0.value) }
            .sorted { abs($0.standing) > abs($1.standing) }
        let active = player.activeMissions.compactMap { am -> PilotSummary.MissionBrief? in
            guard let s = analyzer.brief(forMission: am.missionID, player: player) else { return nil }
            return PilotSummary.MissionBrief(id: am.missionID, name: s.displayName,
                                             objective: s.objective, reward: s.reward,
                                             canAbort: game.mission(am.missionID)?.canAbort ?? true)
        }
        return PilotSummary(
            name: player.pilotName, credits: player.credits, combatRating: player.combatRating,
            shipName: game.ship(player.shipType)?.name ?? "Unknown ship",
            currentSystem: game.system(player.currentSystem)?.name ?? "—",
            date: player.date.description, ranks: ranks, relations: relations, activeMissions: active)
    }

    // MARK: Sample content (previews)

    private static let samplePilot = PilotSummary(
        name: "Ari Vega", credits: 128_450, combatRating: 3, shipName: "IDA Frigate",
        currentSystem: "Sol", date: "12/03/1177",
        ranks: ["Federation Ensign", "Trader"],
        relations: [
            .init(govt: "Federation", standing: 250),
            .init(govt: "Auroran Empire", standing: -80),
            .init(govt: "Pirate", standing: -400)],
        activeMissions: [
            .init(id: 129, name: "Visit Vell-os Homeworld",
                  objective: "Travel to Kania", reward: "8,000 cr"),
            .init(id: 205, name: "Bounty: Renegade Pirate",
                  objective: "Destroy 1 ship", reward: "25,000 cr · +standing with Federation")])

    private static let sampleStorylines: [Storyline] = [
        Storyline(key: "Vellos", title: "Vellos",
                  steps: [
                    step(128, "Delivery to Earth", 1, .completed,
                         obj: "Deliver 5t of cargo to Earth", reward: "15,000 cr", govt: 128),
                    step(129, "Visit Vell-os Homeworld", 2, .active,
                         obj: "Travel to Kania", reward: "8,000 cr", govt: 128),
                    step(130, "Return to Earth for Training", 3, .locked,
                         obj: "Report to Earth", reward: "—",
                         blockers: [BlockingBit(bit: 351, needsSet: true, unlockedBy: [
                            UnlockSource(kind: .mission, id: 129, name: "Visit Vell-os Homeworld",
                                         hint: "Complete “Visit Vell-os Homeworld”")])], govt: 128),
                    step(131, "Infiltrate the Rebels", 4, .locked,
                         obj: "Travel to Rebel space", reward: "20,000 cr", govt: 128)],
                  completedCount: 1, totalCount: 4, currentStepID: 129,
                  governmentID: 128, pluginID: ""),
        Storyline(key: "Federation", title: "Federation",
                  steps: [
                    step(428, "Federation Resupply", 1, .available,
                         obj: "Deliver 20t of cargo to Levo", reward: "12,000 cr · +standing with Federation", govt: 128),
                    step(429, "Patrol the Frontier", 2, .locked,
                         obj: "Destroy 3 ships", reward: "30,000 cr", govt: 128)],
                  completedCount: 0, totalCount: 2, currentStepID: 428,
                  governmentID: 128, pluginID: "SamplePlugin")]

    /// Build a StoryMap from resolved storylines without a live analyzer — used
    /// for previews and the `.sample` model. Links consecutive steps with
    /// `.unlocks` edges (the campaign backbone).
    static func synthesizeMap(from lines: [Storyline], untagged: Int) -> StoryMap {
        var lanes: [StoryMapLane] = []
        var nodes: [StoryMapNode] = []
        var edges: [StoryMapEdge] = []
        for (laneIndex, line) in lines.enumerated() {
            lanes.append(StoryMapLane(key: line.key, title: line.title, index: laneIndex,
                                      completedCount: line.completedCount,
                                      totalCount: line.totalCount, isComplete: line.isComplete,
                                      governmentID: line.governmentID, pluginID: line.pluginID))
            for (rowIndex, s) in line.steps.enumerated() {
                nodes.append(StoryMapNode(step: s, storylineKey: line.key,
                                          laneIndex: laneIndex, rowIndex: rowIndex))
                if rowIndex > 0 {
                    edges.append(StoryMapEdge(from: line.steps[rowIndex - 1].missionID,
                                              to: s.missionID, kind: .unlocks))
                }
            }
        }
        return StoryMap(lanes: lanes, nodes: nodes, edges: edges, untaggedCount: untagged)
    }

    private static func step(_ id: Int, _ name: String, _ n: Int, _ status: MissionStatus,
                             obj: String, reward: String, blockers: [BlockingBit] = [],
                             govt: Int? = nil) -> StorylineStep {
        StorylineStep(missionID: id, displayName: name, stepNumber: n, status: status,
                      offeredAt: "Mission Computer", objective: obj, reward: reward,
                      blockers: blockers, synopsis: "", governmentID: govt)
    }
}

// MARK: Display helpers

extension MissionStatus {
    var symbolName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .active:    return "arrowtriangle.right.circle.fill"
        case .available: return "circle.circle"
        case .locked:    return "lock.fill"
        }
    }
    var tint: Color {
        switch self {
        case .completed: return .green
        case .active:    return .cyan
        case .available: return .yellow
        case .locked:    return .secondary
        }
    }
    var label: String {
        switch self {
        case .completed: return "Completed"
        case .active:    return "In progress"
        case .available: return "Available now"
        case .locked:    return "Locked"
        }
    }
}
