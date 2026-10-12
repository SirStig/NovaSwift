import Foundation

/// Where a resource in the editor's merged view comes from.
public enum Provenance: Hashable, Sendable {
    /// Comes from the base game and the plug-in doesn't touch it.
    case base
    /// Exists only in this plug-in.
    case new
    /// This plug-in replaces a resource that exists underneath it.
    case override
    /// Comes from another enabled plug-in (its `pluginID`) and isn't touched here.
    case otherPlugin(String)
}

public enum PluginFormat: String, Sendable, CaseIterable {
    /// Windows/Graphite "BRGR" `.rez` — what EV Nova CE loads.
    case rez
    /// Classic Macintosh resource fork bytes (also valid as an `.ndat` data fork).
    case classic
}

public enum PluginDocumentError: Swift.Error, CustomStringConvertible, Equatable {
    case notFound(ResourceKey)
    case notInPlugin(ResourceKey)
    case idInUse(ResourceKey)
    case invalidID(Int)
    case fullExportNotConfirmed

    public var description: String {
        switch self {
        case let .notFound(k): return "\(k) doesn't exist"
        case let .notInPlugin(k): return "\(k) isn't part of this plug-in (override it first)"
        case let .idInUse(k): return "\(k) is already taken by the base game or this plug-in"
        case let .invalidID(id): return "\(id) is not a valid resource id (must be -32768...32767)"
        case .fullExportNotConfirmed:
            return "A full export contains the base game's own data; confirm that you may redistribute it first"
        }
    }
}

/// What a renumber did, so the UI can warn about links it couldn't fix.
public struct RenumberReport: Sendable {
    public let from: ResourceKey
    public let to: ResourceKey
    /// Plug-in resources whose references were rewritten to the new id.
    public let rewritten: [ResourceKey]
    /// Resources outside the plug-in (base game / other plug-ins) that still
    /// point at the old id and can't be edited here.
    public let externalReferrers: [ResourceKey]
    /// Resources tied to the old id by id arithmetic (`shän`, `dësc`, `PICT`
    /// companions) that the caller may want to move with it.
    public let implicitRelatives: [ResourceKey]
}

/// The editor's working document: a **layer** holding only the resources a
/// plug-in author added or overrode, laid over a read-only **base** (the base
/// game plus any other enabled plug-ins). The engine plays `effective`
/// (base ⊕ layer); saving writes only the layer unless a full export is asked
/// for. Platform-neutral plain data code (no SwiftUI/Combine): UIs observe it
/// through `onChange`.
///
/// Not thread-safe; use from one actor (normally the main actor).
public final class PluginDocument {

    // MARK: Metadata (not undoable; edits mark the document dirty)

    public var name: String { didSet { if name != oldValue { metadataChanged() } } }
    public var author: String { didSet { if author != oldValue { metadataChanged() } } }
    public var version: String { didSet { if version != oldValue { metadataChanged() } } }
    public var notes: String { didSet { if notes != oldValue { metadataChanged() } } }

    // MARK: Data

    /// Only the plug-in's own resources.
    public private(set) var layer: ResourceCollection
    /// Base game + other enabled plug-ins. Never modified.
    public let base: ResourceCollection

    private var cachedEffective: ResourceCollection?
    private var cachedReferences: ResourceReferences?
    /// Keys changed inside the open `beginGroup`/`endGroup`; flushed as ONE change
    /// (one `onChange`, one reference-graph update) when the outermost group closes.
    private var pendingGroupKeys: Set<ResourceKey> = []

    /// `base` overlaid by `layer`. Maintained incrementally as the layer changes.
    public var effective: ResourceCollection {
        if let cachedEffective { return cachedEffective }
        var e = base
        e.overlay(layer)
        cachedEffective = e
        return e
    }

    /// The reference graph of `effective` (see `ResourceReferences`).
    public var references: ResourceReferences {
        if let cachedReferences { return cachedReferences }
        let r = ResourceReferences(effective)
        cachedReferences = r
        return r
    }

    /// Adopt an effective collection that was built off the main actor from this
    /// document's `base` and `layer` (`base` overlaid by `layer`). Ignored when the
    /// layer changed since the snapshot (`changeCount` moved) or `effective` was
    /// already built, so a late result can never clobber newer state.
    public func adoptEffective(_ built: ResourceCollection, atChangeCount count: Int) {
        guard cachedEffective == nil, changeCount == count else { return }
        cachedEffective = built
    }

