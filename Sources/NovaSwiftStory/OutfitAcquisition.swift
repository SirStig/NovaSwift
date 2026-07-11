import Foundation
import NovaSwiftKit

// The side effects an `oütf` applies to the pilot the moment it is ACQUIRED —
// whether bought at an outfitter or granted by a mission's `Gxxx` set operator.
// These are the modifier effects that mutate campaign state rather than ship
// stats: revealing map systems (ModType 16) and clearing a legal record
// (ModType 21). Ship-stat modifiers (shields, speed, weapons, …) are folded in
// live by `Galaxy.loadout`; these two instead change the persistent
// `PlayerState`, once, at the instant of acquisition.
//
// NOT included here: the outfit's `OnPurchase` NCB set expression. That one is
// specific to a *shop purchase* (the Bible: "evaluated when the item is bought")
// and needs the full NCB set executor, so it is run by the buyer
// (`PilotStore.buyOutfit`) through a `StoryEngine`, not here — a mission-granted
// outfit is not "bought" and does not fire OnPurchase.

extension PlayerState {
    /// Apply outfit `o`'s acquisition-time campaign effects (map reveal +
    /// legal-record clear) as if it were just added while the player is in
    /// `fromSystem`. Safe to call for any outfit — a non-map, non-record outfit
    /// simply does nothing. Idempotent for maps (systems union in) and for
    /// record-clears (already-clean stays clean).
    public mutating func applyOutfitAcquisition(_ o: OutfRes, game: NovaGame, fromSystem: Int) {
        // ModType 16 (map): reveal a scoped set of systems, recorded permanently.
        for modVal in o.mapModVals {
            chartSystems(game.mapRevealedSystems(modVal: modVal, from: fromSystem))
        }
        // ModType 21 (clean legal record): wipe standing with the named govt, or all.
        for govt in o.cleanRecordGovts {
            clearLegalRecord(govt: govt)
        }
    }
}
