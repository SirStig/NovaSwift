import Foundation
import SwiftUI
import NovaSwiftKit
import NovaSwiftPluginStore

/// State behind the Plugins screen: the catalog (remote, cached or bundled),
/// which entries are installed and at what version, and the download/install
/// pipeline. Installed files land under `GameDataController.importedPluginsDir`,
/// which the discovery/merge pipeline already scans.
@MainActor
final class PluginsModel: ObservableObject {
    enum Transfer: Equatable {
        case working(Double?)      // download/unpack; nil = indeterminate
        case failed(String)
    }

    @Published private(set) var entries: [PluginCatalogEntry] = PluginCatalog.all
    @Published private(set) var source: PluginCatalogSource = .bundled
    @Published private(set) var remoteError: String?
    @Published private(set) var isRefreshing = false
    /// The online list couldn't be reached. Browsing the saved catalog still works; downloads don't.
    var isOffline: Bool { remoteError != nil }
    @Published private(set) var transfers: [String: Transfer] = [:]
    @Published private(set) var installedVersions: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Called when an install brings HD graphics (a `.nsx` pack, or a catalog
    /// entry tagged "HD Graphics"), before the game data reloads, so the app
    /// can switch HD on: installing such a plug-in is the player's opt-in.
    var onHDContentInstalled: (([URL]) -> Void)?
    private let provider = PluginCatalogProvider()
    private var didLoad = false

    var browser: PluginBrowser { PluginBrowser(entries: entries, installedVersions: installedVersions) }

    func entry(id: String) -> PluginCatalogEntry? { entries.first { $0.id == id } }

    /// Shows the last good catalog straight away, then asks the network.
    func loadCatalog(force: Bool = false) async {
        if !didLoad {
            didLoad = true
            let local = provider.offline()
            entries = local.document.plugins
            source = local.source
        } else if !force { return }
        isRefreshing = true
        let result = await provider.load()
        entries = result.document.plugins
        source = result.source
        remoteError = result.remoteError
        isRefreshing = false
    }

    /// Re-reads what is installed from disk (the folders are the state).
    func refresh(data: GameDataController) {
        var versions: [String: String] = [:]
        for entry in entries where PluginInstaller.isInstalled(id: entry.id, in: data.importedPluginsDir) {
            versions[entry.id] = PluginInstaller.info(id: entry.id, in: data.importedPluginsDir)?.version ?? ""
        }
        installedVersions = versions
    }

    func status(for entry: PluginCatalogEntry) -> PluginInstallStatus { browser.status(for: entry) }
    func transfer(for entry: PluginCatalogEntry) -> Transfer? { transfers[entry.id] }

    /// Installs or updates `entry`, fetching any missing dependencies first.
    func install(_ entry: PluginCatalogEntry, data: GameDataController) {
        guard tasks[entry.id] == nil, !entry.downloadURLs.isEmpty, !isOffline else { return }
        transfers[entry.id] = .working(nil)
        let root = data.importedPluginsDir
        tasks[entry.id] = Task { [weak self] in
            guard let self else { return }
            do {
                for depID in self.browser.missingDependencies(of: entry) {
                    guard let dep = self.entry(id: depID) else { continue }
                    try await PluginInstallPipeline.install(dep, into: root) { p in
                        Task { @MainActor in self.transfers[entry.id] = .working(p) }
                    }
                }
                try await PluginInstallPipeline.install(entry, into: root) { p in
                    Task { @MainActor in self.transfers[entry.id] = .working(p) }
                }
                self.transfers[entry.id] = nil
                self.refresh(data: data)
                let installed = root.appendingPathComponent(entry.id, isDirectory: true)
                let packs = GameLibrary.discoverGraphicsPacks(in: [installed])
                let tagged = entry.tags.contains { $0.caseInsensitiveCompare("HD Graphics") == .orderedSame }
                if tagged || !packs.isEmpty { self.onHDContentInstalled?(packs) }
                data.reload()
            } catch is CancellationError {
                self.transfers[entry.id] = nil
            } catch {
                self.transfers[entry.id] = .failed(error.localizedDescription)
            }
            self.tasks[entry.id] = nil
        }
    }

    func cancel(_ entry: PluginCatalogEntry) {
        tasks[entry.id]?.cancel()
        tasks[entry.id] = nil
        transfers[entry.id] = nil
    }

    func dismissFailure(_ entry: PluginCatalogEntry) { transfers[entry.id] = nil }

    func delete(_ entry: PluginCatalogEntry, data: GameDataController) {
        do {
            try PluginInstaller.delete(id: entry.id, from: data.importedPluginsDir, prebundled: false)
            refresh(data: data)
            data.reload()
        } catch {
            transfers[entry.id] = .failed(error.localizedDescription)
        }
    }

    func updateAll(data: GameDataController) {
        for entry in browser.updatesAvailable { install(entry, data: data) }
    }
}
