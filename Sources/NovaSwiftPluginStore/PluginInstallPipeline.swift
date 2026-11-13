import Foundation

/// Download + install for one catalog entry. The download step is injectable
/// so tests can run it without a network.
public enum PluginInstallPipeline {
    public typealias Download = @Sendable (_ urls: [URL], _ sha256: String?,
                                           _ progress: @escaping @Sendable (Double?) -> Void) async throws -> (file: URL, name: String)

    public static let networkDownload: Download = { urls, sha, progress in
        // Catalog downloads come from third-party hosts: HTTPS only, and stop at the size cap.
        try await PluginDownloader.download(from: urls, sha256: sha, httpsOnly: true,
                                            maxBytes: PluginDownloader.maxCatalogDownloadBytes,
                                            onProgress: progress)
    }

    /// Installs (or updates, replacing the old folder) `entry` under `root`.
    /// Returns the folder it was installed into.
    @discardableResult
    public static func install(_ entry: PluginCatalogEntry, into root: URL,
                               download: Download = networkDownload,
                               progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> URL {
        let (file, name) = try await download(entry.downloadURLs, entry.sha256, progress)
        try Task.checkCancellation()
        return try PluginInstaller.install(archiveAt: file, id: entry.id, into: root,
                                           originalName: name, version: entry.version,
                                           sha256: entry.sha256)
    }
}
