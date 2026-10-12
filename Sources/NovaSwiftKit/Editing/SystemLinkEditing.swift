import Foundation

/// Bidirectional hyperlink / nav-slot editing on `sÿst` records, shared by the
/// galaxy-map and star-system editors. All mutations are wrapped in one undo
/// group. Platform-neutral plain data code.
public enum SystemLinkEditing {

    public enum LinkResult: Equatable, Sendable {
        case linked
        case alreadyLinked
        /// The named system has no free hyperlink slot (16 max).
        case full(systemID: Int)
        case invalid
    }

    public static let maxLinks = 16
    public static let maxStellars = 16

    /// The (up to 16) slot values of an array field; missing → all -1.
    public static func slots(_ doc: PluginDocument, _ type: FourCharCode, _ id: Int, field: String) -> [Int] {
        guard let schema = ResourceSchemas.schema(for: type), let r = doc.resource(type, id),
              case let .array(vs)? = schema.read(field, from: schema.padded(r.data)) else { return [] }
        return vs.map { $0.intValue ?? -1 }
    }

    /// Valid (>= 128... any non-negative real id) entries of a slot array.
    public static func ids(_ slots: [Int]) -> [Int] { slots.filter { $0 >= 128 } }

    public static func links(of doc: PluginDocument, _ id: Int) -> [Int] {
        ids(slots(doc, NovaType.syst, id, field: "links"))
    }

    public static func stellars(of doc: PluginDocument, _ id: Int) -> [Int] {
        ids(slots(doc, NovaType.syst, id, field: "navDefaults"))
    }

    private static func isFree(_ v: Int) -> Bool { v < 128 }

    private static func put(_ doc: PluginDocument, _ type: FourCharCode, _ id: Int, field: String, slots: [Int]) {
        doc.setValue(.array(slots.map { .int($0) }), field: field, of: type, id)
    }

    /// Link `a` ↔ `b` in free slots of both systems.
    @discardableResult
    public static func link(_ doc: PluginDocument, _ a: Int, _ b: Int) -> LinkResult {
        guard a != b, doc.resource(NovaType.syst, a) != nil, doc.resource(NovaType.syst, b) != nil else { return .invalid }
        var sa = slots(doc, NovaType.syst, a, field: "links")
        var sb = slots(doc, NovaType.syst, b, field: "links")
        let aHas = sa.contains(b), bHas = sb.contains(a)
        if aHas && bHas { return .alreadyLinked }
        if !aHas, !sa.contains(where: isFree) { return .full(systemID: a) }
        if !bHas, !sb.contains(where: isFree) { return .full(systemID: b) }
        doc.withGroup("Link systems \(a) and \(b)") {
            if !aHas, let i = sa.firstIndex(where: isFree) { sa[i] = b; put(doc, NovaType.syst, a, field: "links", slots: sa) }
            if !bHas, let i = sb.firstIndex(where: isFree) { sb[i] = a; put(doc, NovaType.syst, b, field: "links", slots: sb) }
        }
        return .linked
    }

    /// Remove the link between `a` and `b` in both directions.
    @discardableResult
    public static func unlink(_ doc: PluginDocument, _ a: Int, _ b: Int) -> Bool {
        var sa = slots(doc, NovaType.syst, a, field: "links")
        var sb = slots(doc, NovaType.syst, b, field: "links")
        guard sa.contains(b) || sb.contains(a) else { return false }
        doc.withGroup("Unlink systems \(a) and \(b)") {
            if sa.contains(b) { sa = sa.map { $0 == b ? -1 : $0 }; put(doc, NovaType.syst, a, field: "links", slots: sa) }
            if sb.contains(a) { sb = sb.map { $0 == a ? -1 : $0 }; put(doc, NovaType.syst, b, field: "links", slots: sb) }
        }
        return true
    }

    /// Remove every link pointing at `id` from other systems (used before deleting a system).
    public static func unlinkAll(_ doc: PluginDocument, _ id: Int) {
        for other in links(of: doc, id) { unlink(doc, id, other) }
        // Also catch one-way links from systems that point at `id`.
        for r in doc.effective.resources(of: NovaType.syst) where r.id != id {
            if slots(doc, NovaType.syst, r.id, field: "links").contains(id) { unlink(doc, r.id, id) }
        }
    }

    /// Put `spobID` in the first free nav slot of the system. False when full or already present.
    @discardableResult
    public static func addStellar(_ doc: PluginDocument, system: Int, spob: Int) -> Bool {
        var s = slots(doc, NovaType.syst, system, field: "navDefaults")
        guard !s.contains(spob), let i = s.firstIndex(where: isFree) else { return false }
        s[i] = spob
        put(doc, NovaType.syst, system, field: "navDefaults", slots: s)
        return true
    }

    /// Clear the system's nav slot(s) holding `spobID`.
    @discardableResult
    public static func removeStellar(_ doc: PluginDocument, system: Int, spob: Int) -> Bool {
        var s = slots(doc, NovaType.syst, system, field: "navDefaults")
        guard s.contains(spob) else { return false }
        s = s.map { $0 == spob ? -1 : $0 }
        put(doc, NovaType.syst, system, field: "navDefaults", slots: s)
        return true
    }
}
