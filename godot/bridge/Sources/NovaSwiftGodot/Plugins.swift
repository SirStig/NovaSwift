// NovaPlugins — the Godot-visible façade over plug-in loading and the plug-in store.
//
// Mirrors the Apple app's `GameDataController` plug-in half (discovery, enable / order,
// persisted state, merge into the game data) and `PluginsModel` (online catalog, install,
// update, delete). All the rules are shared code:
//   * discovery / original-vs-manual load order / merge  -> NovaSwiftKit `GameLibrary`, `PluginSet`
//   * catalog, download + verify + unpack                -> NovaSwiftPluginStore
// This file only decides *where to look* (game folder, user plug-in folder), persists the state
// as JSON (the Apple app uses UserDefaults) and marshals to Godot. Lists cross as JSON strings
// like the rest of the bridge. Downloads run on Swift tasks (URLSession; FoundationNetworking
// off-Apple) and the GDScript screen polls `transfers()` / `catalog_state()`.
//
// `PluginRuntime.shared` is also what `NovaWorld.loadGame` consults, so every caller of
// `load_game` (Prefs.find_data, the data-setup screen, the self-checks) gets plug-ins merged
// with no GDScript change; `NovaPlugins.reload()` re-runs that load after a change.

import Foundation
import SwiftGodot
import NovaSwiftKit
import NovaSwiftPluginStore

/// Plain-Swift plug-in state shared between `NovaWorld.loadGame` and `NovaPlugins`.
final class PluginRuntime: @unchecked Sendable {
    static let shared = PluginRuntime()

    private let lock = NSLock()
    // Persisted (JSON): the manual-order enhancement flag, and per plug-in enabled + order.
    private var manual = false
    private var stateLoaded = false
    private var stateFileOverride: URL?
    // Session.
    private(set) var plugins: [PluginBundle] = []
    /// Whether `plugins` was arranged under manual order (Apple `pluginsAreManual`): only then
    /// does the in-memory enabled set carry over a rescan.
    private var pluginsAreManual = false
    private(set) var failures: [PluginLoadFailure] = []
    private(set) var baseDir: URL?
    private var extraDirs: [URL] = []
    private(set) var searchedDirs: [URL] = []
    private var installDirOverride: URL?
    /// Set whenever installed content or the enabled set changed since the last data load.
    private(set) var needsReload = false

    // Catalog / store.
    private var entries: [PluginCatalogEntry] = []
    private var catalogSource = "none"
    private var catalogError: String?
    private var refreshing = false
    private var fallback = PluginCatalogDocument(plugins: [])
    private var transfers: [String: (progress: Double?, error: String?)] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var catalogTask: Task<Void, Never>?
    private var images: [URL: Data] = [:]
    private var imageTasks: Set<URL> = []

    // MARK: Locations

    /// `…/NovaSwift` — the per-user data root (state file, catalog cache, Plug-ins folder).
    var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let h = env["NOVA_PLUGIN_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true).standardizedFileURL }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/NovaSwift", isDirectory: true)
        #elseif os(Windows)
        if let a = env["APPDATA"], !a.isEmpty { return URL(fileURLWithPath: a).appendingPathComponent("NovaSwift", isDirectory: true) }
        return home.appendingPathComponent("AppData/Roaming/NovaSwift", isDirectory: true)
        #else
        if let x = env["XDG_DATA_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("NovaSwift", isDirectory: true) }
        return home.appendingPathComponent(".local/share/NovaSwift", isDirectory: true)
        #endif
    }

    /// Where downloaded / imported plug-ins live (the Apple `importedPluginsDir`).
    var installDir: URL {
        lock.lock(); defer { lock.unlock() }
        // Standardised: ZIPFoundation rejects entries whose path does not start with the destination's
        // normalised path, so a `//` or `..` in a user-typed folder would fail every zip install.
        return (installDirOverride ?? root.appendingPathComponent("Plug-ins", isDirectory: true)).standardizedFileURL
    }

