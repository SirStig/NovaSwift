import Foundation

// MARK: The player's legal record — one reputation per system (EC-02)
//
// The original keeps no per-government record. The player's legal standing is
// one signed 16-bit reputation per *system* (clamped to ±32000), and every
// consumer — AI hostility, landing access, prices, mission gates, the status
// labels — reads the value for the system it cares about, usually the one the
// player is in. A crime floods outward from the system it happened in; mission
// rewards walk every system in the galaxy.
//
// Addresses below are in the `4fd5d9b4…` EVNova.exe build; see
// docs/reverse-engineering/FIDELITY_PLAN.md EC-02 for the derivation and the
// emulator run that pinned the relation ladder.

/// The four crime events that feed the reputation flood, in the order of the
/// government penalty table they index (`gövt` SmugPenalty, DisabPenalty,
/// BoardPenalty, KillPenalty). `ShootPenalty`, the fifth slot, is never raised.
public enum CrimeKind: Int, Sendable, CaseIterable {
    case smuggling = 0
    case disable = 1
    case board = 2
    case kill = 3

    /// This crime's penalty in `govt`'s table.
    public func penalty(of govt: GovtRes) -> Int {
        switch self {
        case .smuggling: return govt.smugglePenalty
        case .disable:   return govt.disablePenalty
        case .board:     return govt.boardPenalty
        case .kill:      return govt.killPenalty
        }
    }
}

/// The original's three government-relation helpers, which every reputation
/// rule (and the AI's player-hostility ladder) goes through. They differ from a
/// plain class-set intersection in small ways that matter: a derelict
/// government (`Flags` 0x0800) is allied with and hostile to nobody, an
/// independent party (−1) is hostile only to xenophobes, and "share a class"
/// compares class slots pairwise.
public enum GovtRelations {
    /// `Government_AreGovtsAllied` 0x0046bc90: the same government, or either
    /// one lists one of the other's classes as an ally. Never for a derelict
    /// government or an independent party.
    public static func allied(_ a: Int, _ b: Int, govts: [Int: GovtRes]) -> Bool {
        if a == b { return true }
        guard let ga = govts[a], let gb = govts[b] else { return false }
        if ga.startsDisabled || gb.startsDisabled { return false }
        return !Set(ga.classes).isDisjoint(with: gb.allies) || !Set(gb.classes).isDisjoint(with: ga.allies)
    }

    /// `Government_AreGovtsHostileOrXenophobic` 0x0046bdf0: either one lists
    /// one of the other's classes as an enemy, or — when they aren't allied —
    /// either one is xenophobic. A derelict government is hostile to nobody,
    /// and an independent party (−1) only meets the xenophobe arm.
    public static func hostileOrXenophobic(_ a: Int, _ b: Int, govts: [Int: GovtRes]) -> Bool {
        if a == b { return false }
        let ga = govts[a], gb = govts[b]
        if let ga, let gb {
            if ga.startsDisabled || gb.startsDisabled { return false }
            if !Set(ga.classes).isDisjoint(with: gb.enemies) || !Set(gb.classes).isDisjoint(with: ga.enemies) {
                return true
            }
        }
        if allied(a, b, govts: govts) { return false }
        return (ga?.xenophobic ?? false) || (gb?.xenophobic ?? false)
    }

    /// `Government_DoGovtsShareClass` 0x0046bff0: the same government, or the
    /// two hold the same class **in the same slot** (slot i against slot i
    /// only — the original never cross-compares slots).
    public static func shareClass(_ a: Int, _ b: Int, govts: [Int: GovtRes]) -> Bool {
        if a == b { return true }
        guard let ga = govts[a], let gb = govts[b] else { return false }
        return zip(ga.classSlots, gb.classSlots).contains { $0 >= 0 && $0 == $1 }
    }
}

/// The galaxy as the reputation rules see it: each system's government, its
/// declared hyperlinks in slot order, and its visibility-twin group.
///
/// Twins are systems sharing one map position (the base data swaps in story
/// variants of a system that way). The original's loader chains every such
/// group, lowest id first; the flood changes every member of a group at once
/// and follows links to the group's lowest id.
public struct ReputationMap: Sendable {
    public struct System: Sendable {
        public let id: Int
        /// Owning government, −1 independent.
        public let govt: Int
        public let x: Int
        public let y: Int
        /// Declared hyperlinks, in slot order.
        public let links: [Int]

