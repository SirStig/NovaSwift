import Foundation
import Crypto

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
    /// The plug-in files: top-level `.rez`/`.ndat` of the folder, as if they sat
    /// directly in `Nova Plug-Ins` (for a total conversion: its own `Plug-Ins/`).
    public var fileURLs: [URL]
    public var isEnabled: Bool
    /// A total conversion's own `Nova Files/*.rez`. Non-empty marks the bundle
    /// as a TC: it replaces the stock `Nova Files` instead of overlaying them
    /// (the original runs a TC with its own `Nova Files` + `Plug-Ins`; only
    /// `Nova.rez` is shared).
    public var novaFilesURLs: [URL] = []
    /// A subfolder of a plug-in folder. The original never loads subfolders,
    /// so these are inert unless the user opts in (manual plug-in order).
    public var isOptional: Bool = false

    public var isTotalConversion: Bool { !novaFilesURLs.isEmpty }
    /// Every container the bundle owns (TC base files first).
    public var allFileURLs: [URL] { novaFilesURLs + fileURLs }

    public init(id: String, name: String, kind: PluginKind = .unknown,
                fileURLs: [URL], isEnabled: Bool = false,
                novaFilesURLs: [URL] = [], isOptional: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.fileURLs = fileURLs
        self.isEnabled = isEnabled
        self.novaFilesURLs = novaFilesURLs
        self.isOptional = isOptional
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
        let sorted = out.sorted { ($0.path.uppercased(), $0.path) < ($1.path.uppercased(), $1.path) }
        Log.data.debug("Found \(sorted.count, privacy: .public) resource file(s) under \(directory.path, privacy: .public)")
        return sorted
    }

    /// The resource containers sitting directly in `directory` (no recursion), in
    /// the original folder scan's case-insensitive name order
    /// (`nv_LoadFilesInFolder` 0x0046f500 skips directories).
    public static func topLevelResourceFiles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { resourceExtensions.contains($0.pathExtension.lowercased()) && !isDirectory($0) }
            .sorted(by: nameOrder)
    }

    /// Case-insensitive file-name order, ties by raw bytes.
    static func nameOrder(_ a: URL, _ b: URL) -> Bool {
        (a.lastPathComponent.uppercased(), a.lastPathComponent) < (b.lastPathComponent.uppercased(), b.lastPathComponent)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter(isDirectory).sorted(by: nameOrder)
    }

    /// A total conversion is a folder holding its own `Nova Files/` (the `.nplay`
    /// convention: `Nova Files/`, `Plug-Ins/`, `Pilots/`). Nil when `folder` isn't one.
    static func totalConversion(at folder: URL, id: String) -> PluginBundle? {
        let subs = subdirectories(of: folder)
        guard let novaFiles = subs.first(where: { $0.lastPathComponent.caseInsensitiveCompare("Nova Files") == .orderedSame }) else { return nil }
        let base = topLevelResourceFiles(in: novaFiles)
        guard !base.isEmpty else { return nil }
        let plugDir = subs.first { ["NOVA PLUG-INS", "PLUG-INS"].contains($0.lastPathComponent.uppercased()) }
        var name = id
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let nplay = entries.first(where: { $0.pathExtension.lowercased() == "nplay" }),
           let data = try? Data(contentsOf: nplay),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = json["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty {
            name = n
        }
        return PluginBundle(id: id, name: name, kind: .totalConversion,
                            fileURLs: plugDir.map(topLevelResourceFiles(in:)) ?? [],
                            novaFilesURLs: base)
    }

    /// Bundles for one plug-in folder: its top-level files are the plug-in (as
    /// if they sat in `Nova Plug-Ins`); each subfolder with files is an opt-in
    /// sub-item, since the original never descends. A folder holding only one
    /// subfolder is an archive's wrapper directory and is looked through.
    private static func bundles(forFolder folder: URL, id: String, name: String) -> [PluginBundle] {
        if let tc = totalConversion(at: folder, id: id) { return [tc] }
        let files = topLevelResourceFiles(in: folder)
        let subs = subdirectories(of: folder)
        if files.isEmpty, subs.count == 1 {
            return bundles(forFolder: subs[0], id: id, name: name)
        }
        var out: [PluginBundle] = []
        if !files.isEmpty { out.append(PluginBundle(id: id, name: name, fileURLs: files)) }
        for sub in subs {
            let inner = bundles(forFolder: sub, id: id + "/" + sub.lastPathComponent,
                                name: name + " – " + sub.lastPathComponent)
            for var b in inner where !b.isTotalConversion {
                b.isOptional = true
                out.append(b)
            }
        }
        return out
    }

    /// Each top-level item in `directory` becomes one `PluginBundle`: a folder
    /// contributes its top-level resource files (subfolders become opt-in
    /// sub-items, a total conversion keeps its own `Nova Files`); a loose
    /// `.rez`/`.ndat` is its own bundle. Bundles start disabled; the launcher
    /// persists the enabled set.
    public static func discoverPlugins(in directory: URL) -> [PluginBundle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            Log.data.debug("No plug-in directory at \(directory.path, privacy: .public) (or unreadable) — 0 plug-ins discovered")
            return []
        }

        var bundles: [PluginBundle] = []
        for entry in entries.sorted(by: nameOrder) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let found = Self.bundles(forFolder: entry, id: entry.lastPathComponent, name: entry.lastPathComponent)
                if found.isEmpty {
                    Log.data.debug("Plug-in folder \(entry.lastPathComponent, privacy: .public) has no .rez/.ndat files — skipped")
                }
                bundles.append(contentsOf: found)
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
        for url in bundle.allFileURLs {
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

    // MARK: Load order

    /// The original's base-file precedence: `nv_WinMain` 0x004d2a80 opens
    /// `Nova.rez` before scanning Nova Files, and a later archive wins, so
    /// `Nova.rez` is the weakest layer. The rest follow in the folder scan's
    /// case-insensitive order.
    public static func baseLoadOrder(_ files: [URL]) -> [URL] {
        files.sorted { a, b in
            let aRez = a.lastPathComponent.uppercased() == "NOVA.REZ"
            let bRez = b.lastPathComponent.uppercased() == "NOVA.REZ"
            if aRez != bRez { return aRez }
            return (a.path.uppercased(), a.path) < (b.path.uppercased(), b.path)
        }
    }

    /// The original plug-in rule (`nv_LoadFilesInFolder` 0x0046f500): every
    /// installed plug-in loads, in the folder's case-insensitive alphabetical
    /// order, and a later one wins a conflict. The launcher's enable switches
    /// and drag order are the `manualPluginOrder` enhancement.
    ///
    /// Two kinds are never auto-loaded: subfolder sub-items (the original never
    /// descends into folders) and total conversions (you run one *instead of*
    /// the stock scenario; selecting it is an explicit choice, kept from
    /// `isEnabled`, and only one can be selected).
    public static func originalPluginOrder(_ plugins: [PluginBundle]) -> [PluginBundle] {
        var chosenTC = false
        var out = plugins.reversed().map { p -> PluginBundle in
            var p = p
            if p.isTotalConversion {
                p.isEnabled = p.isEnabled && !chosenTC
                if p.isEnabled { chosenTC = true }
            } else {
                p.isEnabled = !p.isOptional
            }
            return p
        }
        out.reverse()
        return out.sorted { ($0.id.uppercased(), $0.id) < ($1.id.uppercased(), $1.id) }
    }

    /// What actually loads. With a total conversion selected (the last enabled
    /// one) the stock `Nova Files` are dropped (only `Nova.rez` is shared), the
    /// TC's own `Nova Files` take their place, its `Plug-Ins` are the only
    /// plug-ins, and the user's global plug-ins do not apply. Otherwise the
    /// base is all `baseFiles` and the plug-ins are the enabled ones.
    ///
    /// With `flat` (the original) the plug-in files of all bundles form one
    /// list ordered by file name, case-insensitively, as if they sat in one
    /// folder. Otherwise (manual plug-in order) bundle order is kept.
    static func resolveLayers(baseFiles: [URL], plugins: [PluginBundle], flat: Bool)
        -> (base: [URL], plugins: [(id: String, url: URL)]) {
        let enabled = plugins.filter(\.isEnabled)
        var base = baseFiles
        var layered: [PluginBundle]
        if let tc = enabled.last(where: \.isTotalConversion) {
            let shared = baseFiles.filter { $0.lastPathComponent.uppercased() == "NOVA.REZ" }
            base = (shared.isEmpty ? baseFiles : shared) + tc.novaFilesURLs
            var own = tc
            own.novaFilesURLs = []
            layered = [own]
        } else {
            layered = enabled
        }
        var files: [(id: String, url: URL)] = []
        for p in layered { for u in p.fileURLs.sorted(by: nameOrder) { files.append((p.id, u)) } }
        if flat {
            // Ties keep the bundle order they were gathered in.
            files = files.enumerated().sorted { a, b in
                let ka = (a.element.url.lastPathComponent.uppercased(), a.element.url.lastPathComponent)
                let kb = (b.element.url.lastPathComponent.uppercased(), b.element.url.lastPathComponent)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
        }
        return (base, files)
    }

    // MARK: Plug-in files that failed to load

    /// A plug-in file the last `merge` could not open (the original logs and
    /// skips it; the launcher lists it).
    public struct FailedPluginFile: Equatable, Sendable {
        public let url: URL
        public let reason: String
    }

    private static let failedLock = NSLock()
    nonisolated(unsafe) private static var failedFiles: [FailedPluginFile] = []

    /// The plug-in files that failed to open in the most recent `merge`.
    public static var lastFailedPluginFiles: [FailedPluginFile] {
        failedLock.lock(); defer { failedLock.unlock() }
        return failedFiles
    }

    // MARK: Merge (the override chain)

    /// Resolve base + enabled plug-ins into one collection. Base files load in
    /// `baseLoadOrder`; plug-ins are applied in the given order and
    /// `isEnabled == false` bundles are skipped. The result is normalised the
    /// way the original loader sees it (`normalizeScenarioRecords`).
    public static func merge(baseFiles: [URL], plugins: [PluginBundle] = [],
                             flatPluginOrder: Bool = true) throws -> ResourceCollection {
        var collection = ResourceCollection()
        let layers = resolveLayers(baseFiles: baseFiles, plugins: plugins, flat: flatPluginOrder)
        // Reading + parsing a container is independent per file and CPU/IO-bound,
        // so parse them concurrently and then overlay in load order (the overlay
        // itself must stay ordered — later layers override earlier ones).
        for case let col? in try parseConcurrently(baseLoadOrder(layers.base), context: "base file", strict: true) {
            collection.overlay(col)
        }
        Log.data.debug("merge: base layer = \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s) from \(layers.base.count, privacy: .public) file(s)")
        // Like nv_LoadFilesInFolder, a plug-in file that fails to open is logged and skipped.
        failedLock.lock(); failedFiles = []; failedLock.unlock()
        let parsed = try parseConcurrently(layers.plugins.map(\.url), context: "plug-in file", strict: false)
        for (i, col) in parsed.enumerated() {
            guard let col else { continue }
            collection.overlay(col, tag: layers.plugins[i].id)
        }
        Log.data.debug("merge: applied \(layers.plugins.count, privacy: .public) plug-in file(s) — collection now \(collection.totalCount, privacy: .public) resource(s), \(collection.types.count, privacy: .public) type(s)")
        collection.normalizeScenarioRecords()
        return collection
    }

    /// Parse `urls` in parallel, preserving input order in the result (so the
    /// caller's override chain is unaffected). When `strict`, throws the first parse
    /// error; otherwise a failed file yields nil and the rest still load.
    private static func parseConcurrently(_ urls: [URL], context: String, strict: Bool) throws -> [ResourceCollection?] {
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
                if !strict {
                    failedLock.lock()
                    failedFiles.append(FailedPluginFile(url: urls[i], reason: String(describing: error)))
                    failedLock.unlock()
                }
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
            }
        }
        if strict, let firstError { throw firstError }
        return results
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
        for url in bundle.allFileURLs.sorted(by: { $0.path < $1.path }) {
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
    public static func fingerprint(baseFiles: [URL], plugins: [PluginBundle],
                                   flatPluginOrder: Bool = true) -> String {
        let fm = FileManager.default
        func stamp(_ url: URL) -> String {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(url.lastPathComponent)|\(size)|\(Int(mtime))"
        }
        // The resolved layers (TC replacement + plug-in order), in load order:
        // order changes which file wins an override, so it is part of the key.
        let layers = resolveLayers(baseFiles: baseFiles, plugins: plugins, flat: flatPluginOrder)
        var parts: [String] = []
        for url in layers.base.sorted(by: { $0.path < $1.path }) { parts.append("B|" + stamp(url)) }
        for (id, url) in layers.plugins { parts.append("P|\(id)|" + stamp(url)) }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