    private var stateFile: URL {
        if let o = stateFileOverride { return o }
        if let e = ProcessInfo.processInfo.environment["NOVA_PLUGIN_STATE"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return root.appendingPathComponent("plugins-state.json")
    }

    private static let gameFolderNames: Set<String> = ["nova plug-ins", "nova plugins", "nova plug-in"]

    /// Every folder plug-ins are read from, in order (later wins on conflicts only through the
    /// load order, not the folder): `NOVA_PLUGINS_DIR` (dev), the "Nova Plug-ins" folder next
    /// to / inside the chosen data folder (the original install layout), the user plug-in
    /// folder, and any folder added with `addDir`.
    func pluginDirs(for base: URL) -> [URL] {
        var dirs: [URL] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["NOVA_PLUGINS_DIR", "NOVASWIFT_PLUGINS"] {
            if let d = env[key], !d.isEmpty { dirs.append(URL(fileURLWithPath: d, isDirectory: true)) }
        }
        let fm = FileManager.default
        for parent in [base, base.deletingLastPathComponent()] {
            let kids = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where Self.gameFolderNames.contains(k.lastPathComponent.lowercased())
                && ((try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) {
                dirs.append(k)
            }
        }
        if fm.fileExists(atPath: installDir.path) { dirs.append(installDir) }
        lock.lock(); dirs.append(contentsOf: extraDirs); lock.unlock()
        var seen = Set<String>(), out: [URL] = []
        for d in dirs where seen.insert(d.standardizedFileURL.resolvingSymlinksInPath().path).inserted { out.append(d) }
        return out
    }

    // MARK: State persistence

    private struct StateFile: Codable {
        var manual: Bool
        var plugins: [PluginEnableState]
    }

    private func loadState() -> [PluginEnableState] {
        guard let data = try? Data(contentsOf: stateFile),
              let s = try? JSONDecoder().decode(StateFile.self, from: data) else {
            if !stateLoaded { stateLoaded = true }
            return []
        }
        if !stateLoaded { manual = s.manual; stateLoaded = true }
        return s.plugins
    }

    private func saveState(keepPlugins: Bool = false) {
        // Switching the manual flag must not freeze the original rule's "everything loads"
        // into the per-plug-in state (Apple only saves the list on a toggle / move).
        let list = keepPlugins ? loadState() : PluginSet.persistedState(of: plugins)
        let s = StateFile(manual: manual, plugins: list)
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateFile, options: .atomic) }
    }

    // MARK: Discovery / merge (called from NovaWorld.loadGame)

    /// Re-discovers plug-ins for `base` and applies the persisted enabled flags and order
    /// (Apple `prepareReload`). Returns the plug-ins to merge and whether order is manual.
    func rescan(base: URL) -> (plugins: [PluginBundle], manual: Bool, dirs: [URL]) {
        let dirs = pluginDirs(for: base)
        var discovered: [PluginBundle] = []
        for d in dirs { discovered.append(contentsOf: GameLibrary.discoverPlugins(in: d)) }
        lock.lock(); defer { lock.unlock() }
        let persisted = loadState()
        let inMemory = Set(pluginsAreManual ? plugins.filter(\.isEnabled).map(\.id) : [])
        plugins = PluginSet.arrange(discovered: discovered, persisted: persisted, inMemoryEnabled: inMemory, manual: manual)
        pluginsAreManual = manual
        baseDir = base
        searchedDirs = dirs
        return (plugins, manual, dirs)
    }

    /// Discover base files under `baseDir` (minus any that are really plug-in folders inside it),
    /// rescan plug-ins and merge. Nil when there is no readable base data.
    func loadMerged(baseDir: URL) -> ResourceCollection? {
        let r = rescan(base: baseDir)
        let pluginPaths = r.dirs.map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        let base = GameLibrary.discoverResourceFiles(in: baseDir).filter { f in
            let p = f.standardizedFileURL.resolvingSymlinksInPath().path
            return !pluginPaths.contains { p.hasPrefix($0) }
        }
        // `merge` never throws on an empty file list, so reject an empty base explicitly.
        guard !base.isEmpty else { return nil }
        let sink = PluginLoadFailureSink()
        guard let merged = try? GameLibrary.merge(baseFiles: base, plugins: r.plugins,
                                                  flatPluginOrder: !r.manual, failures: sink) else { return nil }
        recordLoad(failures: sink.failures)
        return merged
    }

