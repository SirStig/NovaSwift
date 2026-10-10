import Foundation
import NovaSwiftKit

/// The galaxy tables the original mission rules read — stellars with their
/// systems and flags, system links, and the three government relations —
/// decoded once per data set (`NovaGame.memo`), since the app builds a fresh
/// `StoryEngine` for nearly every story event.
///
/// Government ids here are resource ids (128…); anything below 128 is
/// independent (-1).
struct MissionGeography {
    struct Stellar {
        let id: Int
        let system: Int?
        let govt: Int
        let flags: UInt32
        let flags2: UInt32
        let x: Int, y: Int
        let name: String
    }

    struct System {
        let id: Int
        let x: Int, y: Int
        let links: [Int]
        let spobs: [Int]
        let govt: Int
        let visibility: String
    }

    let stellars: [Int: Stellar]
    /// Stellar ids in resource order — the original's 0x800-slot table order.
    let stellarIDs: [Int]
    let systems: [Int: System]
    let govts: [Int: GovtRes]
    /// System id → the lowest-id system at the same map position. Story
    /// variants of a system are stacked on one spot ("twins"); the original
    /// treats a twin group as one place for adjacency and same-system tests.
    let twinRoot: [Int: Int]
    /// Twin-group root → every system in the group.
    let twinGroups: [Int: [Int]]

    static func of(_ game: NovaGame) -> MissionGeography {
        game.memo("NovaSwiftStory.MissionGeography") { MissionGeography(game: game) }
    }

    private init(game: NovaGame) {
        var systems: [Int: System] = [:]
        var spobSystem: [Int: Int] = [:]
        for s in game.systems() {
            systems[s.id] = System(id: s.id, x: s.x, y: s.y, links: s.links.filter { $0 >= 128 },
                                   spobs: s.spobs.filter { $0 >= 128 },
                                   govt: s.government >= 128 ? s.government : -1,
                                   visibility: s.visibility)
            for sp in s.spobs where sp >= 128 && spobSystem[sp] == nil { spobSystem[sp] = s.id }
        }
        var stellars: [Int: Stellar] = [:]
        for sp in game.spobs() {
            stellars[sp.id] = Stellar(id: sp.id, system: spobSystem[sp.id],
                                      govt: sp.government >= 128 ? sp.government : -1,
                                      flags: sp.flags, flags2: sp.flags2,
                                      x: sp.x, y: sp.y, name: sp.name)
        }
        var root: [Int: Int] = [:]
        var groups: [Int: [Int]] = [:]
        var byPosition: [String: Int] = [:]
        for id in systems.keys.sorted() {
            let s = systems[id]!
            let key = "\(s.x),\(s.y)"
            let r = byPosition[key] ?? id
            byPosition[key] = r
            root[id] = r
            groups[r, default: []].append(id)
        }
        var govts: [Int: GovtRes] = [:]
        for g in game.govts() { govts[g.id] = g }
        self.stellars = stellars
        self.stellarIDs = stellars.keys.sorted()
        self.systems = systems
        self.govts = govts
        self.twinRoot = root
        self.twinGroups = groups
    }

    func root(_ system: Int?) -> Int? { system.flatMap { twinRoot[$0] ?? $0 } }

    // MARK: Government relations (0x0046bc90, 0x0046bdf0, 0x0046bff0)

    /// Either side's class appears in the other's ally list; a government is
    /// allied with itself. Derelict (Flags 0x0800) governments ally with no one.
    func allied(_ a: Int, _ b: Int) -> Bool { GovtRelations.allied(a, b, govts: govts) }

    /// An enemy-class relation either way, or — failing that — one side
    /// xenophobic and the two not allied. A derelict is hostile to no one.
    func hostileOrXenophobic(_ a: Int, _ b: Int) -> Bool { GovtRelations.hostileOrXenophobic(a, b, govts: govts) }

    /// The original compares the raw class slots **positionally** (class 1
    /// with class 1, …), not as sets, and an empty slot never matches; equal
    /// ids always share. (The compacted `classes` list would shift a class
    /// that follows an empty slot into the wrong position.)
    func shareClass(_ a: Int, _ b: Int) -> Bool { GovtRelations.shareClass(a, b, govts: govts) }

    // MARK: Stellars

    /// Twins: the same id, or two stellars at the same spot with the same
    /// name (0x0046efd0).
    func equivalent(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return false }
        if a == b { return true }
        guard let sa = stellars[a], let sb = stellars[b] else { return false }
        return sa.x == sb.x && sa.y == sb.y && sa.name == sb.name
    }

    /// A landable, non-gate stellar (0x0046e440): Flags 0x0001 set, not a
    /// hypergate or wormhole, and — for a destroyable body — in the state its
    /// 0x0080 bit asks for.
    func usableForTravel(_ s: Stellar, destroyed: Bool) -> Bool {
        guard s.flags & 0x0001 != 0, s.flags2 & 0x3000 == 0 else { return false }
        return destroyed == (s.flags & 0x0080 != 0)
    }

    /// 0x00468b50: a random destination must not be in the reference stellar's
    /// system or twin group, nor one jump from it, and must be present in
    /// every twin of its own system.
    func validRandomDestination(_ candidate: Int, reference: Int?) -> Bool {
        guard let c = stellars[candidate], let cSys = c.system else { return false }
        func persistent() -> Bool {
            let group = twinGroups[root(cSys) ?? cSys] ?? [cSys]
            return group.allSatisfy { systems[$0]?.spobs.contains(candidate) ?? false }
        }
        guard let reference, let r = stellars[reference], let rSys = r.system else { return persistent() }
        if cSys == rSys { return false }
        let cRoot = root(cSys), rRoot = root(rSys)
        if cRoot == rRoot { return false }
        if systems[cSys]?.links.contains(where: { root($0) == rRoot }) == true { return false }
        if systems[rSys]?.links.contains(where: { root($0) == cRoot }) == true { return false }
        return persistent()
    }
}
