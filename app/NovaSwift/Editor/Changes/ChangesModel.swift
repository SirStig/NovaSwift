#if os(macOS)
import SwiftUI
import NovaSwiftKit

// What the open plug-in changes relative to the base game: grouped rows, counts, lazy
// per-section summaries and conflicts. Everything is computed off the main actor from value
// snapshots (see docs/PLUGIN_EDITOR.md, "Responsiveness rules").

enum ChangeCategory: String, CaseIterable, Identifiable, Sendable {
    case ships = "Ships", outfits = "Outfits", weapons = "Weapons", world = "Systems & Planets"
    case story = "Missions & Story", people = "Governments & People", graphics = "Graphics"
    case sounds = "Sounds", text = "Text", interface = "Interface", hd = "HD & 3D", other = "Other"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ships: return "airplane"
        case .outfits: return "wrench.and.screwdriver"
        case .weapons: return "scope"
        case .world: return "globe.europe.africa"
        case .story: return "text.book.closed"
        case .people: return "person.3"
        case .graphics: return "photo.on.rectangle"
        case .sounds: return "speaker.wave.2"
        case .text: return "textformat"
        case .interface: return "rectangle.3.group"
        case .hd: return "cube"
        case .other: return "ellipsis.circle"
        }
    }

    private static let strType = NovaSwiftKit.FourCharCode("STR ")!

    static func of(_ t: NovaSwiftKit.FourCharCode) -> ChangeCategory {
        switch t {
        case NovaType.ship, NovaType.shan: return .ships
        case NovaType.outfit: return .outfits
        case NovaType.weapon, NovaType.boom: return .weapons
        case NovaType.syst, NovaType.spob, NovaType.nebula, NovaType.roid, NovaType.junk, NovaType.oops: return .world
        case NovaType.mission, NovaType.cron, NovaType.char: return .story
        case NovaType.govt, NovaType.pers, NovaType.dude, NovaType.fleet, NovaType.rank: return .people
        case NovaType.rleD, NovaType.rle8, NovaType.pict, NovaType.cicn, NovaType.ppat, NovaType.ppatAlt, NovaType.spin:
            return .graphics
        case NovaType.snd: return .sounds
        case NovaType.strList, strType, NovaType.desc: return .text
        case NovaType.ditl, NovaType.dlog, NovaType.intf, NovaType.colr: return .interface
        case GraphicsEnhancementType.descriptor, GraphicsEnhancementType.blob: return .hd
        default: return .other
        }
    }
}

struct ChangeRow: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case new = "New", override = "Override" }
    let key: ResourceKey
    let name: String
    let lowerName: String
    let kind: Kind
    /// An override whose bytes equal the base record (no effective change).
    let identical: Bool
    var id: ResourceKey { key }
    var category: ChangeCategory { ChangeCategory.of(key.type) }
}

struct ChangeSection: Identifiable, Sendable {
    let category: ChangeCategory
    var rows: [ChangeRow]
    var id: ChangeCategory { category }
    var newCount: Int { rows.reduce(0) { $0 + ($1.kind == .new ? 1 : 0) } }
    var overrideCount: Int { rows.reduce(0) { $0 + ($1.kind == .override ? 1 : 0) } }
}

struct ConflictRow: Identifiable, Hashable, Sendable {
    let key: ResourceKey
    let name: String
    let lowerName: String
    /// Other plug-ins defining the key, in load order (last wins).
    let others: [String]
    var id: ResourceKey { key }
    var text: String {
        guard let last = others.last else { return "" }
        return "Also defined by \(others.joined(separator: ", ")) — \(last) wins"
    }
}

/// The plain-language one-liner (and graphic sizes) for one row.
struct ChangeDetail: Sendable, Hashable {
    var summary: String
    /// "46×46 · 36 frames" for the base and the new graphic.
    var oldInfo: String?
    var newInfo: String?
}

struct ChangesSnapshot: Sendable {
    let revision: Int
    let sections: [ChangeSection]
    let conflicts: [ConflictRow]
    let newCount: Int
    let overrideCount: Int
    let identicalCount: Int
    /// Overridden STR# lists.
    let stringListEdits: Int
    /// NSgx descriptors in this plug-in.
    let hdCount: Int

    var totalChanges: Int { newCount + overrideCount }
    func section(_ c: ChangeCategory) -> ChangeSection? { sections.first { $0.category == c } }
}

@MainActor
final class ChangesModel: ObservableObject {
    @Published private(set) var snapshot: ChangesSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var details: [ResourceKey: ChangeDetail] = [:]