    func recordLoad(failures f: [PluginLoadFailure]) {
        lock.lock(); failures = f; needsReload = false; lock.unlock()
    }

    // MARK: Mutations (UI)

    func setManual(_ on: Bool) {
        lock.lock()
        _ = loadState()
        manual = on
        needsReload = true
        saveState(keepPlugins: true)
        lock.unlock()
    }
    var isManual: Bool { lock.lock(); defer { lock.unlock() }; _ = loadState(); return manual }

    func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = loadState()
        guard PluginSet.setEnabled(&plugins, id: id, enabled: enabled, manual: manual) else { return false }
        saveState(); needsReload = true
        return true
    }

    func move(_ id: String, by offset: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = loadState()
        guard PluginSet.move(&plugins, id: id, by: offset, manual: manual) else { return false }
        saveState(); needsReload = true
        return true
    }

    func addDir(_ d: URL) { lock.lock(); extraDirs.append(d); needsReload = true; lock.unlock() }
    func clearDirs() { lock.lock(); extraDirs.removeAll(); lock.unlock() }
    func setStateFile(_ u: URL?) { lock.lock(); stateFileOverride = u; stateLoaded = false; lock.unlock() }
    func setInstallDir(_ u: URL?) { lock.lock(); installDirOverride = u; lock.unlock() }
    func markDirty() { lock.lock(); needsReload = true; lock.unlock() }

    func isUnderInstallDir(_ bundle: PluginBundle) -> Bool {
        let root = installDir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let first = bundle.allFileURLs.first ?? bundle.folderURL else { return false }
        return first.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }

    /// Removes a plug-in the store / importer put in the user folder (never the game's own
    /// "Nova Plug-ins" folder — those are the player's files).
    func delete(_ id: String) -> Bool {
        lock.lock(); let b = plugins.first { $0.id == id }; lock.unlock()
        guard let b, isUnderInstallDir(b) else { return false }
        let fm = FileManager.default
        let top = id.split(separator: "/").first.map(String.init) ?? id
        let folder = installDir.appendingPathComponent(top, isDirectory: true)
        if fm.fileExists(atPath: folder.path) { try? fm.removeItem(at: folder) }
        else { for u in b.fileURLs { try? fm.removeItem(at: u) } }
        markDirty()
        return true
    }

    // MARK: Import (a zip / loose container / folder the player already has)

    func importPlugin(from src: URL) throws -> String {
        let fm = FileManager.default
        let dest = installDir
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        let id: String
        if ext == "zip" {
            id = src.deletingPathExtension().lastPathComponent
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
            try fm.copyItem(at: src, to: tmp)   // the installer deletes what it unpacks
            _ = try PluginInstaller.install(archiveAt: tmp, id: id, into: dest)
        } else {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            guard isDir.boolValue || GameLibrary.resourceExtensions.contains(ext) else {
                throw PluginInstallError.unsupportedArchive
            }
            id = src.lastPathComponent
            let target = dest.appendingPathComponent(id, isDirectory: isDir.boolValue)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: src, to: target)
        }
        markDirty()
        return id
    }

    // MARK: Catalog + store

    private var provider: PluginCatalogProvider {
        PluginCatalogProvider(remoteURL: PluginCatalog.remoteURL,
                              cacheFile: root.appendingPathComponent("PluginCatalog.json"),
                              bundled: fallback)
    }

    /// The bundled catalog copy shipped with the Godot project (read from `path`).
    func setFallbackCatalog(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let doc = try? PluginCatalogProvider.decode(data) else { return false }
        lock.lock(); fallback = doc; lock.unlock()
        return true
    }

    /// Whatever can be shown without the network: the saved catalog, else the bundled copy.
    func catalogOffline() {
        let r = provider.offline()
        lock.lock(); entries = r.document.plugins; catalogSource = r.source.rawValue; lock.unlock()
    }

    func catalogLoadFile(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let doc = try? PluginCatalogProvider.decode(data) else { return false }
        lock.lock(); entries = doc.plugins; catalogSource = "file"; catalogError = nil; lock.unlock()
        return true
    }

    func catalogRefresh() {
        // NOVA_PLUGIN_OFFLINE=1: never touch the network (CI, self-checks, air-gapped Decks).
        if ProcessInfo.processInfo.environment["NOVA_PLUGIN_OFFLINE"] == "1" {
            lock.lock(); catalogError = "Offline mode (NOVA_PLUGIN_OFFLINE)"; lock.unlock()
            return
        }
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        let p = provider
        catalogTask = Task.detached { [self] in
            let r = await p.load()
            lock.lock()
            entries = r.document.plugins
            catalogSource = r.source.rawValue
            catalogError = r.remoteError
            refreshing = false
            lock.unlock()
        }
    }

    private func installedVersions() -> [String: String] {
        var out: [String: String] = [:]
        let dir = installDir
        lock.lock(); let list = entries; lock.unlock()
        for e in list where PluginInstaller.isInstalled(id: e.id, in: dir) {
            out[e.id] = PluginInstaller.info(id: e.id, in: dir)?.version ?? ""
        }
        return out
    }

    func catalogJSON() -> [String: Any] {
        let installed = installedVersions()
        lock.lock(); defer { lock.unlock() }
        let browser = PluginBrowser(entries: entries, installedVersions: installed)
        let list = entries.map { e -> [String: Any] in
            var status = "available", latest = e.version, have = ""
            switch browser.status(for: e) {
            case .notInstalled: break
            case .installed(let v): status = "installed"; have = v ?? ""
            case .updateAvailable(let v, let l): status = "update"; have = v ?? ""; latest = l
            }
            let t = transfers[e.id]
            return [
                "id": e.id, "name": e.name, "author": e.author, "version": latest,
                "installedVersion": have, "summary": e.summary, "description": e.description,
                "tags": e.tags, "tc": e.isTotalConversion, "status": status,
                "size": e.sizeBytes.map { formatPluginSize($0) } ?? "",
                "sizeBytes": e.sizeBytes ?? 0, "license": e.license ?? "",
                "homepage": e.homepageURL?.absoluteString ?? "",
                "icon": e.iconURL?.absoluteString ?? "",
                "downloadHost": e.downloadHost, "popularity": e.popularity, "recency": e.recencyDate,
                "dependencies": e.dependencies, "missingDependencies": browser.missingDependencies(of: e),
                "downloadable": !e.downloadURLs.isEmpty && e.downloadURLs.allSatisfy { $0.scheme?.lowercased() == "https" },
                "transfer": t.map { x -> [String: Any] in
                    ["working": x.error == nil, "progress": x.progress ?? -1.0, "error": x.error ?? ""] } ?? [:],
            ]
        }
        return ["entries": list, "source": catalogSource, "offline": catalogError != nil,
                "error": catalogError ?? "", "refreshing": refreshing,
                "updates": browser.updatesAvailable.map(\.id),
                "needsReload": needsReload, "busy": !tasks.isEmpty]
    }

    /// Installs or updates `id`, fetching missing dependencies first (Apple `PluginsModel.install`).
    func install(_ id: String) -> Bool {
        lock.lock()
        guard tasks[id] == nil, let entry = entries.first(where: { $0.id == id }),
              !entry.downloadURLs.isEmpty, catalogError == nil else { lock.unlock(); return false }
        // The catalog rule (memory: plugin catalog): direct HTTPS only, no exceptions.
        guard entry.downloadURLs.allSatisfy({ $0.scheme?.lowercased() == "https" }) else {
            transfers[id] = (nil, "This plug-in's download link is not HTTPS, so it was not fetched.")
            lock.unlock(); return false
        }
        transfers[id] = (nil, nil)
        let all = entries
        lock.unlock()
        let root = installDir
        let installed = installedVersions()
        tasks[id] = Task.detached { [self] in
            do {
                let browser = PluginBrowser(entries: all, installedVersions: installed)
                for depID in browser.missingDependencies(of: entry) {
                    guard let dep = all.first(where: { $0.id == depID }) else { continue }
                    try await PluginInstallPipeline.install(dep, into: root, progress: { p in self.setProgress(id, p) })
                }
                try await PluginInstallPipeline.install(entry, into: root, progress: { p in self.setProgress(id, p) })
                lock.lock(); transfers[id] = nil; needsReload = true; tasks[id] = nil; lock.unlock()
            } catch is CancellationError {
                lock.lock(); transfers[id] = nil; tasks[id] = nil; lock.unlock()
            } catch {
                lock.lock(); transfers[id] = (nil, error.localizedDescription); tasks[id] = nil; lock.unlock()
            }
        }
        return true
    }

    private func setProgress(_ id: String, _ p: Double?) {
        lock.lock(); if transfers[id]?.error == nil { transfers[id] = (p, nil) }; lock.unlock()
    }

    func cancel(_ id: String) {
        lock.lock(); tasks[id]?.cancel(); tasks[id] = nil; transfers[id] = nil; lock.unlock()
    }
    func dismissFailure(_ id: String) { lock.lock(); transfers[id] = nil; lock.unlock() }

    /// Test / offline seam: install `entry` from a local archive through the same installer
    /// (no network). Copies first — the installer deletes the file it unpacks.
    func installLocal(id: String, archive: URL, version: String?) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + archive.lastPathComponent)
        try fm.copyItem(at: archive, to: tmp)
        _ = try PluginInstaller.install(archiveAt: tmp, id: id, into: installDir, originalName: archive.lastPathComponent,
                                        version: version)
        markDirty()
    }

    /// Catalog artwork bytes once downloaded (empty while pending); starts the fetch on first ask.
    func image(_ url: URL) -> Data {
        lock.lock()
        if let d = images[url] { lock.unlock(); return d }
        guard url.scheme?.lowercased() == "https", imageTasks.insert(url).inserted else { lock.unlock(); return Data() }
        lock.unlock()
        let cache = RemoteImageCache(directory: root.appendingPathComponent("PluginImages", isDirectory: true))
        Task.detached { [self] in
            if let d = try? await cache.data(for: url) {
                lock.lock(); images[url] = d; lock.unlock()
            }
        }
        return Data()
    }
}

