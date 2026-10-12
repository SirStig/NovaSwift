import Foundation

/// One field that differs between a plug-in's override and the record it replaces.
public struct FieldChange: Sendable, Hashable, Identifiable {
    public struct FlagDelta: Sendable, Hashable {
        public let label: String
        public let added: Bool
    }

    public var id: String { key }
    public let key: String
    public let label: String
    public let group: String
    /// The value in the base record (what a revert writes back).
    public let oldValue: FieldValue
    public let newValue: FieldValue
    /// Plain-language renderings (enum labels, ids with names, compact numbers).
    public let oldText: String
    public let newText: String
    /// For flag fields: the bits switched on / off.
    public let flagDeltas: [FlagDelta]

    /// "Max speed 300 → 450" or "Flags +Fires forward −Turret".
    public var summaryText: String {
        if !flagDeltas.isEmpty {
            return label + " " + flagDeltas.map { ($0.added ? "+" : "−") + $0.label }.joined(separator: " ")
        }
        return "\(label) \(oldText) → \(newText)"
    }
}

/// One `STR#` entry that differs between base and override.
public struct StringChange: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    /// Zero-based index.
    public let index: Int
    /// nil when the base list is shorter (an added string).
    public let old: String?
    /// nil when the override list is shorter (a removed string).
    public let new: String?
}

/// Field-level and string-level comparison of a record against its base. Pure and
/// `Sendable`, so lists of thousands of overrides can be diffed off the main actor.
public enum ResourceDiff {

    /// Fields whose value differs, in schema order. `name` resolves a referenced
    /// resource to its display name (return nil/"" when unknown).
    public static func fieldChanges(schema: ResourceSchema, base: Data, new: Data,
                                    name: (FourCharCode, Int) -> String? = { _, _ in nil }) -> [FieldChange] {
        let b = schema.padded(base), n = schema.padded(new)
        var out: [FieldChange] = []
        for f in schema.fields {
            if case .blob = f.kind { continue }
            let ov = FieldCodec.read(f, from: b), nv = FieldCodec.read(f, from: n)
            guard ov != nv else { continue }
            var deltas: [FieldChange.FlagDelta] = []
            let oldText: String, newText: String
            if case let .array(oa) = ov, case let .array(na) = nv {
                var os: [String] = [], ns: [String] = []
                for i in 0..<max(oa.count, na.count) {
                    let o = i < oa.count ? oa[i] : nil, x = i < na.count ? na[i] : nil
                    if o == x { continue }
                    os.append("#\(i + 1): " + (o.map { format($0, f, name) } ?? "—"))
                    ns.append("#\(i + 1): " + (x.map { format($0, f, name) } ?? "—"))
                }
                oldText = os.joined(separator: ", "); newText = ns.joined(separator: ", ")
            } else {
                oldText = format(ov, f, name); newText = format(nv, f, name)
                if case .flags = f.kind, case let .int(a) = ov, case let .int(c) = nv {
                    for bit in f.flagBits where (a & bit.mask != 0) != (c & bit.mask != 0) {
                        deltas.append(.init(label: bit.label, added: c & bit.mask != 0))
                    }
                    let known = f.flagBits.reduce(0) { $0 | $1.mask }
                    let rest = (a ^ c) & ~known
                    if rest != 0 {
                        deltas.append(.init(label: String(format: "bits 0x%lX", rest), added: c & rest != 0))
                    }
                }
            }
            out.append(FieldChange(key: f.key, label: f.label, group: f.group, oldValue: ov, newValue: nv,
                                   oldText: oldText, newText: newText, flagDeltas: deltas))
        }
        return out
    }

    /// "Max speed 300 → 450, Cost 2.1M → 3M, +2 more" (or "Identical to base").
    public static func summary(_ changes: [FieldChange], limit: Int = 2) -> String {
        guard !changes.isEmpty else { return "Identical to base" }
        var parts = changes.prefix(limit).map(\.summaryText)
        if changes.count > limit { parts.append("+\(changes.count - limit) more") }
        return parts.joined(separator: ", ")
    }

    /// Entries that differ between two `STR#` lists.
    public static func stringChanges(base: [String], new: [String]) -> [StringChange] {
        var out: [StringChange] = []
        for i in 0..<max(base.count, new.count) {
            let o = i < base.count ? base[i] : nil, n = i < new.count ? new[i] : nil
            if o != n { out.append(StringChange(index: i, old: o, new: n)) }
        }
        return out
    }

    // MARK: Formatting

    /// 1234567 -> "1.2M"; everything else plain.
    public static func compact(_ v: Int) -> String {
        let a = abs(v)
        guard a >= 1_000_000 else { return String(v) }
        let m = Double(v) / 1_000_000
        let s = String(format: "%.1f", m)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "M"
    }

    public static func format(_ v: FieldValue, _ f: SchemaField,
                              _ name: (FourCharCode, Int) -> String?) -> String {
        switch v {
        case let .int(i): return formatInt(i, f, name)
        case let .uint64(u): return String(format: "0x%llX", u)
        case let .string(s): return s.isEmpty ? "(empty)" : "\"\(s.count > 40 ? String(s.prefix(40)) + "…" : s)\""
        case let .color(r, g, b): return String(format: "#%02X%02X%02X", r, g, b)
        case let .bytes(d): return "\(d.count) bytes"
        case let .point(x, y): return "(\(x), \(y))"
        case let .rect(t, l, b, r): return "(\(t), \(l), \(b), \(r))"
        case let .array(a): return "[" + a.map { format($0, f, name) }.joined(separator: ", ") + "]"
        }
    }

    private static func formatInt(_ i: Int, _ f: SchemaField, _ name: (FourCharCode, Int) -> String?) -> String {
        if case .flags = f.kind {
            let set = f.flagBits.filter { i & $0.mask != 0 }.map(\.label)
            return set.isEmpty ? (i == 0 ? "none" : String(format: "0x%lX", i)) : set.joined(separator: " + ")
        }
        if let opt = f.option(for: i) {
            if opt.isExact { return opt.label }
            let payload = opt.payload(for: i)
            if let t = opt.refType { return "\(opt.label) \(refText(t, payload, name))" }
            return "\(opt.label) \(i)"
        }
        if case .ref = f.kind {
            if let r = f.reference(for: i) { return refText(r.type, r.id, name) }
            return i <= 0 ? "None" : String(i)
        }
        return compact(i)
    }

    private static func refText(_ t: FourCharCode, _ id: Int, _ name: (FourCharCode, Int) -> String?) -> String {
        if let n = name(t, id), !n.isEmpty { return "\(n) (#\(id))" }
        return "#\(id)"
    }
}
