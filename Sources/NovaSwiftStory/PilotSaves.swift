import Foundation
import NovaSwiftKit
import NovaSwiftEngine

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

    /// Write `edit` into save `id` with `archive.save` (no backup rotation, same
    /// as a rename). A new name is copied onto the other slots of the pilot
    /// group so the roster and every slot agree. Returns "" when the file was
    /// written, or a sentence the pilot screen can show.
    public static func write(_ edit: PilotEdit, slot id: UUID, archive: PilotArchive, game: NovaGame) -> String {
        guard var save = try? archive.load(id: id) else { return "Could not open that pilot." }
        let previousPilotName = save.player.pilotName
        let previousDisplayName = save.displayName
        let message = apply(edit, to: &save, game: game)
        if !message.isEmpty { return message }
        do {
            _ = try archive.save(save, backup: false)
        } catch {
            Log.pilot.error("PilotSaves.write: failed to save pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return "Could not write the pilot file."
        }
        if save.player.pilotName != previousPilotName || save.displayName != previousDisplayName {
            let group = save.pilotGroupID
            let newName = save.player.pilotName
            for other in archive.list() where other.pilotGroupID == group && other.id != id {
                var sibling = other
                sibling.displayName = newName
                sibling.player.pilotName = newName
                sibling.refreshSnapshot(game: game)
                do {
                    _ = try archive.save(sibling, backup: false)
                } catch {
                    Log.pilot.error("PilotSaves.write: failed to rename slot \(sibling.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return ""
    }

    /// Copy `edit` onto `save` and refresh the list snapshot. Does not write
    /// the file. Returns "" when the save was changed, or a sentence when the
    /// edit is refused. Fields this does not mention are left as they were.
    public static func apply(_ edit: PilotEdit, to save: inout PilotSave, game: NovaGame) -> String {
        let name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = edit.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let shipName = edit.shipName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > PilotFactory.maxNameLength {
            return "The name has to be 1-\(PilotFactory.maxNameLength) characters."
        }
        if nickname.count > PilotFactory.maxNameLength {
            return "The nickname has to be \(PilotFactory.maxNameLength) characters or shorter."
        }
        if shipName.utf8.count > PilotEdit.maxShipNameUTF8 && shipName != save.player.shipName {
            return "The ship name has to be \(PilotEdit.maxShipNameUTF8) characters or shorter."
        }
        if edit.shipType != save.player.shipType, game.ship(edit.shipType) == nil {
            return "That ship isn't in the loaded game data."
        }
        save.displayName = name
        save.player.pilotName = name
        save.player.nickname = nickname.isEmpty ? nil : nickname
        save.player.isMale = edit.isMale
        save.player.strictPlay = edit.strictPlay
        if edit.shipType != save.player.shipType, let hull = game.ship(edit.shipType) {
            // A hull swap is more than a type id: the same handover `PilotEconomy.buyShip`
            // does (keep only oütf Flags 0x0004 items, grant the new hull's DefaultItems and
            // stock armament, start full, fit the hold), without price, trade-in or the
            // OnRetire/OnPurchase scripts.
            var p = save.player
            p.shipType = hull.id
            p.outfits = p.outfits.filter { id, _ in
                guard let o = game.outfit(id) else { return false }
                return o.flags & 0x0004 != 0 && !o.has(.paint)
            }
            p.stockBank = nil
            PilotEconomy.grantHullFittings(&p, ship: hull, game: game)
            p.armor = nil
            p.shield = nil
            p.fuel = nil
            _ = PilotEconomy.shrinkCargoToCapacity(&p, galaxy: Galaxy(game: game))
            save.player = p
        }
        save.player.shipName = shipName
        // The original keeps both in 32 bits; an editor value past that would overflow later arithmetic.
        save.player.credits = min(max(0, edit.credits), Int(Int32.max))
        save.player.combatRating = min(max(0, edit.combatRating), Int(Int32.max))
        save.refreshSnapshot(game: game)
        return ""
    }
}

/// Fields the `.evpilot` payload already stores and a load leaves in place:
/// the name the game prints, the hull, credits, and combat rating. Shield and
/// armor are cleared by `normalizeForLoad`, and a hidden current system can be
/// moved by `prepareForPlay`, so those are not edited here.
public struct PilotEdit: Equatable, Sendable {
    public var name: String
    public var nickname: String
    public var isMale: Bool
    public var strictPlay: Bool
    public var shipType: Int
    public var shipName: String
    public var credits: Int
    public var combatRating: Int

    /// The ship-name prompt refuses more than 64 UTF-8 bytes (DITL 3001).
    public static let maxShipNameUTF8 = 64

    public init(name: String, nickname: String, isMale: Bool, strictPlay: Bool,
                shipType: Int, shipName: String, credits: Int, combatRating: Int) {
        self.name = name
        self.nickname = nickname
        self.isMale = isMale
        self.strictPlay = strictPlay
        self.shipType = shipType
        self.shipName = shipName
        self.credits = credits
        self.combatRating = combatRating
    }

    public init(save: PilotSave) {
        let player = save.player
        self.init(name: player.pilotName.isEmpty ? save.displayName : player.pilotName,
                  nickname: player.nickname ?? "",
                  isMale: player.isMale,
                  strictPlay: player.isStrictPlay,
                  shipType: player.shipType,
                  shipName: player.shipName,
                  credits: player.credits,
                  combatRating: player.combatRating)
    }
}