@Godot
class NovaPlugins: RefCounted {

    private weak var host: NovaWorld?

    /// Point at the live `NovaWorld` (needed by `reload`). Idempotent.
    @Callable(autoSnakeCase: true) func attach(world: NovaWorld) { host = world }

    // MARK: Installed plug-ins

    /// `[{id,name,kind,kindLabel,enabled,total_conversion,optional,files,index,folder,source,
    ///    deletable,loadsAutomatically,canToggle}]` in load order.
    @Callable(autoSnakeCase: true) func list() -> String {
        let rt = PluginRuntime.shared
        let manual = rt.isManual
        let rows = rt.plugins.enumerated().map { i, p -> [String: Any] in
            let kind = p.kind
            return ["id": p.id, "name": p.name, "kind": kind.rawValue, "kindLabel": kind.label,
                    "enabled": p.isEnabled, "total_conversion": p.isTotalConversion,
                    "optional": p.isOptional, "files": p.allFileURLs.map(\.lastPathComponent),
                    "index": i,
                    "folder": (p.allFileURLs.first ?? p.folderURL)?.deletingLastPathComponent().path ?? "",
                    "deletable": rt.isUnderInstallDir(p),
                    "canToggle": manual || p.isTotalConversion]
        }
        return Self.json(rows)
    }