    /// Adopt a reference graph built off the main actor from `effective`. `staleKeys`
    /// are the resources that changed after the snapshot was taken; they are
    /// re-indexed here (cheap) so the graph is current. Ignored if a graph already
    /// exists or `effective` hasn't been built.
    public func adoptReferences(_ built: ResourceReferences, updating staleKeys: Set<ResourceKey>) {
        guard cachedReferences == nil, cachedEffective != nil else { return }
        var r = built
        if !staleKeys.isEmpty { r.update(staleKeys, in: effective) }
        cachedReferences = r
    }

    /// Whether `effective` / the reference graph are already built (no work to read them).
    public var hasEffectiveCached: Bool { cachedEffective != nil }
    public var hasReferencesCached: Bool { cachedReferences != nil }

    // MARK: Change tracking

    /// Increments on every change, undo and redo (and metadata edit).
    public private(set) var changeCount = 0
    private var savedChangeCount = 0
    public var isDirty: Bool { changeCount != savedChangeCount }
    /// Called after every layer change with the affected keys (also for undo/redo).
    public var onChange: ((Set<ResourceKey>) -> Void)?

    // MARK: Undo

    private enum Slot: Equatable { case absent; case present(Resource) }
    private struct Entry {
        var label: String
        var before: [ResourceKey: Slot]
        var after: [ResourceKey: Slot]
        var coalesce: String?
    }
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var groupDepth = 0
    private var groupEntry: Entry?
    public var undoLimit = 500

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    // MARK: Init

    public init(name: String = "Untitled Plug-in", author: String = "", version: String = "1.0",
                notes: String = "", base: ResourceCollection = ResourceCollection(),
                layer: ResourceCollection = ResourceCollection()) {
        self.name = name; self.author = author; self.version = version; self.notes = notes
        self.base = base; self.layer = layer
    }

    private func metadataChanged() { changeCount += 1 }

    // MARK: Queries

    /// The resource as the game sees it.
    public func resource(_ type: FourCharCode, _ id: Int) -> Resource? { effective.resource(type, id) }

    /// The plug-in's own copy, if it has one.
    public func layerResource(_ type: FourCharCode, _ id: Int) -> Resource? { layer.resource(type, id) }

    public func provenance(_ type: FourCharCode, _ id: Int) -> Provenance? {
        let inBase = base.resource(type, id)
        if layer.resource(type, id) != nil { return inBase == nil ? .new : .override }
        guard let inBase else { return nil }
        return inBase.pluginID.isEmpty ? .base : .otherPlugin(inBase.pluginID)
    }

    public struct BrowserEntry: Hashable, Sendable {
        public let key: ResourceKey
        public let name: String
        public let provenance: Provenance
    }

    /// Every resource of a type in the merged view, sorted by id, with provenance.
    public func browse(_ type: FourCharCode) -> [BrowserEntry] {
        Self.browse(type, effective: effective, layer: layer, base: base)
    }

    /// `browse` over explicit snapshots, so it can run off the main actor
    /// (`ResourceCollection` is a value type; copy them on the owning actor first).
    public static func browse(_ type: FourCharCode, effective: ResourceCollection,
                              layer: ResourceCollection, base: ResourceCollection) -> [BrowserEntry] {
        effective.resources(of: type).map { r in
            let inBase = base.resource(type, r.id)
            let prov: Provenance
            if layer.resource(type, r.id) != nil { prov = inBase == nil ? .new : .override }
            else if let inBase { prov = inBase.pluginID.isEmpty ? .base : .otherPlugin(inBase.pluginID) }
            else { prov = .base }
            return BrowserEntry(key: ResourceKey(type, r.id), name: r.name, provenance: prov)
        }
    }

    /// Smallest id ≥ `from` that neither the base nor the plug-in uses, wrapping
    /// back to 128 when the top of the range is taken. Ids above 32767 aren't
    /// representable; a result of 32768 means every id from 128 up is in use.
    public func nextFreeID(_ type: FourCharCode, from: Int = 128) -> Int {
        let top = Int(Int16.max)
        let start = min(max(from, Int(Int16.min)), top + 1)
        func used(_ id: Int) -> Bool { layer.resource(type, id) != nil || base.resource(type, id) != nil }
        if start <= top {
            for id in start...top where !used(id) { return id }
        }
        if start > 128 {
            for id in 128..<start where !used(id) { return id }
        }
        return top + 1
    }

