import Foundation
import EVNovaKit

/// Turns a `chär` starting scenario into a fresh `PlayerState` — the authentic
/// EV Nova "new pilot" bootstrap: pick a random start system, seed cash / ship /
/// combat rating / calendar date, apply the scenario's initial legal standings,
/// and run its OnStart control-bit script through the real NCB SET executor so
/// story bits, granted outfits and starting missions all fire exactly as they do
/// in the game.
public enum PilotFactory {

    /// Build a new pilot for `scenario`.
    ///
    /// - Parameters:
    ///   - name: the pilot's name.
    ///   - isMale: pilot gender (drives gendered story text / NCB `p` operand).
    ///   - scenario: the chosen `chär`.
    ///   - game: the loaded game data (for ship names, govt relations, OnStart).
    ///   - seed: RNG seed for the random start-system pick. Pass an explicit value
    ///     for reproducibility (tests); leave `nil` — the production default — to
    ///     seed from the system RNG so each new pilot genuinely rolls its own start
    ///     system among the scenario's candidates, exactly as EV Nova does. A fixed
    ///     default would make every pilot start in the same system.
    public static func make(name: String, isMale: Bool, scenario: CharRes,
                            game: NovaGame, seed: UInt64? = nil) -> PlayerState {
        Log.pilot.notice("PilotFactory.make: creating pilot \"\(name, privacy: .public)\" from scenario \(scenario.id) (\"\(scenario.displayName, privacy: .public)\")")
        let resolvedSeed = seed ?? UInt64.random(in: .min ... .max)
        var rng = StoryRNG(seed: resolvedSeed)

        // Random start system among the scenario's candidates; sensible fallback.
        let system: Int
        if !scenario.startSystems.isEmpty {
            system = scenario.startSystems[rng.int(scenario.startSystems.count)]
        } else if let fallback = game.startingSystem()?.id {
            system = fallback
        } else {
            Log.pilot.error("PilotFactory.make: scenario \(scenario.id) has no start systems and game data has no starting system; falling back to hardcoded system 128")
            system = 128
        }

        // Ship + its display name.
        let shipID: Int
        if scenario.shipID >= 128 {
            shipID = scenario.shipID
        } else if let fallback = game.ships().first?.id {
            Log.pilot.error("PilotFactory.make: scenario \(scenario.id) has invalid shipID \(scenario.shipID); falling back to first available ship \(fallback)")
            shipID = fallback
        } else {
            Log.pilot.error("PilotFactory.make: scenario \(scenario.id) has invalid shipID \(scenario.shipID) and game data has no ships; falling back to hardcoded ship 128")
            shipID = 128
        }
        let shipName = game.ship(shipID)?.name ?? ""

        // Calendar date (guard against empty/invalid scenario dates).
        let date: GameDate
        if scenario.startYear > 0 {
            date = GameDate(day: max(1, min(31, scenario.startDay)),
                            month: max(1, min(12, scenario.startMonth)),
                            year: scenario.startYear)
        } else {
            date = .defaultStart
        }

        var player = PlayerState(pilotName: name.isEmpty ? "Captain" : name,
                                 isMale: isMale,
                                 shipType: shipID,
                                 shipName: shipName,
                                 credits: scenario.cash,
                                 currentSystem: system,
                                 date: date)
        player.combatRating = scenario.kills
        player.legalRecord = initialLegalRecord(scenario: scenario, game: game)

        // Apply the OnStart NCB via a throwaway StoryEngine so the exact same SET
        // grammar/side-effects (bits, ranks, outfits, missions, ship swap) run.
        if !scenario.onStart.isEmpty {
            let engine = StoryEngine(game: game, player: player, seed: resolvedSeed)
            engine.apply(set: scenario.onStart)
            player = engine.player
        }
        Log.pilot.debug("PilotFactory.make: pilot \"\(name, privacy: .public)\" started at system \(system) with ship \(shipID), credits=\(player.credits)")
        return player
    }

    /// Convenience: the default new pilot for this data set (first selectable
    /// scenario, else the lowest-id `chär`, else engine defaults).
    public static func makeDefault(name: String, isMale: Bool, game: NovaGame,
                                   seed: UInt64? = nil) -> PlayerState {
        let scenario = game.selectableScenarios().first ?? game.startingChar()
        if let scenario {
            return make(name: name, isMale: isMale, scenario: scenario, game: game, seed: seed)
        }
        // No scenario in the data at all: a bare Shuttle start.
        Log.pilot.error("PilotFactory.makeDefault: no chär scenario found in game data; falling back to bare Shuttle start")
        let shipID = game.ships().first?.id ?? 128
        return PlayerState(pilotName: name.isEmpty ? "Captain" : name, isMale: isMale,
                           shipType: shipID, shipName: game.ship(shipID)?.name ?? "",
                           credits: 0, currentSystem: game.startingSystem()?.id ?? 128)
    }

    /// The scenario's initial per-govt legal standings. The status is applied to
    /// the named government, and its negation to that govt's enemies (govts whose
    /// class membership intersects the named govt's `enemies` classes) — matching
    /// the `chär` template's "applies negative value to govt's enemies" note.
    private static func initialLegalRecord(scenario: CharRes, game: NovaGame) -> [Int: Int] {
        guard !scenario.govtStatuses.isEmpty else { return [:] }
        let allGovts = game.govts()
        var record: [Int: Int] = [:]
        for gs in scenario.govtStatuses {
            record[gs.govt, default: 0] += gs.status
            guard let govt = game.govt(gs.govt), !govt.enemies.isEmpty else { continue }
            let enemyClasses = Set(govt.enemies)
            for other in allGovts where other.id != gs.govt {
                if !enemyClasses.isDisjoint(with: other.classes) {
                    record[other.id, default: 0] -= gs.status
                }
            }
        }
        return record
    }
}
