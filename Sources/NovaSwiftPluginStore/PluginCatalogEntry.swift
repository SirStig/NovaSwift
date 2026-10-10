import Foundation
import NovaSwiftKit

/// The catalog file format (schema version 1). The master copy lives in the
/// NovaSwift-Plugins repo (`catalog.json`); a copy of it ships in the app so
/// the Plugins screen works offline. Keep `schema/catalog.schema.json` in that
/// repo in step with this file.
public struct PluginCatalogDocument: Codable, Equatable, Sendable {
    /// Highest `schemaVersion` this build understands.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var updated: String?
    public var plugins: [PluginCatalogEntry]

    public init(schemaVersion: Int = PluginCatalogDocument.supportedSchemaVersion,
                updated: String? = nil, plugins: [PluginCatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.plugins = plugins
    }
}

/// One plug-in or total conversion in the catalog. Every entry must have a
/// direct download link (a file, not a web page) that the app can fetch and
/// unpack by itself.
public struct PluginCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, also the folder the installer extracts into, so an
    /// installed `PluginBundle.id` equals this id.
    public let id: String
    public let name: String
    public let author: String
    /// Free-form version string ("1.0.7", "1.3-beta"). Compared numerically.
    public let version: String
    /// One or two sentences for the card.
    public let summary: String
    /// Long description, Markdown.
    public let description: String
    public let tags: [String]
    public let isTotalConversion: Bool
    public let iconURL: URL?
    public let screenshotURLs: [URL]
    /// Direct file URLs, tried in order (mirrors/fallbacks).
    public let downloadURLs: [URL]
    /// Hex SHA-256 of the downloaded file, when known. Checked after download.
    public let sha256: String?
    public let sizeBytes: Int64?
    public let homepageURL: URL?
    public let sourceURL: URL?
    /// License / redistribution note shown on the detail page.
    public let license: String?
    public let minNovaSwiftVersion: String?
    /// Ids of other catalog entries this one needs.
    public let dependencies: [String]
    public let addedDate: String?
    public let updatedDate: String?
    /// Higher is more popular (download count or a manual rank).
    public let popularity: Int

    public init(id: String, name: String, author: String, version: String = "1.0",
                summary: String, description: String = "", tags: [String] = [],
                isTotalConversion: Bool = false, iconURL: URL? = nil,
                screenshotURLs: [URL] = [], downloadURLs: [URL] = [], sha256: String? = nil,
                sizeBytes: Int64? = nil, homepageURL: URL? = nil, sourceURL: URL? = nil,
                license: String? = nil, minNovaSwiftVersion: String? = nil,
                dependencies: [String] = [], addedDate: String? = nil,
                updatedDate: String? = nil, popularity: Int = 0) {
        self.id = id; self.name = name; self.author = author; self.version = version
        self.summary = summary; self.description = description; self.tags = tags
        self.isTotalConversion = isTotalConversion; self.iconURL = iconURL
        self.screenshotURLs = screenshotURLs; self.downloadURLs = downloadURLs
        self.sha256 = sha256; self.sizeBytes = sizeBytes; self.homepageURL = homepageURL
        self.sourceURL = sourceURL; self.license = license
        self.minNovaSwiftVersion = minNovaSwiftVersion; self.dependencies = dependencies
        self.addedDate = addedDate; self.updatedDate = updatedDate; self.popularity = popularity
    }

    // Optional fields may be missing; lists default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decode(String.self, forKey: .author)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        summary = try c.decode(String.self, forKey: .summary)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isTotalConversion = try c.decodeIfPresent(Bool.self, forKey: .isTotalConversion) ?? false
        iconURL = try c.decodeIfPresent(URL.self, forKey: .iconURL)
        screenshotURLs = try c.decodeIfPresent([URL].self, forKey: .screenshotURLs) ?? []
        downloadURLs = try c.decodeIfPresent([URL].self, forKey: .downloadURLs) ?? []
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        homepageURL = try c.decodeIfPresent(URL.self, forKey: .homepageURL)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        minNovaSwiftVersion = try c.decodeIfPresent(String.self, forKey: .minNovaSwiftVersion)
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        addedDate = try c.decodeIfPresent(String.self, forKey: .addedDate)
        updatedDate = try c.decodeIfPresent(String.self, forKey: .updatedDate)
        popularity = try c.decodeIfPresent(Int.self, forKey: .popularity) ?? 0
    }

    /// Category, derived from the flags and tags; used for the placeholder icon.
    public var kind: PluginKind {
        if isTotalConversion { return .totalConversion }
        if tags.contains(where: { $0.lowercased() == "patch" }) { return .patch }
        return .gameplay
    }

    public func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.lowercased() == tag.lowercased() }
    }

    /// Where the file comes from, for "Downloaded from ..." text.
    public var downloadHost: String {
        downloadURLs.first?.host ?? "the author's site"
    }

    /// Date used for "Recent" sorting: last update, else when it was added.
    public var recencyDate: String { updatedDate ?? addedDate ?? "" }

    /// True when `installedVersion` is older than the catalog version.
    public func isUpdate(over installedVersion: String?) -> Bool {
        guard let installedVersion else { return false }
        return version.compare(installedVersion, options: .numeric) == .orderedDescending
    }
}