    // MARK: Editing

    /// Add or replace a resource in the plug-in. Returns false for ids that
    /// don't fit the container's signed 16-bit id.
    @discardableResult
    public func put(_ resource: Resource, label: String? = nil, coalesce: String? = nil) -> Bool {
        guard (Int(Int16.min)...Int(Int16.max)).contains(resource.id) else { return false }
        var r = resource
        r.pluginID = ""
        let key = ResourceKey(r.type, r.id)
        apply([key], label: label ?? "Edit \(key)", coalesce: coalesce) { $0.add(r) }
        return true
    }

    /// Remove a resource from the plug-in (base resources can't be deleted; to
    /// hide one, override it). Returns false if the plug-in doesn't have it.
    @discardableResult
    public func remove(_ type: FourCharCode, _ id: Int) -> Bool {
        guard layer.resource(type, id) != nil else { return false }
        apply([ResourceKey(type, id)], label: "Delete \(ResourceKey(type, id))") { $0.remove(type, id) }
        return true
    }

    /// Drop the plug-in's override so the base version shows through again.
    /// Returns false if there is nothing to revert to.
    @discardableResult
    public func revertToBase(_ type: FourCharCode, _ id: Int) -> Bool {
        guard layer.resource(type, id) != nil, base.resource(type, id) != nil else { return false }
        apply([ResourceKey(type, id)], label: "Revert \(ResourceKey(type, id)) to base") { $0.remove(type, id) }
        return true
    }

    /// Copy the current (effective) resource into the plug-in under a new id.
    @discardableResult
    public func duplicate(_ type: FourCharCode, _ id: Int) throws -> Int {
        guard var copy = effective.resource(type, id) else { throw PluginDocumentError.notFound(ResourceKey(type, id)) }
        var newID = nextFreeID(type, from: id + 1)
        if let range = NovaType.slotRange[type], !range.contains(newID) { newID = nextFreeID(type, from: range.lowerBound) }
        guard (Int(Int16.min)...Int(Int16.max)).contains(newID) else { throw PluginDocumentError.invalidID(newID) }
        copy = Resource(type: type, id: newID, name: copy.name.isEmpty ? "" : copy.name + " copy",
                        attributes: copy.attributes, data: copy.data)
        put(copy, label: "Duplicate \(ResourceKey(type, id))")
        return newID
    }

    /// Give a plug-in resource a new id. With `rewriteReferences`, every
    /// plug-in resource that points at the old id (fields and NCB scripts) is
    /// updated in the same undo step.
    @discardableResult
    public func renumber(_ type: FourCharCode, from: Int, to: Int, rewriteReferences: Bool = false) throws -> RenumberReport {
        let src = ResourceKey(type, from), dst = ResourceKey(type, to)
        guard (Int(Int16.min)...Int(Int16.max)).contains(to) else { throw PluginDocumentError.invalidID(to) }
        guard let res = layer.resource(type, from) else {
            throw effective.resource(type, from) == nil ? PluginDocumentError.notFound(src) : PluginDocumentError.notInPlugin(src)
        }
        guard layer.resource(type, to) == nil, base.resource(type, to) == nil else { throw PluginDocumentError.idInUse(dst) }

        var rewritten: [ResourceKey] = []
        var external: [ResourceKey] = []
        let referrers = references.usedBy(src).filter { $0.kind != .implicit }.map(\.source)
        var implicit: [ResourceKey] = []
        if let schema = ResourceSchemas.schema(for: type) {
            implicit = schema.related.map { ResourceKey($0.type, from + $0.idOffset) }
                .filter { effective.resource($0.type, $0.id) != nil }
        }

        beginGroup("Renumber \(src) → \(to)")
        defer { endGroup() }
        let moved = Resource(type: type, id: to, name: res.name, attributes: res.attributes, data: res.data)
        apply([src, dst], label: "Renumber \(src)") { $0.remove(type, from); $0.add(moved) }

        if rewriteReferences {
            for key in Set(referrers) {
                guard let r = layer.resource(key.type, key.id == from && key.type == type ? to : key.id) else {
                    external.append(key); continue
                }
                if let updated = ResourceReferences.rewritten(r, from: src, to: to) {
                    put(updated, label: "Update references in \(ResourceKey(r.type, r.id))")
                    rewritten.append(ResourceKey(r.type, r.id))
                }
            }
        } else {
            external = referrers.filter { layer.resource($0.type, $0.id) == nil }
        }
        return RenumberReport(from: src, to: dst, rewritten: rewritten.sorted(),
                              externalReferrers: Array(Set(external)).sorted(), implicitRelatives: implicit)
    }

