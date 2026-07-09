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
        for url in baseFiles.sorted(by: { $0.path < $1.path }) {
            do {
                collection.overlay(try ResourceFile.read(contentsOf: url))
            } catch {
                Log.data.error("merge: failed to load base file \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        Log.data.debug("merge: base layer = \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s) from \(baseFiles.count, privacy: .public) file(s)")
        for plugin in plugins where plugin.isEnabled {
            for url in plugin.fileURLs {
                do {
                    collection.overlay(try ResourceFile.read(contentsOf: url))
                } catch {
                    Log.data.error("merge: failed to load plug-in \(plugin.name, privacy: .public) file \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw error
                }
            }
            Log.data.debug("merge: applied plug-in \(plugin.name, privacy: .public) (\(plugin.id, privacy: .public)) — collection now \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s)")
        }
        return collection
    }
}
