import Foundation
import NovaSwiftKit

/// The special "government" id used for the player and for truly independent
/// ships (EV Nova uses −1 for independent). Independent ships are hostile to no
/// one by default and are only fought if provoked.
public let independentGovt = -1

/// EV Nova governments are resources 128…383, but several fields (e.g.
/// `flët.LinkSyst`'s banded government ranges) encode a government by its
/// 0-based *index* rather than its resource id. Add this base to turn such an
/// index into the resource id everything else here (system/ship `government`,
/// `Diplomacy`) speaks in.
public let govtResourceBase = 128

/// Resolves who fights whom, exactly the way EV Nova's `gövt` relations work:
/// governments carry *class* memberships plus lists of ally/enemy classes, and
/// two governments are enemies when one's enemy-classes intersect the other's
/// classes. Xenophobes attack anyone who isn't an ally.
///
/// The player is judged on the original's legal record: one reputation per
/// *system* (EC-02, `SystemReputation`), seeded from the pilot when a system
/// session starts, changed live by crimes (which flood across the galaxy), and
/// drained back to the pilot with `consumeReputationDelta()`.
public final class Diplomacy {
    /// government id → decoded record.
    public private(set) var govts: [Int: GovtRes]
    /// The player's reputation in every system (sparse; a missing system is
    /// 0) — the pilot's `systemReputation` plus every crime committed since
    /// `seed(reputation:)`.
    public private(set) var reputation: [Int: Int] = [:]
    /// `reputation` as of the last seed or drain — the baseline
    /// `consumeReputationDelta()` diffs against.
    private var seededReputation: [Int: Int] = [:]
    /// The system the player is in. Its reputation is what the AI's
    /// player-hostility ladder reads, and it is where a crime starts its flood.
    public var currentSystemID = -1
    /// Game data backing `reputationMap`. Nil in unit tests that hand-build
    /// bare `GovtRes` values; those assign `reputationMap` directly.
    public var game: NovaGame?
    /// Every system's owner, links and twin group. Built from `game` on first
    /// use; tests may assign one.
    public var reputationMap: ReputationMap {
        get {
            if let map = cachedMap { return map }
            let map = game?.reputationMap() ?? ReputationMap(systems: [])
            cachedMap = map
            return map
        }
        set { cachedMap = newValue }
    }
    private var cachedMap: ReputationMap?

    /// Combat rating earned by kills since the last `consumeCombatRatingDelta`
    /// — each kill's `CombatRatingRule.points` — which the host folds into
    /// `PlayerState.combatRating` with `CombatRatingRule.fold`.
    public private(set) var combatRating = 0

    /// Government ids we've already warned about missing from the table, so a
    /// per-frame AI lookup (`favorableOdds`, `isHostile`, etc.) doesn't spam
    /// the same "unknown government" warning every tick.
    private var warnedMissingGovt: Set<Int> = []

    public init(govts: [GovtRes], currentSystemID: Int = -1, game: NovaGame? = nil) {
        self.govts = Dictionary(uniqueKeysWithValues: govts.map { ($0.id, $0) })
        self.currentSystemID = currentSystemID
        self.game = game
    }

    public func govt(_ id: Int) -> GovtRes? {
        let g = govts[id]
        if g == nil { warnMissingGovt(id) }
        return g
    }

    /// `id == independentGovt` (−1) is the documented "no government entry"
    /// case and is expected — don't warn on it. Anything else missing means a
    /// ship/data reference points at a government id the table never loaded
    /// (a real content/data bug), and every caller silently treats it as "no
    /// relations" (peaceful/never-hostile), which can look exactly like
    /// "NPCs never fight" or "NPCs never turn hostile" with no other clue.
    private func warnMissingGovt(_ id: Int) {
        guard id != independentGovt, !warnedMissingGovt.contains(id) else { return }
        warnedMissingGovt.insert(id)
        Log.world.error("Diplomacy: no govt record for id \(id) — treating as no-government fallback (peaceful / never hostile)")
    }

    // MARK: Government ↔ government

    /// Does government `a` consider `b` an enemy? Directional (mirrors the data),
    /// but combat should treat a pair as enemies if *either* side does — see
    /// `areEnemies`.
    public func considersHostile(_ a: Int, toward b: Int) -> Bool {
        guard a != b else { return false }
        guard let ga = govts[a] else {
            warnMissingGovt(a)                                // independent / unknown: peaceful
            return false
        }
        let bClasses = govts[b]?.classes ?? []
        if !Set(ga.enemies).isDisjoint(with: bClasses) { return true }
        if ga.xenophobic {                                    // attacks all non-allies
            let allied = !Set(ga.allies).isDisjoint(with: bClasses)
            return !allied
        }
        return false
    }

