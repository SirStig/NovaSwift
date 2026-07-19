#if canImport(CloudKit)
import Foundation
import CloudKit
import NovaSwiftPluginStore

/// Syncs the imported base game data ("Nova Files") across the player's
/// devices through their own **private** CloudKit database — the "import once,
/// play everywhere" path.
///
/// After any successful import (and once per launch, fingerprint-guarded) the
/// data set is zipped and saved as a `CKAsset` on a single well-known record.
/// A device with no data checks for that record and offers to restore — and
/// tvOS restores automatically, which is also its self-heal when the system
/// purges the caches-only sandbox (see `NovaStorage`).
///
/// Legal footing (mirrors `DataSetupWizard`): the archive only ever lands in
/// the *user's own* private database, visible to their Apple ID alone — the
/// same act as them putting the files in iCloud Drive themselves. Nothing is
/// ever written where another user (or we) could read it; discovery/lobby
/// records on the public database (`OnlineLobbyDirectory`) carry no game data.
///
/// **Setup this depends on (can't be done from code):** the CloudKit container
/// `iCloud.com.houseofkac.novaswift` learns the `GameDataArchive` record type
/// automatically in the Development environment on first save; the schema must
/// be promoted to Production before a release build can use it — same routine
/// as the multiplayer lobby types (docs/MULTIPLAYER.md).
@MainActor
final class GameDataCloudSync: ObservableObject {

    enum Phase: Equatable {
        case idle, checking, uploading, downloading
    }

    /// What the cloud currently holds, sans the (large) asset itself.
    struct RemoteArchive: Equatable {
        let fingerprint: String
        let fileCount: Int
        let sizeBytes: Int64
        let modified: Date?

        /// "23 files · 142 MB" for the wizard's restore card.
        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            return "\(fileCount) file(s) · \(size)"
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// A data set exists in the player's iCloud and can be restored.
    @Published private(set) var remote: RemoteArchive?
    /// Last sync trouble, in player terms. Never fatal — the local data and
    /// every other import path keep working; only syncing degrades.
    @Published private(set) var lastError: String?

    private let container = CKContainer(identifier: "iCloud.com.houseofkac.novaswift")
    private var database: CKDatabase { container.privateCloudDatabase }

    private static let recordType = "GameDataArchive"
    /// One well-known record: a player has exactly one base data set, so
    /// up-to-dateness is a fingerprint compare, not a query.
    private static let recordID = CKRecord.ID(recordName: "base-game-data")

    // MARK: - Status

    /// Refresh `remote` from the cloud without downloading the asset.
    func refreshRemoteStatus() async {
        guard phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        guard await accountAvailable() else { return }
        do {
            let results = try await database.records(
                for: [Self.recordID],
                desiredKeys: ["fingerprint", "fileCount", "sizeBytes"])
            switch results[Self.recordID] {
            case .success(let record):
                remote = Self.remoteArchive(from: record)
            case .failure(let error) where isUnknownItem(error):
                remote = nil    // nothing uploaded yet
            case .failure(let error):
                lastError = friendly(error)
            case nil:
                remote = nil
            }
        } catch let error where isUnknownItem(error) {
            remote = nil
        } catch {
            lastError = friendly(error)
        }
    }

    // MARK: - Upload

    /// Zip and upload `baseDir` to the player's private iCloud — unless the
    /// cloud already holds this exact data set (fingerprint match), which makes
    /// this cheap enough to call on every launch and after every import.
    /// Best-effort: failures set `lastError` and leave local play untouched.
    func uploadIfNeeded(baseDir: URL) async {
        guard phase == .idle else { return }
        guard let localFingerprint = await Task.detached(priority: .utility, operation: {
            GameDataArchiver.fingerprint(of: baseDir)
        }).value else { return }    // nothing imported here (e.g. dev NOVASWIFT_DATA override)

        await refreshRemoteStatus()
        if remote?.fingerprint == localFingerprint { return }    // cloud is current

        guard phase == .idle else { return }
        guard await accountAvailable() else { return }
        phase = .uploading
        defer { phase = .idle }
        do {
            let zipURL = try await Task.detached(priority: .utility, operation: {
                try GameDataArchiver.zip(directory: baseDir)
            }).value
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let sizeBytes = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]))
                .flatMap { $0.fileSize.map(Int64.init) } ?? 0
            let fileCount = await Task.detached(priority: .utility, operation: {
                GameLibraryFileCounter.count(in: baseDir)
            }).value

            // A fresh record + `.allKeys` overwrites whatever is there without
            // a fetch-modify round trip — last writer wins, which is correct
            // for "the newest import is the data set".
            let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
            record["fingerprint"] = localFingerprint
            record["fileCount"] = Int64(fileCount)
            record["sizeBytes"] = sizeBytes
            record["archive"] = CKAsset(fileURL: zipURL)
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .allKeys)
            remote = RemoteArchive(fingerprint: localFingerprint, fileCount: fileCount,
                                   sizeBytes: sizeBytes, modified: Date())
            lastError = nil
            Log.data.info("iCloud sync: uploaded game data (\(fileCount, privacy: .public) file(s), \(sizeBytes, privacy: .public) bytes)")
        } catch {
            lastError = friendly(error)
            Log.data.error("iCloud sync: upload failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Restore

    /// Download the archived data set and unpack it into `destDir` (replacing
    /// whatever partial state is there). Returns the number of files restored.
    /// The caller reloads the game data afterwards.
    @discardableResult
    func restore(into destDir: URL) async throws -> Int {
        guard phase == .idle else { throw CKError(.operationCancelled) }
        phase = .downloading
        defer { phase = .idle }
        do {
            // Fetching without `desiredKeys` is what actually downloads the asset.
            let record = try await database.record(for: Self.recordID)
            guard let asset = record["archive"] as? CKAsset, let file = asset.fileURL else {
                throw CKError(.assetFileNotFound)
            }
            let count = try await Task.detached(priority: .userInitiated, operation: {
                try GameDataArchiver.unzip(archive: file, into: destDir)
            }).value
            remote = Self.remoteArchive(from: record)
            lastError = nil
            Log.data.info("iCloud sync: restored \(count, privacy: .public) file(s) from iCloud")
            return count
        } catch {
            lastError = friendly(error)
            Log.data.error("iCloud sync: restore failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Helpers

    private func accountAvailable() async -> Bool {
        ((try? await container.accountStatus()) ?? .couldNotDetermine) == .available
    }

    private static func remoteArchive(from record: CKRecord) -> RemoteArchive {
        RemoteArchive(fingerprint: record["fingerprint"] as? String ?? "",
                      fileCount: (record["fileCount"] as? Int64).map(Int.init) ?? 0,
                      sizeBytes: record["sizeBytes"] as? Int64 ?? 0,
                      modified: record.modificationDate)
    }

    private func isUnknownItem(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    private func friendly(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .networkUnavailable, .networkFailure:
            return "iCloud isn't reachable right now — will sync when you're back online."
        case .notAuthenticated:
            return "Sign in to iCloud on this device to sync your game data."
        case .quotaExceeded:
            return "Your iCloud storage is full — free up space to sync game data."
        default:
            return "iCloud sync hit a snag: \(error.localizedDescription)"
        }
    }
}

/// Counts what the sync record advertises as "files" — everything the archive
/// carries. Kept out of `GameDataArchiver` so the record's number matches what
/// `unzip` will report on the other end.
private enum GameLibraryFileCounter {
    static func count(in directory: URL) -> Int {
        let fm = FileManager()
        guard let e = fm.enumerator(at: directory,
                                    includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return 0 }
        return e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.count
    }
}
#endif
