import Foundation

/// Identifies one resource: its type code and id.
public struct ResourceKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let type: FourCharCode
    public let id: Int
    public init(_ type: FourCharCode, _ id: Int) { self.type = type; self.id = id }
    public var description: String { "\(type) #\(id)" }
    public static func < (a: ResourceKey, b: ResourceKey) -> Bool {
        a.type != b.type ? a.type < b.type : a.id < b.id
    }
}

/// One link between two resources.
public struct ResourceReference: Hashable, Sendable {
    public enum Kind: Sendable {
        /// A schema field stores the target's id (directly or range-encoded).
        case field
        /// The target is owned by id arithmetic (e.g. `shïp` N → `shän` N),
        /// so it may legitimately not exist.
        case implicit
        /// An NCB expression names the target (`S781`, `o210`, …).
        case script
    }
    public let source: ResourceKey
    /// Schema field key (or, for implicit links, the relation's label).
    public let fieldKey: String
    /// Element index for array fields; 0 otherwise.
    public let index: Int
    public let target: ResourceKey
    public let kind: Kind

    /// Missing optional targets are not errors.
    public var isOptional: Bool { kind == .implicit }
}

/// The reference graph over a resource collection: for every resource, what it
/// points at (`outgoing`) and what points at it (`incoming`, the editor's
/// "used by" list). Built from the schema `ref` fields, range-encoded ids
/// (govt classes, `mïsn` AvailStel bands, …), contextual values (`oütf` ModVal),
/// implicit id-arithmetic relations (`dësc`/`PICT`/`shän` companions), NCB
/// script operands, and the `NSgx` → `NSbl` blob link.
public struct ResourceReferences {
    public private(set) var outgoing: [ResourceKey: [ResourceReference]] = [:]
    public private(set) var incoming: [ResourceKey: [ResourceReference]] = [:]

    public init(_ collection: ResourceCollection) {
        for type in collection.types {
            for r in collection.resources(of: type) { insert(r) }
        }
    }

    public init() {}

    public func uses(_ key: ResourceKey) -> [ResourceReference] { outgoing[key] ?? [] }
    public func usedBy(_ key: ResourceKey) -> [ResourceReference] { incoming[key] ?? [] }

    /// Re-index after `keys` changed in `collection` (added, edited or removed).
    public mutating func update(_ keys: Set<ResourceKey>, in collection: ResourceCollection) {
        for key in keys { remove(key) }
        for key in keys { if let r = collection.resource(key.type, key.id) { insert(r) } }
    }

    private mutating func insert(_ r: Resource) {
        let refs = Self.references(of: r)
        guard !refs.isEmpty else { return }
        let key = ResourceKey(r.type, r.id)
        outgoing[key] = refs
        for ref in refs { incoming[ref.target, default: []].append(ref) }
    }

    private mutating func remove(_ key: ResourceKey) {
        guard let refs = outgoing.removeValue(forKey: key) else { return }
        for ref in refs {
            incoming[ref.target]?.removeAll { $0.source == key }
            if incoming[ref.target]?.isEmpty == true { incoming[ref.target] = nil }
        }
    }

    // MARK: Extraction

    /// Types whose absence can be covered by an alternative with the same id:
    /// a sprite id resolves to an `rlëD`, an `rlë8`, or a PICT sheet.
    static let alternates: [FourCharCode: [FourCharCode]] = [
        NovaType.rleD: [NovaType.rle8, NovaType.pict],
    ]

    /// Whether `key` (or an accepted alternative) exists in `collection`.
    public static func exists(_ key: ResourceKey, in collection: ResourceCollection) -> Bool {
        if collection.resource(key.type, key.id) != nil { return true }
        return (alternates[key.type] ?? []).contains { collection.resource($0, key.id) != nil }
    }