    /// Symmetric hostility: fights break out if either government is hostile.
    public func areEnemies(_ a: Int, _ b: Int) -> Bool {
        considersHostile(a, toward: b) || considersHostile(b, toward: a)
    }

    /// Are these governments explicitly allied (one lists the other's class)?
    public func areAllied(_ a: Int, _ b: Int) -> Bool {
        if a == b { return true }
        let bClasses = govts[b]?.classes ?? []
        let aClasses = govts[a]?.classes ?? []
        if let ga = govts[a], !Set(ga.allies).isDisjoint(with: bClasses) { return true }
        if let gb = govts[b], !Set(gb.allies).isDisjoint(with: aClasses) { return true }
        return false
    }

    // MARK: Government ↔ player

    /// The player's reputation in the current system.
    public var reputationHere: Int { reputation[currentSystemID] ?? 0 }

    /// The current system's owning government, −1 independent.
    public var currentSystemGovernment: Int { reputationMap.govt(of: currentSystemID) }

    /// Governments whose ships won't automatically attack the player because the
    /// player holds an active `ränk` from them with the "won't attack" flag
    /// (`ränk.Flags` 0x0100; the original's rank privilege 0). Seeded from the
    /// pilot's active ranks; empty otherwise.
    public var rankProtectedGovts: Set<Int> = []
    /// Every active rank's (government, `ränk.Flags`), seeded by the host
    /// like `rankProtectedGovts`. The ship comm window (0x0047e470) reads
    /// 0x0400 (an allied ship helps for free against a threat) and 0x0800
    /// (assistance is free) from ranks whose government is allied with the
    /// hailed ship.
    public var activeRankFlags: [(govt: Int, flags: Int)] = []

    /// The session's IFF-scrambler and reinforcement-inhibitor latches (OS-10).
    public var latches: GovernmentLatches = .shared

    /// Rank privilege and the IFF-scrambler latch both clear the player as a
    /// candidate (`Ship_AcquirePrimaryTargetForShip` 0x0040e020, after the
    /// ladder).
    public func playerShielded(from g: Int) -> Bool {
        rankProtectedGovts.contains(g) || latches.isScrambled(g)
    }