        public init(id: Int, govt: Int, x: Int, y: Int, links: [Int]) {
            self.id = id; self.govt = govt; self.x = x; self.y = y; self.links = links
        }
    }

    public let systems: [Int: System]
    /// system id → its twin group (lowest id first; a lone system is a group of one).
    public let groups: [Int: [Int]]
    /// Every system id, ascending.
    public let ids: [Int]

    public init(systems list: [System]) {
        var byID: [Int: System] = [:]
        for s in list where byID[s.id] == nil { byID[s.id] = s }
        systems = byID
        ids = byID.keys.sorted()
        var byPosition: [[Int]: [Int]] = [:]
        for id in ids {
            let s = byID[id]!
            byPosition[[s.x, s.y], default: []].append(id)
        }
        var g: [Int: [Int]] = [:]
        for members in byPosition.values {
            for id in members { g[id] = members }
        }
        groups = g
    }

    /// The group's root (lowest id) — where `System_ResolveSystemDiscoverySlot`
    /// 0x0046b9b0 sends a link.
    public func root(of id: Int) -> Int { groups[id]?.first ?? id }

    public func govt(of id: Int) -> Int { systems[id]?.govt ?? -1 }
}

/// The reputation rules themselves. Reputations live in a sparse
/// `[system id: value]` dictionary; a missing system reads 0.
public enum SystemReputation {
    /// The clamp `Government_PropagateFactionCombatInfluenceToNearbySystems`
    /// applies to every write.
    public static let limit = 32000
    /// Per-level weight of the flood.
    public static let spreadFactor: Float = 0.65

    public static func clamp(_ value: Int) -> Int { min(limit, max(-limit, value)) }

    /// `rep` as the original's signed 16-bit field holds it after an unclamped
    /// write: the mission-reward paths add without clamping and wrap.
    static func int16(_ value: Int) -> Int { Int(Int16(truncatingIfNeeded: value)) }

    // MARK: Crimes

    /// `Government_ProcessFactionCombatEvent` 0x00466fc0 →
    /// `Government_PropagateFactionCombatInfluenceToNearbySystems` 0x00467140
    /// (pinned by running both under the oracle). A crime of `kind` against a
    /// ship (or stellar) of government `victim` — −1 for an independent one —
    /// committed in system `origin`.
    ///
    /// Each system's change `d` is laddered by its own government `S`:
    /// - `S` is the victim's government or allied with it → the victim's full penalty;
    /// - `S` is any other government (enemy, neutral, xenophobe, or allied-and-
    ///   hostile) → *minus* half of `S`'s **own** penalty for this crime (a bonus);
    /// - independent system → a quarter of the victim's penalty, or minus half
    ///   of it when the victim is xenophobic;
    /// - independent victim → half the *first* government's penalty in an
    ///   independent system, minus half of `S`'s own in a xenophobe's system,
    ///   plus half of it in a nosy (`Flags` 0x0002) government's, else nothing.
    ///
    /// `rep = trunc(rep − d·w)` toward zero, clamped to ±32000, for every twin
    /// in the system's group whose |d·w| ≥ 1. `w` starts at 1 and falls ×0.65
    /// per level of a depth-first walk over each system's 16 declared links,
    /// visiting every system once. A system with no change stops the walk
    /// there, so there is no fixed radius. A derelict victim government
    /// (`Flags` 0x0800) changes nothing, and neither does a crime against a
    /// mission ship (`missionShip`), whose event takes the original's
    /// mission-slot arm.
    public static func applyCrime(_ kind: CrimeKind, victim: Int, inSystem origin: Int,
                                  to reputation: inout [Int: Int],
                                  govts: [Int: GovtRes], map: ReputationMap,
                                  missionShip: Bool = false) {
        if let v = govts[victim], v.startsDisabled { return }
        guard !missionShip else { return }
        var visited = Set<Int>()
        flood(kind, victim: victim, system: origin, weight: 1.0,
              reputation: &reputation, visited: &visited, govts: govts, map: map)
    }

