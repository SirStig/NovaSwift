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

public enum PluginFormat: String, Codable, Sendable, CaseIterable {
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
    /// Companions (`implicitRelatives` that live in the plug-in) moved along with the resource,
    /// by `moveCompanions: true`. Old keys.
    public let movedCompanions: [ResourceKey]
    /// Companions that could not move (not in the plug-in, or the target id is taken / out of range).
    public let blockedCompanions: [ResourceKey]
}

/// One implicit companion of a resource and what a renumber would do with it
/// (see `PluginDocument.companionPlan`).
public struct CompanionMove: Sendable, Hashable {
    public let label: String
    public let from: ResourceKey
    public let to: ResourceKey
    /// True when the companion is in the plug-in and `to` is free, so it can move.
    public let movable: Bool
    /// Why it can't move, for the UI.
    public let blockedReason: String?
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
        /// Source-file reassignments (`setSourceFile`); "" = no source.
        var srcBefore: [ResourceKey: String] = [:]
        var srcAfter: [ResourceKey: String] = [:]
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

    private func metadataChanged() {
        changeCount += 1
        // The editor metadata lives in the primary file only, so that file needs rewriting.
        if let p = primaryFile { modifiedSources.insert(p) }
    }

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

    /// The implicit companions (`shän` with the same id as a `shïp`, `dësc` / `PICT` at fixed id
    /// offsets per type, from the schema's `related` list) that exist for `type`/`from`, with where
    /// each would go if the resource moved to `to`. Reads only the layer and base, so it is cheap
    /// enough for a live preview in a sheet.
    public func companionPlan(_ type: FourCharCode, from: Int, to: Int) -> [CompanionMove] {
        guard let schema = ResourceSchemas.schema(for: type) else { return [] }
        let valid = Int(Int16.min)...Int(Int16.max)
        var out: [CompanionMove] = []
        for rel in schema.related {
            let src = ResourceKey(rel.type, from + rel.idOffset)
            // layer ∪ base == effective, without forcing the merged view to be built.
            guard layer.resource(src.type, src.id) != nil || base.resource(src.type, src.id) != nil else { continue }
            let dst = ResourceKey(rel.type, to + rel.idOffset)
            var reason: String?
            if layer.resource(src.type, src.id) == nil { reason = "not part of this plug-in" }
            else if !valid.contains(dst.id) { reason = "new id out of range" }
            else if src == dst { reason = "id unchanged" }
            else if layer.resource(dst.type, dst.id) != nil || base.resource(dst.type, dst.id) != nil { reason = "target id in use" }
            out.append(CompanionMove(label: rel.label, from: src, to: dst, movable: reason == nil, blockedReason: reason))
        }
        return out
    }

