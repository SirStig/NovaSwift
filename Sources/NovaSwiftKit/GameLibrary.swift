import Foundation
import CryptoKit

/// How a plug-in relates to the base scenario. Drives load order and mutual
/// exclusivity in the launcher (you play at most one total conversion at a time;
/// small gameplay plug-ins can stack). See docs/MOBILE_AND_PLUGINS.md §3.
public enum PluginKind: String, Codable, Sendable {
    case base
    case totalConversion
    case gameplay
    case patch
    case unknown

    /// Display label shared by the launcher's Installed list and the plug-in
    /// store, so both agree on wording.
    public var label: String {
        switch self {
        case .base: return "Base"
        case .totalConversion: return "Total conversion"
        case .patch: return "Content patch"
        case .gameplay: return "Gameplay tweak"
        case .unknown: return "Plug-in"
        }
    }

    /// SF Symbol used as a generic placeholder tile when a catalog entry has
    /// no bundled screenshot.
    public var symbolName: String {
        switch self {
        case .base: return "globe"
        case .totalConversion: return "sparkles"
        case .patch: return "paintbrush.fill"
        case .gameplay: return "slider.horizontal.3"
        case .unknown: return "puzzlepiece.extension.fill"
        }
    }
}

/// One installable unit of content: the base game, a total conversion, or a
/// gameplay plug-in. `fileURLs` are the resource containers it contributes.
public struct PluginBundle: Identifiable, Codable, Hashable, Sendable {
    public let id: String        // stable identity (folder / file name)
    public var name: String      // display name
    public var kind: PluginKind
    public var fileURLs: [URL]
    public var isEnabled: Bool

    public init(id: String, name: String, kind: PluginKind = .unknown,
                fileURLs: [URL], isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileURLs = fileURLs
        self.isEnabled = isEnabled
    }
}

/// Discovers game/plug-in data on disk and merges an enabled set into a single
/// resolved `ResourceCollection` (base first, then enabled plug-ins, later layers
/// overriding earlier ones by `(type, id)` — the EV Nova plug-in model).
public enum GameLibrary {
    /// Extensions we recognise as resource containers. (Classic resource-fork
    /// files with no extension are handled by the importer, which appends
    /// `/..namedfork/rsrc`; here we key on data-fork containers.)
    public static let resourceExtensions: Set<String> = ["rez", "ndat"]

    // MARK: Discovery

