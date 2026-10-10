import Foundation

/// The filter chips on the Plugins screen. Each one also implies a sort.
public enum PluginFilter: String, CaseIterable, Identifiable, Sendable {
    case popular, recent, totalConversions, ships, story, graphics, gameplay, installed, updates

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .popular: return "Popular"
        case .recent: return "Recent"
        case .totalConversions: return "Total conversions"
        case .ships: return "Ships"
        case .story: return "Story"
        case .graphics: return "Graphics"
        case .gameplay: return "Gameplay"
        case .installed: return "Installed"
        case .updates: return "Updates"
        }
    }
}

public enum PluginInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String?)
    case updateAvailable(installed: String?, latest: String)

    public var isInstalled: Bool { self != .notInstalled }
}

/// Pure filtering, sorting and status logic over a catalog and the set of
/// installed plug-ins (id -> installed version, "" when unknown). No UI, no
/// disk access, so it can be tested with synthetic data.
public struct PluginBrowser: Sendable {
    public var entries: [PluginCatalogEntry]
    public var installedVersions: [String: String]

    public init(entries: [PluginCatalogEntry], installedVersions: [String: String] = [:]) {
        self.entries = entries
        self.installedVersions = installedVersions
    }

    public func status(for entry: PluginCatalogEntry) -> PluginInstallStatus {
        guard let v = installedVersions[entry.id] else { return .notInstalled }
        let known: String? = v.isEmpty ? nil : v
        if let known, entry.isUpdate(over: known) {
            return .updateAvailable(installed: known, latest: entry.version)
        }
        return .installed(version: known)
    }

    public var updatesAvailable: [PluginCatalogEntry] {
        entries.filter { if case .updateAvailable = status(for: $0) { return true } else { return false } }
    }

    /// Dependencies of `entry` that are not installed yet (ids).
    public func missingDependencies(of entry: PluginCatalogEntry) -> [String] {
        entry.dependencies.filter { installedVersions[$0] == nil }
    }

    public func results(filter: PluginFilter, query: String = "") -> [PluginCatalogEntry] {
        var list: [PluginCatalogEntry]
        switch filter {
        case .popular: list = entries
        case .recent: list = entries
        case .totalConversions: list = entries.filter(\.isTotalConversion)
        case .ships: list = entries.filter { $0.hasTag("ships") || $0.hasTag("ship") }
        case .story: list = entries.filter { $0.hasTag("story") }
        case .graphics: list = entries.filter { $0.hasTag("graphics") }
        case .gameplay: list = entries.filter { $0.hasTag("gameplay") }
        case .installed: list = entries.filter { status(for: $0).isInstalled }
        case .updates: list = updatesAvailable
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.author.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }
            }
        }
        switch filter {
        case .recent:
            return list.sorted { ($0.recencyDate, $1.name) > ($1.recencyDate, $0.name) }
        default:
            return list.sorted { ($0.popularity, $1.name) > ($1.popularity, $0.name) }
        }
    }
}

/// "12.4 MB" style size text.
public func formatPluginSize(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    return String(format: "%.0f KB", max(1, Double(bytes) / 1024))
}
