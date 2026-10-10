import Foundation

/// Where the catalog comes from and the copy that ships in the app.
public enum PluginCatalog {
    /// The master catalog. Change this one constant to point the app at a fork.
    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/main/catalog.json")!

    /// The copy bundled with the app (always available, possibly old).
    public static let bundled: PluginCatalogDocument = loadBundled()

    /// Bundled entries, in catalog order.
    public static var all: [PluginCatalogEntry] { bundled.plugins }

    public static func entry(id: String) -> PluginCatalogEntry? {
        all.first { $0.id == id }
    }

    private static func loadBundled() -> PluginCatalogDocument {
        guard let url = Bundle.module.url(forResource: "PluginCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? PluginCatalogProvider.decode(data) else {
            return PluginCatalogDocument(plugins: [])
        }
        return doc
    }
}
