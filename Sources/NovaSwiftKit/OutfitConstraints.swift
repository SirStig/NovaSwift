import Foundation

// Outfit purchase constraints that depend on *other* owned outfits — i.e. the
// `oütf` ModType 27 ("increase maximum") mechanic, which lets one outfit raise
// another's per-player `Max` cap. Kept in the base Kit layer so the shop
// (`PilotStore.canBuyOutfit`) and the loadout aggregator agree on one number.

extension NovaGame {
    /// The effective per-player `Max` for outfit `outfitID`, given everything the
    /// player currently owns (`ownedOutfits`: outfit id → count).
    ///
    /// EV Nova Bible, oütf ModType 27 ("increase maximum"), verbatim: "The ID
    /// number of another outfit item, (call it 'B') whose maximum value is to be
    /// increased. Item B's standard maximum will be multiplied by the number of
    /// items the player has that have a ModType of 27 and point to B."
    ///
    /// So the effective cap is `base.max × (owned ModType-27 items pointing at
    /// B)`. When the player owns none, the standard `base.max` stands unchanged
    /// (the multiplication clause only engages once at least one expander is
    /// owned — otherwise every ordinary outfit, which no expander points at,
    /// would collapse to a zero cap). A `base.max` of 0 means "unlimited" and is
    /// returned untouched.
    public func effectiveMaxInstallable(of outfitID: Int, ownedOutfits: [Int: Int]) -> Int {
        guard let base = outfit(outfitID)?.maxInstallable else { return 0 }
        guard base > 0 else { return 0 }   // 0 = unlimited, never capped

        var expanders = 0
        for (ownedID, count) in ownedOutfits where count > 0 {
            if outfit(ownedID)?.increasesMaxOf.contains(outfitID) ?? false {
                expanders += count
            }
        }
        return expanders >= 1 ? base * expanders : base
    }
}