    /// Give a plug-in resource a new id. With `rewriteReferences`, every
    /// plug-in resource that points at the old id (fields and NCB scripts) is
    /// updated in the same undo step. With `moveCompanions`, the plug-in's own
    /// implicit companions (see `companionPlan`) move to the matching new ids in
    /// the same undo step, and their references are rewritten too when
    /// `rewriteReferences` is on. Companions that can't move are reported in
    /// `blockedCompanions` / `implicitRelatives`.
    @discardableResult
    public func renumber(_ type: FourCharCode, from: Int, to: Int, rewriteReferences: Bool = false,
                         moveCompanions: Bool = false) throws -> RenumberReport {
        let src = ResourceKey(type, from), dst = ResourceKey(type, to)
        guard (Int(Int16.min)...Int(Int16.max)).contains(to) else { throw PluginDocumentError.invalidID(to) }
        guard let res = layer.resource(type, from) else {
            throw effective.resource(type, from) == nil ? PluginDocumentError.notFound(src) : PluginDocumentError.notInPlugin(src)
        }
        guard layer.resource(type, to) == nil, base.resource(type, to) == nil else { throw PluginDocumentError.idInUse(dst) }

        var rewritten: [ResourceKey] = []
        var external: [ResourceKey] = []
        let plan = companionPlan(type, from: from, to: to)
        let implicit = plan.map(\.from)
        let toMove = moveCompanions ? plan.filter(\.movable) : []
        let blocked = moveCompanions ? plan.filter { !$0.movable }.map(\.from) : []

        // Every old -> new pair this renumber performs (the resource itself, then companions).
        var moves: [(from: ResourceKey, to: ResourceKey)] = [(src, dst)]
        for c in toMove { moves.append((c.from, c.to)) }
        var movedMap: [ResourceKey: ResourceKey] = [:]
        for m in moves { movedMap[m.from] = m.to }
        var referrersByMove: [[ResourceKey]] = []
        for m in moves {
            referrersByMove.append(references.usedBy(m.from).filter { $0.kind != .implicit }.map(\.source))
        }

        beginGroup("Renumber \(src) → \(to)")
        defer { endGroup() }
        for m in moves {
            guard let r = layer.resource(m.from.type, m.from.id) else { continue }
            let moved = Resource(type: m.to.type, id: m.to.id, name: r.name, attributes: r.attributes, data: r.data)
            let file = sourceMap[m.from]          // the moved resource stays in the file it was in
            apply([m.from, m.to], label: "Renumber \(m.from)") { $0.remove(m.from.type, m.from.id); $0.add(moved) }
            if let file, sourceFiles.contains(file) {
                sourceMap[m.to] = file
                modifiedSources.insert(file)
            }
        }

        if rewriteReferences {
            for (n, m) in moves.enumerated() {
                for key in Set(referrersByMove[n]) {
                    let current = movedMap[key] ?? key
                    guard let r = layer.resource(current.type, current.id) else {
                        external.append(key); continue
                    }
                    if let updated = ResourceReferences.rewritten(r, from: m.from, to: m.to.id) {
                        put(updated, label: "Update references in \(ResourceKey(r.type, r.id))")
                        let k = ResourceKey(r.type, r.id)
                        if !rewritten.contains(k) { rewritten.append(k) }
                    }
                }
            }
        } else {
            for (n, _) in moves.enumerated() {
                external.append(contentsOf: referrersByMove[n].filter { k in
                    let current = movedMap[k] ?? k
                    return layer.resource(current.type, current.id) == nil
                })
            }
        }
        let movedOld = toMove.map(\.from)
        return RenumberReport(from: src, to: dst, rewritten: rewritten.sorted(),
                              externalReferrers: Array(Set(external)).sorted(),
                              implicitRelatives: implicit.filter { !movedOld.contains($0) },
                              movedCompanions: movedOld, blockedCompanions: blocked)
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
            if !entry.before.isEmpty || !entry.srcBefore.isEmpty { pushUndo(entry) }
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
        restore(entry.before, sources: entry.srcBefore)
        redoStack.append(entry)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard groupDepth == 0, let entry = redoStack.popLast() else { return false }
        restore(entry.after, sources: entry.srcAfter)
        undoStack.append(entry)
        return true
    }

    public func clearUndoHistory() { undoStack.removeAll(); redoStack.removeAll() }

