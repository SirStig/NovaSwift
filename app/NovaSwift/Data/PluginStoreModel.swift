import Foundation
import SwiftUI
import EVNovaKit
import EVNovaPluginStore

/// Tracks install/download state for the plug-in store catalog and drives the
/// install/delete pipeline. Installed files land under
/// `GameDataController.importedPluginsDir`, which the existing discovery/merge
/// pipeline (`GameLibrary.discoverPlugins` → `GameDataController.reload()`)
/// already scans — installing here is purely additive to that pipeline.
@MainActor
final class PluginStoreModel: ObservableObject {
    enum InstallState: Equatable {
        case notInstalled
        case downloading(Double?)   // fractional progress, nil = indeterminate
        case installed
        case failed(String)
    }

    @Published private(set) var installState: [String: InstallState] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// Seed state from what's already on disk (survives relaunch without any
    /// separate persistence — the folder itself *is* the state).
    func refresh(data: GameDataController) {
        for entry in PluginCatalog.all {
            if entry.prebundled {
                installState[entry.id] = .installed
            } else if PluginInstaller.isInstalled(id: entry.id, in: data.importedPluginsDir) {
                installState[entry.id] = .installed
            } else if case .downloading = installState[entry.id] {
                // leave an in-flight download alone
            } else {
                installState[entry.id] = .notInstalled
            }
        }
    }

    func state(for entry: PluginCatalogEntry) -> InstallState {
        installState[entry.id] ?? .notInstalled
    }

    func install(_ entry: PluginCatalogEntry, data: GameDataController) {
        guard let url = entry.sourceURL, !entry.prebundled else { return }
        guard downloadTasks[entry.id] == nil else { return }
        installState[entry.id] = .downloading(nil)

        downloadTasks[entry.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await PluginDownloader.download(from: url) { progress in
                    Task { @MainActor in self.installState[entry.id] = .downloading(progress) }
                }
                _ = try PluginInstaller.install(archiveAt: zip, id: entry.id, into: data.importedPluginsDir)
                installState[entry.id] = .installed
                data.reload()
            } catch {
                installState[entry.id] = .failed(error.localizedDescription)
            }
            downloadTasks[entry.id] = nil
        }
    }

    func cancelInstall(_ entry: PluginCatalogEntry) {
        downloadTasks[entry.id]?.cancel()
        downloadTasks[entry.id] = nil
        installState[entry.id] = .notInstalled
    }

    func delete(_ entry: PluginCatalogEntry, data: GameDataController) {
        guard !entry.prebundled else { return }
        do {
            try PluginInstaller.delete(id: entry.id, from: data.importedPluginsDir, prebundled: false)
            installState[entry.id] = .notInstalled
            data.reload()
        } catch {
            installState[entry.id] = .failed(error.localizedDescription)
        }
    }
}