    /// `{manual, dirs, installDir, base, failures:[{plugin,file,message}], needsReload}`.
    @Callable(autoSnakeCase: true) func state() -> String {
        let rt = PluginRuntime.shared
        return Self.json([
            "manual": rt.isManual, "dirs": rt.searchedDirs.map(\.path), "installDir": rt.installDir.path,
            "base": rt.baseDir?.path ?? "", "needsReload": rt.needsReload,
            "failures": rt.failures.map { ["plugin": $0.pluginID, "file": $0.fileName, "message": $0.message] },
        ] as [String: Any])
    }

    /// Re-scan the plug-in folders without touching the loaded data (to refresh `list`).
    @Callable(autoSnakeCase: true) func rescan() {
        let rt = PluginRuntime.shared
        guard let base = rt.baseDir else { return }
        _ = rt.rescan(base: base)
    }

    /// The manual plug-in order enhancement (Apple `manualPluginOrder`): off = the original
    /// rule, every plug-in loads alphabetically; on = choose which load and in what order.
    @Callable(autoSnakeCase: true) func setManualOrder(on: Bool) {
        PluginRuntime.shared.setManual(on)
        rescan()
    }
    @Callable(autoSnakeCase: true) func manualOrder() -> Bool { PluginRuntime.shared.isManual }