    private func restore(_ slots: [ResourceKey: Slot], sources: [ResourceKey: String] = [:]) {
        for (k, slot) in slots {
            switch slot {
            case .absent: layer.remove(k.type, k.id)
            case let .present(r): layer.add(r)
            }
        }
        for (k, s) in sources {
            if let old = sourceMap[k] { modifiedSources.insert(old) }
            if s.isEmpty { sourceMap[k] = nil } else { sourceMap[k] = s; modifiedSources.insert(s) }
        }
        changed(Set(slots.keys).union(sources.keys))
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
        trackSources(keys)
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

    // MARK: Source files

    /// Prefix of the source key of an `.nsx` graphics pack (`pack:<relative path>.nsx`).
    public static let packPrefix = "pack:"
    public static func isPackKey(_ key: String) -> Bool { key.hasPrefix(packPrefix) }

    /// The files this plug-in was loaded from, in load order (later files win a clash). Each is a
    /// stable key: the path relative to the plug-in's folder (`ARPIA2 3.rez`, `Nova Files/X.rez`),
    /// or `pack:<relative path>.nsx` for a graphics pack. Empty for a new document and for ones
    /// opened through the legacy single-file `open(url:)`.
    public private(set) var sourceFiles: [String] = []
    /// On-disk container format of each non-pack source file, so Save writes it back the same way.
    public private(set) var fileFormats: [String: PluginFormat] = [:]
    /// Where new resources go. nil = pick by type (see `defaultSource(for:)`).
    public var targetFile: String?

    private var sourceMap: [ResourceKey: String] = [:]
    /// Resources a later file of the same plug-in overrides. They aren't visible in `layer`
    /// (one resource per key) but are written back to their own file so Save loses nothing.
    private var shadowed: [String: [Resource]] = [:]
    /// Source files that changed since the last save (only these are rewritten).
    private var modifiedSources: Set<String> = []

    /// True when Save must write several files (or a `.nsx` pack) instead of one.
    public var usesFolderLayout: Bool {
        sourceFiles.count > 1 || sourceFiles.contains(where: Self.isPackKey)
    }

    private static func baseName(_ key: String) -> String { (key as NSString).lastPathComponent.lowercased() }

    /// The data file that receives editor metadata and untyped new resources: the first
    /// non-pack file that doesn't look like a dedicated graphics/sounds file.
    public var primaryFile: String? {
        let data = sourceFiles.filter { !Self.isPackKey($0) }
        return data.first { !Self.baseName($0).contains("graphic") && !Self.baseName($0).contains("sound") } ?? data.first
    }

    /// The source file a new resource of `type` lands in (the explicit `targetFile`, else by type:
    /// HD `NSgx`/`NSbl` to the first graphics pack, sprites/pictures to a "Graphics" file, sounds
    /// to a "Sounds" file, everything else to the primary file).
    public func defaultSource(for type: FourCharCode) -> String? {
        if let t = targetFile, sourceFiles.contains(t) { return t }
        let data = sourceFiles.filter { !Self.isPackKey($0) }
        if type == GraphicsEnhancementType.descriptor || type == GraphicsEnhancementType.blob {
            return sourceFiles.first(where: Self.isPackKey) ?? primaryFile
        }
        let graphics: Set<FourCharCode> = [NovaType.rleD, NovaType.rle8, NovaType.pict, NovaType.cicn,
                                           NovaType.ppat, NovaType.ppatAlt]
        if graphics.contains(type), let g = data.first(where: { Self.baseName($0).contains("graphic") }) { return g }
        if type == NovaType.snd, let s = data.first(where: { Self.baseName($0).contains("sound") }) { return s }
        return primaryFile
    }

    /// The file a plug-in resource is stored in (nil when it isn't in the layer or sources aren't tracked).
    public func sourceFile(of key: ResourceKey) -> String? {
        guard layer.resource(key.type, key.id) != nil else { return nil }
        return sourceMap[key]
    }

    /// Move a plug-in resource to another source file. Undoable. False if `file` isn't a source
    /// file, the resource isn't in the layer, or it's already there.
    @discardableResult
    public func setSourceFile(_ file: String, for key: ResourceKey) -> Bool {
        guard sourceFiles.contains(file), layer.resource(key.type, key.id) != nil else { return false }
        let old = sourceMap[key]
        guard old != file else { return false }
        sourceMap[key] = file
        modifiedSources.insert(file)
        if let old { modifiedSources.insert(old) }
        if groupDepth > 0, var g = groupEntry {
            if g.srcBefore[key] == nil { g.srcBefore[key] = old ?? "" }
            g.srcAfter[key] = file
            groupEntry = g
        } else {
            var e = Entry(label: "Move \(key) to \((file as NSString).lastPathComponent)",
                          before: [:], after: [:], coalesce: nil)
            e.srcBefore = [key: old ?? ""]
            e.srcAfter = [key: file]
            pushUndo(e)
        }
        if groupDepth > 0 { redoStack.removeAll() }
        changed([key])
        return true
    }

    /// Keep `sourceMap` / `modifiedSources` in step with a change to `keys`.
    private func trackSources(_ keys: Set<ResourceKey>) {
        guard !sourceFiles.isEmpty else { return }
        for k in keys {
            if layer.resource(k.type, k.id) != nil, sourceMap[k] == nil, let d = defaultSource(for: k.type) {
                sourceMap[k] = d
            }
            if let s = sourceMap[k] { modifiedSources.insert(s) }
        }
    }

    /// Treat every source file as changed, so the next Save rewrites all of them (used after a
    /// recovery restore, where the on-disk originals may not match the recovered content).
    public func markAllSourcesModified() { modifiedSources = Set(sourceFiles) }

    /// Fold every source file into one (after "merge into a single file" saves).
    public func collapseSources(to name: String, format: PluginFormat) {
        sourceFiles = [name]
        fileFormats = [name: format]
        sourceMap = [:]
        for (type, rs) in layer.byType { for id in rs.keys { sourceMap[ResourceKey(type, id)] = name } }
        shadowed = [:]
        modifiedSources = [name]
        targetFile = nil
    }

    /// A plug-in resource that wasn't loaded into a single file: used to size the Save plan and
    /// by tests.
    var shadowedResourceCount: Int { shadowed.values.reduce(0) { $0 + $1.count } }

    // MARK: Multi-file save

    /// Snapshot what Save would write, as plain values that can be encoded and written off the
    /// main actor (`PluginSavePlan.write(to:)`). Call `didSave(_:)` once it succeeded.
    ///
    /// Only files that changed since the last save are included (`rewriteAll` forces every file,
    /// for "Save As" to a new folder), so untouched files stay byte-identical. `.nsx` packs are
    /// written back as `.nsx` folders unless `embedPacksInFile`, which folds their `NSgx`/`NSbl`
    /// into the primary data file instead.
    public func makeSavePlan(rewriteAll: Bool = false, embedPacksInFile: Bool = false,
                             embedMetadata: Bool = true) -> PluginSavePlan {
        let packs = sourceFiles.filter(Self.isPackKey)
        let dataKeys = sourceFiles.filter { !Self.isPackKey($0) }
        // A graphics-only plug-in has no data file; one is created only if something needs it.
        let synthName = Self.safeFileName(name) + ".rez"
        let dataTarget = primaryFile ?? synthName
        func isHD(_ t: FourCharCode) -> Bool { t == GraphicsEnhancementType.descriptor || t == GraphicsEnhancementType.blob }

        var perFile: [String: ResourceCollection] = [:]
        for (type, rs) in layer.byType {
            for (id, r) in rs {
                var target = sourceMap[ResourceKey(type, id)]
                if target == nil || !sourceFiles.contains(target!) { target = defaultSource(for: type) ?? dataTarget }
                var t = target ?? dataTarget
                if Self.isPackKey(t), embedPacksInFile || !isHD(type) { t = dataTarget }
                perFile[t, default: ResourceCollection()].add(r)
            }
        }
        for (file, rs) in shadowed where !Self.isPackKey(file) {
            for r in rs where perFile[file]?.resource(r.type, r.id) == nil { perFile[file, default: ResourceCollection()].add(r) }
        }
        // A descriptor's asset must travel with it.
        for (file, col) in perFile {
            var out = col
            for d in col.resources(of: GraphicsEnhancementType.descriptor) {
                guard let blob = (try? JSONDecoder().decode(GraphicsEnhancement.self, from: d.data))?.blob,
                      out.resource(GraphicsEnhancementType.blob, blob) == nil,
                      let b = layer.resource(GraphicsEnhancementType.blob, blob) else { continue }
                out.add(b)
            }
            perFile[file] = out
        }
        let usesSynth = primaryFile == nil && perFile[synthName] != nil
        if embedMetadata, primaryFile != nil || usesSynth,
           let json = try? JSONEncoder().encode(Metadata(name: name, author: author, version: version, notes: notes)) {
            perFile[dataTarget, default: ResourceCollection()].add(
                Resource(type: Self.metadataType, id: Self.metadataID, name: "Editor metadata", data: json))
        }

        var plan = PluginSavePlan(changeCount: changeCount)
        func wanted(_ key: String) -> Bool { rewriteAll || modifiedSources.contains(key) || !sourceFiles.contains(key) }
        var written: Set<String> = []
        var dataOrder = dataKeys
        if usesSynth { dataOrder.append(synthName) }
        for key in dataOrder {
            let primaryForcedByPacks = embedPacksInFile && key == dataTarget && !packs.isEmpty
            guard wanted(key) || primaryForcedByPacks else { continue }
            plan.dataFiles.append(.init(relativePath: key, format: fileFormats[key] ?? .rez,
                                        collection: perFile[key] ?? ResourceCollection()))
            written.insert(key)
        }
        if !embedPacksInFile {
            for key in packs where wanted(key) {
                let rel = String(key.dropFirst(Self.packPrefix.count))
                let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                plan.packs.append(.init(relativePath: rel, name: name, collection: perFile[key] ?? ResourceCollection()))
                written.insert(key)
            }
        }
        plan.writtenKeys = written
        return plan
    }

    /// Mark a `makeSavePlan` result as written: the document is clean again unless it changed since.
    public func didSave(_ plan: PluginSavePlan) {
        if changeCount == plan.changeCount { modifiedSources.subtract(plan.writtenKeys) }
        savedChangeCount = plan.changeCount
    }

    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled Plug-in" : s
    }