    private var snapshotTask: Task<Void, Never>?
    private var detailsLoadedAt: [ChangeCategory: Int] = [:]
    private var detailsInflight: Set<ChangeCategory> = []
    private var revision = -1
    private var conflictInput = -1

    func reset() {
        snapshotTask?.cancel()
        snapshot = nil; details = [:]; detailsLoadedAt = [:]; detailsInflight = []
        revision = -1; conflictInput = -1; busy = false
    }

    // MARK: Snapshot

    /// Rebuild the grouped rows for the model's current data revision (debounced after the
    /// first build; the previous snapshot stays visible meanwhile).
    func refresh(_ model: EditorModel) async {
        guard model.dataReady else { return }
        let rev = model.dataRevision
        let conflictCount = model.conflicts.count
        if snapshot != nil, revision == rev, conflictInput == conflictCount { return }
        let first = snapshot == nil
        busy = true
        if !first {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
        }
        let layer = model.document.layer, base = model.base, eff = model.effective
        let conflicts = model.conflicts
        let out = await Task.detached(priority: .userInitiated) {
            Self.compute(revision: rev, layer: layer, base: base, eff: eff, conflicts: conflicts)
        }.value
        if Task.isCancelled { return }
        snapshot = out
        revision = rev
        conflictInput = conflictCount
        busy = false
    }

    nonisolated private static func compute(revision: Int, layer: ResourceCollection, base: ResourceCollection,
                                            eff: ResourceCollection,
                                            conflicts: [ResourceKey: [String]]) -> ChangesSnapshot {
        var byCat: [ChangeCategory: [ChangeRow]] = [:]
        var n = 0, o = 0, same = 0, strEdits = 0, hd = 0
        for (type, items) in layer.byType {
            // NSbl asset payloads are shown via their NSgx; NSmd is the editor's own bookkeeping.
            if type == GraphicsEnhancementType.blob || type.stringValue == "NSmd" { continue }
            for (id, r) in items {
                let b = base.resource(type, id)
                let kind: ChangeRow.Kind = b == nil ? .new : .override
                let identical = b.map { $0.data == r.data && $0.name == r.name } ?? false
                let name = r.name.isEmpty ? (b?.name ?? "") : r.name
                byCat[ChangeCategory.of(type), default: []]
                    .append(ChangeRow(key: ResourceKey(type, id), name: name, lowerName: name.lowercased(),
                                      kind: kind, identical: identical))
                // HD descriptors are counted on their own chip only — they're
                // art for existing objects, not new or overridden game data.
                if type == GraphicsEnhancementType.descriptor { hd += 1; continue }
                if kind == .new { n += 1 } else { o += 1; if identical { same += 1 } }
                if type == NovaType.strList, kind == .override { strEdits += 1 }
            }
        }
        var sections: [ChangeSection] = []
        for c in ChangeCategory.allCases {
            guard var rows = byCat[c], !rows.isEmpty else { continue }
            rows.sort { ($0.key.type.rawValue, $0.key.id) < ($1.key.type.rawValue, $1.key.id) }
            sections.append(ChangeSection(category: c, rows: rows))
        }
        var crows: [ConflictRow] = []
        for (k, others) in conflicts where !others.isEmpty && layer.resource(k.type, k.id) != nil {
            let name = eff.resource(k.type, k.id)?.name ?? ""
            crows.append(ConflictRow(key: k, name: name, lowerName: name.lowercased(), others: others))
        }
        crows.sort { $0.key < $1.key }
        return ChangesSnapshot(revision: revision, sections: sections, conflicts: crows, newCount: n,
                               overrideCount: o, identicalCount: same, stringListEdits: strEdits, hdCount: hd)
    }

    // MARK: Lazy details

    /// Compute the one-line summaries for a section (called when it is expanded). Cheap
    /// header reads for graphics; schema diffs for records. Stays off the main actor.
    func loadDetails(_ category: ChangeCategory, model: EditorModel) async {
        guard let snap = snapshot, let section = snap.section(category) else { return }
        if detailsLoadedAt[category] == snap.revision || detailsInflight.contains(category) { return }
        detailsInflight.insert(category)
        let layer = model.document.layer, base = model.base, eff = model.effective
        let rows = section.rows
        let rev = snap.revision
        let out = await Task.detached(priority: .utility) { () -> [ResourceKey: ChangeDetail] in
            var d: [ResourceKey: ChangeDetail] = [:]
            d.reserveCapacity(rows.count)
            for r in rows {
                if Task.isCancelled { break }
                d[r.key] = Self.detail(for: r, layer: layer, base: base, eff: eff)
            }
            return d
        }.value
        detailsInflight.remove(category)
        if Task.isCancelled { return }
        details.merge(out) { _, new in new }
        detailsLoadedAt[category] = rev
    }