    @Callable(autoSnakeCase: true) func setEnabled(id: String, enabled: Bool) -> Bool {
        PluginRuntime.shared.setEnabled(id, enabled)
    }
    @Callable(autoSnakeCase: true) func move(id: String, offset: Int) -> Bool {
        PluginRuntime.shared.move(id, by: offset)
    }
    @Callable(autoSnakeCase: true) func needsReload() -> Bool { PluginRuntime.shared.needsReload }

    /// Re-run the game-data load with the current plug-in set (rebuilds the galaxy / data the
    /// way the Apple `GameDataController.reload` does). Returns false if no data folder is known.
    /// Heavy: show a loading indicator first. Safe only while no world is being played (the
    /// main menu), since the data objects are replaced.
    @Callable(autoSnakeCase: true) func reload() -> Bool {
        guard let host, let base = PluginRuntime.shared.baseDir else { return false }
        return host.loadGame(baseDir: base.path)
    }

    /// Resource count of the currently loaded merged data (for display / checks).
    @Callable(autoSnakeCase: true) func loadedResourceCount() -> Int {
        host?.dbgGame?.resources.totalCount ?? 0
    }

    /// Count of one resource type (4-char code, e.g. "shïp") in the merged data.
    @Callable(autoSnakeCase: true) func loadedTypeCount(type: String) -> Int {
        FourCharCode(type).flatMap { host?.dbgGame?.resources.resources(of: $0).count } ?? 0
    }

    /// `{pluginId: {type: count}}` of merged resources by the layer that supplied them
    /// (`""` = base game). Shows what a plug-in actually contributes after overrides.
    @Callable(autoSnakeCase: true) func contributionSummary() -> String {
        guard let res = host?.dbgGame?.resources else { return "{}" }
        var out: [String: [String: Int]] = [:]
        for t in res.types {
            for r in res.resources(of: t) { out[r.pluginID, default: [:]][t.stringValue, default: 0] += 1 }
        }
        return Self.json(out)
    }

    /// Which layer supplied a merged resource: "" = base game, else the plug-in id; "?" = absent.
    @Callable(autoSnakeCase: true) func resourceSource(type: String, id: Int) -> String {
        guard let t = FourCharCode(type), let r = host?.dbgGame?.resources.resource(t, id) else { return "?" }
        return r.pluginID
    }

    // MARK: Plug-in media (music, movies)

    /// Folders to search for loose media (title music, `dësc` movies) in priority order, as JSON
    /// `[path]`: the selected total conversion's own `Plug-Ins` + `Nova Files` (global plug-ins do
    /// not apply under a TC, as in `GameLibrary.resolveLayers`), else the enabled plug-ins' folders
    /// (later load order first), then the base data folder. Original rule (`FUN_004ab5d0`,
    /// `Ui_PlayMovieFileModal`): "Nova Plug-ins" before "Nova Files".
    @Callable(autoSnakeCase: true) func mediaDirs() -> String {
        let rt = PluginRuntime.shared
        var out: [String] = []
        func add(_ u: URL?) {
            guard let p = u?.path, !p.isEmpty, !out.contains(p) else { return }
            out.append(p)
        }
        let active = rt.plugins.filter(\.isEnabled)
        if let tc = active.last(where: \.isTotalConversion) {
            for u in tc.fileURLs { add(u.deletingLastPathComponent()) }
            for u in tc.novaFilesURLs { add(u.deletingLastPathComponent()) }
        } else {
            for p in active.reversed() {
                for u in p.allFileURLs { add(u.deletingLastPathComponent()) }
                add(p.folderURL)
            }
        }
        add(rt.baseDir)
        return Self.json(out)
    }

