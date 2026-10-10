import Foundation
import ZIPFoundation
import NovaSwiftKit

public enum PluginInstallError: Error, LocalizedError {
    case unsupportedArchive
    case prebundledCannotBeDeleted
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchive: return "Couldn't open this file as a plug-in. Only .zip archives and loose .rez/.ndat files are supported."
        case .prebundledCannotBeDeleted: return "Prebundled plug-ins can be disabled but not deleted."
        case .checksumMismatch: return "The download doesn't match the checksum in the catalog, so it was discarded."
        }
    }
}

/// What the installer remembers about a plug-in it put on disk, so the app can
/// tell which version is installed and offer updates.
public struct InstalledPluginInfo: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var installedAt: Date
    public var sha256: String?

    public init(id: String, version: String, installedAt: Date = Date(), sha256: String? = nil) {
        self.id = id; self.version = version; self.installedAt = installedAt; self.sha256 = sha256
    }
}

/// One file inside an installed plug-in folder.
public struct InstalledFile: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String   // relative to the plug-in folder
    public let size: Int64
}

/// Extracts a downloaded plug-in archive into the plug-ins directory and
/// removes installed (non-prebundled) plug-ins.
///
/// Always extracts into `destRoot/<id>/`, regardless of the zip's own
/// internal folder structure — this is what guarantees the resulting
/// `PluginBundle.id` (folder name, per `GameLibrary.discoverPlugins`) equals
/// the catalog id, so installed-state lookups are a plain dictionary match.
public enum PluginInstaller {
    static let metadataName = ".novaswift-plugin.json"

    /// Installs a downloaded file. A zip is unpacked; a loose `.rez`/`.ndat`
    /// is copied in under its own name. `originalName` is only used to find
    /// the extension of a loose file.
    @discardableResult
    public static func install(archiveAt zipURL: URL, id: String, into destRoot: URL,
                               originalName: String? = nil,
                               version: String? = nil, sha256: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let destDir = destRoot.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: destDir.path) { try fm.removeItem(at: destDir) }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        do {
            if isZip(zipURL) {
                try fm.unzipItem(at: zipURL, to: destDir)
            } else {
                let name = originalName ?? zipURL.lastPathComponent
                guard GameLibrary.resourceExtensions.contains((name as NSString).pathExtension.lowercased()) else {
                    throw PluginInstallError.unsupportedArchive
                }
                try fm.copyItem(at: zipURL, to: destDir.appendingPathComponent(name))
            }
        } catch {
            try? fm.removeItem(at: destDir)
            throw PluginInstallError.unsupportedArchive
        }
        // The archive's own wrapper folder may hold macOS junk; drop it.
        try? fm.removeItem(at: destDir.appendingPathComponent("__MACOSX"))
        try? fm.removeItem(at: zipURL)
        if let version {
            writeInfo(InstalledPluginInfo(id: id, version: version, sha256: sha256), in: destRoot)
        }
        return destDir
    }

    static func isZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04]) || magic == Data([0x50, 0x4B, 0x05, 0x06])
    }

    public static func writeInfo(_ info: InstalledPluginInfo, in destRoot: URL) {
        let file = destRoot.appendingPathComponent(info.id, isDirectory: true).appendingPathComponent(metadataName)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(info) { try? data.write(to: file, options: .atomic) }
    }

    public static func info(id: String, in destRoot: URL) -> InstalledPluginInfo? {
        let file = destRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent(metadataName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(InstalledPluginInfo.self, from: data)
    }

    /// Every file under an installed plug-in's folder, for the "view files" list.
    public static func files(id: String, in destRoot: URL) -> [InstalledFile] {
        let dir = destRoot.appendingPathComponent(id, isDirectory: true).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [InstalledFile] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(InstalledFile(path: rel, size: Int64(v?.fileSize ?? 0)))
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