    // MARK: Opening several files

    /// Open a plug-in made of several files (and/or `.nsx` packs) as one layer over `base`, with
    /// per-resource source tracking. `files` are in load order, packs last. Pack blobs are
    /// renumbered into the layer's `NSbl` id space (and back to `asset_N` files on save).
    public static func open(files: [LoadedPluginFile], defaultName: String,
                            base: ResourceCollection = ResourceCollection()) -> PluginDocument {
        // Metadata: the primary file's wins, else the first one found.
        var metas: [(key: String, meta: Metadata)] = []
        var reservedBlobs = Set<Int>()
        var cleaned: [LoadedPluginFile] = []
        for var f in files {
            if !f.isPack {
                if let m = f.collection.resource(metadataType, metadataID),
                   let decoded = try? JSONDecoder().decode(Metadata.self, from: m.data) {
                    metas.append((f.key, decoded))
                }
                f.collection.remove(metadataType, metadataID)
                reservedBlobs.formUnion(f.collection.resources(of: GraphicsEnhancementType.blob).map(\.id))
            }
            cleaned.append(f)
        }
        let primary: String? = {
            let data = cleaned.filter { !$0.isPack }.map(\.key)
            func b(_ k: String) -> String { (k as NSString).lastPathComponent.lowercased() }
            return data.first { !b($0).contains("graphic") && !b($0).contains("sound") } ?? data.first
        }()
        let meta = metas.first(where: { $0.key == primary })?.meta ?? metas.first?.meta
            ?? Metadata(name: defaultName, author: "", version: "1.0", notes: "")

        var layer = ResourceCollection()
        var map: [ResourceKey: String] = [:]
        var shadow: [String: [Resource]] = [:]
        for f in cleaned {
            let col = f.isPack ? renumberedBlobs(f.collection, reserving: &reservedBlobs) : f.collection
            for (type, rs) in col.byType {
                for (id, r) in rs {
                    let k = ResourceKey(type, id)
                    if let prev = layer.resource(type, id), let ps = map[k] { shadow[ps, default: []].append(prev) }
                    layer.add(r)
                    map[k] = f.key
                }
            }
        }
        let doc = PluginDocument(name: meta.name, author: meta.author, version: meta.version,
                                 notes: meta.notes, base: base, layer: layer)
        doc.sourceFiles = cleaned.map(\.key)
        for f in cleaned where !f.isPack { doc.fileFormats[f.key] = f.format }
        doc.sourceMap = map
        doc.shadowed = shadow
        doc.modifiedSources = []
        doc.savedChangeCount = doc.changeCount
        return doc
    }

