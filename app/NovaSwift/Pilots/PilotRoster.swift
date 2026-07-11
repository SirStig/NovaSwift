import Foundation
import SwiftUI
import NovaSwiftKit
import NovaSwiftStory

/// The app-facing library of saved pilots: the launcher's pilot list and the
/// create / select / delete / duplicate actions, backed by `NovaSwiftStory`'s
/// `PilotArchive` (many `.evpilot` files + rotating auto-backups). This is the
/// *durable* multi-pilot store; the live in-session pilot is `AppModel.pilot`
/// (a `PilotStore`), which this loads into when the player starts or resumes.
///
/// iCloud is ready but off: `PilotArchive.resolveDefault(preferICloud:)` will
/// point at the ubiquity container once the entitlement is configured in Xcode.
@MainActor
final class PilotRoster: ObservableObject {
    let archive: PilotArchive
    /// Every saved pilot, newest-first (mirrors `archive.list()`).
    @Published private(set) var pilots: [PilotSave] = []

    init(archive: PilotArchive? = nil) {
        self.archive = archive ?? PilotArchive.resolveDefault(preferICloud: false)
        Log.pilot.debug("PilotRoster.init: archive at \(self.archive.root.path, privacy: .public) (iCloud=\(self.archive.location.isCloud))")
        refresh()
    }

    /// Reload the roster from disk.
    func refresh() {
        pilots = archive.list()
        Log.pilot.debug("PilotRoster.refresh: \(self.pilots.count) pilot(s) in roster")
    }

    var isEmpty: Bool { pilots.isEmpty }
    var mostRecent: PilotSave? { pilots.first }

    // MARK: Create / persist

    /// Create a brand-new pilot from a starting scenario and save it to the store.
    /// Returns the new save (its `player` is what the live pilot should adopt).
    @discardableResult
    func create(name: String, isMale: Bool, scenario: CharRes, game: NovaGame) -> PilotSave {
        let player = PilotFactory.make(name: name, isMale: isMale, scenario: scenario, game: game)
        var save = PilotSave(displayName: name.isEmpty ? "Captain" : name,
                             scenarioName: scenario.displayName,
                             player: player, game: game,
                             dataFingerprint: Self.fingerprint(for: game))
        do {
            save = try archive.save(save, backup: false)
            Log.pilot.notice("PilotRoster.create: created pilot \(save.id, privacy: .public) \"\(save.displayName, privacy: .public)\"")
        } catch {
            // NOTE: possible bug — if this write fails, `save` below is the
            // in-memory PilotSave that was never actually persisted to disk, yet
            // the caller receives it as if creation succeeded (and `refresh()`
            // won't show it in the roster, since archive.list() reads from disk).
            Log.pilot.error("PilotRoster.create: failed to persist new pilot \"\(save.displayName, privacy: .public)\": \(String(describing: error), privacy: .public)")
        }
        refresh()
        return save
    }

    /// Adopt an already-live pilot state that was never created through this
    /// roster (e.g. the no-data-required demo path, or a dev autoplay session)
    /// into the durable archive for the first time, so it has a roster id and
    /// autosave stops silently no-oping for it. Returns the new save.
    @discardableResult
    func adopt(state: PlayerState, game: NovaGame?) -> PilotSave {
        var save = PilotSave(displayName: state.pilotName.isEmpty ? "Captain" : state.pilotName,
                             scenarioName: "", player: state, game: game,
                             dataFingerprint: game.map(Self.fingerprint(for:)) ?? "")
        do {
            save = try archive.save(save, backup: false)
            Log.pilot.notice("PilotRoster.adopt: adopted live pilot into roster as \(save.id, privacy: .public)")
        } catch {
            Log.pilot.error("PilotRoster.adopt: failed to persist adopted pilot \"\(save.displayName, privacy: .public)\": \(String(describing: error), privacy: .public)")
        }
        refresh()
        return save
    }

