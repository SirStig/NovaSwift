import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PluginCatalogError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateIDs([String])
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "The catalog uses format version \(v); update NovaSwift to read it."
        case .duplicateIDs(let ids): return "The catalog lists the same plug-in twice: \(ids.joined(separator: ", "))."
        case .badStatus(let code): return "The catalog server answered HTTP \(code)."
        }
    }
}

/// Where a loaded catalog came from.
public enum PluginCatalogSource: String, Sendable { case remote, cache, bundled }

public struct PluginCatalogResult: Sendable {
    public let document: PluginCatalogDocument
    public let source: PluginCatalogSource
    /// Why the remote fetch failed, when we fell back.
    public let remoteError: String?
    /// True when the online list could not be reached; what's shown is a saved copy.
    public var isOffline: Bool { remoteError != nil }
}

/// Loads the catalog: remote first, then the on-disk copy of the last good
/// download, then the copy bundled with the app.
public struct PluginCatalogProvider: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public let remoteURL: URL
    public let cacheFile: URL
    public let bundled: PluginCatalogDocument
    let fetch: Fetch

    public init(remoteURL: URL = PluginCatalog.remoteURL,
                cacheFile: URL = PluginCatalogProvider.defaultCacheFile,
                bundled: PluginCatalogDocument = PluginCatalog.bundled,
                fetch: @escaping Fetch = PluginCatalogProvider.urlSessionFetch) {
        self.remoteURL = remoteURL
        self.cacheFile = cacheFile
        self.bundled = bundled
        self.fetch = fetch
    }

    public static var defaultCacheFile: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NovaSwift/PluginCatalog.json")
    }

    public static let urlSessionFetch: Fetch = { url in
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("NovaSwift", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PluginCatalogError.badStatus(http.statusCode)
        }
        return data
    }

    /// Decodes and sanity-checks catalog JSON.
    public static func decode(_ data: Data) throws -> PluginCatalogDocument {
        let doc = try JSONDecoder().decode(PluginCatalogDocument.self, from: data)
        guard doc.schemaVersion >= 1, doc.schemaVersion <= PluginCatalogDocument.supportedSchemaVersion else {
            throw PluginCatalogError.unsupportedSchema(doc.schemaVersion)
        }
        var seen = Set<String>(), dupes = Set<String>()
        for p in doc.plugins where !seen.insert(p.id).inserted { dupes.insert(p.id) }
        if !dupes.isEmpty { throw PluginCatalogError.duplicateIDs(dupes.sorted()) }
        return doc
    }

    /// The catalog saved by the last successful download, if readable.
    public func cached() -> PluginCatalogDocument? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? Self.decode(data)
    }

    /// Fast path for startup: whatever we can show right now without network.
    public func offline(error: String? = nil) -> PluginCatalogResult {
        if let doc = cached() { return PluginCatalogResult(document: doc, source: .cache, remoteError: error) }
        return PluginCatalogResult(document: bundled, source: .bundled, remoteError: error)
    }

    public func load() async -> PluginCatalogResult {
        do {
            let data = try await fetch(remoteURL)
            let doc = try Self.decode(data)
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return PluginCatalogResult(document: doc, source: .remote, remoteError: nil)
        } catch {
            return offline(error: error.localizedDescription)
        }
    }
}
