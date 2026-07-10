import Foundation
import EVNovaKit

/// The special "government" id used for the player and for truly independent
/// ships (EV Nova uses −1 for independent). Independent ships are hostile to no
/// one by default and are only fought if provoked.
public let independentGovt = -1

/// Resolves who fights whom, exactly the way EV Nova's `gövt` relations work:
/// governments carry *class* memberships plus lists of ally/enemy classes, and
/// two governments are enemies when one's enemy-classes intersect the other's
/// classes. Xenophobes attack anyone who isn't an ally. The player is tracked
/// separately through a per-government legal record.
public final class Diplomacy {
    /// government id → decoded record.
    public private(set) var govts: [Int: GovtRes]
    /// Player's standing with each government (negative = criminal there).
    public private(set) var playerRecord: [Int: Int] = [:]
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
    /// (mirroring `playerRecord` above); `EVNovaStory.PlayerState` has its
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

    public init(govts: [GovtRes]) {
        self.govts = Dictionary(uniqueKeysWithValues: govts.map { ($0.id, $0) })
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

    /// Does government `g` want to attack the player right now?
    public func isHostileToPlayer(_ g: Int) -> Bool {
        guard let gov = govts[g] else {
            warnMissingGovt(g)
            return false
        }
        if gov.neverAttacksPlayer { return false }
        if gov.alwaysAttacksPlayer { return true }
        if gov.xenophobic { return true }
        if gov.nosy && isCriminal(with: g) { return true }
        return isCriminal(with: g)
    }

    /// Apply a legal-record change to a government (e.g. the player fired on one
    /// of its ships). Also propagates a smaller hit to explicit allies.
    public func recordCrime(against govt: Int, penalty: Int) {
        playerRecord[govt, default: 0] -= penalty
        for (id, other) in govts where id != govt {
            if !Set(other.classes).isDisjoint(with: govts[govt]?.allies ?? []) {
                playerRecord[id, default: 0] -= penalty / 2
            }
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
    /// `BoardPenalty` evilness. No boarding/plunder mechanic exists anywhere
    /// in this codebase yet (no event to hook this into) — see
    /// docs/reverse-engineering/GOVERNMENT.md §5. Provided so the method
    /// exists and is correct the moment boarding is implemented.
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
