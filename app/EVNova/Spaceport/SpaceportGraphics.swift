import SwiftUI
import EVNovaKit

/// Decodes and caches the EV Nova interface graphics the spaceport screens draw
/// themselves from — **all from the player's own data**, never our own artwork:
///   • frame PICTs (Spaceport 8500, Shipyard 8501, Outfit 8502, Bar 8503/8504,
///     Trade 8510, Mission BBS 8505),
///   • the three-slice button PICTs (7500–7508),
///   • the button labels (`STR# 150`),
///   • per-planet landscape PICTs and per-item outfit/ship pictures.
///
/// One instance is built per play session and shared by every spaceport screen.
@MainActor
final class SpaceportGraphics {
    let game: NovaGame
    private var cache: [Int: CGImage] = [:]
    private var missed: Set<Int> = []
    private var shipFallbackCache: [Int: CGImage?] = [:]

    init(game: NovaGame) {
        self.game = game
        Log.spaceport.debug("SpaceportGraphics created for this session")
    }

    // MARK: Frame + interface PICT ids (from the real data's PICT names)
    enum Frame: Int {
        case spaceport = 8500, shipyard = 8501, outfit = 8502
        case bar = 8503, barPict = 8504, missionBBS = 8505, trade = 8510
    }

    /// Decode any PICT resource by id → CGImage (cached). Returns nil if the
    /// resource is missing or uses an encoding we can't decode yet.
    func pict(_ id: Int) -> CGImage? {
        if let c = cache[id] { return c }
        if missed.contains(id) { return nil }
        guard let data = game.resources.resource(NovaType.pict, id)?.data else {
            Log.spaceport.error("PICT \(id, privacy: .public) not found in loaded data — falling back to placeholder")
            missed.insert(id); return nil
        }
        guard let sheet = try? PICT.decode(data), let cg = sheet.makeCGImage() else {
            Log.spaceport.error("PICT \(id, privacy: .public) found (\(data.count, privacy: .public) bytes) but failed to decode — falling back to placeholder")
            missed.insert(id); return nil
        }
        cache[id] = cg
        return cg
    }

    func frame(_ f: Frame) -> CGImage? { pict(f.rawValue) }

    // MARK: Buttons — three-slice PICTs (left cap / tiling middle / right cap)
    enum ButtonState { case normal, clicked, grey }

    /// (left, middle, right) PICT ids for a button state.
    func buttonSlices(_ state: ButtonState) -> (left: CGImage?, middle: CGImage?, right: CGImage?) {
        let base: Int
        switch state {
        case .normal:  base = 7500
        case .clicked: base = 7503
        case .grey:    base = 7506
        }
        return (pict(base), pict(base + 1), pict(base + 2))
    }

    /// A label from `STR# 150` ("button labels"): Leave, Buy, Sell, Buy Ship,
    /// Done, Recharge, Trade Center, Outfitter, Shipyard, Bar, Gamble, Holovid.
    func buttonLabel(_ index1: Int, fallback: String) -> String {
        guard let list = game.stringList(150) else {
            Log.spaceport.error("STR# 150 (button labels) missing from loaded data — using fallback \"\(fallback, privacy: .public)\"")
            return fallback
        }
        guard let s = list.string(at: index1) else {
            Log.spaceport.error("STR# 150 has no entry at index \(index1, privacy: .public) — using fallback \"\(fallback, privacy: .public)\"")
            return fallback
        }
        return s
    }

    // MARK: Per-item pictures

    /// A planet's landing landscape PICT (10000-range), if it defines one.
    func landscape(for spob: SpobRes) -> CGImage? {
        let id = spob.landingPictID
        guard id > 0, id != 0xFFFF else { return nil }
        return pict(id)
    }

    /// An outfit's outfitter picture (`pictID = id − 128 + 6000`).
    func outfitPicture(_ outfit: OutfRes) -> CGImage? {
        pict(outfit.id - 128 + 6000)
    }

    /// A ship's shipyard display picture (`pictID = id − 128 + 5000`) — a large,
    /// dedicated piece of art distinct from the small in-flight `rlëD` sprite.
    /// Using the flight sprite here (e.g. a Shuttle's 24×24 frame) stretched to
    /// fill the shipyard panel is what made ships look blurry/pixelated.
    func shipPicture(_ ship: ShipRes) -> CGImage? {
        pict(ship.id - 128 + 5000)
    }

    /// The small in-flight sprite's frame 0, standing in for a ship's shipyard
    /// picture when it doesn't define dedicated `5000`-series art. Cached —
    /// `SpriteSheet.frameCGImage` rebuilds a full `CGImage` (copying the whole
    /// sprite sheet's pixel buffer) on every call, and the Shipyard grid calls
    /// this once per visible tile, every render.
    func shipFallbackPicture(_ ship: ShipRes) -> CGImage? {
        if let c = shipFallbackCache[ship.id] { return c }
        let image = game.shipSprite(ship.id)?.frameCGImage(0)
        shipFallbackCache[ship.id] = .some(image)
        return image
    }
}

/// Standard EV Nova button-label indices in `STR# 150`, verified directly
/// against the real resource (`evnova-extract raw data/base 'STR#' 150`):
/// Leave, Buy, Sell, Buy Ship, Done, Recharge, Trade Center, Outfitter,
/// Shipyard, Bar, Gamble, Holovid, Hire Escort, Bet 1000, Bet 5000, Mission
/// BBS, … `missionBBS` was previously mis-set to 11 (actually "Gamble") —
/// the two are 5 apart, not adjacent.
enum SpaceportLabel {
    static let leave = 1, buy = 2, sell = 3, buyShip = 4, done = 5, recharge = 6
    static let tradeCenter = 7, outfitter = 8, shipyard = 9, bar = 10
    static let gamble = 11, holovid = 12, hireEscort = 13, bet1000 = 14, bet5000 = 15
    static let missionBBS = 16
}
