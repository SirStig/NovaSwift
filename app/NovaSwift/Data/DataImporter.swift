import Foundation
import NovaSwiftKit
import NovaSwiftPluginStore

/// Copies resource files (`.rez`/`.ndat`) — and any bundled soundtrack file
/// (e.g. `Nova Music.mp3`) or original fonts (`Charcoal.ttf`/`Geneva.ttf`) —
/// from a chosen folder or file into the app's base-data directory. Handles
/// iOS security-scoped URLs. Driven by `DataSetupWizard`'s Import step.
///
/// `GameLibrary.discoverResourceFiles` deliberately only looks at resource
/// containers, so without also copying audio/font/video files here,
/// `GameDataController.musicTrackURL()`/`registerFonts(from:)`/`raceVideoURL()`
/// would search a sandbox copy that never had them in it — even the player's own
/// EV Nova install ships them right alongside the `.rez`s.
enum DataImporter {

    /// What one import actually managed to do. A copy that fails on a single
    /// file (a permissions hiccup, a source that vanished mid-copy) must not
    /// abort the whole import the way a thrown error used to: the files that
    /// *did* land are still worth keeping, and the ones that didn't have to be
    /// nameable, or the player is left with a silent partial data set and no
    /// idea which file to go back for.
    struct Outcome: Sendable {
        var copied: Int = 0
        /// Source files found but not copied, by file name.
        var failed: [String] = []
        /// Files that exist in the source only as un-downloaded iCloud
        /// placeholders and were still not materialised when we gave up
        /// waiting, by their real (non-placeholder) file name.
        var pendingDownload: [String] = []
    }

    /// How long to wait for iCloud to materialise placeholder files we asked
    /// for before importing whatever did arrive. Runs off the main actor (see
    /// `DataSetupWizard.handleImport`), so this never blocks the UI.
    private static let iCloudWait: TimeInterval = 20

    @discardableResult
    static func importBase(from src: URL, into destDir: URL) throws -> Outcome {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // A .zip (e.g. the zipped Windows build, or a zipped Nova Files
        // folder) imports as the folder it unpacks to — same discovery,
        // same filtering.
        if src.pathExtension.lowercased() == "zip" {
            let unpacked = try GameDataArchiver.unzipToTemporary(archive: src)
            defer { try? fm.removeItem(at: unpacked) }
            return try importBase(from: unpacked, into: destDir)
        }

        var outcome = Outcome()
        var sources: [URL] = []
        if (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // Files the player keeps in iCloud Drive can be present only as
            // `.Nova Graphics 3.rez.icloud` placeholders. Those are *hidden*,
            // so every discovery pass below skips them and the import silently
            // comes out partial (classically: the "Nova Data" files land and
            // the art doesn't). Ask iCloud for them first and give it a moment.
            outcome.pendingDownload = materialiseICloudPlaceholders(in: src)
            sources = GameLibrary.discoverResourceFiles(in: src)
                + GameDataController.discoverAudioFiles(in: src)
                + GameDataController.discoverFontFiles(in: src)
                + GameDataController.discoverVideoFiles(in: src)
        } else {
            sources = [src]
        }
        for file in sources {
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
                outcome.copied += 1
            } catch {
                // Keep going: one unreadable file must not cost the player the
                // twenty that copy fine.
                Log.data.error("import: failed to copy \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome.failed.append(file.lastPathComponent)
            }
        }
        Log.data.info("import: copied \(outcome.copied, privacy: .public) file(s) from \(src.path, privacy: .public), \(outcome.failed.count, privacy: .public) failed, \(outcome.pendingDownload.count, privacy: .public) still downloading from iCloud")
        return outcome
    }

    /// Names of the files that exist in `directory` only as iCloud
    /// placeholders. Kicks off a download for each importable one and waits up
    /// to `iCloudWait` for them to appear, returning whatever still hasn't.
    private static func materialiseICloudPlaceholders(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        // A placeholder is ".<real name>.icloud" sitting where the real file goes.
        var awaited: [URL] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "icloud" {
            let placeholder = url.lastPathComponent
            guard placeholder.hasPrefix(".") else { continue }
            let realName = String(placeholder.dropFirst().dropLast(".icloud".count))
            let ext = (realName as NSString).pathExtension.lowercased()
            guard GameLibrary.resourceExtensions.contains(ext)
                    || GameDataController.audioExtensions.contains(ext)
                    || GameDataController.fontExtensions.contains(ext)
                    || GameDataController.videoExtensions.contains(ext)
            else { continue }
            let real = url.deletingLastPathComponent().appendingPathComponent(realName)
            do {
                try fm.startDownloadingUbiquitousItem(at: real)
                awaited.append(real)
                Log.data.info("import: requested iCloud download of \(realName, privacy: .public)")
            } catch {
                Log.data.error("import: cannot download \(realName, privacy: .public) from iCloud: \(String(describing: error), privacy: .public)")
                awaited.append(real)
            }
        }
        guard !awaited.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(iCloudWait)
        while Date() < deadline {
            awaited.removeAll { fm.fileExists(atPath: $0.path) }
            if awaited.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        awaited.removeAll { fm.fileExists(atPath: $0.path) }
        return awaited.map(\.lastPathComponent)
    }
}