    /// The change `d` (before weighting) the crime makes in a system of `owner`.
    public static func crimeDelta(_ kind: CrimeKind, victim: Int, systemGovt owner: Int,
                                  govts: [Int: GovtRes]) -> Float {
        let victimGovt = govts[victim]
        let victimXeno = victimGovt?.xenophobic ?? false
        func pen(_ g: GovtRes?) -> Float { Float(g.map { kind.penalty(of: $0) } ?? 0) }
        if owner == -1 || govts[owner] == nil {
            if victim == -1 || victimGovt == nil {
                // Indexes government record 0 — the first gövt.
                return pen(govts[firstGovernmentID]) * 0.5
            }
            return victimXeno ? -pen(victimGovt) * 0.5 : pen(victimGovt) * 0.25
        }
        let s = govts[owner]!
        if owner == victim { return pen(victimGovt) }
        if victim == -1 || victimGovt == nil {
            if s.xenophobic { return -pen(s) * 0.5 }
            if s.nosy { return pen(s) * 0.5 }
            return 0
        }
        guard GovtRelations.allied(victim, owner, govts: govts),
              !GovtRelations.hostileOrXenophobic(victim, owner, govts: govts) else {
            return -pen(s) * 0.5
        }
        return pen(victimGovt)
    }

    /// The resource id of the original's government record 0.
    static let firstGovernmentID = 128

    private static func flood(_ kind: CrimeKind, victim: Int, system: Int, weight: Double,
                              reputation: inout [Int: Int], visited: inout Set<Int>,
                              govts: [Int: GovtRes], map: ReputationMap) {
        guard map.systems[system] != nil, !visited.contains(system) else { return }
        visited.insert(system)
        var changed = false
        for member in map.groups[system] ?? [system] {
            visited.insert(member)
            let d = crimeDelta(kind, victim: victim, systemGovt: map.govt(of: member), govts: govts)
                * Float(weight)
            guard abs(d) >= 1 else { continue }
            changed = true
            let current = Float(reputation[member] ?? 0)
            store(clamp(Int((current - d).rounded(.towardZero))), at: member, in: &reputation)
        }
        guard changed, let links = map.systems[system]?.links else { return }
        let next = weight * Double(spreadFactor)
        for link in links {
            flood(kind, victim: victim, system: map.root(of: link), weight: next,
                  reputation: &reputation, visited: &visited, govts: govts, map: map)
        }
    }

    static func store(_ value: Int, at system: Int, in reputation: inout [Int: Int]) {
        reputation[system] = value == 0 ? nil : value
    }

    // MARK: Missions (MS-10 owns which paths call these)

    /// `Mission_ResolveMissionSuccess` 0x00440410: CompReward walks every
    /// system in the galaxy with no decay and no clamp — `+delta` where `govt`
    /// owns the system, `−delta/2` in systems of governments hostile to it (or
    /// xenophobic), `+delta/2` in allied ones, nothing in independent or
    /// unrelated systems. The halves truncate toward zero and the sum wraps
    /// like the original's 16-bit field.
    public static func applyMissionSuccess(govt: Int, delta: Int, to reputation: inout [Int: Int],
                                           govts: [Int: GovtRes], map: ReputationMap) {
        guard delta != 0 else { return }
        for id in map.ids {
            let owner = map.govt(of: id)
            let current = reputation[id] ?? 0
            if owner == govt {
                store(int16(current + delta), at: id, in: &reputation)
            } else if owner != -1 {
                let half = Float(delta) * 0.5
                if GovtRelations.hostileOrXenophobic(owner, govt, govts: govts) {
                    store(int16(Int((Float(current) - half).rounded(.towardZero))), at: id, in: &reputation)
                } else if GovtRelations.allied(owner, govt, govts: govts) {
                    store(int16(Int((Float(current) + half).rounded(.towardZero))), at: id, in: &reputation)
                }
            }
        }
    }

    /// `Mission_ResolveMissionFailure` 0x00440930: `−trunc(delta/2)` in every
    /// system `govt` owns, nothing elsewhere.
    public static func applyMissionFailure(govt: Int, delta: Int, to reputation: inout [Int: Int],
                                           map: ReputationMap) {
        add(-(delta / 2), toSystemsOf: govt, in: &reputation, map: map)
    }