    nonisolated static func detail(for row: ChangeRow, layer: ResourceCollection, base: ResourceCollection,
                                   eff: ResourceCollection) -> ChangeDetail {
        let key = row.key
        guard let new = layer.resource(key.type, key.id) else { return ChangeDetail(summary: "") }
        let old = base.resource(key.type, key.id)
        let isNew = old == nil
        let kind = ResourceSchemas.editorKind(for: key.type)

        if row.identical { return ChangeDetail(summary: "Identical to base — no effective change") }

        if kind == .graphic {
            let ni = graphicInfo(key.type, new.data)
            let oi = old.flatMap { graphicInfo(key.type, $0.data) }
            let s: String
            if isNew { s = ni.map { "New graphic · \($0)" } ?? "New graphic" }
            else if let ni, let oi { s = ni == oi ? "Same size (\(ni)) — new pixels" : "\(oi) → \(ni)" }
            else { s = "Replaces the classic graphic" }
            return ChangeDetail(summary: s, oldInfo: oi, newInfo: ni)
        }
        if key.type == GraphicsEnhancementType.descriptor { return ChangeDetail(summary: "HD / 3D attachment") }

        if let schema = ResourceSchemas.schema(for: key.type), schema.editorKind == .form {
            guard let old else {
                return ChangeDetail(summary: "New \(schema.displayName.lowercased())")
            }
            let changes = ResourceDiff.fieldChanges(schema: schema, base: old.data, new: new.data) { t, id in
                eff.resource(t, id)?.name
            }
            var s = ResourceDiff.summary(changes)
            if changes.isEmpty, old.name != new.name { s = "Renamed from “\(old.name)”" }
            return ChangeDetail(summary: s)
        }

        switch key.type {
        case NovaType.strList:
            let ns = TextResourceCodec.decodeStringList(new.data)
            guard let old else { return ChangeDetail(summary: "New list · \(ns.count) strings") }
            let os = TextResourceCodec.decodeStringList(old.data)
            let ch = ResourceDiff.stringChanges(base: os, new: ns)
            return ChangeDetail(summary: "\(ch.count) of \(max(ns.count, os.count)) strings changed")
        case NovaType.desc:
            let nt = DescRecord(new.data)
            guard let old else { return ChangeDetail(summary: snippet(nt.text)) }
            let ot = DescRecord(old.data)
            if ot.text != nt.text { return ChangeDetail(summary: snippet(nt.text)) }
            if ot.pictureID != nt.pictureID { return ChangeDetail(summary: "Picture #\(ot.pictureID) → #\(nt.pictureID)") }
            return ChangeDetail(summary: "Movie / flags changed")
        default:
            if key.type.stringValue == "STR " {
                let nt = TextResourceCodec.decodeString(new.data)
                return ChangeDetail(summary: snippet(nt))
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(new.data.count), countStyle: .file)
            if let old {
                let os = ByteCountFormatter.string(fromByteCount: Int64(old.data.count), countStyle: .file)
                return ChangeDetail(summary: "\(os) → \(size)")
            }
            return ChangeDetail(summary: "New · \(size)")
        }
    }

    nonisolated private static func snippet(_ s: String) -> String {
        let flat = TextResourceCodec.display(s).replacingOccurrences(of: "\n", with: " ")
        let t = flat.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "(empty text)" }
        return "“" + (t.count > 90 ? String(t.prefix(90)) + "…" : t) + "”"
    }

    /// "46×46 · 36 frames" from the resource header, without decoding any pixels.
    nonisolated static func graphicInfo(_ type: NovaSwiftKit.FourCharCode, _ d: Data) -> String? {
        switch type {
        case NovaType.rleD, NovaType.rle8:
            guard d.count >= 10 else { return nil }
            let w = FieldCodec.readInt(d, 0, 2, signed: true), h = FieldCodec.readInt(d, 2, 2, signed: true)
            let f = FieldCodec.readInt(d, 8, 2, signed: true)
            guard w > 0, h > 0 else { return nil }
            return "\(w)×\(h) · \(f) frame\(f == 1 ? "" : "s")"
        case NovaType.pict:
            guard d.count >= 10 else { return nil }
            let t = FieldCodec.readInt(d, 2, 2, signed: true), l = FieldCodec.readInt(d, 4, 2, signed: true)
            let b = FieldCodec.readInt(d, 6, 2, signed: true), r = FieldCodec.readInt(d, 8, 2, signed: true)
            guard r > l, b > t else { return nil }
            return "\(r - l)×\(b - t)"
        default:
            return nil
        }
    }
}
#endif
