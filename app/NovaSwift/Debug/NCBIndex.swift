import Foundation
import NovaSwiftKit
import NovaSwiftStory

/// One place a single control bit is referenced in the loaded game data.
///
/// A raw bit number means nothing on its own — "bit 1042" is only meaningful
/// once you know that finishing *Ambush at Kania* sets it and that three later
/// missions gate on it. Every such relationship is already declared in the
/// data (mïsn `OnSuccess`, `AvailBits`, crön `EnableOn`, …); this type is one
/// edge of that graph, inverted so it can be looked up bit-first.
struct NCBReference: Sendable, Identifiable {
    enum Role: Sendable, Equatable {
        case set, clear, toggle
        /// Read by an availability/visibility expression. `negated` means the
        /// expression wants the bit **clear** (it appeared under a `!`).
        case test(negated: Bool)
    }

    let id = UUID()
    let role: Role
    /// The resource type's Nova four-char label, e.g. `mïsn`.
    let kind: String
    let resourceID: Int
    let resourceName: String
    /// Which field the expression came from, e.g. `OnSuccess`.
    let field: String

    var isTest: Bool {
        if case .test = role { return true }
        return false
    }
}

/// A bit-first cross-reference over every NCB expression in the data set.
///
/// Built once per data set and cached; see `DevBitBrowser`. Construction walks
/// every mission, cron, ship, outfit, stellar, system, person, fleet, öops and
/// junk resource, so it runs off the main thread.
struct NCBIndex: Sendable {
    /// bit number → every reference to it.
    let references: [Int: [NCBReference]]
    /// Every bit referenced anywhere, ascending.
    let bits: [Int]
    /// bit → lowercased names of the resources referencing it, so the browser
    /// can search by storyline name instead of only by number.
    let searchText: [Int: String]

    static let empty = NCBIndex(references: [:], bits: [], searchText: [:])

    func references(for bit: Int) -> [NCBReference] { references[bit] ?? [] }

    /// Builds the index. Pure and self-contained so it can run on any thread.
    static func build(from game: NovaGame) -> NCBIndex {
        var refs: [Int: [NCBReference]] = [:]
        var names: [Int: Set<String>] = [:]

        func record(_ bit: Int, _ role: NCBReference.Role,
                    _ kind: String, _ id: Int, _ name: String, _ field: String) {
            refs[bit, default: []].append(
                NCBReference(role: role, kind: kind, resourceID: id,
                             resourceName: name, field: field))
            names[bit, default: []].insert(name.lowercased())
        }

        func addTest(_ expr: String, _ kind: String, _ id: Int, _ name: String, _ field: String) {
            guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            for (bit, negated) in NCBTest(expr).referencedBits {
                record(bit, .test(negated: negated), kind, id, name, field)
            }
        }

        func addSet(_ expr: String, _ kind: String, _ id: Int, _ name: String, _ field: String) {
            guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            for (bit, effect) in NCBSet.referencedBits(expr) {
                let role: NCBReference.Role
                switch effect {
                case .set: role = .set
                case .clear: role = .clear
                case .toggle: role = .toggle
                }
                record(bit, role, kind, id, name, field)
            }
        }

        for m in game.missions() {
            let n = m.displayName, i = m.id
            addTest(m.availBits, "mïsn", i, n, "AvailBits")
            addSet(m.onAccept, "mïsn", i, n, "OnAccept")
            addSet(m.onRefuse, "mïsn", i, n, "OnRefuse")
            addSet(m.onSuccess, "mïsn", i, n, "OnSuccess")
            addSet(m.onFailure, "mïsn", i, n, "OnFailure")
            addSet(m.onAbort, "mïsn", i, n, "OnAbort")
            addSet(m.onShipDone, "mïsn", i, n, "OnShipDone")
        }
        for c in game.crons() {
            let n = c.name, i = c.id
            addTest(c.enableOn, "crön", i, n, "EnableOn")
            addSet(c.onStart, "crön", i, n, "OnStart")
            addSet(c.onEnd, "crön", i, n, "OnEnd")
        }
        for s in game.spobs() {
            let n = s.displayName, i = s.id
            addSet(s.onDominate, "spöb", i, n, "OnDominate")
            addSet(s.onRelease, "spöb", i, n, "OnRelease")
            addSet(s.onDestroy, "spöb", i, n, "OnDestroy")
            addSet(s.onRegen, "spöb", i, n, "OnRegen")
        }
        for s in game.ships() {
            let n = s.displayName, i = s.id
            addTest(s.availBits, "shïp", i, n, "AvailBits")
            addTest(s.appearOn, "shïp", i, n, "AppearOn")
            addSet(s.onPurchase, "shïp", i, n, "OnPurchase")
            addSet(s.onCapture, "shïp", i, n, "OnCapture")
            addSet(s.onRetire, "shïp", i, n, "OnRetire")
        }
        for o in game.outfits() {
            let n = o.displayName, i = o.id
            addTest(o.availBits, "oütf", i, n, "AvailBits")
            addSet(o.onPurchase, "oütf", i, n, "OnPurchase")
            addSet(o.onSell, "oütf", i, n, "OnSell")
        }
        for p in game.perses() {
            addTest(p.activeOn, "përs", p.id, p.displayName, "ActiveOn")
        }
        for s in game.systems() {
            addTest(s.visibility, "sÿst", s.id, s.displayName, "Visibility")
        }
        for f in game.fleets() {
            addTest(f.appearOn, "flët", f.id, f.name, "AppearOn")
        }
        for o in game.oopses() {
            addTest(o.activateOn, "öops", o.id, o.name, "ActivateOn")
        }
        for j in game.junks() {
            addTest(j.buyOn, "jünk", j.id, j.name, "BuyOn")
            addTest(j.sellOn, "jünk", j.id, j.name, "SellOn")
        }

        return NCBIndex(
            references: refs,
            bits: refs.keys.sorted(),
            searchText: names.mapValues { $0.joined(separator: " ") })
    }

}
