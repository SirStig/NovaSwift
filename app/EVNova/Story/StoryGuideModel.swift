import Foundation
import SwiftUI
import EVNovaKit
import EVNovaStory

// View-model backing the in-game Pilot window + aftermarket Story Guide. It turns
// the story engine's state into display-ready values, and offers a `.sample`
// factory so the SwiftUI views render in Xcode Previews without loading any
// (copyrighted) game data.

/// A view-friendly snapshot of the pilot for the Pilot window.
struct PilotSummary {
    var name: String
    var credits: Int
    var combatRating: Int
    var shipName: String
    var currentSystem: String
    var date: String
    var ranks: [String]
    var relations: [Relation]
    var activeMissions: [MissionBrief]

    struct Relation: Identifiable { let id = UUID(); let govt: String; let standing: Int }
    struct MissionBrief: Identifiable { let id: Int; let name: String; let objective: String; let reward: String }
}

@MainActor
final class StoryGuideModel: ObservableObject {
    @Published private(set) var storylines: [Storyline] = []
    @Published private(set) var pilot: PilotSummary
    @Published private(set) var untaggedCount: Int = 0

    private let game: NovaGame?
    private var player: PlayerState
    private let analyzer: StorylineAnalyzer?

    /// Build from a live game + pilot.
    init(game: NovaGame, player: PlayerState) {
        self.game = game
        self.player = player
        self.analyzer = StorylineAnalyzer(game: game)
        self.pilot = PilotSummary(name: player.pilotName, credits: player.credits,
                                  combatRating: player.combatRating, shipName: "", currentSystem: "",
                                  date: player.date.description, ranks: [], relations: [], activeMissions: [])
        refresh()
    }

    /// Sample data for previews / when no game is loaded.
    private init(sample: Bool) {
        self.game = nil
        self.player = PlayerState()
        self.analyzer = nil
        self.pilot = StoryGuideModel.samplePilot
        self.storylines = StoryGuideModel.sampleStorylines
        self.untaggedCount = 537
    }

    static var sample: StoryGuideModel { StoryGuideModel(sample: true) }

    /// Recompute everything from the current player state (call after the game
    /// mutates the pilot).
    func update(player: PlayerState) { self.player = player; refresh() }

    private func refresh() {
        guard let game, let analyzer else { return }
        storylines = analyzer.storylines(for: player)
        untaggedCount = analyzer.untaggedMissionCount

        let ranks = player.activeRanks.compactMap { game.rank($0)?.conversationName }
            .filter { !$0.isEmpty }.sorted()
        let relations = player.legalRecord
            .filter { $0.value != 0 }
            .map { PilotSummary.Relation(govt: game.govt($0.key)?.name ?? "Govt #\($0.key)", standing: $0.value) }
            .sorted { abs($0.standing) > abs($1.standing) }
        let active = player.activeMissions.compactMap { am -> PilotSummary.MissionBrief? in
            guard let s = analyzer.brief(forMission: am.missionID, player: player) else { return nil }
            return PilotSummary.MissionBrief(id: am.missionID, name: s.displayName,
                                             objective: s.objective, reward: s.reward)
        }
        pilot = PilotSummary(
            name: player.pilotName,
            credits: player.credits,
            combatRating: player.combatRating,
            shipName: game.ship(player.shipType)?.name ?? "Unknown ship",
            currentSystem: game.system(player.currentSystem)?.name ?? "—",
            date: player.date.description,
            ranks: ranks,
            relations: relations,
            activeMissions: active)
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
                         obj: "Deliver 5t of cargo to Earth", reward: "15,000 cr"),
                    step(129, "Visit Vell-os Homeworld", 2, .active,
                         obj: "Travel to Kania", reward: "8,000 cr"),
                    step(130, "Return to Earth for Training", 3, .locked,
                         obj: "Report to Earth", reward: "—",
                         blockers: [BlockingBit(bit: 351, needsSet: true, unlockedBy: [
                            UnlockSource(kind: .mission, id: 129, name: "Visit Vell-os Homeworld",
                                         hint: "Complete “Visit Vell-os Homeworld”")])]),
                    step(131, "Infiltrate the Rebels", 4, .locked,
                         obj: "Travel to Rebel space", reward: "20,000 cr")],
                  completedCount: 1, totalCount: 4, currentStepID: 129),
        Storyline(key: "Federation", title: "Federation",
                  steps: [
                    step(428, "Federation Resupply", 1, .available,
                         obj: "Deliver 20t of cargo to Levo", reward: "12,000 cr · +standing with Federation"),
                    step(429, "Patrol the Frontier", 2, .locked,
                         obj: "Destroy 3 ships", reward: "30,000 cr")],
                  completedCount: 0, totalCount: 2, currentStepID: 428)]

    private static func step(_ id: Int, _ name: String, _ n: Int, _ status: MissionStatus,
                             obj: String, reward: String, blockers: [BlockingBit] = []) -> StorylineStep {
        StorylineStep(missionID: id, displayName: name, stepNumber: n, status: status,
                      offeredAt: "Mission Computer", objective: obj, reward: reward,
                      blockers: blockers, synopsis: "")
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
