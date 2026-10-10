import Foundation
import NovaSwiftKit

// The pilot-side entry points to the per-system legal record (EC-02). The rules
// live in `SystemReputation` (NovaSwiftKit); these bind them to a `PlayerState`
// and the loaded game data.

extension NovaGame {
    /// Every government, keyed by resource id — the table the reputation rules
    /// read relations and penalties from.
    public func govtTable() -> [Int: GovtRes] {
        Dictionary(govts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension PlayerState {
    /// Seed `systemReputation` for a pilot saved under the old per-government
    /// model. Each system takes the standing its owning government held there
    /// (the universal record plus that system's combat component); independent
    /// systems start at 0. The old fields stay in the save, untouched. Returns
    /// whether anything changed. This is the "migration default" recorded as a
    /// user decision in FIDELITY_PLAN.md (Q-EC-10).
    @discardableResult
    public mutating func migrateLegalRecordIfNeeded(game: NovaGame) -> Bool {
        guard systemReputation == nil else { return false }
        let legacy = self
        systemReputation = SystemReputation.migrated(map: game.reputationMap()) { govt, system in
            legacy.legacyStanding(govt: govt, atSystem: system)
        }
        let seeded = systemReputation?.count ?? 0
        let oldRecords = legacy.legalRecord.count
        Log.pilot.notice("""
            migrateLegalRecord: seeded \(seeded, privacy: .public) system reputation(s) from \
            \(oldRecords, privacy: .public) per-government record(s); the old record is kept in the save
            """)
        return true
    }

    /// Fold a live session's per-system change (`Diplomacy.consumeReputationDelta`)
    /// into the record, clamped to ±32000.
    public mutating func applyReputationDelta(_ delta: [Int: Int]) {
        guard !delta.isEmpty else { return }
        var rep = systemReputation ?? [:]
        for (system, d) in delta {
            let v = SystemReputation.clamp((rep[system] ?? 0) + d)
            rep[system] = v == 0 ? nil : v
        }
        systemReputation = rep
    }

    /// A crime of `kind` against `govt` committed in the player's current
    /// system — the flood, outside a flight session (a contraband fine
    /// assessed while landed).
    public mutating func recordCrime(_ kind: CrimeKind, against govt: Int, game: NovaGame) {
        var rep = systemReputation ?? [:]
        SystemReputation.applyCrime(kind, victim: govt, inSystem: currentSystem, to: &rep,
                                    govts: game.govtTable(), map: game.reputationMap())
        systemReputation = rep
        revokeRanks(forCrime: kind, against: govt, game: game)
    }

    /// The crime arm of `Government_ProcessFactionCombatEvent` 0x00466fc0
    /// (EC-10): after the flood, every active non-permanent rank whose
    /// government is allied with the victim (or is the victim) is deactivated
    /// when its Flags hold 0x0040 (any crime) or 0x0004 and the crime is a
    /// disable or a kill. Ranks are visited in id order and lose their
    /// siblings the way `L` does. A derelict victim or a mission ship's
    /// (`missionShip`) changes nothing. Returns the revoked rank ids.
    @discardableResult
    public mutating func revokeRanks(forCrime kind: CrimeKind, against victim: Int, game: NovaGame,
                                     missionShip: Bool = false) -> [Int] {
        let govts = game.govtTable()
        if missionShip { return [] }
        if let v = govts[victim], v.startsDisabled { return [] }
        var revoked: [Int] = []
        for id in activeRanks.sorted() where activeRanks.contains(id) {
            guard let r = game.rank(id), !r.permanent,
                  GovtRelations.allied(victim, r.govt, govts: govts) else { continue }
            let sensitive = r.flags & 0x0040 != 0 || (r.flags & 0x0004 != 0 && (kind == .disable || kind == .kill))
            guard sensitive else { continue }
            deactivateRank(id, game: game)
            revoked.append(id)
        }
        return revoked
    }

    /// `Rank_Deactivate` 0x00427f40 — what `L` does: clears the rank, then
    /// with Flags 0x0002 the government's other ranks and with 0x0020 its
    /// lower-weight ones, sparing permanent (0x0008) siblings.
    public mutating func deactivateRank(_ id: Int, game: NovaGame) {
        if activeRanks.contains(id) {
            activeRanks.remove(id)
            if let r = game.rank(id) {
                if r.flags & 0x0002 != 0 { clearSiblingRanks(of: r, lowerWeightOnly: false, game: game) }
                if r.flags & 0x0020 != 0 { clearSiblingRanks(of: r, lowerWeightOnly: true, game: game) }
            }
        }
        if recentRank == id { recentRank = nil }
    }

    /// Clear `rank`'s non-permanent siblings (the same government), or only
    /// the lower-weight ones.
    mutating func clearSiblingRanks(of rank: RankRes, lowerWeightOnly: Bool, game: NovaGame) {
        for other in activeRanks where other != rank.id {
            guard let r = game.rank(other), r.govt == rank.govt, !r.permanent else { continue }
            if lowerWeightOnly, r.weight >= rank.weight { continue }
            activeRanks.remove(other)
            if recentRank == other { recentRank = nil }
        }
    }

    /// A clean record (`oütf` ModType 21, mission PayVal codes): lifts every
    /// negative reputation in the scope back to 0.
    public mutating func cleanLegalRecord(_ scope: SystemReputation.CleanScope, game: NovaGame) {
        var rep = systemReputation ?? [:]
        SystemReputation.clean(scope, in: &rep, govts: game.govtTable(), map: game.reputationMap())
        systemReputation = rep
    }

    /// Mission completion's CompReward (`SystemReputation.applyMissionSuccess`).
    public mutating func applyMissionSuccessReputation(govt: Int, delta: Int, game: NovaGame) {
        var rep = systemReputation ?? [:]
        SystemReputation.applyMissionSuccess(govt: govt, delta: delta, to: &rep,
                                             govts: game.govtTable(), map: game.reputationMap())
        systemReputation = rep
    }

    /// Mission failure's half CompReward penalty (`SystemReputation.applyMissionFailure`).
    public mutating func applyMissionFailureReputation(govt: Int, delta: Int, game: NovaGame) {
        var rep = systemReputation ?? [:]
        SystemReputation.applyMissionFailure(govt: govt, delta: delta, to: &rep, map: game.reputationMap())
        systemReputation = rep
    }

    /// A mission abort's −5 × CompReward (`SystemReputation.applyMissionAbort`).
    public mutating func applyMissionAbortReputation(govt: Int, delta: Int, game: NovaGame) {
        var rep = systemReputation ?? [:]
        SystemReputation.applyMissionAbort(govt: govt, delta: delta, to: &rep, map: game.reputationMap())
        systemReputation = rep
    }
}