    // MARK: Field editing conveniences

    /// Set one schema field of a resource, creating a plug-in override from the
    /// effective version if the plug-in doesn't have it yet. Consecutive edits
    /// of the same field coalesce into one undo step.
    @discardableResult
    public func setValue(_ value: FieldValue, field key: String, of type: FourCharCode, _ id: Int) -> Bool {
        guard let schema = ResourceSchemas.schema(for: type), schema.field(key) != nil,
              var r = layer.resource(type, id) ?? effective.resource(type, id) else { return false }
        var data = schema.padded(r.data)
        schema.write(value, key: key, into: &data)
        r.data = data
        return put(r, label: "Edit \(schema.field(key)!.label)", coalesce: "\(type)/\(id)/\(key)")
    }

    /// Create a blank resource of a schema'd type at the next free id (or `id`).
    @discardableResult
    public func create(_ type: FourCharCode, id: Int? = nil, name: String = "") throws -> Int {
        let newID = id ?? nextFreeID(type)
        guard (Int(Int16.min)...Int(Int16.max)).contains(newID) else { throw PluginDocumentError.invalidID(newID) }
        let data: Data
        if type == NovaType.desc { data = DescRecord().encode() }
        else if let schema = ResourceSchemas.schema(for: type) { data = schema.makeDefault() }
        else if type == NovaType.strList { data = TextResourceCodec.encodeStringList([]) }
        else { data = Data() }
        put(Resource(type: type, id: newID, name: name, data: data), label: "New \(type) #\(newID)")
        return newID
    }

    // MARK: Undo / redo

    /// Everything between `beginGroup` and the matching `endGroup` becomes one
    /// undo step (nest freely).
    public func beginGroup(_ label: String) {
        if groupDepth == 0 { groupEntry = Entry(label: label, before: [:], after: [:], coalesce: nil) }
        groupDepth += 1
    }

