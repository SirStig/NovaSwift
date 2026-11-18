import Foundation
import NovaSwiftKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Finds the game's dialog layouts (the DLOG/DITL resources the exe reads from
/// `Nova.rez` before `Nova Files`, 0x004d2a80) when an import didn't bring
/// them along. Shared by the Apple `DataImporter` and the Godot `GameDataImport`.
///
/// Where they live depends on the edition:
/// - **Windows / Community Edition:** `Nova.rez` beside `Nova Files` in the
///   game folder. Importing only `Nova Files` misses it.
/// - **WineNova** (the community Mac edition, the Windows build in a Wine
///   wrapper): the install folder has no `Nova.rez`. It ships zipped inside
///   the app (`EV Nova.app/Contents/Resources/Zips/SharedSupport.zip` →
///   `…/drive_c/Program Files/EV Nova/Nova.rez`), and the first launch unpacks
///   it under `~/Library/Application Support/WineNova/`.
/// - **The original Mac release:** in the application's own resources (a
///   `.rsrc` in the bundle, or the classic app's resource fork), with game
///   files also kept under `~/Library/Application Support/EV Nova/`.
///
/// Every candidate is opened and only accepted when it really holds the
/// dialogs (DITL 3001), so the search can be generous without importing the
/// wrong file. Resource-fork bytes are written out as a plain `Nova.rez`
/// (the reader detects the format from the bytes, not the name).
public enum NovaRezLocator {
    static let wineNovaPrefixPath =
        "Library/Application Support/WineNova/SharedSupport/prefix/drive_c/Program Files/EV Nova/Nova.rez"
    static let wineNovaZipPath = "Contents/Resources/Zips/SharedSupport.zip"
    static let macSupportPath = "Library/Application Support/EV Nova"
    /// Skip anything this large: a dialog archive is ~100 KB, game data files are MBs.
    static let maxCandidateBytes = 8 << 20

    /// True when `files` already include a `Nova.rez`.
    public static func hasNovaRez(_ files: [URL]) -> Bool {
        files.contains { $0.lastPathComponent.caseInsensitiveCompare("Nova.rez") == .orderedSame }
    }

    /// A readable `Nova.rez` holding the dialogs, for an import rooted at
    /// `root` that lacks one, or nil. Copies pulled out of a zip or a resource
    /// fork land in a fresh temporary folder.
    public static func locate(in root: URL) -> URL? {
        let fm = FileManager.default
        // Windows, only `Nova Files` picked: it sits one folder up.
        // (A sandboxed app can't read there and just moves on.)
        if root.lastPathComponent.caseInsensitiveCompare("Nova Files") == .orderedSame,
           let hit = accept(root.deletingLastPathComponent().appendingPathComponent("Nova.rez")) {
            return hit
        }
        for app in appBundles(in: root) {
            // WineNova: the wrapper zip.
            let zip = app.appendingPathComponent(wineNovaZipPath)
            if fm.fileExists(atPath: zip.path), let rez = extractNovaRez(fromZip: zip) { return rez }
            // Original Mac release: resources inside the bundle.
            for f in files(in: app.appendingPathComponent("Contents/Resources"), depth: 1)
            where f.pathExtension.lowercased() == "rsrc" || f.pathExtension.isEmpty {
                if let hit = accept(f) { return hit }
            }
            for f in files(in: app.appendingPathComponent("Contents/MacOS"), depth: 0) {
                if let hit = accept(f) { return hit }
            }
        }
        // A classic (pre-bundle) app is a single file with a resource fork.
        for f in files(in: root, depth: 0) where f.pathExtension.isEmpty {
            if let hit = accept(f) { return hit }
        }
        let home = fm.homeDirectoryForCurrentUser
        for f in files(in: home.appendingPathComponent(macSupportPath), depth: 2) {
            if let hit = accept(f) { return hit }
        }
        return accept(home.appendingPathComponent(wineNovaPrefixPath))
    }

    /// True when `url` (data fork, or on macOS its resource fork) parses as a
    /// resource container carrying DITL 3001.
    public static func holdsDialogs(_ url: URL) -> Bool { dialogBytes(url) != nil }

    /// The container bytes holding the dialogs, from the data fork or the
    /// resource fork.
    static func dialogBytes(_ url: URL) -> Data? {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else { return nil }
        var forks = [url]
        #if os(macOS)
        forks.append(url.appendingPathComponent("..namedfork/rsrc"))
        #endif
        for f in forks {
            guard let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int,
                  size >= 16, size <= maxCandidateBytes,
                  let data = try? Data(contentsOf: f),
                  let c = try? ResourceFile.read(data),
                  c.resource(NovaType.ditl, 3001) != nil else { continue }
            return data
        }
        return nil
    }

    /// `url` itself when its data fork is already a dialog archive, else its
    /// dialog bytes written to a temporary `Nova.rez`; nil when it holds none.
    static func accept(_ url: URL) -> URL? {
        guard let data = dialogBytes(url) else { return nil }
        if url.lastPathComponent.caseInsensitiveCompare("Nova.rez") == .orderedSame,
           (try? Data(contentsOf: url)) == data {
            return url
        }
        return writeTemp(data)
    }

    static func writeTemp(_ data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaswift-novarez-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent("Nova.rez")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dest)
            return dest
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Regular files under `dir`, `depth` folders deep (0 = only `dir`).
    static func files(in dir: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [URL] = []
        for k in kids {
            let isDir = (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if !isDir { out.append(k) }
            else if depth > 0, k.pathExtension.lowercased() != "app" { out += files(in: k, depth: depth - 1) }
        }
        return out
    }

    /// `.app` bundles in `root` or one folder below it (the picked folder may
    /// be the install or its parent), or `root` itself.
    static func appBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        func kids(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }
        var out: [URL] = root.pathExtension.lowercased() == "app" ? [root] : []
        for k in kids(root) {
            if k.pathExtension.lowercased() == "app" { out.append(k) }
            else if (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out += kids(k).filter { $0.pathExtension.lowercased() == "app" }
            }
        }
        return out
    }

    /// Pulls only the `Nova.rez` entry out of a WineNova wrapper zip.
    static func extractNovaRez(fromZip zip: URL) -> URL? {
        #if canImport(ZIPFoundation)
        guard let archive = Archive(url: zip, accessMode: .read),
              let entry = archive.first(where: {
                  $0.type == .file
                      && ($0.path as NSString).lastPathComponent.caseInsensitiveCompare("Nova.rez") == .orderedSame
                      && $0.uncompressedSize <= UInt64(maxCandidateBytes)
              }) else { return nil }
        var data = Data()
        do { _ = try archive.extract(entry) { data.append($0) } } catch { return nil }
        guard let c = try? ResourceFile.read(data), c.resource(NovaType.ditl, 3001) != nil else { return nil }
        return writeTemp(data)
        #else
        return nil
        #endif
    }
}
