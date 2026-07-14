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
/// iCloud: the archive points at the ubiquity container when the player has
/// iCloud saves enabled (`GameSettings.iCloudSaves`) *and* the container is
/// reachable; otherwise it uses the local Application Support store. Toggling
/// the setting calls `useICloud(_:)`, which migrates existing pilots across.
@MainActor
final class PilotRoster: ObservableObject {
    /// The on-disk store. `var` (not `let`) so `useICloud` can swap it between
    /// the local and iCloud roots at runtime.
    private(set) var archive: PilotArchive
    /// Every saved pilot, newest-first (mirrors `archive.list()`).
    @Published private(set) var pilots: [PilotSave] = []
    /// Whether the roster is currently backed by iCloud (vs. local storage).
    @Published private(set) var isCloudBacked: Bool

    /// The save the menu shows and "Enter Ship" resumes, chosen explicitly by
    /// the player (via New Pilot / Open Pilot / playing a slot) and remembered
    /// across launches. Kept as a save id — see `selected`.
    @Published private(set) var selectedID: UUID?
    private static let selectedIDKey = "com.novaswift.roster.selectedPilotID"

    init(archive: PilotArchive? = nil, preferICloud: Bool = false) {
        let resolved = archive ?? PilotArchive.resolveDefault(preferICloud: preferICloud)
        self.archive = resolved
        self.isCloudBacked = resolved.location.isCloud
        // Restore the last explicit selection, if any.
        // Instance-scoped so a second local-MP test instance remembers its own
        // loaded pilot rather than fighting the primary over one key (`AppInstance`).
        if let raw = AppInstance.defaults.string(forKey: Self.selectedIDKey) {
            self.selectedID = UUID(uuidString: raw)
        }
        Log.pilot.debug("PilotRoster.init: archive at \(self.archive.root.path, privacy: .public) (iCloud=\(self.archive.location.isCloud))")
        refresh()
    }

    /// Reload the roster from disk.
    func refresh() {
        pilots = archive.list()
        // Drop a dangling selection whose file no longer exists (deleted pilot).
        if let id = selectedID, !pilots.contains(where: { $0.id == id }) {
            Log.pilot.debug("PilotRoster.refresh: clearing stale selection \(id, privacy: .public)")
            setSelected(nil)
        }
        Log.pilot.debug("PilotRoster.refresh: \(self.pilots.count) pilot(s) in roster")
    }

    var isEmpty: Bool { pilots.isEmpty }
    var mostRecent: PilotSave? { pilots.first }

    // MARK: Selection (the "loaded pilot" Enter Ship resumes)

    /// The pilot "Enter Ship" resumes and the main-menu readout shows. An
    /// explicit selection wins; with none, we fall back to the sole pilot only
    /// when there's exactly one group — never silently pick among several, so
    /// "Enter Ship" prompts a choice instead of grabbing whatever's newest.
    var selected: PilotSave? {
        if let id = selectedID, let save = pilots.first(where: { $0.id == id }) { return save }
        let gs = groups
        return gs.count == 1 ? gs[0].mostRecent : nil
    }

    /// True when there is a pilot for "Enter Ship" to resume without prompting.
    var hasSelection: Bool { selected != nil }

    /// Remember `id` as the loaded pilot (persisted across launches). When the
    /// caller passes any slot of a group, the whole group is "selected" — the
    /// readout resolves the group's most-recent slot via `selected`.
    func setSelected(_ id: UUID?) {
        selectedID = id
        if let id { AppInstance.defaults.set(id.uuidString, forKey: Self.selectedIDKey) }
        else { AppInstance.defaults.removeObject(forKey: Self.selectedIDKey) }
    }

    // MARK: Storage location (local ⇄ iCloud)

    /// Switch the roster between local and iCloud storage, migrating existing
    /// pilots into the destination so none appear to vanish. Requesting iCloud
    /// when it isn't reachable is a no-op that stays on local (the caller's
    /// setting can stay on so it takes effect once the user signs in). The
    /// ubiquity lookup can block, so it runs off the main thread.
    func useICloud(_ prefer: Bool) {
        // Already in the requested state? Nothing to do.
        if prefer == isCloudBacked { return }
        let currentLocal = !isCloudBacked
        Task.detached(priority: .userInitiated) {
            let destination: PilotArchive?
            if prefer {
                if let cloud = PilotArchive.iCloudRoot() {
                    destination = PilotArchive(location: .iCloud(cloud))
                } else {
                    destination = nil   // iCloud not available; stay local
                }
            } else {
                destination = PilotArchive(location: .local(PilotArchive.defaultLocalRoot()))
            }
            await MainActor.run {
                guard let destination else {
                    Log.pilot.notice("PilotRoster.useICloud: iCloud requested but unavailable; staying on local storage")
                    return
                }
                // Bring the old store's pilots into the new one before switching.
                destination.importPilots(from: self.archive, overwrite: false)
                self.archive = destination
                self.isCloudBacked = destination.location.isCloud
                Log.pilot.notice("PilotRoster.useICloud: switched to \(self.isCloudBacked ? "iCloud" : "local", privacy: .public) storage at \(destination.root.path, privacy: .public) (was \(currentLocal ? "local" : "iCloud", privacy: .public))")
                self.refresh()
            }
        }
    }

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
        // Prefer to update the existing on-disk save so its metadata (name,
        // createdAt, scenario, pilotGroupID) is preserved. If it can't be loaded
        // — missing after a botched write, or corrupt — DON'T drop the autosave;
        // reconstruct a fresh save from the live state under the same id so the
        // player's progress is still written somewhere. Losing the metadata is
        // strictly better than losing the whole session's play.
        var save: PilotSave
        if let existing = try? archive.load(id: id) {
            save = existing
            save.player = state
        } else {
            Log.pilot.error("PilotRoster.persist: pilot \(id, privacy: .public) not loadable; reconstructing from live state so progress isn't lost")
            save = PilotSave(id: id,
                             displayName: state.pilotName.isEmpty ? "Captain" : state.pilotName,
                             scenarioName: "", player: state, game: game,
                             dataFingerprint: game.map(Self.fingerprint(for:)) ?? "")
        }
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
    nonisolated static let maxSlotsPerPilot = 3

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
