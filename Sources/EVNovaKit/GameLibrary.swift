import Foundation

/// How a plug-in relates to the base scenario. Drives load order and mutual
/// exclusivity in the launcher (you play at most one total conversion at a time;
/// small gameplay plug-ins can stack). See docs/MOBILE_AND_PLUGINS.md §3.
public enum PluginKind: String, Codable, Sendable {
    case base
    case totalConversion
    case gameplay
    case patch
    case unknown
}

/// One installable unit of content: the base game, a total conversion, or a
/// gameplay plug-in. `fileURLs` are the resource containers it contributes.
public struct PluginBundle: Identifiable, Codable, Hashable {
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
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where resourceExtensions.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Each top-level item in `directory` becomes one `PluginBundle`: a folder
    /// gathers every resource file within it; a loose `.rez`/`.ndat` is its own
    /// bundle. Bundles start disabled; the launcher persists the enabled set.
    public static func discoverPlugins(in directory: URL) -> [PluginBundle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var bundles: [PluginBundle] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let files = discoverResourceFiles(in: entry)
                guard !files.isEmpty else { continue }
                bundles.append(PluginBundle(id: entry.lastPathComponent,
                                            name: entry.lastPathComponent,
                                            fileURLs: files))
            } else if resourceExtensions.contains(entry.pathExtension.lowercased()) {
                bundles.append(PluginBundle(id: entry.lastPathComponent,
                                            name: entry.deletingPathExtension().lastPathComponent,
                                            fileURLs: [entry]))
            }
        }
        return bundles
    }

    // MARK: Classification (optional, parses the bundle — call lazily)

    /// Guess a bundle's kind by how much world it defines. Parses its files, so
    /// call it on demand (e.g. when the launcher first shows a plug-in), not for
    /// every bundle up front.
    public static func classify(_ bundle: PluginBundle) -> PluginKind {
        var systems = 0, ships = 0, total = 0
        for url in bundle.fileURLs {
            guard let col = try? ResourceFile.read(contentsOf: url) else { continue }
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
        for url in baseFiles.sorted(by: { $0.path < $1.path }) {
            collection.overlay(try ResourceFile.read(contentsOf: url))
        }
        for plugin in plugins where plugin.isEnabled {
            for url in plugin.fileURLs {
                collection.overlay(try ResourceFile.read(contentsOf: url))
            }
        }
        return collection
    }
}
