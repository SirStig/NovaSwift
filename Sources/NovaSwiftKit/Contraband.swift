import Foundation

// Contraband & scan-fine mechanics (EV Nova `gövt.ScanMask` / `ScanFine` /
// `SmugPenalty`). A government polices the cargo and equipment whose own
// `ScanMask` shares a set bit with the government's `ScanMask`. When one of its
// ships scans the player and finds such an item — and the player isn't yet
// criminal enough to simply be attacked — it fines him.
//
// Ground truth (EV Nova Bible, via docs/reverse-engineering/GOVERNMENT.md):
//   ScanMask   "If any of the 1 bits in a government's ScanMask field match any
//              of the 1 bits in a mission's [/jünk/oütf] ScanMask field, that
//              government will consider that cargo illegal."
//   ScanFine   ">=1 fine this amount; 0 no fine, just a warning; -1 and below
//              fine this % of the player's cash."
//   SmugPenalty "The amount of evilness a player gains for being detected
//              smuggling illegal cargo (defined in a mïsn resource)."

public enum Contraband {
    /// Whether two ScanMasks share a set bit — the single rule that decides
    /// illegality on every axis (mission cargo, junk cargo, outfit).
    public static func matches(_ itemMask: UInt16, _ govtMask: UInt16) -> Bool {
        itemMask != 0 && govtMask != 0 && (itemMask & govtMask) != 0
    }

    /// The credit fine a government levies for detected non-mission contraband,
    /// from its `ScanFine` field and the player's current `cash`.
    /// - `>= 1`  → a flat fine of that many credits (never more than the player has).
    /// - `0`     → warning only (`warningOnly == true`, no credits taken).
    /// - `<= -1` → that percentage of the player's cash (`-5` ⇒ 5%).
    public static func fine(scanFine: Int, cash: Int) -> (amount: Int, warningOnly: Bool) {
        let cash = max(0, cash)
        if scanFine == 0 { return (0, true) }
        if scanFine >= 1 { return (min(scanFine, cash), false) }
        // scanFine <= -1: percentage of cash.
        let percent = min(100, -scanFine)
        return (cash * percent / 100, false)
    }
}

extension NovaGame {
    /// A government's contraband jurisdiction mask (`gövt.ScanMask`), 0 if the
    /// government polices nothing or doesn't exist.
    public func governmentScanMask(_ govtID: Int) -> UInt16 { govt(govtID)?.scanMask ?? 0 }

    /// Whether owning outfit `outfitID` is contraband to government `govtID`
    /// (`oütf.ScanMask` ∩ `gövt.ScanMask`).
    public func isOutfitContraband(_ outfitID: Int, to govtID: Int) -> Bool {
        guard let o = outfit(outfitID) else { return false }
        return Contraband.matches(o.scanMask, governmentScanMask(govtID))
    }

    /// Whether carrying cargo type `cargoID` is contraband to government
    /// `govtID` (`jünk.ScanMask` ∩ `gövt.ScanMask`). Standard commodities have no
    /// `jünk` record and so are never contraband.
    public func isCargoContraband(_ cargoID: Int, to govtID: Int) -> Bool {
        guard let j = junk(cargoID) else { return false }
        return Contraband.matches(j.scanMask, governmentScanMask(govtID))
    }

    /// Whether mission `missionID`'s cargo is contraband to government `govtID`
    /// (`mïsn.ScanMask` ∩ `gövt.ScanMask`) — the smuggling case that also earns
    /// `SmugPenalty` evilness when detected.
    public func isMissionCargoContraband(_ missionID: Int, to govtID: Int) -> Bool {
        guard let m = mission(missionID), m.scanMask != 0 else { return false }
        return Contraband.matches(UInt16(truncatingIfNeeded: m.scanMask), governmentScanMask(govtID))
    }
}
