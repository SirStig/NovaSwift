import Foundation
import NovaSwiftKit
import NovaSwiftNet
import NovaSwiftPluginStore

/// The server's plug-ins: the NovaSwift catalog (browse + download), plug-ins the admin adds from a file, and the
/// gameplay manifest computed from the files on disk (no game and no EV Nova data involved). Players joining get
/// the manifest and, for catalog plug-ins, the one-click "Install & Join" prompt.
public final class PluginManager {
    public struct Job: Equatable {
        public enum State: String { case queued, downloading, installing, done, failed }
        public var id: String
        public var state: State
        public var progress: Double?
        public var message: String
    }

    public struct InstalledPlugin: Equatable {
        public var id: String
        public var name: String
        public var isTotalConversion: Bool
        public var cosmetic: Bool
        public var contentHash: String
        public var sizeBytes: Int64
        public var fromCatalog: Bool
        public var version: String?
        public var fileCount: Int
    }

    public struct CatalogState {
        public var entries: [PluginCatalogEntry]
        public var source: String       // "remote" | "cache" | "none"
        public var error: String?
        public var fetchedAt: Date?
    }

    public let pluginsDir: URL
    private let cacheDir: URL
    private let log: ServerLog
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var catalogState = CatalogState(entries: [], source: "none", error: nil, fetchedAt: nil)
    private var analysisCache: [String: PluginGameplay.Result] = [:]
    /// Test hook: replaces the network fetch of catalog.json.
    var catalogFetch: PluginCatalogProvider.Fetch = PluginCatalogProvider.urlSessionFetch
    /// Test hook: replaces the download of a plug-in archive.
    var archiveFetch: (([URL], String?) async throws -> (file: URL, name: String))?
    public var catalogURL = PluginCatalog.remoteURL

