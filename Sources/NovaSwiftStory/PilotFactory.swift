import Foundation
import NovaSwiftKit

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
                                 credits: max(0, scenario.cash),
                                 currentSystem: system,
                                 date: date)
        player.combatRating = scenario.kills
        player.systemReputation = initialReputation(scenario: scenario, game: game)
        player.datePrefix = scenario.datePrefix
        player.dateSuffix = scenario.dateSuffix

        // Everything the starting hull comes with becomes *owned* outfits, the
        // same way `PilotEconomy.buyShip` grants a purchased hull's: its
        // `DefaultItems`, and its stock `WeapType` armament materialised into the
        // outfits that install it (see `PilotEconomy.hullFittings`). Without this
        // a brand-new pilot flew a Shuttle whose Light Blaster existed only inside
        // `Galaxy.loadout` — the outfitter showed no quantity badge for it, Sell
        // stayed greyed out, and the ship could never be stripped down, only added
        // to. The Shuttle in particular has *no* DefaultItems at all; its blaster
        // is purely a `WeapType`, which is why covering only DefaultItems left the
        // most-reported case still broken.
        if let hull = game.ship(shipID) {
            PilotEconomy.grantHullFittings(&player, ship: hull, game: game)
        }

        // `spöb.Flags2` 0x0040 ("Starts destroyed"): some stellars begin every new
        // game already blown up, to be revealed later by a storyline (or by their
        // own `DeadTime` timer). Seeded here rather than at load so it applies
        // once, to a fresh pilot, and can then be undone normally by a `U` op.
        // No base-game stellar sets this bit, so stock scenarios seed nothing.
        let preDestroyed = game.spobs().filter(\.startsDestroyed).map(\.id)
        if !preDestroyed.isEmpty {
            player.destroyedStellars = Set(preDestroyed)
            Log.pilot.notice("PilotFactory.make: \(preDestroyed.count) stellar(s) start destroyed")
        }

        // Apply the OnStart NCB via a throwaway StoryEngine so the exact same SET
        // grammar/side-effects (bits, ranks, outfits, missions, ship swap) run.
        // The same engine then books the start system and every visible system
        // one jump from it as explored (UI-04) and draws the first mission-offer
        // rolls, as the original's new game does.
        let engine = StoryEngine(game: game, player: player, seed: resolvedSeed)
        if !scenario.onStart.isEmpty {
            engine.apply(set: scenario.onStart,
                         source: "chär \(scenario.id) \"\(scenario.name)\" OnStart")
        }
        if let start = game.system(engine.player.currentSystem) {
            for link in start.links where link >= 128 && engine.isSystemVisible(link) {
                engine.player.exploredSystems.insert(link)
            }
        }
        engine.rerollMissionOffers()
        player = engine.player

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

    /// The new pilot's per-system reputations (EC-02): every system starts at
    /// its owner's `gövt` InitialRec (0 if negative or independent), then each
    /// `chär` government status overwrites the systems of that government's
    /// allies with `status` and those of its enemies (and xenophobes) with
    /// `−status` — see `SystemReputation.initial`.
    private static func initialReputation(scenario: CharRes, game: NovaGame) -> [Int: Int] {
        SystemReputation.initial(statuses: scenario.govtStatuses.map { ($0.govt, $0.status) },
                                 govts: game.govtTable(), map: game.reputationMap())
    }
}
