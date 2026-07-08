import Foundation

/// The bundled catalog of browsable plug-ins/total conversions. Loaded once
/// from `Resources/PluginCatalog.json`, which ships in the app bundle — so
/// browsing the store works fully offline; only installing an entry needs
/// network (see `PluginDownloader`).
public enum PluginCatalog {
    /// All known entries, in catalog (display) order. Empty (not a crash) if
    /// the bundled JSON is missing or malformed — the store UI should treat
    /// that as "no catalog available" rather than failing to launch.
    public static let all: [PluginCatalogEntry] = load()

    public static func entry(id: String) -> PluginCatalogEntry? {
        all.first { $0.id == id }
    }

    private static func load() -> [PluginCatalogEntry] {
        guard let url = Bundle.module.url(forResource: "PluginCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([PluginCatalogEntry].self, from: data)) ?? []
    }

    /// The folder containing bundled screenshots for `id`, if any exist.
    public static func screenshotsDirectory(forEntryID id: String) -> URL? {
        Bundle.module.url(forResource: id, withExtension: nil, subdirectory: "Screenshots")
    }

    public static func screenshotURL(entryID: String, fileName: String) -> URL? {
        screenshotsDirectory(forEntryID: entryID)?.appendingPathComponent(fileName)
    }
}