    /// Every outgoing reference one resource makes.
    public static func references(of r: Resource) -> [ResourceReference] {
        let source = ResourceKey(r.type, r.id)
        var out: [ResourceReference] = []

        if r.type == GraphicsEnhancementType.descriptor {
            if let blob = nsgxBlobID(r.data) {
                out.append(ResourceReference(source: source, fieldKey: "blob", index: 0,
                                             target: ResourceKey(GraphicsEnhancementType.blob, blob), kind: .field))
            }
            return out
        }
        if r.type == NovaType.desc {
            let rec = DescRecord(r.data)
            if rec.pictureID > 0 {
                out.append(ResourceReference(source: source, fieldKey: "picture", index: 0,
                                             target: ResourceKey(NovaType.pict, rec.pictureID), kind: .field))
            }
            return out
        }
        guard let schema = ResourceSchemas.schema(for: r.type) else { return out }
        let data = schema.padded(r.data)

        for f in schema.fields {
            if case let .ncb(kind, _) = f.kind {
                let text = FieldCodec.readCString(data, f.offset, f.kind.byteSize)
                for op in NCBSyntax.operands(text, kind: kind) {
                    guard let t = op.resource else { continue }
                    out.append(ResourceReference(source: source, fieldKey: f.key, index: 0, target: t, kind: .script))
                }
                continue
            }
            let isRefLike: Bool
            switch f.kind {
            case .ref: isRefLike = true
            default: isRefLike = !f.options.isEmpty || f.contextual != nil
            }
            guard isRefLike else { continue }
            let selectorField = f.contextual.flatMap { schema.field($0.selector) }
            for i in 0..<f.count {
                let v = FieldCodec.readElement(f.kind, from: data, at: f.offset + i * f.stride).intValue ?? 0
                var sel: Int?
                if let sf = selectorField {
                    sel = FieldCodec.readElement(sf.kind, from: data, at: sf.offset + (sf.isArray ? i * sf.stride : 0)).intValue
                }
                if let (t, id) = f.reference(for: v, selector: sel) {
                    out.append(ResourceReference(source: source, fieldKey: f.key, index: i,
                                                 target: ResourceKey(t, id), kind: .field))
                }
            }
        }
        for rel in schema.related {
            out.append(ResourceReference(source: source, fieldKey: rel.label, index: 0,
                                         target: ResourceKey(rel.type, r.id + rel.idOffset), kind: .implicit))
        }
        return out
    }

    /// `blob` id of an `NSgx` JSON descriptor, if it has one.
    static func nsgxBlobID(_ data: Data) -> Int? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (obj["blob"] as? NSNumber)?.intValue
    }

    // MARK: Rewriting (renumber support)

    /// `r` with every reference to `from` replaced by `to`, or nil when nothing
    /// pointed at it. Implicit (id-arithmetic) relations can't be rewritten.
    public static func rewritten(_ r: Resource, from: ResourceKey, to newID: Int) -> Resource? {
        guard let schema = ResourceSchemas.schema(for: r.type) else { return nil }
        var data = schema.padded(r.data)
        var changed = false
        for f in schema.fields {
            if case let .ncb(kind, size) = f.kind {
                let text = FieldCodec.readCString(data, f.offset, size)
                let new = NCBSyntax.rewrite(text, kind: kind) { t, id in t == from.type && id == from.id ? newID : nil }
                if new != text {
                    FieldCodec.writeElement(.string(new), kind: f.kind, into: &data, at: f.offset)
                    changed = true
                }
                continue
            }
            guard case .ref = f.kind else {
                if f.options.contains(where: { $0.refType == from.type }) || f.contextual != nil {
                    changed = rewriteNumeric(f, schema: schema, from: from, to: newID, data: &data) || changed
                }
                continue
            }
            changed = rewriteNumeric(f, schema: schema, from: from, to: newID, data: &data) || changed
        }
        guard changed else { return nil }
        var out = r
        out.data = data
        return out
    }

    private static func rewriteNumeric(_ f: SchemaField, schema: ResourceSchema, from: ResourceKey, to newID: Int,
                                       data: inout Data) -> Bool {
        var changed = false
        let selectorField = f.contextual.flatMap { schema.field($0.selector) }
        for i in 0..<f.count {
            let off = f.offset + i * f.stride
            let v = FieldCodec.readElement(f.kind, from: data, at: off).intValue ?? 0
            var sel: Int?
            if let sf = selectorField {
                sel = FieldCodec.readElement(sf.kind, from: data, at: sf.offset + (sf.isArray ? i * sf.stride : 0)).intValue
            }
            guard let (t, id) = f.reference(for: v, selector: sel), t == from.type, id == from.id else { continue }
            let new: Int
            if let ctx = f.contextual, let sel { new = newID - ctx.meaning(for: sel).idBase }
            else if f.contextual != nil { continue }
            else if let opt = f.option(for: v), opt.refType != nil { new = opt.value(forPayload: newID) }
            else if case let .ref(_, base) = f.kind { new = newID - base }
            else { continue }
            FieldCodec.writeElement(.int(new), kind: f.kind, into: &data, at: off)
            changed = true
        }
        return changed
    }
}