    /// The reputation arm of `Ship_AcquirePrimaryTargetForShip` 0x0040e020
    /// (AI-05): would a ship of government `g` flag the player as a target
    /// here, judged on the player's reputation `rep` in the **current**
    /// system and on `g`'s `CrimeTol`?
    ///
    /// - `g` owns the system: `rep < −CrimeTol`.
    /// - Independent system: nosy (`Flags` 0x0002) only, `rep < −2·CrimeTol`.
    /// - `g` hostile to the owner (or either is xenophobic): `rep > CrimeTol` —
    ///   known bug #132, a *good* record makes the owner's enemies attack.
    /// - Allied with the owner: `rep < −1.5·CrimeTol`.
    /// - Neutral to the owner: nosy only, `rep < −2·CrimeTol`.
    ///
    /// `Flags` 0x0040 blocks all of it, and a xenophobe takes its own branch
    /// (`xenophobeTargetsPlayer`). Rank privilege and the scrambler latch
    /// clear the result. The caller adds the per-ship parts: the
    /// `cadence × 600` px box, the 1-in-50 inherent-government roll
    /// (`inherentGovtGrudge`) and the MaxOdds filter.
    public func reputationFlagsPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g] else { return false }
        // `Flags` 0x0004 turns a ship hostile to the player outright as it
        // arrives in the system, whatever the record.
        if gov.alwaysAttacksPlayer { return true }
        if gov.xenophobic { return xenophobeTargetsPlayer(g) }
        guard !gov.neverAttacksPlayer, !playerShielded(from: g) else { return false }
        return reputationLadderFlagsPlayer(g)
    }

    /// The bare relation ladder of `reputationFlagsPlayer` for a
    /// non-xenophobic government: no `Flags` 0x0004 / 0x0040 arm, no rank or
    /// scrambler shield. The original AI applies those itself, in the order
    /// 0x0040e020 does (`OriginalAI.acquirePrimaryTarget`).
    public func reputationLadderFlagsPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g] else { return false }
        let rep = reputationHere
        let tol = gov.crimeTolerance
        let owner = currentSystemGovernment
        if g == owner { return rep < -tol }
        if owner == independentGovt { return gov.nosy && rep < tol * -2 }
        if GovtRelations.hostileOrXenophobic(g, owner, govts: govts) { return tol < rep }
        if GovtRelations.allied(g, owner, govts: govts) { return Double(rep) < Double(-tol) * 1.5 }
        return gov.nosy && rep < tol * -2
    }

    /// A xenophobic government's ships flag the player anywhere except their
    /// own system, where a reputation of 1 or more keeps the peace
    /// (0x0040e020's xenophobe scan). `Flags` 0x0040, rank privilege and the
    /// scrambler latch still apply. There is no acquisition box: a xenophobe
    /// sees the player system-wide.
    public func xenophobeTargetsPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g], !gov.neverAttacksPlayer, !playerShielded(from: g) else { return false }
        return g == currentSystemGovernment ? reputationHere < 1 : true
    }

    /// The 1-in-50 arm: a ship of `g` may flag the player when the player's
    /// hull has an inherent government hostile to `g`. The caller rolls.
    public func inherentGovtGrudge(_ g: Int, playerHullGovt: Int) -> Bool {
        guard g != independentGovt, playerHullGovt != independentGovt,
              !playerShielded(from: g) else { return false }
        return GovtRelations.hostileOrXenophobic(g, playerHullGovt, govts: govts)
    }

    /// Does government `g` want the player dead here, as a government? The
    /// reputation ladder with no per-ship box or roll — what the radar colour,
    /// the reinforcement gate and other government-level readers use.
    public func isHostileToPlayer(_ g: Int) -> Bool {
        guard govts[g] != nil else {
            warnMissingGovt(g)
            return false
        }
        return reputationFlagsPlayer(g)
    }

    /// `Government_IsCandidateHostileToTargeter` 0x004629e0, player arm: a
    /// stellar's batteries (government `g`, or the system's owner for an
    /// independent stellar) fire on the player when `rep < −CrimeTol`; failing
    /// that, a non-xenophobic stellar fires when the player's hull has an
    /// inherent government hostile to the stellar's own, and a xenophobic one
    /// when `rep < 0`. Rank privilege and the scrambler latch clear it.
    public func stellarBatteriesTargetPlayer(stellarGovt: Int, playerHullGovt: Int) -> Bool {
        let g = stellarGovt == independentGovt ? currentSystemGovernment : stellarGovt
        guard let gov = govts[g] else { return false }
        let rep = reputationHere
        var hostile = rep < -gov.crimeTolerance
        if !hostile {
            if gov.xenophobic {
                hostile = rep < 0
            } else if GovtRelations.hostileOrXenophobic(playerHullGovt, stellarGovt, govts: govts) {
                hostile = true
            }
        }
        return hostile && !playerShielded(from: g)
    }

    /// Set the player's reputation in the current system to an exact value —
    /// the debug suite's "make this system friendly/hostile" override. No
    /// flood, and the value counts as already synced.
    public func setReputationHere(_ value: Int) {
        let v = SystemReputation.clamp(value)
        reputation[currentSystemID] = v == 0 ? nil : v
        seededReputation[currentSystemID] = reputation[currentSystemID]
    }

    /// Drop the player's reputation in the current system to `minStatus − 1`
    /// when it still meets `minStatus` (a tribute demand or a release,
    /// 0x00480030): a direct write to this system's entry, no flood, kept for
    /// the next `consumeReputationDelta()`. `MinStatus` −32767 / 32767 never
    /// lowers anything.
    public func lowerReputationHere(belowMinStatus minStatus: Int) {
        guard minStatus > -32767, minStatus != 32767, reputationHere >= minStatus else { return }
        let v = minStatus - 1
        reputation[currentSystemID] = v == 0 ? nil : v
    }

    /// Seed from the pilot's persisted per-system reputation. A fresh
    /// `Diplomacy` is built for every system session, so call this once,
    /// right after construction and before any combat.
    public func seed(reputation persisted: [Int: Int]) {
        reputation = persisted
        seededReputation = persisted
    }

    /// Per-system change since the last seed or drain, resetting the
    /// baseline, so draining from several sync points never double-counts.
    /// The host folds it into `PlayerState` (`applyReputationDelta`).
    public func consumeReputationDelta() -> [Int: Int] {
        defer { seededReputation = reputation }
        var result: [Int: Int] = [:]
        for id in Set(reputation.keys).union(seededReputation.keys) {
            let delta = (reputation[id] ?? 0) - (seededReputation[id] ?? 0)
            if delta != 0 { result[id] = delta }
        }
        return result
    }

    /// Returns the combat rating earned since the last call and resets the live
    /// tally to 0. The host folds it into `PlayerState.combatRating` at natural
    /// save points (landing, jump-out); a fresh instance starting at 0 and
    /// drained on every sync is double-count-safe.
    public func consumeCombatRatingDelta() -> Int {
        defer { combatRating = 0 }
        return combatRating
    }

    /// A crime of `kind` against a ship (or stellar) of `govt` in the current
    /// system: the original's flood (`SystemReputation.applyCrime`). A crime
    /// against a mission ship changes nothing.
    public func recordCrime(_ kind: CrimeKind, against govt: Int, missionShip: Bool = false) {
        SystemReputation.applyCrime(kind, victim: govt, inSystem: currentSystemID, to: &reputation,
                                    govts: govts, map: reputationMap, missionShip: missionShip)
        if !missionShip { crimeEvents.append((kind, govt)) }
    }

    /// Crimes since the last drain, for the rank revocation the same event
    /// runs in the original (EC-10, `PlayerState.revokeRanks`); the ranks live
    /// in the pilot, so the host applies them.
    private var crimeEvents: [(kind: CrimeKind, victim: Int)] = []

    public func consumeCrimeEvents() -> [(kind: CrimeKind, victim: Int)] {
        defer { crimeEvents = [] }
        return crimeEvents
    }

    // MARK: Crime events → legal record + combat rating
    //
    // The four live crime events are the kill, disable, board and smuggling
    // penalties; `ShootPenalty` is never raised by the original, so gunfire
    // itself never touches the record.

    /// The player (or one of the player's direct escorts) destroyed a ship
    /// belonging to `govt`: the kill flood, and the kill's combat-rating
    /// points (`CombatRatingRule.points`, from the hull's `shïp.Strength`).
    public func recordKill(of govt: Int, shipStrength: Int, missionShip: Bool = false) {
        combatRating += CombatRatingRule.points(forStrength: shipStrength)
        recordCrime(.kill, against: govt, missionShip: missionShip)
    }

    /// The player disabled (but did not destroy) a ship belonging to `govt`.
    public func recordDisable(of govt: Int, missionShip: Bool = false) {
        recordCrime(.disable, against: govt, missionShip: missionShip)
    }

    /// The player boarded a ship belonging to `govt` — the single "forced
    /// entry" event, whatever is taken afterwards.
    public func recordBoard(of govt: Int, missionShip: Bool = false) {
        recordCrime(.board, against: govt, missionShip: missionShip)
    }

    /// The player was caught smuggling by a ship of `govt`.
    public func recordSmuggling(against govt: Int) {
        recordCrime(.smuggling, against: govt)
    }
}