    /// The movie file a `dësc` record names ("" = none), plus whether it plays after the text:
    /// `{movie, after}`. The Apple app plays it with the mission offer (`MissionBoardView`).
    @Callable(autoSnakeCase: true) func descMovie(id: Int) -> String {
        guard let d = host?.dbgGame?.desc(id), let m = d.movieFilename else { return Self.json(["movie": "", "after": false] as [String: Any]) }
        return Self.json(["movie": m, "after": d.moviePlaysAfterText] as [String: Any])
    }

    // MARK: Folders (tests, "add folder")

    @Callable(autoSnakeCase: true) func addDir(path: String) { PluginRuntime.shared.addDir(URL(fileURLWithPath: path, isDirectory: true)) }
    @Callable(autoSnakeCase: true) func clearDirs() { PluginRuntime.shared.clearDirs() }
    /// Override where enabled/order state is stored (default `<data root>/plugins-state.json`).
    @Callable(autoSnakeCase: true) func setStateFile(path: String) {
        PluginRuntime.shared.setStateFile(path.isEmpty ? nil : URL(fileURLWithPath: path))
    }
    /// Override the user plug-in (install) folder (default `<data root>/Plug-ins`).
    @Callable(autoSnakeCase: true) func setInstallDir(path: String) {
        PluginRuntime.shared.setInstallDir(path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true))
    }
    @Callable(autoSnakeCase: true) func installDir() -> String { PluginRuntime.shared.installDir.path }

    /// `{ok,id,error}` — import a .zip / .rez / .ndat / folder the player already has.
    @Callable(autoSnakeCase: true) func importFrom(path: String) -> String {
        do {
            let id = try PluginRuntime.shared.importPlugin(from: URL(fileURLWithPath: path))
            return Self.json(["ok": true, "id": id, "error": ""] as [String: Any])
        } catch {
            return Self.json(["ok": false, "id": "", "error": error.localizedDescription] as [String: Any])
        }
    }

    @Callable(autoSnakeCase: true) func delete(id: String) -> Bool { PluginRuntime.shared.delete(id) }

    // MARK: Online catalog

    /// The catalog copy shipped with the Godot project, used when offline and uncached.
    @Callable(autoSnakeCase: true) func setBundledCatalog(path: String) -> Bool {
        PluginRuntime.shared.setFallbackCatalog(path: path)
    }
    /// Show what is available without the network (saved or bundled catalog).
    @Callable(autoSnakeCase: true) func catalogOffline() { PluginRuntime.shared.catalogOffline() }
    /// Fetch the online catalog in the background (HTTPS); poll `catalog_state`.
    @Callable(autoSnakeCase: true) func catalogRefresh() { PluginRuntime.shared.catalogRefresh() }
    /// Load a catalog from a local JSON file (fixtures; never touches the network).
    @Callable(autoSnakeCase: true) func catalogLoadFile(path: String) -> Bool { PluginRuntime.shared.catalogLoadFile(path: path) }
    @Callable(autoSnakeCase: true) func catalogState() -> String { Self.json(PluginRuntime.shared.catalogJSON()) }
    @Callable(autoSnakeCase: true) func install(id: String) -> Bool { PluginRuntime.shared.install(id) }
    @Callable(autoSnakeCase: true) func cancelInstall(id: String) { PluginRuntime.shared.cancel(id) }
    @Callable(autoSnakeCase: true) func dismissFailure(id: String) { PluginRuntime.shared.dismissFailure(id) }
    /// Install from a local archive via the real installer (no network): `{ok,error}`.
    @Callable(autoSnakeCase: true) func installLocal(id: String, archivePath: String, version: String) -> String {
        do {
            try PluginRuntime.shared.installLocal(id: id, archive: URL(fileURLWithPath: archivePath),
                                                  version: version.isEmpty ? nil : version)
            return Self.json(["ok": true, "error": ""] as [String: Any])
        } catch {
            return Self.json(["ok": false, "error": error.localizedDescription] as [String: Any])
        }
    }
    /// Catalog artwork (PNG / JPEG bytes) for an https URL; empty until downloaded.
    @Callable(autoSnakeCase: true) func image(url: String) -> PackedByteArray {
        guard let u = URL(string: url) else { return PackedByteArray() }
        return PackedByteArray([UInt8](PluginRuntime.shared.image(u)))
    }

    private static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}
