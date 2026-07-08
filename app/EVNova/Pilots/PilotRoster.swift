import Foundation
import SwiftUI
import EVNovaKit
import EVNovaStory

/// The app-facing library of saved pilots: the launcher's pilot list and the
/// create / select / delete / duplicate actions, backed by `EVNovaStory`'s
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
        refresh()
    }

    /// Reload the roster from disk.
    func refresh() { pilots = archive.list() }

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
        save = (try? archive.save(save, backup: false)) ?? save
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
        save = (try? archive.save(save, backup: false)) ?? save
        refresh()
        return save
    }

    /// Update the durable save for `id` from the live pilot state. Called on
    /// landing / hyperjump / manual save / the autosave tick; backs up on the
    /// meaningful events so a stuck or corrupted pilot can be rolled back.
    func persist(id: UUID, state: PlayerState, game: NovaGame?, backup: Bool) {
        guard var save = try? archive.load(id: id) else { return }
        save.player = state
        save.refreshSnapshot(game: game)
        _ = try? archive.save(save, backup: backup)
        refresh()
    }

    // MARK: Manage

    func delete(_ id: UUID) { try? archive.delete(id: id); refresh() }
    func duplicate(_ id: UUID) { _ = try? archive.duplicate(id: id); refresh() }
    func rename(_ id: UUID, to name: String, game: NovaGame?) {
        guard var save = try? archive.load(id: id) else { return }
        save.displayName = name
        _ = try? archive.save(save, backup: false)
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
        refresh()
        return restored
    }

    /// A coarse fingerprint of the loaded data set, so a save records which data
    /// produced it (a full-parity check is a later concern).
    static func fingerprint(for game: NovaGame) -> String {
        "ships:\(game.ships().count) syst:\(game.systems().count) char:\(game.characters().count)"
    }
}