/// The original's per-government byte latches that an owned outfit sets and
/// nothing clears until the game quits (`Outfit_RecomputeOutfitDerivedState`
/// 0x0046d4b0, OS-10): owning an IFF scrambler (ModType 48) marks every
/// government holding its ModVal class "scrambled"; owning a reinforcement
/// inhibitor (ModType 44) marks them "inhibited", and ModVal −1 on an
/// inhibitor inhibits every government. A scrambler with ModVal −1 matches
/// nothing. Selling the outfit leaves the latch set.
///
/// Process-wide on purpose: the original keeps these in the loaded government
/// table, which outlives every system session and pilot load.
public final class GovernmentLatches: @unchecked Sendable {
    public static let shared = GovernmentLatches()

    private let lock = NSLock()
    private var scrambled: Set<Int> = []
    private var inhibited: Set<Int> = []
    private var inhibitAll = false

    public init() {}

    /// Latch the governments an outfit set of `scramblerClasses` /
    /// `inhibitorClasses` (ModVals) matches. Idempotent; never clears.
    public func latch(scramblerClasses: Set<Int>, inhibitorClasses: Set<Int>, govts: [GovtRes]) {
        guard !scramblerClasses.isEmpty || !inhibitorClasses.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if inhibitorClasses.contains(-1) { inhibitAll = true }
        for g in govts {
            let classes = Set(g.classes)
            if !classes.isDisjoint(with: scramblerClasses) { scrambled.insert(g.id) }
            if !classes.isDisjoint(with: inhibitorClasses) { inhibited.insert(g.id) }
        }
    }

    public func isScrambled(_ govt: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scrambled.contains(govt)
    }

    public func isInhibited(_ govt: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inhibitAll || inhibited.contains(govt)
    }

    /// Forget every latch (the game quitting; tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        scrambled = []; inhibited = []; inhibitAll = false
    }
}

/// `Frame_AddCombatRatingPoints` (0x0046f1e0): a kill of a hull with
/// `shïp.Strength` below 5 earns 1 point; anything stronger earns
/// `trunc(strength × 0.2)`. A rating already at 10,000,000 is pinned there.
/// The rank thresholds (100 / 200 / … / 25600) read the result directly.
public enum CombatRatingRule {
    public static let cap = 10_000_000

    /// Points one kill of a hull of `strength` earns.
    public static func points(forStrength strength: Int) -> Int {
        strength < 5 ? 1 : Int((Double(strength) * 0.2).rounded(.down))
    }

    /// `rating` after earning `points` more: the original adds while below
    /// the cap and pins at the cap once there.
    public static func fold(_ rating: Int, adding points: Int) -> Int {
        guard points != 0 else { return rating }
        return rating >= cap ? cap : rating + points
    }
}
