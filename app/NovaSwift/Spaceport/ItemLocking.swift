import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// Whether a mission/story-gated outfit or ship can be shown/bought at the
/// current spaceport, per the Nova Bible's `Availability`/`Require`/
/// `Contribute`/`RequireGovt` mechanism. This is separate from tech-level
/// gating (`NovaEconomy.sells(techLevel:at:)`), which fully hides an item —
/// the Bible's default here is "shown, greyed, unpurchasable" instead; full
/// hiding only happens when the item opts into it (`hidesWhenLocked`).
enum LockState: Equatable {
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
    func contributedBits(pilot: PlayerState) -> UInt64 {
        var bits: UInt64 = ship(pilot.shipType)?.contribute ?? 0
        for (outfitID, qty) in pilot.outfits where qty > 0 {
            bits |= outfit(outfitID)?.contribute ?? 0
        }
        for rankID in pilot.activeRanks {
            bits |= rank(rankID)?.contribute ?? 0
        }
        for (cronID, rt) in pilot.cronRuntime where rt.isActive {
            bits |= cron(cronID)?.contribute ?? 0
        }
        return bits
    }

    /// Whether `outfit`'s `Require` bits actually gate purchase *at this
    /// spöb*, per its `RequireGovt` scoping (Bible: -1 everywhere; 128-383
    /// this govt/allies only; 1128-1383 + independent; 2128-2383 all-but;
    /// 3128-3383 all-but + independent). Outside the scope, the Require gate
    /// simply doesn't apply there.
    private func requireGovtApplies(_ requireGovt: Int, at spob: SpobRes, diplomacy: Diplomacy) -> Bool {
        guard requireGovt >= 0 else { return true }
        let scopeGovt = requireGovt % 1000
        let independent = spob.government < 0
        let hereOrAlly = spob.government == scopeGovt || diplomacy.areAllied(spob.government, scopeGovt)
        switch requireGovt {
        case 128...383:   return hereOrAlly
        case 1128...1383: return independent || hereOrAlly
        case 2128...2383: return !hereOrAlly
        case 3128...3383: return !(independent || hereOrAlly)
        default:          return true
        }
    }

    /// Lock state for an outfit at a given spöb (needs `RequireGovt` scoping).
    func lockState(for item: OutfRes, pilot: PlayerState, at spob: SpobRes, diplomacy: Diplomacy) -> LockState {
        if item.ignoresRequirements || pilot.hasOutfit(item.id) { return .available }
        let availOK = NCBTest(item.availBits).evaluate(pilot)
        let requireOK = !requireGovtApplies(item.requireGovt, at: spob, diplomacy: diplomacy)
            || (item.require & contributedBits(pilot: pilot)) == item.require
        if availOK && requireOK { return .available }
        return item.hidesWhenLocked ? .hidden : .locked
    }

    /// Lock state for a ship class (no documented `RequireGovt` for ships —
    /// the Bible's shïp section never mentions govt-scoped requirements).
    func lockState(for item: ShipRes, pilot: PlayerState) -> LockState {
        if pilot.shipType == item.id { return .available }
        let availOK = NCBTest(item.availBits).evaluate(pilot)
        let requireOK = (item.require & contributedBits(pilot: pilot)) == item.require
        if availOK && requireOK { return .available }
        return item.hidesWhenLocked ? .hidden : .locked
    }
}
