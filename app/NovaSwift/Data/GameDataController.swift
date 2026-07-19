import Foundation
import SwiftUI
import CoreText
import NovaSwiftKit
import NovaSwiftStory
import NovaSwiftPluginStore

/// Locates game data and the plug-in catalog, tracks which plug-ins are enabled,
/// and produces a merged `NovaGame` for the engine.
///
/// Data sources, in priority order:
///  1. User-imported base data in Application Support (the mobile BYO-data path).
///  2. A dev override via the `NOVASWIFT_DATA` environment variable (points at a
///     `Nova Files` folder) — used when running from the repo.
///  3. A bundled plug-in catalog (prebundled, toggleable) — see docs/MOBILE_AND_PLUGINS.md §3.
@MainActor
final class GameDataController: ObservableObject {
    @Published private(set) var hasBaseData = false
    @Published private(set) var plugins: [PluginBundle] = []
    @Published private(set) var status: String = "No game data imported yet."

    /// The latest prewarm report, in order. Kept separate from `status` so the
    /// loading screen's transient per-sprite chatter doesn't overwrite the
    /// launcher's "Loaded N resources…" summary pill.
    @Published private(set) var prewarmProgress: PrewarmProgress?
    /// `prewarmProgress.fraction`, clamped to never decrease.
    @Published private(set) var prewarmFraction: Double = 0

    /// The resolved game, once base data is available.
    private(set) var game: NovaGame?
    private var loaded = false

    /// Every tagged mission's storyline key/title (`StorylineAnalyzer.storylineTags()`),
    /// prewarmed once per data set — see `prewarm()`. Mission-offer screens read
    /// this instead of each re-scanning the whole mission/cron control-bit graph.
    private(set) var storylineTags: [Int: MissionStorylineTag] = [:]
    private var storylineTagCache: StorylineTagCache?

    init() {
        // So titles/chrome look intentional (not system-font-default) even
        // before any game data is imported.
        Self.registerBundledFallbackFonts()
    }

    // MARK: Locations

    private var appSupport: URL {
        NovaStorage.root.appendingPathComponent("NovaSwift", isDirectory: true)
    }

    /// Where imported base data lives on device.
    var importedBaseDir: URL { appSupport.appendingPathComponent("Base/Nova Files", isDirectory: true) }
    /// Where imported plug-ins live on device.
    var importedPluginsDir: URL { appSupport.appendingPathComponent("Plugins", isDirectory: true) }

    /// Bundled plug-ins shipped inside the app (if present in the app bundle).
    private var bundledPluginsDir: URL? {
        Bundle.main.url(forResource: "Plugins", withExtension: nil)
    }