    /// The mission computer's abort (0x00446150, missions with `Flags` 0x0040):
    /// `−5 × delta` in every system `govt` owns, nothing elsewhere.
    public static func applyMissionAbort(govt: Int, delta: Int, to reputation: inout [Int: Int],
                                         map: ReputationMap) {
        add(-5 * delta, toSystemsOf: govt, in: &reputation, map: map)
    }

    private static func add(_ delta: Int, toSystemsOf govt: Int, in reputation: inout [Int: Int],
                            map: ReputationMap) {
        guard delta != 0, govt != -1 else { return }
        for id in map.ids where map.govt(of: id) == govt {
            store(int16((reputation[id] ?? 0) + delta), at: id, in: &reputation)
        }
    }

    // MARK: Clean records

    /// Which systems a "clean legal record" wipes.
    public enum CleanScope: Sendable {
        /// Every system (`oütf` ModType 21 with ModVal −1).
        case everywhere
        /// Systems `govt` owns (ModType 21; mission PayVal −10000 − n).
        case government(Int)
        /// Systems whose owner is allied with `govt` (PayVal −20000 − n).
        case alliesOf(Int)
        /// Systems whose owner shares a class slot with `govt` (PayVal −30000 − n).
        case classmatesOf(Int)
    }

    /// `Outfit_GrantOutfitToPlayer` 0x00427770 (ModType 21) and
    /// `Government_ApplyReputationCreditDelta` 0x00440750 (PayVal codes): a
    /// clean record only lifts a **negative** reputation back to 0; a good one
    /// is kept.
    public static func clean(_ scope: CleanScope, in reputation: inout [Int: Int],
                             govts: [Int: GovtRes], map: ReputationMap) {
        for (id, value) in reputation where value < 0 {
            let owner = map.govt(of: id)
            let hit: Bool
            switch scope {
            case .everywhere:           hit = true
            case .government(let g):    hit = owner == g
            case .alliesOf(let g):      hit = GovtRelations.allied(owner, g, govts: govts)
            case .classmatesOf(let g):  hit = GovtRelations.shareClass(owner, g, govts: govts)
            }
            if hit { reputation[id] = nil }
        }
    }

    // MARK: New pilots and old saves

    /// A new pilot's reputations. `Game_ResetReputationAndAvailability`
    /// 0x004b4220 raises each system to its owner's `gövt` InitialRec (an
    /// independent system to 0), then `PilotData_InitializePlayerState`
    /// 0x004cd4b0 applies each `chär` government status by *overwriting*:
    /// `status` in every system whose owner is allied with that government,
    /// `−status` where the owner is hostile to it or xenophobic.
    public static func initial(statuses: [(govt: Int, status: Int)], govts: [Int: GovtRes],
                               map: ReputationMap) -> [Int: Int] {
        var rep: [Int: Int] = [:]
        for id in map.ids {
            let owner = map.govt(of: id)
            store(max(0, govts[owner]?.initialRecord ?? 0), at: id, in: &rep)
        }
        for entry in statuses where entry.govt >= 128 {
            for id in map.ids {
                let owner = map.govt(of: id)
                if GovtRelations.allied(owner, entry.govt, govts: govts) {
                    store(int16(entry.status), at: id, in: &rep)
                } else if GovtRelations.hostileOrXenophobic(owner, entry.govt, govts: govts) {
                    store(int16(-entry.status), at: id, in: &rep)
                }
            }
        }
        return rep
    }

    /// Seeds per-system reputations for a pilot saved under the old
    /// per-government model: each system takes the record its owning
    /// government held there (`standing(govt, system)`), an independent system
    /// 0, clamped to ±32000. This is the "migration default" user decision in
    /// FIDELITY_PLAN.md (Q-EC-10).
    public static func migrated(map: ReputationMap,
                                standing: (_ govt: Int, _ system: Int) -> Int) -> [Int: Int] {
        var rep: [Int: Int] = [:]
        for id in map.ids {
            let owner = map.govt(of: id)
            guard owner != -1 else { continue }
            store(clamp(standing(owner, id)), at: id, in: &rep)
        }
        return rep
    }
}
