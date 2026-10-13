import Foundation
import NovaSwiftKit

/// The frontend-independent half of the pilot roster: creating a save from a
/// `chär` scenario, writing the live pilot back to its `.evpilot`, and
/// preparing a loaded save for play. Extracted from the Apple-only
/// `PilotRoster` / `AppModel.play` / `PilotStore.migrateIfNeeded` (the way
/// `PilotEconomy` was lifted out of `PilotStore`) so the Godot bridge writes and
/// reads the exact same files with the exact same repair rules, instead of
/// reimplementing them. The Apple types now call through here.
public enum PilotSaves {

    /// A coarse fingerprint of the loaded data set, so a save records which data
    /// produced it (a full-parity check is a later concern).
    public static func fingerprint(for game: NovaGame) -> String {
        "ships:\(game.ships().count) syst:\(game.systems().count) char:\(game.characters().count)"
    }

    /// Build (but do not write) the save for a brand-new pilot.
    public static func makeNew(name: String, isMale: Bool, strictPlay: Bool = false,
                               scenario: CharRes, game: NovaGame,
                               nickname: String = "", shipName: String? = nil) -> PilotSave {
        var player = PilotFactory.make(name: name, isMale: isMale, scenario: scenario, game: game,
                                       nickname: nickname, shipName: shipName)
        player.strictPlay = strictPlay
        return PilotSave(displayName: name.isEmpty ? "Captain" : name,
                         scenarioName: scenario.displayName,
                         player: player, game: game,
                         dataFingerprint: fingerprint(for: game))
    }

    /// Write the live pilot state into the durable save `id`. Prefers to update
    /// the on-disk save so its metadata (name, createdAt, scenario, group) is
    /// kept; if it can't be loaded, reconstructs a fresh save under the same id
    /// so the session's progress is never dropped. Returns whether it was written.
    @discardableResult
    public static func persist(archive: PilotArchive, id: UUID, state: PlayerState,
                               game: NovaGame?, backup: Bool) -> Bool {
        var save: PilotSave
        if let existing = try? archive.load(id: id) {
            save = existing
            save.player = state
        } else {
            Log.pilot.error("PilotSaves.persist: pilot \(id, privacy: .public) not loadable; reconstructing from live state so progress isn't lost")
            save = PilotSave(id: id,
                             displayName: state.pilotName.isEmpty ? "Captain" : state.pilotName,
                             scenarioName: "", player: state, game: game,
                             dataFingerprint: game.map(fingerprint(for:)) ?? "")
        }
        save.refreshSnapshot(game: game)
        do {
            _ = try archive.save(save, backup: backup)
            return true
        } catch {
            Log.pilot.error("PilotSaves.persist: failed to save pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Prepare a save read from disk for play, as `AppModel.play` does: full
    /// shield/armor with gone plug-in data pruned (UI-03), explored nebulae's
    /// region events re-run, then `migrate`. `repaired` is true when missing
    /// data had to be dropped (the original warns with STR# 140 #52).
    public static func prepareForPlay(_ save: PilotSave, game: NovaGame)
        -> (state: PlayerState, repaired: Bool) {
        var state = save.player
        let repaired = state.normalizeForLoad(outfitExists: { game.outfit($0) != nil },
                                              junkExists: { game.junk($0) != nil },
                                              shipExists: { game.ship($0) != nil },
                                              fallbackShipID: game.ships().first?.id)
        let engine = StoryEngine(game: game, player: state)
        engine.pilotOpened()
        state = engine.player
        _ = migrate(&state, game: game)
        return (state, repaired)
    }

    /// Bring a save written by an older build up to the current `PlayerState`
    /// contract (see `PilotStore.migrateIfNeeded`): per-system reputation seeded
    /// from the old legal record, hull fittings topped up into `outfits`, and the
    /// twin-system bookkeeping the original's pilot load runs. Returns true when
    /// anything changed (the caller then saves).
    @discardableResult
    public static func migrate(_ state: inout PlayerState, game: NovaGame) -> Bool {
        let reputationMigrated = state.migrateLegalRecordIfNeeded(game: game)
        let fittingsMigrated = PilotEconomy.migrateHullFittings(&state, game: game)
        let story = StoryEngine(game: game, player: state)
        story.refreshSystemState()
        let systemMigrated = story.player.currentSystem != state.currentSystem
            || story.player.exploredSystems != state.exploredSystems
            || story.player.landedSystems != state.landedSystems
            || story.player.chartedSystems != state.chartedSystems
        if systemMigrated { state = story.player }
        return reputationMigrated || fittingsMigrated || systemMigrated
    }
}
