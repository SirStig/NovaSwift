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
        guard let url = bundledURL(),
              let data = try? Data(contentsOf: url),
              let doc = try? PluginCatalogProvider.decode(data) else {
            return PluginCatalogDocument(plugins: [])
        }
        return doc
    }

    /// Off Darwin, SwiftPM's `Bundle.module` traps when the resource bundle isn't beside the
    /// executable -- and the Godot Linux/Windows packages ship only the native libraries. Look
    /// for it ourselves and fall back to an empty catalog (the remote one is fetched anyway).
    private static func bundledURL() -> URL? {
        #if canImport(Darwin)
        return Bundle.module.url(forResource: "PluginCatalog", withExtension: "json")
        #else
        let bundleName = "NovaSwift_NovaSwiftPluginStore.resources"
        var dirs: [URL] = [Bundle.main.bundleURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        for d in dirs {
            let u = d.appendingPathComponent(bundleName).appendingPathComponent("PluginCatalog.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
        #endif
    }
}
