#if os(macOS)
import SwiftUI
import NovaSwiftKit

struct EditorTypeStat: Identifiable, Hashable {
    let type: NovaSwiftKit.FourCharCode
    let total: Int
    let new: Int
    let overridden: Int
    var id: NovaSwiftKit.FourCharCode { type }
    var name: String { ResourceSchemas.displayName(for: type) }
}

/// Per-(type, revision) memo of `PluginDocument.browse` and of the sidebar
/// counts, so typing in an inspector field never re-sorts every list.
@MainActor
final class EditorBrowseCache {
    private var entryCache: [NovaSwiftKit.FourCharCode: (rev: Int, list: [PluginDocument.BrowserEntry])] = [:]
    private var statCache: (rev: Int, list: [EditorTypeStat])?

    func entries(_ type: NovaSwiftKit.FourCharCode, _ model: EditorModel) -> [PluginDocument.BrowserEntry] {
        if let c = entryCache[type], c.rev == model.revision { return c.list }
        let list = model.document.browse(type)
        entryCache[type] = (model.revision, list)
        return list
    }

    func stats(_ model: EditorModel) -> [EditorTypeStat] {
        if let c = statCache, c.rev == model.revision { return c.list }
        let eff = model.effective, layer = model.document.layer, base = model.base
        var types = Set(eff.types)
        for t in ResourceSchemas.knownTypes { types.insert(t) }
        let known = ResourceSchemas.knownTypes
        var out: [EditorTypeStat] = []
        for t in types {
            let total = eff.byType[t]?.count ?? 0
            var n = 0, o = 0
            for id in (layer.byType[t] ?? [:]).keys { if base.resource(t, id) == nil { n += 1 } else { o += 1 } }
            if total == 0 && !known.contains(t) { continue }
            out.append(EditorTypeStat(type: t, total: total, new: n, overridden: o))
        }
        // Schema'd form types first (schema order), then the rest by code.
        let order = Dictionary(uniqueKeysWithValues: known.enumerated().map { ($1, $0) })
        out.sort { (order[$0.type] ?? 10_000, $0.type.rawValue) < (order[$1.type] ?? 10_000, $1.type.rawValue) }
        statCache = (model.revision, out)
        return out
    }

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