    /// All resource-container files under `directory`, recursively, sorted by path
    /// (so the base "Nova Files" load order is deterministic).
    public static func discoverResourceFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else {
            Log.data.error("Could not enumerate \(directory.path, privacy: .public) for resource files")
            return []
        }
        var out: [URL] = []
        for case let url as URL in e where resourceExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        let sorted = out.sorted { $0.path < $1.path }
        Log.data.debug("Found \(sorted.count, privacy: .public) resource file(s) under \(directory.path, privacy: .public)")
        return sorted
    }

    /// Each top-level item in `directory` becomes one `PluginBundle`: a folder
    /// gathers every resource file within it; a loose `.rez`/`.ndat` is its own
    /// bundle. Bundles start disabled; the launcher persists the enabled set.
    public static func discoverPlugins(in directory: URL) -> [PluginBundle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            Log.data.debug("No plug-in directory at \(directory.path, privacy: .public) (or unreadable) — 0 plug-ins discovered")
            return []
        }

        var bundles: [PluginBundle] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let files = discoverResourceFiles(in: entry)
                guard !files.isEmpty else {
                    Log.data.debug("Plug-in folder \(entry.lastPathComponent, privacy: .public) has no .rez/.ndat files — skipped")
                    continue
                }
                bundles.append(PluginBundle(id: entry.lastPathComponent,
                                            name: entry.lastPathComponent,
                                            fileURLs: files))
            } else if resourceExtensions.contains(entry.pathExtension.lowercased()) {
                bundles.append(PluginBundle(id: entry.lastPathComponent,
                                            name: entry.deletingPathExtension().lastPathComponent,
                                            fileURLs: [entry]))
            }
        }
        Log.data.debug("Discovered \(bundles.count, privacy: .public) plug-in bundle(s) under \(directory.path, privacy: .public)")
        return bundles
    }

    // MARK: Classification (optional, parses the bundle — call lazily)

    /// Guess a bundle's kind by how much world it defines. Parses its files, so
    /// call it on demand (e.g. when the launcher first shows a plug-in), not for
    /// every bundle up front.
    public static func classify(_ bundle: PluginBundle) -> PluginKind {
        var systems = 0, ships = 0, total = 0
        for url in bundle.fileURLs {
            guard let col = try? ResourceFile.read(contentsOf: url) else {
                Log.data.error("classify(\(bundle.id, privacy: .public)): failed to parse \(url.path, privacy: .public) — skipped, kind guess may be inaccurate")
                continue
            }
            systems += col.resources(of: NovaType.syst).count
            ships += col.resources(of: NovaType.ship).count
            total += col.totalCount
        }
        if systems >= 20 || ships >= 30 { return .totalConversion }
        if systems > 0 || ships > 0 { return .patch }
        if total > 0 { return .gameplay }
        return .unknown
    }

    // MARK: Merge (the override chain)

    /// Resolve base + enabled plug-ins into one collection. Plug-ins are applied
    /// in the given order; `isEnabled == false` bundles are skipped.
    public static func merge(baseFiles: [URL], plugins: [PluginBundle] = []) throws -> ResourceCollection {
        var collection = ResourceCollection()
        // Reading + parsing a container is independent per file and CPU/IO-bound,
        // so parse them concurrently and then overlay in load order (the overlay
        // itself must stay ordered — later layers override earlier ones).
        for col in try parseConcurrently(baseFiles.sorted(by: { $0.path < $1.path }), context: "base file") {
            collection.overlay(col)
        }
        Log.data.debug("merge: base layer = \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s) from \(baseFiles.count, privacy: .public) file(s)")
        for plugin in plugins where plugin.isEnabled {
            for col in try parseConcurrently(plugin.fileURLs, context: "plug-in \(plugin.name)") {
                collection.overlay(col, tag: plugin.id)
            }
            Log.data.debug("merge: applied plug-in \(plugin.name, privacy: .public) (\(plugin.id, privacy: .public)) — collection now \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s)")
        }
        return collection
    }

    /// Parse `urls` in parallel, preserving input order in the result (so the
    /// caller's override chain is unaffected). Throws the first parse error
    /// encountered — matching the serial version's fail-fast behaviour.
    private static func parseConcurrently(_ urls: [URL], context: String) throws -> [ResourceCollection] {
        guard !urls.isEmpty else { return [] }
        var results = [ResourceCollection?](repeating: nil, count: urls.count)
        var firstError: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            do {
                let col = try ResourceFile.read(contentsOf: urls[i])
                lock.lock(); results[i] = col; lock.unlock()
            } catch {
                Log.data.error("merge: failed to load \(context, privacy: .public) \(urls[i].path, privacy: .public): \(String(describing: error), privacy: .public)")
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
            }
        }
        if let firstError { throw firstError }
        return results.compactMap { $0 }
    }

    // MARK: Plug-in content hash (multiplayer compatibility)

    /// A content hash of a plug-in's resource bytes — its *version* identity, for
    /// verifying two players run the same plug-in in multiplayer. Unlike
    /// `fingerprint` (which keys on size/mtime for a per-machine cache name), this
    /// hashes the actual file contents so it's identical across devices for the
    /// same plug-in build. Files are streamed, so a large container doesn't blow up
    /// memory. Order-stable (files sorted by path).
    public static func contentHash(of bundle: PluginBundle) -> String {
        var hasher = SHA256()
        for url in bundle.fileURLs.sorted(by: { $0.path < $1.path }) {
            // Fold the filename in too, so identical bytes under different names
            // (e.g. load-order-significant containers) don't collide.
            hasher.update(data: Data(url.lastPathComponent.utf8))
            guard let stream = InputStream(url: url) else { continue }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                hasher.update(data: Data(buffer[0..<read]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Data-set fingerprint

    /// A stable hash of the exact set of container files (base + enabled plug-ins)
    /// and their size/mtime. Two launches over the same data set produce the same
    /// fingerprint; importing new data, toggling a plug-in, reordering plug-ins
    /// (load order changes which one wins an override — see `merge`), or a file
    /// changing on disk produces a different one. Used to name the decoded-sprite
    /// disk cache so a stale cache is never read (see `SpriteDiskCache`).
    ///
    /// `SHA256` (not `Hasher`) because `Hasher` is seeded randomly per process —
    /// its output would differ every launch, defeating a cross-launch cache.
    public static func fingerprint(baseFiles: [URL], plugins: [PluginBundle]) -> String {
        let fm = FileManager.default
        func stamp(_ url: URL) -> String {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(url.lastPathComponent)|\(size)|\(Int(mtime))"
        }
        var parts: [String] = []
        for url in baseFiles.sorted(by: { $0.path < $1.path }) { parts.append("B|" + stamp(url)) }
        // NOT sorted by id: `plugins`' array order is load order, and load order
        // changes which plug-in wins an override, so it must be part of the key.
        for plugin in plugins.filter(\.isEnabled) {
            for url in plugin.fileURLs.sorted(by: { $0.path < $1.path }) {
                parts.append("P|\(plugin.id)|" + stamp(url))
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
