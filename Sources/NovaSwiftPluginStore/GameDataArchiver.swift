import Foundation
import CryptoKit
import ZIPFoundation

/// Zips and unzips the imported base-data directory ("Nova Files") for
/// cross-device sync, plus a content fingerprint to tell whether two copies
/// are the same data set without comparing bytes.
///
/// Lives in this package (rather than the app) because it's where ZIPFoundation
/// is already linked. All functions are synchronous and blocking — callers run
/// them off the main actor.
public enum GameDataArchiver {

    /// A stable fingerprint of a directory's contents: SHA-256 over every
    /// file's relative path and size, sorted. Deliberately excludes
    /// modification times — a copy of the same files (e.g. restored on another
    /// device) must fingerprint identically or every device would re-upload
    /// the data it just downloaded. Returns nil for a missing/empty directory.
    public static func fingerprint(of directory: URL) -> String? {
        let files = regularFiles(under: directory)
        guard !files.isEmpty else { return nil }
        let manifest = files
            .map { "\($0.relativePath(from: directory))|\($0.fileSize)" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Zips `directory`'s *contents* (no wrapping parent folder) into a fresh
    /// temporary file and returns its URL. The caller owns the file and should
    /// delete it once consumed.
    public static func zip(directory: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-gamedata-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try FileManager().zipItem(at: directory, to: dest,
                                  shouldKeepParent: false, compressionMethod: .deflate)
        return dest
    }

    /// Replaces `destDir` with the archive's contents and returns how many
    /// files landed. On failure the half-written destination is removed so a
    /// partial download never masquerades as a valid data set.
    @discardableResult
    public static func unzip(archive: URL, into destDir: URL) throws -> Int {
        let fm = FileManager()
        if fm.fileExists(atPath: destDir.path) { try fm.removeItem(at: destDir) }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: archive, to: destDir)
        } catch {
            try? fm.removeItem(at: destDir)
            throw error
        }
        return regularFiles(under: destDir).count
    }

    /// Unzips `archive` into a fresh temporary directory and returns it. The
    /// caller owns the directory and should delete it once consumed. Used by
    /// the import paths that accept a .zip (a zipped "Nova Files" folder or
    /// the Windows build's download) instead of a live folder.
    public static func unzipToTemporary(archive: URL) throws -> URL {
        let fm = FileManager()
        let dest = fm.temporaryDirectory
            .appendingPathComponent("novaswift-unzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: archive, to: dest)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return dest
    }

    private static func regularFiles(under directory: URL) -> [URL] {
        let fm = FileManager()
        guard let e = fm.enumerator(at: directory,
                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }
}

private extension URL {
    func relativePath(from base: URL) -> String {
        let full = standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard full.hasPrefix(basePath) else { return lastPathComponent }
        return String(full.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var fileSize: Int {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}
