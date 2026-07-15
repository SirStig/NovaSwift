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
/// classes. Xenophobes attack anyone who isn't an ally. The player is tracked
/// separately through a per-government legal record.
public final class Diplomacy {
    /// government id → decoded record.
    public private(set) var govts: [Int: GovtRes]
    /// Player's standing with each government *at `currentSystemID`*
    /// (negative = criminal there) — the EVN wiki's "displayed legal
    /// status," combining the universal (mission-driven) and local
    /// (combat-driven) components already on record for this system, seeded
    /// once via `seed(legalRecord:)`. Live combat mutates this directly (full
    /// weight, same as before spatial decay existed — see `recordCrime`) and
    /// additionally spreads a tapered share to nearby systems in `localSpread`.
    public private(set) var playerRecord: [Int: Int] = [:]
    /// `playerRecord` as of the last `seed(legalRecord:)` call — the baseline
    /// `consumeLocalRecordDelta()` diffs against to find what changed at
    /// `currentSystemID` this session.
    private var seededPlayerRecord: [Int: Int] = [:]
    /// Legal-record deltas earned this session in systems *other* than
    /// `currentSystemID`, from the Legal Status radius rule (hostile actions
    /// felt in nearby systems at reduced weight). govt id -> system id ->
    /// delta. Drained by `consumeLocalSpread()`.
    public private(set) var localSpread: [Int: [Int: Int]] = [:]
    /// The system this `Diplomacy` instance is scoped to — a fresh instance
    /// is built per system-session (see `seed(legalRecord:)`'s doc comment),
    /// so this is also the origin for `recordKill`/`recordDisable`/
    /// `recordBoard`'s spatial spread. Set by the caller (`GameContainerView`)
    /// right after construction, alongside `game`.
    public var currentSystemID = -1
    /// Game data backing `NovaGame.systemsWithinHops` for the spatial spread.
    /// nil (e.g. in unit tests that hand-build bare `GovtRes` values with no
    /// backing `NovaGame`) simply skips neighboring-system propagation —
    /// `playerRecord`, the current system's own standing, is unaffected.
    public var game: NovaGame?
    /// Fallback record-at-or-below-which-hostile, used only when a government
    /// is unknown/missing from the table (so `crimeTolerance` can't be read) —
    /// see `isCriminal`. Per-government hostility now uses `gövt.CrimeTol`
    /// (`GovtRes.crimeTolerance`, Bible: "the maximum amount of evilness the
    /// player can accumulate before warships of this govt start to beat on
    /// him" — Appendix II) instead of this single constant for every govt.
    public var hostileThreshold = -1

    /// Player's combat rating: the sum of `shïp.strength` (per-kill) of every
    /// ship the player has destroyed (Appendix I: "the sum of the strengths
    /// of all the ships you have destroyed, times some internal multiplier
    /// for adjustment"). The multiplier is never given a value by the Bible,
    /// and disassembly of the real tier-selection routine (`fcn.00469030`)
    /// shows no scaling applied at the comparison stage either — see
    /// docs/reverse-engineering/GOVERNMENT.md §3. Until that's pinned down
    /// further we use multiplier = 1 (no scaling), the documented-safe
    /// default. This is the engine-layer tally, updated live as kills happen
    /// (mirroring `playerRecord` above); `NovaSwiftStory.PlayerState` has its
    /// own persisted `combatRating` (seeded once from `chär.Kills` at pilot
    /// creation) that this module has no dependency on and therefore cannot
    /// write to directly — syncing the two is a pre-existing gap (see
    /// GOVERNMENT.md §5's "two separate modules that never talk to each
    /// other"), not something this file can close; whatever bridges
    /// `World`'s kill event to `Diplomacy.recordKill` should also copy this
    /// value into `PlayerState.combatRating`.
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

    /// Is the player criminal (attackable-on-sight-once-provoked) with this
    /// government? Per Appendix II, this is a **per-government ratio**, not a
    /// single hardcoded point value: warships turn hostile once the player's
    /// accumulated evilness with that govt reaches its own `CrimeTol`
    /// (`GovtRes.crimeTolerance`) — a govt with `CrimeTol = 500` tolerates far
    /// more than one with `CrimeTol = 5`. Falls back to the old single
    /// `hostileThreshold` constant only if the government is missing from the
    /// table entirely (so no `crimeTolerance` can be read).
    public func isCriminal(with govt: Int) -> Bool {
        guard let gov = self.govt(govt) else {
            return (playerRecord[govt] ?? 0) <= hostileThreshold
        }
        let evilness = -(playerRecord[govt] ?? 0)
        guard evilness > 0 else { return false }
        // CrimeTol <= 0 is data-invalid/unset; treat any evilness as enough
        // to provoke rather than making the govt impossible to anger.
        guard gov.crimeTolerance > 0 else { return true }
        return evilness >= gov.crimeTolerance
    }