    public init(paths: ServerPaths, log: ServerLog) {
        pluginsDir = paths.pluginsDir
        cacheDir = paths.cacheDir
        self.log = log
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("catalog.json")),
           let doc = try? PluginCatalogProvider.decode(data) {
            catalogState = CatalogState(entries: doc.plugins, source: "cache", error: nil, fetchedAt: nil)
        }
    }

    // MARK: Catalog

    public var catalog: CatalogState { lock.lock(); defer { lock.unlock() }; return catalogState }

    /// Fetch the catalog (falls back to the saved copy when offline). Completion on a background thread.
    public func refreshCatalog(completion: (() -> Void)? = nil) {
        let provider = PluginCatalogProvider(
            remoteURL: catalogURL, cacheFile: cacheDir.appendingPathComponent("catalog.json"),
            bundled: PluginCatalogDocument(plugins: []), fetch: catalogFetch)
        Task {
            let r = await provider.load()
            self.storeCatalog(r)
            if let e = r.remoteError { self.log.warn("Plug-in catalog: \(e)") }
            else { self.log.info("Plug-in catalog loaded: \(r.document.plugins.count) plug-ins.") }
            completion?()
        }
    }

    private func storeCatalog(_ r: PluginCatalogResult) {
        lock.lock(); defer { lock.unlock() }
        catalogState = CatalogState(
            entries: r.document.plugins,
            source: r.source == .remote ? "remote" : (r.document.plugins.isEmpty ? "none" : "cache"),
            error: r.remoteError.map { "Couldn't reach the plug-in catalog (\($0)). Showing the last saved copy." },
            fetchedAt: r.source == .remote ? Date() : catalogState.fetchedAt)
    }

    private func dropAnalysis(_ id: String) {
        lock.lock(); analysisCache = analysisCache.filter { !$0.key.hasPrefix(id + "|") }; lock.unlock()
    }

    public func catalogEntry(_ id: String) -> PluginCatalogEntry? { catalog.entries.first { $0.id == id } }

    // MARK: Install / remove

    public var activeJobs: [Job] { lock.lock(); defer { lock.unlock() }; return jobs.values.sorted { $0.id < $1.id } }
    public func job(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    private func setJob(_ id: String, _ state: Job.State, progress: Double? = nil, _ message: String = "") {
        lock.lock(); jobs[id] = Job(id: id, state: state, progress: progress, message: message); lock.unlock()
    }

    public func isInstalled(_ id: String) -> Bool { PluginInstaller.isInstalled(id: id, in: pluginsDir) }

    /// Download + install a catalog plug-in (and the plug-ins it depends on). Returns immediately; poll `job(_:)`.
    /// `completion` runs when it finishes (success or failure).
    public func install(catalogID id: String, completion: ((Bool) -> Void)? = nil) {
        guard let entry = catalogEntry(id) else {
            setJob(id, .failed, "\"\(id)\" isn't in the plug-in catalog.")
            completion?(false); return
        }
        if let j = job(id), j.state == .queued || j.state == .downloading || j.state == .installing { return }
        setJob(id, .queued, "Waiting...")
        Task {
            var ok = true
            for dep in entry.dependencies where !self.isInstalled(dep) {
                if self.catalogEntry(dep) != nil { ok = await self.installNow(dep) && ok }
            }
            ok = await self.installNow(id) && ok
            completion?(ok)
        }
    }

    @discardableResult
    func installNow(_ id: String) async -> Bool {
        guard let entry = catalogEntry(id) else { setJob(id, .failed, "\"\(id)\" isn't in the plug-in catalog."); return false }
        guard !entry.downloadURLs.isEmpty else {
            setJob(id, .failed, "\(entry.name) has no download link in the catalog, so it can't be installed automatically. Add the file by hand instead.")
            return false
        }
        setJob(id, .downloading, progress: nil, "Downloading \(entry.name)...")
        log.info("Downloading plug-in \(entry.name) from \(entry.downloadHost)...")
        do {
            let (file, name): (URL, String)
            if let archiveFetch { (file, name) = try await archiveFetch(entry.downloadURLs, entry.sha256) }
            else {
                (file, name) = try await PluginDownloader.download(from: entry.downloadURLs, sha256: entry.sha256) { [weak self] p in
                    self?.setJob(id, .downloading, progress: p, "Downloading \(entry.name)...")
                }
            }
            setJob(id, .installing, "Unpacking...")
            try PluginInstaller.install(archiveAt: file, id: id, into: pluginsDir, originalName: name,
                                        version: entry.version, sha256: entry.sha256)
            dropAnalysis(id)
            setJob(id, .done, "Installed.")
            log.info("Installed plug-in \(entry.name) \(entry.version).")
            return true
        } catch {
            let msg = Self.friendly(error, name: entry.name)
            setJob(id, .failed, msg)
            log.error("Plug-in \(entry.name): \(msg)")
            return false
        }
    }

    static func friendly(_ error: Error, name: String) -> String {
        let d = error.localizedDescription
        if let u = error as? URLError, u.code == .notConnectedToInternet || u.code == .cannotFindHost || u.code == .timedOut {
            return "Couldn't download \(name): the server has no internet connection (or the download site is down)."
        }
        return "Couldn't install \(name): \(d)"
    }

    /// Add a plug-in the admin supplies (a .zip or a loose .rez / .ndat). Not from the catalog, so players have to
    /// get it themselves. Returns the plug-in id (the folder name).
    @discardableResult
    public func addLocal(file: URL, originalName: String) throws -> String {
        let base = (originalName as NSString).deletingPathExtension
        let id = Self.sanitizeID(base.isEmpty ? "plugin" : base)
        let ext = (originalName as NSString).pathExtension.lowercased()
        guard ["zip", "rez", "ndat", "sit", "hqx", "sea", "bin"].contains(ext) else {
            throw PluginInstallError.unsupportedArchive
        }
        try PluginInstaller.install(archiveAt: file, id: id, into: pluginsDir, originalName: originalName,
                                    version: "local")
        dropAnalysis(id)
        // A plug-in with no resource files in it is useless: say so right away.
        if GameLibrary.discoverPlugins(in: pluginsDir).first(where: { $0.id == id }) == nil {
            try? FileManager.default.removeItem(at: pluginsDir.appendingPathComponent(id))
            throw LocalPluginError.noResources
        }
        log.info("Added local plug-in \(id).")
        return id
    }

    public enum LocalPluginError: Error, LocalizedError {
        case noResources
        public var errorDescription: String? { "That file doesn't contain any EV Nova plug-in data (.rez / .ndat files)." }
    }

    public static func sanitizeID(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        var out = String(s.filter { allowed.contains($0) }).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if out.isEmpty { out = "plugin" }
        return String(out.prefix(60))
    }

    public func remove(_ id: String) throws {
        let dir = pluginsDir.appendingPathComponent(id)
        guard dir.standardizedFileURL.deletingLastPathComponent().path == pluginsDir.standardizedFileURL.path else { return }
        try FileManager.default.removeItem(at: dir)
        dropAnalysis(id)
    }

    // MARK: Manifest from the files

    /// Plug-ins found on disk (top level only, as the game itself loads them).
    public func installed() -> [InstalledPlugin] {
        let bundles = GameLibrary.discoverPlugins(in: pluginsDir).filter { !$0.isOptional }
        let cat = catalog.entries
        return bundles.map { b in
            let r = analyze(b)
            let info = PluginInstaller.info(id: b.id, in: pluginsDir)
            let size = b.allFileURLs.reduce(Int64(0)) { $0 + Int64((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
            return InstalledPlugin(id: b.id, name: cat.first { $0.id == b.id }?.name ?? b.name, isTotalConversion: b.isTotalConversion,
                                   cosmetic: r.cosmetic, contentHash: r.hash, sizeBytes: size,
                                   fromCatalog: cat.contains { $0.id == b.id } && info?.version != "local",
                                   version: info?.version, fileCount: b.allFileURLs.count)
        }
    }

    func analyze(_ b: PluginBundle) -> PluginGameplay.Result {
        let key = stamp(b)
        lock.lock(); if let r = analysisCache[key] { lock.unlock(); return r }; lock.unlock()
        let r = PluginGameplay.analyze(b)
        lock.lock(); analysisCache[key] = r; lock.unlock()
        return r
    }

    private func stamp(_ b: PluginBundle) -> String {
        var parts = [b.id + "|"]
        for url in b.allFileURLs.sorted(by: { $0.path < $1.path }) {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.intValue ?? -1
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            parts.append("\(url.lastPathComponent)|\(size)|\(Int(m))")
        }
        return parts.joined(separator: ";")
    }

    public struct Manifest {
        public var all: PluginManifest                // gameplay + cosmetic
        public var requirements: PluginRequirements   // what the beacon / directory advertise
        public var missing: [String]                  // enabled ids not on disk
    }

    /// The manifest of the enabled plug-ins, hashed from their files. `enabled` is the load order.
    public func manifest(enabled: [String]) -> Manifest {
        let bundles = Dictionary(GameLibrary.discoverPlugins(in: pluginsDir).filter { !$0.isOptional }.map { ($0.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        var reqs: [PluginRequirement] = []
        var missing: [String] = []
        var tc: String?
        var addOns: [String] = []
        for id in enabled {
            guard let b = bundles[id] else { missing.append(id); continue }
            let r = analyze(b)
            let name = catalogEntry(id)?.name ?? b.name
            reqs.append(PluginRequirement(id: id, name: name, contentHash: r.hash, cosmetic: r.cosmetic))
            if b.isTotalConversion { tc = tc ?? id } else { addOns.append(id) }
        }
        let gameplay = reqs.filter { !$0.cosmetic }
        let addOnIDs = tc == nil ? [] : addOns.filter { id in gameplay.contains { $0.id == id } }
        return Manifest(all: PluginManifest(reqs),
                        requirements: PluginRequirements(plugins: gameplay, totalConversion: tc, addOns: addOnIDs),
                        missing: missing)
    }
}
