#if os(macOS)
import SwiftUI
import NovaSwiftKit

struct EditorTypeStat: Identifiable, Hashable, Sendable {
    let type: NovaSwiftKit.FourCharCode
    let total: Int
    let new: Int
    let overridden: Int
    /// Display name + 4-char code, precomputed and lowercased for the sidebar filter.
    let name: String
    let searchText: String
    var id: NovaSwiftKit.FourCharCode { type }
}

/// One browsable resource with its filter keys precomputed, so typing in a search
/// field only runs `contains` over ready-made lowercase strings.
struct BrowseRow: Identifiable, Hashable, Sendable {
    let entry: PluginDocument.BrowserEntry
    let lowerName: String
    let idText: String
    var id: ResourceKey { entry.key }

    func matches(_ lowerQuery: String) -> Bool {
        idText.contains(lowerQuery) || lowerName.contains(lowerQuery)
    }
}

/// Every resource of one type at one data revision (sorted by id, with provenance).
struct BrowseList: Sendable {
    let revision: Int
    let rows: [BrowseRow]
    var entries: [PluginDocument.BrowserEntry] { rows.map(\.entry) }
}

/// Per-(type, data revision) memo of `PluginDocument.browse` and of the sidebar counts.
/// Everything is built off the main actor from value snapshots, coalesced (one build per
/// type per revision), and the last result stays available while a newer one is being
/// built, so lists never blank out after an edit. Typing in an inspector field never
/// re-sorts every list on the main thread.
@MainActor
final class EditorBrowseCache: ObservableObject {
    /// Sidebar rows. `nil` until the first computation finishes (sidebar shows skeletons).
    @Published private(set) var stats: [EditorTypeStat]?
    /// True while a newer stats result is being computed (stale `stats` stay visible).
    @Published private(set) var statsBusy = false

    private var lists: [NovaSwiftKit.FourCharCode: BrowseList] = [:]
    private var inflight: [NovaSwiftKit.FourCharCode: (revision: Int, task: Task<BrowseList, Never>)] = [:]
    private var statsRevision = -1
    private var statsTask: Task<Void, Never>?

    /// Forget everything (a different document was opened): lists and counts rebuild from
    /// skeletons rather than briefly showing the previous document's data.
    func reset() {
        statsTask?.cancel()
        for (_, f) in inflight { f.task.cancel() }
        inflight = [:]
        lists = [:]
        stats = nil
        statsRevision = -1
        statsBusy = false
    }

    // MARK: Lists

    /// The most recent list for `type`, possibly from an older revision (nil if never built).
    func cachedList(_ type: NovaSwiftKit.FourCharCode) -> BrowseList? { lists[type] }

    /// The list for `type` at the model's current data revision, built off-main (and shared
    /// by concurrent callers).
    func list(_ type: NovaSwiftKit.FourCharCode, _ model: EditorModel) async -> BrowseList {
        let rev = model.dataRevision
        if let c = lists[type], c.revision == rev { return c }
        if let f = inflight[type], f.revision == rev { return await f.task.value }
        let eff = model.effective, layer = model.document.layer, base = model.base
        let task = Task.detached(priority: .userInitiated) { () -> BrowseList in
            let entries = PluginDocument.browse(type, effective: eff, layer: layer, base: base)
            let rows = entries.map { BrowseRow(entry: $0, lowerName: $0.name.lowercased(), idText: String($0.key.id)) }
            return BrowseList(revision: rev, rows: rows)
        }
        inflight[type] = (rev, task)
        let result = await task.value
        if inflight[type]?.revision == rev { inflight[type] = nil }
        if (lists[type]?.revision ?? -1) < result.revision { lists[type] = result }
        return result
    }

    // MARK: Sidebar stats

    /// Recompute the sidebar counts for the current data revision. Coalesced and debounced
    /// (the first computation runs immediately); stale counts stay on screen meanwhile.
    func refreshStats(_ model: EditorModel) {
        guard model.dataReady else { return }
        let rev = model.dataRevision
        if stats != nil, statsRevision == rev { return }
        statsTask?.cancel()
        let eff = model.effective, layer = model.document.layer, base = model.base
        let first = stats == nil
        statsBusy = true
        statsTask = Task { [weak self] in
            if !first {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            let out = await Task.detached(priority: .userInitiated) {
                Self.computeStats(eff: eff, layer: layer, base: base)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.stats = out
            self.statsRevision = rev
            self.statsBusy = false
        }
    }

    nonisolated private static func computeStats(eff: ResourceCollection, layer: ResourceCollection,
                                                 base: ResourceCollection) -> [EditorTypeStat] {
        var types = Set(eff.types)
        let known = ResourceSchemas.knownTypes
        for t in known { types.insert(t) }
        var out: [EditorTypeStat] = []
        for t in types {
            let total = eff.byType[t]?.count ?? 0
            var n = 0, o = 0
            for id in (layer.byType[t] ?? [:]).keys { if base.resource(t, id) == nil { n += 1 } else { o += 1 } }
            if total == 0 && !known.contains(t) { continue }
            let name = ResourceSchemas.displayName(for: t)
            out.append(EditorTypeStat(type: t, total: total, new: n, overridden: o, name: name,
                                      searchText: (name + " " + t.stringValue).lowercased()))
        }
        // Schema'd form types first (schema order), then the rest by code.
        let order = Dictionary(uniqueKeysWithValues: known.enumerated().map { ($1, $0) })
        out.sort { (order[$0.type] ?? 10_000, $0.type.rawValue) < (order[$1.type] ?? 10_000, $1.type.rawValue) }
        return out
    }

    // MARK: Labels (dictionary lookups on the already-built effective collection)

    func name(_ type: NovaSwiftKit.FourCharCode, _ id: Int, _ model: EditorModel) -> String {
        model.effective.resource(type, id)?.name ?? ""
    }

    /// "#128 Shuttle" (or "#128 (missing)").
    func label(_ type: NovaSwiftKit.FourCharCode, _ id: Int, _ model: EditorModel) -> String {
        guard let r = model.effective.resource(type, id) else { return "#\(id) (missing)" }
        return r.name.isEmpty ? "#\(id)" : "#\(id) \(r.name)"
    }
}

extension Provenance {
    var badgeText: String {
        switch self {
        case .base: return "Base"
        case .new: return "New"
        case .override: return "Override"
        case let .otherPlugin(id): return id
        }
    }
    var badgeColor: Color {
        switch self {
        case .base: return .secondary
        case .new: return .green
        case .override: return novaAmber
        case .otherPlugin: return .cyan
        }
    }
    var isOwn: Bool { self == .new || self == .override }
}

struct ProvenanceBadge: View {
    let provenance: Provenance
    var body: some View {
        Text(provenance.badgeText)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(provenance.badgeColor)
            .background(provenance.badgeColor.opacity(0.14), in: Capsule())
    }
}
#endif
