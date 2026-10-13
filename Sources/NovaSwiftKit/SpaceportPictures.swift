import Foundation

/// Which PICT resource each spaceport picture lives in. The numbering rules are
/// the original's, kept here so every frontend (the Apple app's SwiftUI
/// spaceport and the Godot one) resolves the same art; decoding is the
/// portable `PICT.decode`.
extension NovaGame {
    /// A planet's landing landscape PICT id: `CustPicID` when >= 128, else
    /// `Graphic + 10000` (0x0048e970). The resource may not exist (a station has
    /// none) — check `hasPICT` / `pictSheet`.
    public func landscapePictID(for spob: SpobRes) -> Int {
        spob.landingPictID >= 128 && spob.landingPictID != 0xFFFF ? spob.landingPictID : spob.graphicRaw + 10000
    }

    /// An outfit's outfitter picture (`id − 128 + 6000`).
    public func outfitPictID(_ outfit: OutfRes) -> Int { outfit.id - 128 + 6000 }

    /// A ship's shipyard display picture (`id − 128 + 5000`): large dedicated
    /// art, distinct from the small in-flight `rlëD` sprite. Only base hulls
    /// carry it — the data defines PICTs 5000–5054 for ships 128–182 and nothing
    /// for second-hand or government variants, which fall back to the
    /// lowest-numbered hull of the same display name that owns art (a used
    /// Valkyrie borrows the Valkyrie's). Nil when neither has any.
    public func shipPictID(for ship: ShipRes) -> Int? {
        let own = ship.id - 128 + 5000
        if hasPICT(own) { return own }
        let target = ship.displayName
        let base = ships()
            .filter { $0.id != ship.id && $0.displayName == target }
            .sorted { $0.id < $1.id }
            .first { hasPICT($0.id - 128 + 5000) }
        return base.map { $0.id - 128 + 5000 }
    }

    public func hasPICT(_ id: Int) -> Bool {
        resources.resource(NovaType.pict, id) != nil
    }

    /// The decoded PICT (single-frame RGBA sheet), or nil if absent/undecodable.
    public func pictSheet(_ id: Int) -> SpriteSheet? {
        guard let data = resources.resource(NovaType.pict, id)?.data else { return nil }
        return PICT.decodeLogged(data, id: id)
    }
}