    /// `pack` with its `NSbl` blobs moved to ids not in `reserved` (which then grows), and the
    /// descriptors' `blob` fields rewritten to match.
    private static func renumberedBlobs(_ pack: ResourceCollection, reserving reserved: inout Set<Int>) -> ResourceCollection {
        var out = ResourceCollection()
        var idMap: [Int: Int] = [:]
        var next = GraphicsPackEmbedding.firstBlobID
        for r in pack.resources(of: GraphicsEnhancementType.blob) {
            while reserved.contains(next) { next += 1 }
            reserved.insert(next)
            idMap[r.id] = next
            out.add(Resource(type: r.type, id: next, name: r.name, attributes: r.attributes, data: r.data))
        }
        for (type, rs) in pack.byType where type != GraphicsEnhancementType.blob {
            for (_, r) in rs {
                guard type == GraphicsEnhancementType.descriptor,
                      var g = try? JSONDecoder().decode(GraphicsEnhancement.self, from: r.data),
                      let old = g.blob, let new = idMap[old], new != old else { out.add(r); continue }
                g.blob = new
                if let json = try? JSONEncoder().encode(g) {
                    out.add(Resource(type: r.type, id: r.id, name: r.name, attributes: r.attributes, data: json))
                } else { out.add(r) }
            }
        }
        return out
    }

