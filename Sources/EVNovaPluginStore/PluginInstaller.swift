import Foundation
import ZIPFoundation

public enum PluginInstallError: Error, LocalizedError {
    case unsupportedArchive
    case prebundledCannotBeDeleted

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchive: return "Couldn't open this file as a plug-in archive."
        case .prebundledCannotBeDeleted: return "Prebundled plug-ins can be disabled but not deleted."
        }
    }
}

/// Extracts a downloaded plug-in archive into the plug-ins directory and
/// removes installed (non-prebundled) plug-ins.
///
/// Always extracts into `destRoot/<id>/`, regardless of the zip's own
/// internal folder structure — this is what guarantees the resulting
/// `PluginBundle.id` (folder name, per `GameLibrary.discoverPlugins`) equals
/// the catalog id, so installed-state lookups are a plain dictionary match.
public enum PluginInstaller {
    @discardableResult
    public static func install(archiveAt zipURL: URL, id: String, into destRoot: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let destDir = destRoot.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: destDir.path) { try fm.removeItem(at: destDir) }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        do {
            try fm.unzipItem(at: zipURL, to: destDir)
        } catch {
            try? fm.removeItem(at: destDir)
            throw PluginInstallError.unsupportedArchive
        }
        try? fm.removeItem(at: zipURL)
        return destDir
    }

    /// Removes an installed (downloaded) plug-in. Refuses prebundled entries —
    /// those only ever live under the app bundle's `Plugins/` dir, never under
    /// `destRoot`, so this also acts as a sanity check on the caller.
    public static func delete(id: String, from destRoot: URL, prebundled: Bool) throws {
        guard !prebundled else { throw PluginInstallError.prebundledCannotBeDeleted }
        let dir = destRoot.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Whether catalog entry `id` already has an installed folder under `destRoot`.
    public static func isInstalled(id: String, in destRoot: URL) -> Bool {
        var isDir: ObjCBool = false
        let path = destRoot.appendingPathComponent(id, isDirectory: true).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
