import Foundation

/// The on-disk pilot store: a directory of `<uuid>.evpilot` files (one per pilot,
/// unlimited count) plus rotating auto-backups. Pure `Foundation` and
/// platform-agnostic, so the CLI, tests and both iOS/macOS app targets share it.
///
/// Design notes for the requested features:
///  • **Many pilots** — one file each; `list()` returns them newest-first.
///  • **Auto-backup** — every overwrite first copies the previous file into
///    `Backups/<uuid>/<epochMillis>.evpilot`, keeping the newest N plus the very
///    first (a safety anchor). `backUpNow` gives the future editor a pre-edit copy.
///  • **Atomic writes** — never leaves a half-written save on a crash.
///  • **Pluggable root** — `StorageLocation` lets the same archive point at the
///    iCloud ubiquity container once the entitlement is configured; local today.
public final class PilotArchive {

    /// Where the pilot directory lives.
    public enum StorageLocation: Equatable, Sendable {
        case local(URL)
        case iCloud(URL)

        public var url: URL {
            switch self { case .local(let u), .iCloud(let u): return u }
        }
        public var isCloud: Bool { if case .iCloud = self { return true }; return false }
    }

    public let location: StorageLocation
    /// Directory holding the `.evpilot` files.
    public var root: URL { location.url }
    /// Directory holding per-pilot backup folders.
    public var backupsRoot: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    /// How many recent backups to keep per pilot (the first is always kept too).
    public var maxBackupsPerPilot: Int
    /// Injectable clock (keeps backup filenames deterministic in tests).
    private let now: () -> Date

    private let fm = FileManager.default