    /// Audio file extensions EV Nova's shipped soundtrack might use (e.g. the
    /// Community Edition's `Nova Music.mp3`). Shared with `DataImporter` so the
    /// import step actually copies the track alongside the `.rez`/`.ndat` files
    /// — `GameLibrary.discoverResourceFiles` deliberately excludes it.
    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "aiff", "aif", "wav"]

    /// Recursively find audio files under `directory` (music lives a folder
    /// down from wherever the resource files are, e.g. "Nova Files/Nova Music.mp3").
    nonisolated static func discoverAudioFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// The game's original fonts (Charcoal.ttf, Geneva.ttf) — copyrighted, so
    /// like audio they're not part of `GameLibrary.resourceExtensions` and must
    /// be discovered/copied separately by the importer, then registered with
    /// CoreText at runtime (see `registerFonts(from:)`) rather than bundled.
    nonisolated static let fontExtensions: Set<String> = ["ttf", "otf"]

    /// Recursively find font files under `directory` (they ship a folder up
    /// from "Nova Files", alongside the .exe, in the CE Windows distribution).
    nonisolated static func discoverFontFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { fontExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Holovid clip extensions — the base install's Galaxy Racing Network races
    /// ship as "Race 1.mov".."Race 4.mov" alongside the `.rez`/`.ndat` files.
    /// Like audio and fonts these aren't resource containers, so
    /// `GameLibrary.discoverResourceFiles` skips them and the importer must copy
    /// them explicitly — otherwise `raceVideoURL()` finds nothing in the sandbox
    /// copy and the Bar's Gambling screen hangs on a loading spinner.
    nonisolated static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Recursively find holovid files under `directory`.
    nonisolated static func discoverVideoFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Registers any imported font files with CoreText for this process, so
    /// `Font.custom("Charcoal"/"Geneva", size:)` resolves to the game's actual
    /// fonts instead of the bundled free lookalikes (see `registerBundledFallbackFonts()`).
    /// Safe to call repeatedly (e.g. on every `reload()`) — duplicate
    /// registration errors are expected and ignored.
    nonisolated static func registerFonts(from directory: URL) {
        for url in discoverFontFiles(in: directory) { registerFont(at: url) }
        NovaFontAvailability.reset()
    }

    /// Registers the free, SIL-OFL-licensed fonts bundled with the app
    /// (`Resources/Fonts/`) — close visual stand-ins for Charcoal/Geneva, used
    /// until the player imports their own copy of the real fonts. See
    /// `NovaFontFallback` for the family-name mapping. Called once at launch;
    /// safe to call repeatedly.
    nonisolated static func registerBundledFallbackFonts() {
        for name in NovaFontFallback.bundledFontFileNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            else {
                Log.data.error("Bundled fallback font \(name, privacy: .public).ttf not found in app bundle")
                continue
            }
            registerFont(at: url)
        }
        NovaFontAvailability.reset()
    }

    private nonisolated static func registerFont(at url: URL) {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let error {
            let nsError = error.takeUnretainedValue() as Error as NSError
            // kCTFontManagerErrorAlreadyRegistered — expected on repeat calls.
            if nsError.code != CTFontManagerError.alreadyRegistered.rawValue {
                Log.data.error("Font registration failed for \(url.lastPathComponent, privacy: .public): \(nsError, privacy: .public)")
            }
        }
    }

    /// Resolve the base "Nova Files" directory from the available sources.
    private func resolveBaseDir() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: importedBaseDir.path),
           !GameLibrary.discoverResourceFiles(in: importedBaseDir).isEmpty {
            return importedBaseDir
        }
        if let dev = ProcessInfo.processInfo.environment["NOVASWIFT_DATA"],
           !dev.isEmpty, fm.fileExists(atPath: dev) {
            return URL(fileURLWithPath: dev)
        }
        return nil
    }

    private func resolvePluginDirs() -> [URL] {
        var dirs: [URL] = []
        if let b = bundledPluginsDir { dirs.append(b) }
        if FileManager.default.fileExists(atPath: importedPluginsDir.path) {
            dirs.append(importedPluginsDir)
        }
        // Dev convenience: repo plug-ins next to NOVASWIFT_DATA/../..
        if let dev = ProcessInfo.processInfo.environment["NOVASWIFT_PLUGINS"], !dev.isEmpty {
            dirs.append(URL(fileURLWithPath: dev))
        }
        return dirs
    }

    // MARK: Loading

    func reloadIfNeeded() { if !loaded { reload() } }

    /// Like `reloadIfNeeded`, but runs the container parse/merge off the main
    /// actor so the loading screen stays live while ~60 MB of `.rez`/`.ndat`
    /// is read and parsed. The launcher path awaits this instead of the blocking
    /// `reloadIfNeeded`. No-op once loaded.
    func reloadIfNeededAsync() async { if !loaded { await reloadAsync() } }

    /// Eagerly decodes the catalog (ships/outfits/governments) and every hull's
    /// sprites off the main thread, publishing progress through
    /// `prewarmProgress` — see `NovaGame.prewarm`. Meant to run once on the
    /// loading screen between picking/creating a pilot and entering the game, so
    /// the first Shipyard/Outfitter visit and the first time a hull is seen never
    /// pay decode cost mid-frame. No-op if data hasn't loaded. Safe to await from
    /// the main actor.
    ///
    /// Reports stream through an `AsyncStream` rather than one unstructured
    /// `Task { @MainActor in … }` per callback: those tasks carry no ordering
    /// guarantee between them, so a later "210/266" could be applied before an
    /// earlier "200/266" and the counter would visibly jump around. The stream
    /// preserves the order `prewarm` produced them in; `max` is a cheap belt to
    /// the stream's braces, keeping the published fraction monotonic.
    func prewarm() async {
        guard let game else { return }
        let reports = AsyncStream<PrewarmProgress> { continuation in
            Task.detached(priority: .userInitiated) {
                game.prewarm { continuation.yield($0) }
                continuation.finish()
            }
        }
        for await report in reports {
            prewarmProgress = report
            prewarmFraction = max(prewarmFraction, report.fraction)
        }
        await prewarmStorylineTags(game: game)
    }

    /// Loads the mission→storyline table from disk cache, or (on a miss)
    /// rebuilds it off-main from the loaded data and writes it back — so a
    /// warm cache costs a JSON read and a cold one costs it exactly once per
    /// data set, not once per mission screen. Reported through the same
    /// `prewarmProgress`/`prewarmFraction` the sprite prewarm uses, so the
    /// loading screen shows it as one more phase.
    private func prewarmStorylineTags(game: NovaGame) async {
        prewarmProgress = PrewarmProgress(phase: "Charting storylines", completed: 0, total: 1)
        if let cached = storylineTagCache?.load() {
            storylineTags = cached
            prewarmProgress = PrewarmProgress(phase: "Charting storylines", completed: 1, total: 1)
            prewarmFraction = max(prewarmFraction, 1)
            return
        }
        let cache = storylineTagCache
        let tags = await Task.detached(priority: .userInitiated) {
            StorylineAnalyzer(game: game).storylineTags()
        }.value
        storylineTags = tags
        prewarmProgress = PrewarmProgress(phase: "Charting storylines", completed: 1, total: 1)
        prewarmFraction = max(prewarmFraction, 1)
        cache?.store(tags)
    }

    func reload() {
        guard let (baseDir, baseFiles) = prepareReload() else { return }
        do {
            applyMerged(try GameLibrary.merge(baseFiles: baseFiles, plugins: plugins),
                        baseDir: baseDir, baseFiles: baseFiles)
        } catch {
            applyMergeFailure(String(describing: error), baseDir: baseDir)
        }
    }

    /// Off-main variant of `reload()`: the container parse/merge (the expensive,
    /// blocking part) runs on a detached task; only the cheap discovery prologue
    /// and the final published-state assignment touch the main actor.
    func reloadAsync() async {
        guard let (baseDir, baseFiles) = prepareReload() else { return }
        let pluginsSnapshot = plugins
        let (merged, errorText): (ResourceCollection?, String?) =
            await Task.detached(priority: .userInitiated) {
                do { return (try GameLibrary.merge(baseFiles: baseFiles, plugins: pluginsSnapshot), nil) }
                catch { return (nil, String(describing: error)) }
            }.value
        if let merged {
            applyMerged(merged, baseDir: baseDir, baseFiles: baseFiles)
        } else {
            applyMergeFailure(errorText ?? "unknown error", baseDir: baseDir)
        }
    }

    /// Shared prologue for both reload paths: discover plug-ins, preserve their
    /// enabled state, resolve the base dir and register its fonts. Returns the
    /// base dir and its resource files, or nil if there's no base data (having
    /// already published the "no data" state).
    private func prepareReload() -> (baseDir: URL, baseFiles: [URL])? {
        loaded = true
        // Discover plug-ins (catalog is available even before base data).
        var discovered: [PluginBundle] = []
        for dir in resolvePluginDirs() {
            discovered.append(contentsOf: GameLibrary.discoverPlugins(in: dir))
        }
        // Preserve enabled state and load order across reloads (in-memory) and
        // app launches (persisted — see `pluginStateKey`). Persisted state wins
        // for order (it's the only durable record of a user's drag/reorder);
        // in-memory state is folded into "enabled" too so a toggle earlier this
        // launch survives a reload that races the save.
        let persisted = Self.loadPluginState()
        let persistedOrder = Dictionary(uniqueKeysWithValues: persisted.enumerated().map { ($1.id, $0) })
        let previouslyEnabled = Set(plugins.filter(\.isEnabled).map(\.id))
            .union(persisted.filter(\.isEnabled).map(\.id))
        for i in discovered.indices where previouslyEnabled.contains(discovered[i].id) {
            discovered[i].isEnabled = true
        }
        // Known IDs sort by their persisted position; newly-discovered plug-ins
        // (never seen before) fall after all known ones, alphabetically among themselves.
        discovered.sort { a, b in
            switch (persistedOrder[a.id], persistedOrder[b.id]) {
            case let (ai?, bi?): return ai < bi
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        plugins = discovered
        Log.data.debug("reload: \(discovered.count, privacy: .public) plug-in(s) discovered, \(discovered.filter(\.isEnabled).count, privacy: .public) enabled")

        guard let baseDir = resolveBaseDir() else {
            hasBaseData = false
            game = nil
            status = "No EV Nova data found. Import your game data to play. \(plugins.count) plug-in(s) ready."
            Log.data.notice("reload: no base game data found (checked \(self.importedBaseDir.path, privacy: .public) and NOVASWIFT_DATA) — \(self.plugins.count, privacy: .public) plug-in(s) ready but nothing to play")
            return nil
        }
        Log.data.info("reload: using base data at \(baseDir.path, privacy: .public)")
        Self.registerFonts(from: baseDir)
        return (baseDir, GameLibrary.discoverResourceFiles(in: baseDir))
    }

    /// Publish a successfully merged data set, attaching a cross-launch decoded-
    /// sprite cache keyed by the data set's fingerprint (see `SpriteDiskCache`).
    private func applyMerged(_ merged: ResourceCollection, baseDir: URL, baseFiles: [URL]) {
        let fingerprint = GameLibrary.fingerprint(baseFiles: baseFiles, plugins: plugins)
        let spriteCache = SpriteDiskCache(fingerprint: fingerprint)
        game = NovaGame(merged, spriteCache: spriteCache)
        storylineTagCache = StorylineTagCache(fingerprint: fingerprint)
        storylineTags = [:]   // stale from any previous data set until `prewarm()` recomputes
        hasBaseData = true
        status = "Loaded \(merged.totalCount) resources from base + \(plugins.filter(\.isEnabled).count) plug-in(s)."
        let byType = merged.typeCounts.map { "\($0.type)=\($0.count)" }.joined(separator: ", ")
        Log.data.info("reload: loaded \(merged.totalCount, privacy: .public) resource(s) from base (\(baseFiles.count, privacy: .public) file(s)) + \(self.plugins.filter(\.isEnabled).count, privacy: .public) plug-in(s) — by type: \(byType, privacy: .public)")
    }

    private func applyMergeFailure(_ message: String, baseDir: URL) {
        hasBaseData = false
        game = nil
        status = "Failed to load data: \(message)"
        Log.data.error("reload: failed to merge game data from \(baseDir.path, privacy: .public): \(message, privacy: .public)")
    }

    func setPlugin(_ id: String, enabled: Bool) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].isEnabled = enabled
        Self.savePluginState(plugins)
        reload()
    }

    /// Moves the plug-in at `id` `offset` places within the load-order list
    /// (negative = earlier/lower priority, positive = later/higher priority —
    /// see `GameLibrary.merge`, which applies enabled plug-ins in array order
    /// and lets a later one override an earlier one's same `(type,id)`
    /// resource). No-op if the move would run off either end.
    func movePlugin(id: String, by offset: Int) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard plugins.indices.contains(j) else { return }
        plugins.swapAt(i, j)
        Self.savePluginState(plugins)
        reload()
    }

    /// One plug-in's persisted enabled flag + position, keyed by
    /// `PluginBundle.id` (stable folder/file name). Array order *is* the
    /// persisted load order.
    private struct PersistedPluginState: Codable {
        let id: String
        let isEnabled: Bool
    }

    /// Persisted across app launches. v2 folds load order in alongside the
    /// enabled flag (v1 only remembered which IDs were enabled).
    private static let pluginStateKey = "com.novaswift.plugins.state.v2"

    private static func loadPluginState() -> [PersistedPluginState] {
        guard let data = UserDefaults.standard.data(forKey: pluginStateKey),
              let s = try? JSONDecoder().decode([PersistedPluginState].self, from: data) else { return [] }
        return s
    }

    private static func savePluginState(_ plugins: [PluginBundle]) {
        let s = plugins.map { PersistedPluginState(id: $0.id, isEnabled: $0.isEnabled) }
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: pluginStateKey)
        }
    }

    /// Whether `plugin` lives in the app-bundled `Plugins/` dir (shipped with
    /// the app, can only be enabled/disabled) as opposed to anywhere the user
    /// or the store installed it (deletable). Prebundled plugins have no
    /// delete affordance in the Plug-in Manager.
    func isPrebundled(_ plugin: PluginBundle) -> Bool {
        guard let bundled = bundledPluginsDir, let first = plugin.fileURLs.first else { return false }
        return first.path.hasPrefix(bundled.path)
    }

    /// Removes an installed (non-prebundled) plug-in's on-disk folder/file and
    /// reloads. No-op if `plugin` is prebundled — callers should check
    /// `isPrebundled` first to avoid showing a delete affordance at all.
    func deletePlugin(_ plugin: PluginBundle) {
        guard !isPrebundled(plugin) else { return }
        let fm = FileManager.default
        // A plugin is either its own containing folder (importedPluginsDir/<id>)
        // or, for a loose imported .rez/.ndat, the file itself.
        let folder = importedPluginsDir.appendingPathComponent(plugin.id, isDirectory: true)
        if fm.fileExists(atPath: folder.path) {
            try? fm.removeItem(at: folder)
        } else {
            for url in plugin.fileURLs { try? fm.removeItem(at: url) }
        }
        reload()
    }

    /// Imports a user-picked plug-in — a `.zip` archive, a loose `.rez`/`.ndat`
    /// container, or a folder of them — that didn't come through the Store
    /// (e.g. a total conversion downloaded from a fan site). Lands in
    /// `importedPluginsDir` under the same discovery/merge pipeline the Store
    /// and prebundled plug-ins use, so it shows up in the Installed list,
    /// participates in load order, and persists exactly like any other plug-in.
    /// Returns the new plug-in's id (its folder/file name) for confirmation UI.
    @discardableResult
    func importPlugin(from src: URL) throws -> String {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try fm.createDirectory(at: importedPluginsDir, withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        let id: String

        if ext == "zip" {
            // `PluginInstaller.install` deletes the archive it's handed once
            // extracted (appropriate for a throwaway downloaded temp file) —
            // copy the user's picked file first so we never touch their original.
            id = src.deletingPathExtension().lastPathComponent
            let tmp = fm.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: src, to: tmp)
            _ = try PluginInstaller.install(archiveAt: tmp, id: id, into: importedPluginsDir)
        } else {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            guard isDir.boolValue || GameLibrary.resourceExtensions.contains(ext) else {
                throw PluginInstallError.unsupportedArchive
            }
            id = src.lastPathComponent
            let dest = importedPluginsDir.appendingPathComponent(id, isDirectory: isDir.boolValue)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        }
        reload()
        return id
    }

    /// Pick a reasonable player ship: the first ship the data defines (usually the
    /// Shuttle, id 128), else nil so the scene falls back to a placeholder.
    func defaultPlayerShip() -> ShipRes? {
        game?.ship(128) ?? game?.ships().first
    }

    /// A background-music track shipped alongside the base data, if the player's
    /// copy includes one (EV Nova CE ships `Nova Music.mp3` in "Nova Files").
    /// Sound *effects* come from `snd ` resources; music is an external audio file.
    func musicTrackURL() -> URL? {
        guard let baseDir = resolveBaseDir() else { return nil }
        let tracks = Self.discoverAudioFiles(in: baseDir)
        // Prefer a file that looks like the main music track.
        return tracks.first { $0.lastPathComponent.lowercased().contains("music") } ?? tracks.first
    }

    /// The Galaxy Racing Network holovid for race outcome `index` (1-4), shipped
    /// alongside the base data as "Race 1.mov".."Race 4.mov" — each video's
    /// winning ship colour is confirmed to match its index (1=Blue, 2=Green,
    /// 3=Yellow, 4=Red, per PICT 8530-8533/8550-8553's colour order). Backs the
    /// Bar's authentic Gambling screen (`STR# 150` #11/14/15: Gamble/Bet 1000/
    /// Bet 5000).
    func raceVideoURL(index: Int) -> URL? {
        videoURL(named: "Race \(index).mov")
    }

    /// Any holovid clip shipped alongside the base data OR a plugin, by exact
    /// filename — e.g. a `dësc` record's `movieFilename` (`DescRes.movieFilename`),
    /// which a plugin like ARPIA2 ships as its own `.mov` next to its `.rez`
    /// files rather than in the base install. Searches the base data directory
    /// first, then every discovered plugin directory, each the same
    /// direct-hit-then-recursive-search way `raceVideoURL` always has.
    func videoURL(named name: String) -> URL? {
        for dir in ([resolveBaseDir()] + resolvePluginDirs()).compactMap({ $0 }) {
            let direct = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let hit = e.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                return hit
            }
        }
        return nil
    }
}
