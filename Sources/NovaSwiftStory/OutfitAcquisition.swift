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
    /// Returns the systems a map reached, in reach order, for their nebula
    /// OnExplore events (`StoryEngine.exploreNebulae`).
    @discardableResult
    public mutating func applyOutfitAcquisition(_ o: OutfRes, game: NovaGame, fromSystem: Int) -> [Int] {
        // ModType 16 (map): reveal a scoped set of systems at discovery level
        // 2, recorded permanently. Hidden (NCB-invisible) systems stop the
        // flood.
        var reached: [Int] = []
        let me = self
        for modVal in o.mapModVals {
            let order = game.mapRevealOrder(modVal: modVal, from: fromSystem) { id in
                guard let test = game.system(id)?.visibility, !test.isEmpty else { return true }
                return NCBTest(test).evaluate(me)
            }
            chartSystems(order)
            reached += order
        }
        // ModType 21 (clean legal record): lift every criminal reputation in the
        // named government's systems, or everywhere for −1.
        for govt in o.cleanRecordGovts {
            cleanLegalRecord(govt == -1 ? .everywhere : .government(govt), game: game)
        }
        return reached
    }
}
