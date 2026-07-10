import Foundation
import SwiftUI
import CoreText
import EVNovaKit

/// Locates game data and the plug-in catalog, tracks which plug-ins are enabled,
/// and produces a merged `NovaGame` for the engine.
///
/// Data sources, in priority order:
///  1. User-imported base data in Application Support (the mobile BYO-data path).
///  2. A dev override via the `EVNOVA_DATA` environment variable (points at a
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

    // MARK: Locations

    private var appSupport: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EVNova", isDirectory: true)
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

    /// Registers any imported font files with CoreText for this process, so
    /// `Font.custom("Charcoal"/"Geneva", size:)` resolves to the game's actual
    /// fonts instead of silently falling back to a system font. Safe to call
    /// repeatedly (e.g. on every `reload()`) — duplicate registration errors
    /// are expected and ignored.
    nonisolated static func registerFonts(from directory: URL) {
        for url in discoverFontFiles(in: directory) {
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
    }

    /// Resolve the base "Nova Files" directory from the available sources.
    private func resolveBaseDir() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: importedBaseDir.path),
           !GameLibrary.discoverResourceFiles(in: importedBaseDir).isEmpty {
            return importedBaseDir
        }
        if let dev = ProcessInfo.processInfo.environment["EVNOVA_DATA"],
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
        // Dev convenience: repo plug-ins next to EVNOVA_DATA/../..
        if let dev = ProcessInfo.processInfo.environment["EVNOVA_PLUGINS"], !dev.isEmpty {
            dirs.append(URL(fileURLWithPath: dev))
        }
        return dirs
    }

    // MARK: Loading

    func reloadIfNeeded() { if !loaded { reload() } }

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
    }

    func reload() {
        loaded = true
        // Discover plug-ins (catalog is available even before base data).
        var discovered: [PluginBundle] = []
        for dir in resolvePluginDirs() {
            discovered.append(contentsOf: GameLibrary.discoverPlugins(in: dir))
        }
        // Preserve enabled state across reloads.
        let previouslyEnabled = Set(plugins.filter(\.isEnabled).map(\.id))
        for i in discovered.indices where previouslyEnabled.contains(discovered[i].id) {
            discovered[i].isEnabled = true
        }
        plugins = discovered
        Log.data.debug("reload: \(discovered.count, privacy: .public) plug-in(s) discovered, \(discovered.filter(\.isEnabled).count, privacy: .public) enabled")

        guard let baseDir = resolveBaseDir() else {
            hasBaseData = false
            game = nil
            status = "No EV Nova data found. Import your game data to play. \(plugins.count) plug-in(s) ready."
            Log.data.notice("reload: no base game data found (checked \(self.importedBaseDir.path, privacy: .public) and EVNOVA_DATA) — \(self.plugins.count, privacy: .public) plug-in(s) ready but nothing to play")
            return
        }
        Log.data.info("reload: using base data at \(baseDir.path, privacy: .public)")
        Self.registerFonts(from: baseDir)
        let baseFiles = GameLibrary.discoverResourceFiles(in: baseDir)
        do {
            let merged = try GameLibrary.merge(baseFiles: baseFiles, plugins: plugins)
            game = NovaGame(merged)
            hasBaseData = true
            status = "Loaded \(merged.totalCount) resources from base + \(plugins.filter(\.isEnabled).count) plug-in(s)."
            let byType = merged.typeCounts.map { "\($0.type)=\($0.count)" }.joined(separator: ", ")
            Log.data.info("reload: loaded \(merged.totalCount, privacy: .public) resource(s) from base (\(baseFiles.count, privacy: .public) file(s)) + \(self.plugins.filter(\.isEnabled).count, privacy: .public) plug-in(s) — by type: \(byType, privacy: .public)")
        } catch {
            hasBaseData = false
            game = nil
            status = "Failed to load data: \(error)"
            Log.data.error("reload: failed to merge game data from \(baseDir.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func setPlugin(_ id: String, enabled: Bool) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[i].isEnabled = enabled
        reload()
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
        guard let baseDir = resolveBaseDir() else { return nil }
        let name = "Race \(index).mov"
        let direct = baseDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let e = FileManager.default.enumerator(at: baseDir, includingPropertiesForKeys: nil) else { return nil }
        return e.compactMap { $0 as? URL }.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}