    public func endGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        guard groupDepth == 0 else { return }
        if let entry = groupEntry {
            groupEntry = nil
            if !entry.before.isEmpty { pushUndo(entry) }
        }
        flushPendingGroupChange()
    }

    /// Announce everything a finished group touched as a single change.
    private func flushPendingGroupChange() {
        guard !pendingGroupKeys.isEmpty else { return }
        let keys = pendingGroupKeys
        pendingGroupKeys = []
        updateReferences(keys)
        onChange?(keys)
    }

    public func withGroup<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        beginGroup(label)
        defer { endGroup() }
        return try body()
    }

    @discardableResult
    public func undo() -> Bool {
        guard groupDepth == 0, let entry = undoStack.popLast() else { return false }
        restore(entry.before)
        redoStack.append(entry)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard groupDepth == 0, let entry = redoStack.popLast() else { return false }
        restore(entry.after)
        undoStack.append(entry)
        return true
    }

    public func clearUndoHistory() { undoStack.removeAll(); redoStack.removeAll() }

    private func restore(_ slots: [ResourceKey: Slot]) {
        for (k, slot) in slots {
            switch slot {
            case .absent: layer.remove(k.type, k.id)
            case let .present(r): layer.add(r)
            }
        }
        changed(Set(slots.keys))
    }

    // MARK: Core mutation

    private func capture(_ keys: [ResourceKey]) -> [ResourceKey: Slot] {
        Dictionary(keys.map { k in (k, layer.resource(k.type, k.id).map(Slot.present) ?? .absent) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func apply(_ keys: [ResourceKey], label: String, coalesce: String? = nil,
                       _ mutate: (inout ResourceCollection) -> Void) {
        let before = capture(keys)
        mutate(&layer)
        let after = capture(keys)
        guard before != after else { return }

        if var g = groupEntry, groupDepth > 0 {
            for (k, s) in before where g.before[k] == nil { g.before[k] = s }
            for (k, s) in after { g.after[k] = s }
            groupEntry = g
        } else {
            redoStack.removeAll()
            if let coalesce, var last = undoStack.last, last.coalesce == coalesce, Set(last.before.keys) == Set(before.keys) {
                last.after = after
                undoStack[undoStack.count - 1] = last
            } else {
                pushUndo(Entry(label: label, before: before, after: after, coalesce: coalesce))
            }
        }
        if groupDepth > 0 { redoStack.removeAll() }
        changed(Set(keys))
    }

    private func pushUndo(_ e: Entry) {
        undoStack.append(e)
        redoStack.removeAll()
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
    }

    private func changed(_ keys: Set<ResourceKey>) {
        changeCount += 1
        if cachedEffective != nil {
            for k in keys {
                if let r = layer.resource(k.type, k.id) { cachedEffective!.add(r) }
                else if let b = base.resource(k.type, k.id) { cachedEffective!.add(b) }
                else { cachedEffective!.remove(k.type, k.id) }
            }
        }
        // Inside a group the reference update and `onChange` wait for the group to close,
        // so a many-key edit (renumber, bulk rewrite) costs one update and one revision bump.
        if groupDepth > 0 { pendingGroupKeys.formUnion(keys); return }
        updateReferences(keys)
        onChange?(keys)
    }

    private func updateReferences(_ keys: Set<ResourceKey>) {
        if cachedReferences != nil, let e = cachedEffective { cachedReferences!.update(keys, in: e) }
        else if cachedReferences != nil { cachedReferences = nil }
    }

    // MARK: Save / open

    /// Metadata travels inside the file as a resource the original game never
    /// asks for, like the HD `NSgx`/`NSbl` types.
    public static let metadataType = FourCharCode("NSmd")!
    static let metadataID = 128

    private struct Metadata: Codable { var name: String; var author: String; var version: String; var notes: String }

    /// The bytes of the plug-in file. By default only the plug-in's own
    /// resources are written. `includeBase: true` writes the whole effective
    /// set, base game included — this **redistributes base game data**, so
    /// callers must only offer it behind an explicit, warned choice.
    public func exportData(format: PluginFormat, includeBase: Bool = false, embedMetadata: Bool = true) throws -> Data {
        var out = includeBase ? effective : layer
        if embedMetadata,
           let json = try? JSONEncoder().encode(Metadata(name: name, author: author, version: version, notes: notes)) {
            out.add(Resource(type: Self.metadataType, id: Self.metadataID, name: "Editor metadata", data: json))
        }
        switch format {
        case .rez: return RezWriter.write(out)
        case .classic: return try ClassicForkWriter.write(out)
        }
    }

    /// The whole effective set (base game included) as one file. This
    /// redistributes base game data, so it refuses to run unless the caller
    /// passes `acknowledgingBaseRedistribution: true` after warning the user.
    public func exportFull(format: PluginFormat, acknowledgingBaseRedistribution: Bool,
                           embedMetadata: Bool = true) throws -> Data {
        guard acknowledgingBaseRedistribution else { throw PluginDocumentError.fullExportNotConfirmed }
        return try exportData(format: format, includeBase: true, embedMetadata: embedMetadata)
    }

    /// Write the plug-in to `url` and mark the document clean.
    public func save(to url: URL, format: PluginFormat, includeBase: Bool = false, embedMetadata: Bool = true) throws {
        try exportData(format: format, includeBase: includeBase, embedMetadata: embedMetadata).write(to: url, options: .atomic)
        savedChangeCount = changeCount
    }

    /// Load a plug-in file (`.rez`, classic fork, `.ndat`) as the layer over `base`.
    public static func open(url: URL, base: ResourceCollection = ResourceCollection()) throws -> PluginDocument {
        var data = try Data(contentsOf: url)
        if data.isEmpty, let fork = try? Data(contentsOf: url.appendingPathComponent("..namedfork/rsrc")), !fork.isEmpty {
            data = fork // classic file whose resources live in the resource fork
        }
        return try open(data: data, defaultName: url.deletingPathExtension().lastPathComponent, base: base)
    }

    public static func open(data: Data, defaultName: String = "Untitled Plug-in",
                            base: ResourceCollection = ResourceCollection()) throws -> PluginDocument {
        var layer = try ResourceFile.read(data)
        var meta = Metadata(name: defaultName, author: "", version: "1.0", notes: "")
        if let m = layer.resource(metadataType, metadataID),
           let decoded = try? JSONDecoder().decode(Metadata.self, from: m.data) {
            meta = decoded
            layer.remove(metadataType, metadataID)
        }
        let doc = PluginDocument(name: meta.name, author: meta.author, version: meta.version, notes: meta.notes,
                                 base: base, layer: layer)
        doc.savedChangeCount = doc.changeCount
        return doc
    }
}