    // MARK: Save / open

    /// Metadata travels inside the file as a resource the original game never
    /// asks for, like the HD `NSgx`/`NSbl` types.
    public static let metadataType = FourCharCode("NSmd")!
    static let metadataID = 128

    private struct Metadata: Codable { var name: String; var author: String; var version: String; var notes: String }

    /// A plain-value snapshot of what a single-file export would write, so the (slow) encoding and
    /// the file write can run off the main actor. Make it with `makeExportJob`.
    public struct ExportJob: Sendable {
        let layer: ResourceCollection
        /// Non-nil for a full export: the base the layer is overlaid on.
        let base: ResourceCollection?
        let metadata: Data?
        let excludeHD: Bool
        public let format: PluginFormat
        /// `changeCount` when the snapshot was taken (pass to `markSaved(atChangeCount:)`).
        public let changeCount: Int

        /// Encode the plug-in file.
        public func encode() throws -> Data {
            var out: ResourceCollection
            if let base {
                out = base
                out.overlay(layer)
            } else if excludeHD {
                out = ResourceCollection()
                for (t, rs) in layer.byType where t != GraphicsEnhancementType.descriptor && t != GraphicsEnhancementType.blob {
                    for r in rs.values { out.add(r) }
                }
            } else {
                out = layer
            }
            if let metadata {
                out.add(Resource(type: PluginDocument.metadataType, id: PluginDocument.metadataID,
                                 name: "Editor metadata", data: metadata))
            }
            switch format {
            case .rez: return RezWriter.write(out)
            case .classic: return try ClassicForkWriter.write(out)
            }
        }
    }

    /// Snapshot for an off-main export (cheap: value-type copies). `includeBase` redistributes base
    /// game data, so only pass it after the caller's explicit, warned confirmation.
    public func makeExportJob(format: PluginFormat, includeBase: Bool = false, embedMetadata: Bool = true,
                              excludeHD: Bool = false) -> ExportJob {
        var json: Data?
        if embedMetadata {
            json = try? JSONEncoder().encode(Metadata(name: name, author: author, version: version, notes: notes))
        }
        return ExportJob(layer: layer, base: includeBase ? base : nil, metadata: json, excludeHD: excludeHD,
                         format: format, changeCount: changeCount)
    }

    /// The bytes of the plug-in file. By default only the plug-in's own
    /// resources are written. `includeBase: true` writes the whole effective
    /// set, base game included — this **redistributes base game data**, so
    /// callers must only offer it behind an explicit, warned choice.
    public func exportData(format: PluginFormat, includeBase: Bool = false, embedMetadata: Bool = true) throws -> Data {
        try makeExportJob(format: format, includeBase: includeBase, embedMetadata: embedMetadata).encode()
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

    /// Mark the document clean as of `count` (an `ExportJob.changeCount`) after an off-main save
    /// succeeded; edits made while it was writing keep the document dirty.
    public func markSaved(atChangeCount count: Int) { savedChangeCount = count }

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