    /// Governments whose ships won't automatically attack the player because the
    /// player holds an active `ränk` from them with the "won't attack" flag
    /// (`ränk.Flags` 0x0100). Seeded from the pilot's active ranks alongside
    /// `legalRecord`; empty otherwise.
    public var rankProtectedGovts: Set<Int> = []

    /// Does government `g` want to attack the player right now?
    public func isHostileToPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g] else {
            warnMissingGovt(g)
            return false
        }
        // An active rank that grants "govt won't attack" overrides the govt's
        // own default aggression (short of it being a criminal-provoked case
        // the player themselves triggered — `neverAttacksPlayer` is stronger).
        if rankProtectedGovts.contains(g) { return false }
        if gov.neverAttacksPlayer { return false }
        if gov.alwaysAttacksPlayer { return true }
        if gov.xenophobic { return true }
        if gov.nosy && isCriminal(with: g) { return true }
        return isCriminal(with: g)
    }

    /// Force the player's standing with a government at the current system to
    /// an exact value. Unlike `recordCrime`/`recordKill`, this doesn't
    /// propagate to allies or apply any penalty scaling — it's a direct
    /// override, used by the in-game debug suite to make a government
    /// instantly friendly or hostile so combat/hailing behaviour can be
    /// exercised on demand. Also clears any pending spread to other systems
    /// for this govt from earlier this session, so the override actually
    /// sticks rather than being partly undone by a later sync.
    public func setPlayerRecord(_ govt: Int, to value: Int) {
        playerRecord[govt] = value
        seededPlayerRecord[govt] = value
        localSpread[govt] = nil
    }

    /// Bulk-seed `playerRecord` from a persisted, already-combined snapshot
    /// (e.g. `PlayerState.effectiveLegalRecords(atSystem:)`, universal +
    /// local-at-this-system). A fresh `Diplomacy` is built from scratch on
    /// every jump/session rebuild (`GameHost.init` → `Galaxy(game:)` →
    /// `makeDiplomacy()`), so without this the player's standing would silently
    /// reset to neutral every time they jumped. Call once, right after
    /// construction (and after setting `currentSystemID`/`game`), before any
    /// combat can mutate it — this also snapshots the baseline
    /// `consumeLocalRecordDelta()` diffs against.
    public func seed(legalRecord: [Int: Int]) {
        for (govt, value) in legalRecord { playerRecord[govt] = value }
        seededPlayerRecord = playerRecord
    }

    /// How much `playerRecord` (standing at `currentSystemID`) has changed
    /// since the last `seed`/`consumeLocalRecordDelta` call, and resets the
    /// baseline — mirrors `consumeCombatRatingDelta`'s drain-on-read pattern
    /// so calling this from multiple sync points in a session never double-
    /// counts. Fold the result into `PlayerState.localLegalRecord[govt]
    /// [currentSystemID]` (NOT `PlayerState.legalRecord`, the universal/
    /// mission-only component this must never touch).
    public func consumeLocalRecordDelta() -> [Int: Int] {
        defer { seededPlayerRecord = playerRecord }
        var result: [Int: Int] = [:]
        for (govt, value) in playerRecord {
            let delta = value - (seededPlayerRecord[govt] ?? 0)
            if delta != 0 { result[govt] = delta }
        }
        return result
    }

    /// Drain `localSpread` (legal-record deltas earned this session in
    /// systems other than `currentSystemID`) — same drain-on-read safety as
    /// `consumeLocalRecordDelta()`.
    public func consumeLocalSpread() -> [Int: [Int: Int]] {
        defer { localSpread = [:] }
        return localSpread
    }

    /// Returns the combat rating earned since the last call and resets the live
    /// tally to 0. `combatRating` here only ever tracks kills made during the
    /// current `Diplomacy` instance's lifetime (one jump/session, per the
    /// `seed(legalRecord:)` doc comment) — folding this delta into
    /// `PlayerState.combatRating` at natural save points (landing, jump-out)
    /// is what makes it persist, without needing to seed it back in (a fresh
    /// instance starting at 0 and being drained on every sync is already
    /// double-count-safe regardless of how often this is called).
    public func consumeCombatRatingDelta() -> Int {
        defer { combatRating = 0 }
        return combatRating
    }

    /// Apply a legal-record change to a government (e.g. the player disabled/
    /// killed one of its ships). Per the Bible (§1.2): "Doing evil deeds to one
    /// government will improve your rating with its enemies, and vice versa.
    /// Allied governments also communicate your actions, so attacking one
    /// government will make its allies hate you too." Neither propagation's
    /// magnitude is quantified by the Bible; both use the same invented-but-
    /// consistent half-penalty, mirrored in sign (allies suffer, enemies
    /// benefit). `playerRecord` (standing at `currentSystemID`) always gets
    /// the full penalty; when `game` is available, a tapered share also
    /// spreads to nearby systems via `localSpread` (see `applyLocal`'s doc
    /// comment for the wiki-sourced radius rule) — without it (e.g. a unit
    /// test with no backing `NovaGame`), only the current system is affected.
    public func recordCrime(against govt: Int, penalty: Int) {
        if let game {
            LegalRecordPropagation.applyLocal(penalty: penalty, to: govt, atSystem: currentSystemID,
                                              current: &playerRecord, spread: &localSpread,
                                              govts: govts, game: game)
        } else {
            LegalRecordPropagation.apply(penalty: penalty, to: govt, in: &playerRecord, govts: govts)
        }
    }

    // MARK: Combat/piracy events → legal standing + combat rating
    //
    // The Bible's four *live* evilness sources (Appendix II §2.1) are
    // KillPenalty/DisabPenalty/BoardPenalty/SmugPenalty — `ShootPenalty` is
    // explicitly called out as "currently ignored" in the real game, so
    // per-hit gunfire should never call `recordCrime` directly. These methods
    // are the correct call sites for the events that actually happen; wire
    // combat/story code to these instead of reading `.shootPenalty`.

    /// The player destroyed a ship belonging to `govt`. Applies `KillPenalty`
    /// evilness and credits `combatRating` with the destroyed ship's
    /// `shïp.strength` (see `combatRating`'s doc comment above for the
    /// "internal multiplier" caveat). `World.despawnDepartedAndDead` already
    /// emits a `.shipDestroyed` event for this — that call site just needs to
    /// invoke this method instead of (or in addition to) its current
    /// `gov.shootPenalty`-on-every-hit logic.
    public func recordKill(of govt: Int, shipStrength: Int) {
        combatRating += shipStrength
        if let gov = self.govt(govt) {
            recordCrime(against: govt, penalty: gov.killPenalty)
        }
    }

    /// The player disabled (but did not destroy) a ship belonging to `govt`.
    /// Applies `DisabPenalty` evilness. `World.applyHit` already emits a
    /// `.shipDisabled` event for this transition — that call site just needs
    /// to invoke this method.
    public func recordDisable(of govt: Int) {
        if let gov = self.govt(govt) {
            recordCrime(against: govt, penalty: gov.disablePenalty)
        }
    }

    /// The player boarded/plundered a ship belonging to `govt`. Applies
    /// `BoardPenalty` evilness. Called from `World.board(shipID:)` the moment
    /// the player docks with a hulk — that's the single "forced entry" event,
    /// independent of what's taken or whether a follow-up capture succeeds.
    public func recordBoard(of govt: Int) {
        if let gov = self.govt(govt) {
            recordCrime(against: govt, penalty: gov.boardPenalty)
        }
    }

    /// The player was *detected* smuggling `govt`-illegal mission cargo
    /// (matched via `mïsn.ScanMask` ∩ `gövt.ScanMask`). Applies
    /// `SmugPenalty` evilness — the point cost of getting caught, not of
    /// merely carrying the cargo. No ScanMask/illegal-cargo detection system
    /// exists anywhere in this codebase yet (no event to hook this into) —
    /// see docs/reverse-engineering/GOVERNMENT.md §5. Provided so the method
    /// exists and is correct the moment scan-and-fine is implemented.
    public func recordSmuggling(against govt: Int) {
        if let gov = self.govt(govt) {
            recordCrime(against: govt, penalty: gov.smugglePenalty)
        }
    }
}
