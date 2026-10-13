import NovaSwiftKit
import NovaSwiftEngine

/// Whether a mission/story-gated outfit or ship can be shown/bought at the
/// current spaceport, per the Nova Bible's `Availability`/`Require`/
/// `Contribute`/`RequireGovt` mechanism. This is separate from tech-level
/// gating (`NovaEconomy.sells(techLevel:at:)`), which fully hides an item —
/// the Bible's default here is "shown, greyed, unpurchasable" instead; full
/// hiding only happens when the item opts into it (`hidesWhenLocked`).
public enum LockState: Equatable, Sendable {
    case available
    /// Still shown, but Buy is disabled — the Bible's default treatment.
    case locked
    /// Opted into full hiding via the outfit/ship's own "don't show" flags.
    case hidden
}

extension NovaGame {
    /// Bits contributed toward a `Require` check by the pilot's current ship,
    /// everything they currently own, and every rank/crön they currently hold —
    /// the Bible: Contribute fields are "combined with the Contribute fields from
    /// the player's ship and the other outfit items in the player's possession",
    /// and a ränk/crön contributes its bits "while active". Mirrors
    /// `StoryEngine.activeContributeBits()` so the purchase gate and the story
    /// engine agree on what the player has unlocked (an active-rank Contribute
    /// used to unlock nothing here — a rank-gated hull/outfit stayed locked in
    /// the shipyard even after the player earned the rank).
    public func contributedBits(pilot: PlayerState) -> UInt64 {
        var bits: UInt64 = ship(pilot.shipType)?.contribute ?? 0
        for (outfitID, qty) in pilot.ownedOutfits where qty > 0 {
            bits |= outfit(outfitID)?.contribute ?? 0
        }
        for rankID in pilot.activeRanks {
            bits |= rank(rankID)?.contribute ?? 0
        }
        for (cronID, rt) in pilot.cronRuntime where rt.contributes {
            bits |= cron(cronID)?.contribute ?? 0
        }
        return bits
    }

    /// Whether the Require bits are **enforced** for an outfit with `RequireGovt` at this spöb
    /// (`NovaLanded_CanBuyOutfit` 0x00491950; EC-12). The value is a band of resource ids:
    /// 128-383 enforce only at that government or an ally; 1128-1383 also at an independent
    /// port; 2128-2383 waive at that government or an ally and enforce everywhere else,
    /// independent included; 3128-3383 also waive at an independent port. Outside every band
    /// (−1 and negatives included) the bits are always enforced. Alliance is
    /// `Government_AreGovtsAllied` 0x0046bc90 (`GovtRelations.allied`: never a derelict
    /// government). Inside a waived scope the bit test is skipped and the buy is allowed.
    func requireBitsEnforced(_ requireGovt: Int, at spob: SpobRes) -> Bool {
        let table = RankPrivilege.govtTable(self)
        let independent = spob.government == -1
        func hereOrAlly(_ g: Int) -> Bool {
            spob.government == g || (!independent && GovtRelations.allied(spob.government, g, govts: table))
        }
        switch requireGovt {
        case 128...383:   return hereOrAlly(requireGovt - 128)
        case 1128...1383: return independent || hereOrAlly(requireGovt - 1128)
        case 2128...2383: return !hereOrAlly(requireGovt - 2128)
        case 3128...3383: return !(independent || hereOrAlly(requireGovt - 3128))
        default:          return true
        }
    }

    /// Lock state for an outfit at a given spöb (needs `RequireGovt` scoping).
    public func lockState(for item: OutfRes, pilot: PlayerState, at spob: SpobRes, diplomacy: Diplomacy) -> LockState {
        // Note: `ignoresRequirements` (Bible `Flags` 0x0800) is sell-side only
        // ("can be sold anywhere, regardless of tech level, requirements, or
        // mission bits") — it does not waive the buy-side Require/Availability
        // gate here. See OUTFITTERS.md §3.5.
        // Owning one does not skip tech, Require or Availability (0x00491950; EC-12).
        let availOK = outfitAvailabilityPasses(item, pilot: pilot)
        let requireOK = outfitRequirePasses(item, pilot: pilot, at: spob, diplomacy: diplomacy)
        if availOK && requireOK { return .available }
        return item.hidesWhenLocked ? .hidden : .locked
    }

    /// The outfit's Availability test (`oütf.AvailBits`).
    public func outfitAvailabilityPasses(_ item: OutfRes, pilot: PlayerState) -> Bool {
        NCBTest(item.availBits).evaluate(pilot)
    }

    /// The outfit's Require test: the bits must be held unless the `RequireGovt` scope waives
    /// them at this port (a waived scope allows the buy; EC-12).
    public func outfitRequirePasses(_ item: OutfRes, pilot: PlayerState, at spob: SpobRes, diplomacy: Diplomacy) -> Bool {
        !requireBitsEnforced(item.requireGovt, at: spob)
            || (item.require & contributedBits(pilot: pilot)) == item.require
    }

    /// Lock state for a ship class (no documented `RequireGovt` for ships —
    /// the Bible's shïp section never mentions govt-scoped requirements).
    public func lockState(for item: ShipRes, pilot: PlayerState) -> LockState {
        if pilot.shipType == item.id { return .available }
        let availOK = NCBTest(item.availBits).evaluate(pilot)
        let requireOK = (item.require & contributedBits(pilot: pilot)) == item.require
        if availOK && requireOK { return .available }
        // Each hide bit answers its own test (0x00469e90): 0x0200 hides on a
        // failed Require, 0x0100 on a failed Availability.
        if item.flags3 & 0x0200 != 0, !requireOK { return .hidden }
        if item.flags3 & 0x0100 != 0, !availOK { return .hidden }
        return .locked
    }
}