    public init(location: StorageLocation,
                maxBackupsPerPilot: Int = 8,
                now: @escaping () -> Date = { Date() }) {
        self.location = location
        self.maxBackupsPerPilot = max(1, maxBackupsPerPilot)
        self.now = now
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.pilot.error("PilotArchive.init: failed to create pilot directory at \(self.root.path, privacy: .public) (iCloud=\(location.isCloud)): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Default roots

    /// `…/Application Support/EVNova/Pilots` — the local, always-available store.
    public static func defaultLocalRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EVNova/Pilots", isDirectory: true)
    }

    /// The iCloud ubiquity `Documents/Pilots` folder, if the app is entitled and
    /// signed in. Returns nil otherwise so the caller falls back to local.
    public static func iCloudRoot(containerID: String? = nil) -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            return nil
        }
        return container.appendingPathComponent("Documents/Pilots", isDirectory: true)
    }

    /// The archive to use: iCloud when requested *and* available, else local.
    /// iCloud stays off until the entitlement/container is configured in Xcode.
    public static func resolveDefault(preferICloud: Bool, containerID: String? = nil,
                                      maxBackupsPerPilot: Int = 8) -> PilotArchive {
        if preferICloud, let cloud = iCloudRoot(containerID: containerID) {
            return PilotArchive(location: .iCloud(cloud), maxBackupsPerPilot: maxBackupsPerPilot)
        }
        return PilotArchive(location: .local(defaultLocalRoot()), maxBackupsPerPilot: maxBackupsPerPilot)
    }

    // MARK: Paths

    public func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(PilotSave.fileExtension)")
    }
    private func backupDir(for id: UUID) -> URL {
        backupsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: List / load

    /// All saved pilots, most-recently-updated first. Unreadable files are skipped.
    public func list() -> [PilotSave] {
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            Log.pilot.error("PilotArchive.list: failed to read pilot directory at \(self.root.path, privacy: .public)")
            return []
        }
        let saves = items
            .filter { $0.pathExtension == PilotSave.fileExtension }
            .compactMap { url -> PilotSave? in
                do {
                    return try decode(contentsOf: url)
                } catch {
                    // A corrupt/unreadable save silently drops that pilot from the
                    // roster — worth surfacing, since the player would otherwise
                    // just see a shorter list with no explanation.
                    Log.pilot.error("PilotArchive.list: skipping unreadable pilot file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
        Log.pilot.debug("PilotArchive.list: loaded \(saves.count) pilot(s) from \(items.count) file(s)")
        return saves.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) throws -> PilotSave {
        do {
            return try decode(contentsOf: fileURL(for: id))
        } catch {
            Log.pilot.error("PilotArchive.load: failed to load pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func exists(id: UUID) -> Bool { fm.fileExists(atPath: fileURL(for: id).path) }

    private func decode(contentsOf url: URL) throws -> PilotSave {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(PilotSave.self, from: data)
    }

    // MARK: Save

    /// Persist `pilot`, bumping `updatedAt` and (by default) rotating a backup of
    /// the previous file first. Atomic.
    @discardableResult
    public func save(_ pilot: PilotSave, backup: Bool = true) throws -> PilotSave {
        var pilot = pilot
        pilot.updatedAt = now()
        let url = fileURL(for: pilot.id)
        if backup, fm.fileExists(atPath: url.path) {
            do {
                try backUp(id: pilot.id, from: url)
            } catch {
                // Non-fatal: we still proceed with the save itself, but a failed
                // pre-save backup means the previous state is unrecoverable if
                // this write goes wrong — worth knowing about.
                Log.pilot.error("PilotArchive.save: pre-save backup failed for pilot \(pilot.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(pilot)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.pilot.error("PilotArchive.save: failed to save pilot \(pilot.id, privacy: .public) (\"\(pilot.displayName, privacy: .public)\"): \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.pilot.debug("PilotArchive.save: saved pilot \(pilot.id, privacy: .public) (\"\(pilot.displayName, privacy: .public)\")")
        return pilot
    }

    /// Copy the *current* on-disk save into a fresh backup (for the future editor's
    /// pre-edit snapshot), independent of the normal save-time rotation.
    public func backUpNow(id: UUID) throws {
        let url = fileURL(for: id)
        guard fm.fileExists(atPath: url.path) else {
            Log.pilot.debug("PilotArchive.backUpNow: no on-disk save for pilot \(id, privacy: .public); nothing to back up")
            return
        }
        do {
            try backUp(id: id, from: url)
        } catch {
            Log.pilot.error("PilotArchive.backUpNow: failed for pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func backUp(id: UUID, from url: URL) throws {
        let dir = backupDir(for: id)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(now().timeIntervalSince1970 * 1000)
            var dest = dir.appendingPathComponent("\(stamp).\(PilotSave.fileExtension)")
            // Guard against same-millisecond collisions.
            var bump = 0
            while fm.fileExists(atPath: dest.path) {
                bump += 1
                dest = dir.appendingPathComponent("\(stamp)-\(bump).\(PilotSave.fileExtension)")
            }
            try fm.copyItem(at: url, to: dest)
        } catch {
            Log.pilot.error("PilotArchive.backUp: failed to write backup for pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        pruneBackups(id: id)
    }

    /// Keep the newest `maxBackupsPerPilot` backups plus the very first one.
    private func pruneBackups(id: UUID) {
        let all = backups(for: id)   // ascending by timestamp
        guard all.count > maxBackupsPerPilot else { return }
        let keep = Set([all.first!] + all.suffix(maxBackupsPerPilot - 1))
        for url in all where !keep.contains(url) { try? fm.removeItem(at: url) }
    }

    /// This pilot's backups, oldest-first (sorted by the numeric timestamp name).
    public func backups(for id: UUID) -> [URL] {
        let dir = backupDir(for: id)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { $0.pathExtension == PilotSave.fileExtension }
            .sorted { backupOrder($0) < backupOrder($1) }
    }

    /// This pilot's backups, decoded and paired with their file, newest-first —
    /// the "many saves for one pilot" history: each is a full snapshot from a
    /// past land/jump/manual save, so the player can jump back to an earlier
    /// point without it cluttering the main roster (which only ever shows one
    /// row per pilot identity). The URL is what `restore(id:from:)` needs.
    public func loadBackups(for id: UUID) -> [(url: URL, save: PilotSave)] {
        backups(for: id).reversed().compactMap { url in
            do {
                return (url, try decode(contentsOf: url))
            } catch {
                Log.pilot.error("PilotArchive.loadBackups: skipping unreadable backup \(url.lastPathComponent, privacy: .public) for pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Restore a pilot from one of its backup files (backing up the current first).
    @discardableResult
    public func restore(id: UUID, from backupURL: URL) throws -> PilotSave {
        do {
            var save = try decode(contentsOf: backupURL)
            save.id = id   // keep the roster identity stable
            let restored = try self.save(save, backup: true)
            Log.pilot.notice("PilotArchive.restore: restored pilot \(id, privacy: .public) from backup \(backupURL.lastPathComponent, privacy: .public)")
            return restored
        } catch {
            Log.pilot.error("PilotArchive.restore: failed to restore pilot \(id, privacy: .public) from \(backupURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The numeric millisecond timestamp encoded in a backup file's name.
    public func backupTimestamp(_ url: URL) -> Int { backupOrder(url) }

    private func backupOrder(_ url: URL) -> Int {
        // Filenames are "<millis>.evpilot" or "<millis>-<n>.evpilot".
        let name = url.deletingPathExtension().lastPathComponent
        let head = name.split(separator: "-").first.map(String.init) ?? name
        return Int(head) ?? 0
    }

    // MARK: Delete / duplicate

    public func delete(id: UUID) throws {
        let file = fileURL(for: id)
        if fm.fileExists(atPath: file.path) {
            do {
                try fm.removeItem(at: file)
            } catch {
                Log.pilot.error("PilotArchive.delete: failed to remove pilot file for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let dir = backupDir(for: id)
        if fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
            } catch {
                Log.pilot.error("PilotArchive.delete: failed to remove backups for pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        Log.pilot.notice("PilotArchive.delete: deleted pilot \(id, privacy: .public)")
    }

    /// Clone a pilot under a new id (and optional new name) — a "copy pilot" action.
    @discardableResult
    public func duplicate(id: UUID, newName: String? = nil) throws -> PilotSave {
        do {
            var save = try load(id: id)
            save.id = UUID()
            if let newName { save.displayName = newName }
            else { save.displayName += " Copy" }
            save.createdAt = now()
            let duplicated = try self.save(save, backup: false)
            Log.pilot.notice("PilotArchive.duplicate: duplicated pilot \(id, privacy: .public) as \(duplicated.id, privacy: .public)")
            return duplicated
        } catch {
            Log.pilot.error("PilotArchive.duplicate: failed to duplicate pilot \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: Coders

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
