import Foundation
import EVNovaKit

/// Where a catalog entry's installable file is actually hosted. Purely
/// informational (shown to the user before they download); the store never
/// mirrors these files itself — see docs/MOBILE_AND_PLUGINS.md §3.
public enum PluginSourceHost: String, Codable, Sendable {
    case evstuff        // andrews05/evstuff, via the GitHub LFS media endpoint
    case evDownload      // download.escape-velocity.games
    case other

    public var displayName: String {
        switch self {
        case .evstuff: return "andrews05's EV Stuff"
        case .evDownload: return "download.escape-velocity.games"
        case .other: return "an external host"
        }
    }
}

/// One entry in the browsable plug-in store: metadata about a plug-in or total
/// conversion, independent of whether it's installed. Reuses `PluginKind` from
/// `EVNovaKit` so a catalog entry and its installed `PluginBundle` agree on kind.
public struct PluginCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity. Also the folder name the installer extracts this entry
    /// into under the plug-ins directory, so an installed `PluginBundle.id`
    /// always equals this id (see `PluginInstaller`).
    public let id: String
    public let name: String
    public let author: String
    public let kind: PluginKind
    public let summary: String
    public let description: String
    public let tags: [String]
    public let requiresBase: Bool
    /// True for plug-ins shipped inside the app bundle (never downloaded, can't
    /// be deleted — only enabled/disabled). False for anything the store must
    /// fetch on demand.
    public let prebundled: Bool
    public let sourceHost: PluginSourceHost
    public let sourceURL: URL?
    public let approxSizeMB: Double?
    /// File names under `Resources/Screenshots/<id>/`, in display order.
    public let screenshotNames: [String]
    public let videoURL: URL?

    public init(id: String, name: String, author: String, kind: PluginKind,
                summary: String, description: String, tags: [String] = [],
                requiresBase: Bool = true, prebundled: Bool = false,
                sourceHost: PluginSourceHost = .other, sourceURL: URL? = nil,
                approxSizeMB: Double? = nil, screenshotNames: [String] = [],
                videoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.author = author
        self.kind = kind
        self.summary = summary
        self.description = description
        self.tags = tags
        self.requiresBase = requiresBase
        self.prebundled = prebundled
        self.sourceHost = sourceHost
        self.sourceURL = sourceURL
        self.approxSizeMB = approxSizeMB
        self.screenshotNames = screenshotNames
        self.videoURL = videoURL
    }
}