    /// Update the durable save for `id` from the live pilot state. Called on
    /// landing / hyperjump / manual save / the autosave tick; backs up on the
    /// meaningful events so a stuck or corrupted pilot can be rolled back.
    func persist(id: UUID, state: PlayerState, game: NovaGame?, backup: Bool) {
        guard var save = try? archive.load(id: id) else {
            // NOTE: possible bug — this silently no-ops the entire autosave for
            // this tick (e.g. after landing or a hyperjump) if the on-disk save
            // can't be loaded (missing/corrupt file). The player's in-session
            // progress since the last successful persist is not written anywhere.
            Log.pilot.error("PilotRoster.persist: failed to load pilot \(id, privacy: .public) for autosave; this update was NOT persisted")
            return
        }
        save.player = state
        save.refreshSnapshot(game: game)
        do {
            _ = try archive.save(save, backup: backup)
            Log.pilot.debug("PilotRoster.persist: persisted pilot \(id, privacy: .public) (backup=\(backup))")
        } catch {
            Log.pilot.error("PilotRoster.persist: failed to save pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    // MARK: Manage

    func delete(_ id: UUID) {
        do {
            try archive.delete(id: id)
            Log.pilot.notice("PilotRoster.delete: deleted pilot \(id, privacy: .public)")
        } catch {
            Log.pilot.error("PilotRoster.delete: failed to delete pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
    func duplicate(_ id: UUID) {
        do {
            let dup = try archive.duplicate(id: id)
            Log.pilot.notice("PilotRoster.duplicate: duplicated pilot \(id, privacy: .public) as \(dup.id, privacy: .public)")
        } catch {
            Log.pilot.error("PilotRoster.duplicate: failed to duplicate pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
    func rename(_ id: UUID, to name: String, game: NovaGame?) {
        guard var save = try? archive.load(id: id) else {
            Log.pilot.error("PilotRoster.rename: failed to load pilot \(id, privacy: .public) to rename")
            return
        }
        save.displayName = name
        do {
            _ = try archive.save(save, backup: false)
        } catch {
            Log.pilot.error("PilotRoster.rename: failed to save renamed pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    // MARK: Save history (many saves, one pilot)

    /// One past save point in a pilot's history: a full snapshot plus the
    /// backup file it lives in (needed to restore it).
    struct HistoryEntry: Identifiable {
        let url: URL
        let save: PilotSave
        var id: URL { url }
    }

    /// This pilot's past save points (auto-backed-up on land/jump/manual save),
    /// newest first — lets the player rewind to an earlier point in the *same*
    /// pilot's story instead of every playthrough needing its own roster entry.
    func history(for id: UUID) -> [HistoryEntry] {
        archive.loadBackups(for: id).map { HistoryEntry(url: $0.url, save: $0.save) }
    }

    /// Roll `id` back to an earlier save point (backing up the current state
    /// first, so this itself is undoable). The pilot's identity/id is unchanged
    /// — it stays the same roster row, just with older progress.
    @discardableResult
    func restore(_ id: UUID, from entry: HistoryEntry) -> PilotSave? {
        let restored = try? archive.restore(id: id, from: entry.url)
        if restored == nil {
            Log.pilot.error("PilotRoster.restore: failed to restore pilot \(id, privacy: .public) from \(entry.url.lastPathComponent, privacy: .public)")
        } else {
            Log.pilot.notice("PilotRoster.restore: restored pilot \(id, privacy: .public) from \(entry.url.lastPathComponent, privacy: .public)")
        }
        refresh()
        return restored
    }

    /// A coarse fingerprint of the loaded data set, so a save records which data
    /// produced it (a full-parity check is a later concern).
    static func fingerprint(for game: NovaGame) -> String {
        "ships:\(game.ships().count) syst:\(game.systems().count) char:\(game.characters().count)"
    }

    // MARK: Save slots (many independent saves, one pilot identity)

    /// Our own native save format supports up to 3 independent save slots per
    /// pilot (unlike a single obfuscated `.plt`) — this is separate from a
    /// slot's own backup history (`history(for:)`/`groupHistory(for:)`), which
    /// keeps happening underneath each slot regardless of how many slots exist.
    static let maxSlotsPerPilot = 3

    /// A pilot identity: every save sharing a `pilotGroupID`, oldest first (so
    /// "Slot 1/2/3" is just position — no separate stored index needed).
    struct PilotGroup: Identifiable {
        let id: UUID   // == pilotGroupID
        let slots: [PilotSave]
        var mostRecent: PilotSave { slots.max { $0.updatedAt < $1.updatedAt } ?? slots[0] }
        var canAddSlot: Bool { slots.count < PilotRoster.maxSlotsPerPilot }
    }

    /// Every pilot, grouped by `pilotGroupID` and sorted by each group's most
    /// recently played slot — this is what the pilot list should show one row
    /// per, instead of `pilots` directly (which is per-save, i.e. per-slot).
    var groups: [PilotGroup] {
        Dictionary(grouping: pilots, by: \.pilotGroupID)
            .map { PilotGroup(id: $0.key, slots: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.mostRecent.updatedAt > $1.mostRecent.updatedAt }
    }

    /// Add another save slot to `groupID`, cloned from `templateID` (typically
    /// the group's `mostRecent` slot). Refuses past the 3-slot cap.
    @discardableResult
    func addSlot(to groupID: UUID, from templateID: UUID) -> PilotSave? {
        guard groups.first(where: { $0.id == groupID })?.canAddSlot == true else {
            Log.pilot.debug("PilotRoster.addSlot: group \(groupID, privacy: .public) is already at the \(PilotRoster.maxSlotsPerPilot)-slot cap")
            return nil
        }
        let created = try? archive.createSlot(from: templateID)
        if let created {
            Log.pilot.notice("PilotRoster.addSlot: added slot \(created.id, privacy: .public) to group \(groupID, privacy: .public)")
        } else {
            Log.pilot.error("PilotRoster.addSlot: failed to create a slot from \(templateID, privacy: .public)")
        }
        refresh()
        return created
    }

    /// Rename every slot in `groupID` — display name is the shared pilot
    /// identity across slots, not a per-slot label.
    func renameGroup(_ groupID: UUID, to name: String, game: NovaGame?) {
        for slot in groups.first(where: { $0.id == groupID })?.slots ?? [] {
            rename(slot.id, to: name, game: game)
        }
    }

    /// Delete every slot in `groupID` — the whole pilot, all its slots, and
    /// each slot's own backups. Use plain `delete(_:)` instead to drop a
    /// single slot while keeping the rest of the group.
    func deleteGroup(_ groupID: UUID) {
        for slot in groups.first(where: { $0.id == groupID })?.slots ?? [] {
            do {
                try archive.delete(id: slot.id)
            } catch {
                Log.pilot.error("PilotRoster.deleteGroup: failed to delete slot \(slot.id, privacy: .public) of group \(groupID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        Log.pilot.notice("PilotRoster.deleteGroup: deleted pilot group \(groupID, privacy: .public)")
        refresh()
    }

    /// One backup, tagged with which slot it belongs to (a group can have up
    /// to 3 slots, each with its own independent backup history).
    struct GroupHistoryEntry: Identifiable {
        let slotID: UUID
        let entry: HistoryEntry
        var id: URL { entry.url }
    }

    /// Every backup across every slot in `groupID`, newest-first — "all
    /// backups for this pilot", merging each slot's own `history(for:)`.
    func groupHistory(for groupID: UUID) -> [GroupHistoryEntry] {
        let slots = groups.first(where: { $0.id == groupID })?.slots ?? []
        return slots
            .flatMap { slot in history(for: slot.id).map { GroupHistoryEntry(slotID: slot.id, entry: $0) } }
            .sorted { $0.entry.save.updatedAt > $1.entry.save.updatedAt }
    }
}
