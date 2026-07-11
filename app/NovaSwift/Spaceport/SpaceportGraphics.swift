import SwiftUI
import NovaSwiftKit

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
    private var baseHullCache: [Int: Int?] = [:]

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

    private var buttonSliceCache: [Int: CGImage] = [:]

    /// (left, middle, right) PICT ids for a button state, with their baked
    /// neutral-grey backing keyed to transparent. The cap PICTs (7500-7508) carry
    /// a flat grey (≈0x424242) frame around the red pill, meant to vanish into the
    /// grey button recesses the game's dialogs are drawn with. Our frames don't
    /// reproduce those exact recesses pixel-for-pixel, so that grey read as a hard
    /// box around every button. Keying just the neutral-grey pixels (leaving the
    /// red pill and its dark-red bevel untouched, since those aren't R≈G≈B) lets
    /// the pill sit cleanly on any surface.
    func buttonSlices(_ state: ButtonState) -> (left: CGImage?, middle: CGImage?, right: CGImage?) {
        let base: Int
        switch state {
        case .normal:  base = 7500
        case .clicked: base = 7503
        case .grey:    base = 7506
        }
        return (keyedSlice(base), keyedSlice(base + 1), keyedSlice(base + 2))
    }

    private func keyedSlice(_ id: Int) -> CGImage? {
        if let c = buttonSliceCache[id] { return c }
        guard let raw = pict(id) else { return nil }
        let keyed = Self.keyOutNeutralGrey(raw) ?? raw
        buttonSliceCache[id] = keyed
        return keyed
    }

    /// Make flat neutral-grey pixels (R≈G≈B, mid-dark brightness) transparent,
    /// leaving coloured (e.g. red) pixels intact. Used to lift the button caps'
    /// grey backing so only the pill shows.
    private static func keyOutNeutralGrey(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            // Neutral (low chroma) AND not near-black / not bright: the grey frame.
            if mx - mn <= 14, mx >= 32, mx <= 120 {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
    ///
    /// Only the base hulls carry this art: the data defines PICTs 5000–5054 for
    /// ships 128–182 and nothing for the twelve second-hand variants (361–372) or
    /// the government/escort variants that share a hull. Those all fall back to
    /// the base hull's picture, found by display name — a used Valkyrie (#371)
    /// borrows the Valkyrie's (#137 → PICT 5009).
    func shipPicture(_ ship: ShipRes) -> CGImage? {
        if let own = pict(ship.id - 128 + 5000) { return own }
        guard let base = baseHull(for: ship) else { return nil }
        return pict(base - 128 + 5000)
    }

    /// The id of the lowest-numbered ship sharing `ship`'s display name that owns
    /// shipyard art. Nil when `ship` *is* that ship, or nothing matches.
    private func baseHull(for ship: ShipRes) -> Int? {
        if let cached = baseHullCache[ship.id] { return cached }
        let target = ship.displayName
        let base = game.ships()
            .filter { $0.id != ship.id && $0.displayName == target }
            .sorted { $0.id < $1.id }
            .first { pict($0.id - 128 + 5000) != nil }?
            .id
        if base == nil {
            Log.spaceport.error("No shipyard art for ship \(ship.id, privacy: .public) (\(ship.name, privacy: .public)) and no base hull named \"\(target, privacy: .public)\" has any either")
        }
        baseHullCache[ship.id] = .some(base)
        return base
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
/// against the real resource (`novaswift-extract raw data/base 'STR#' 150`):
/// Leave, Buy, Sell, Buy Ship, Done, Recharge, Trade Center, Outfitter,
/// Shipyard, Bar, Gamble, Holovid, Hire Escort, Bet 1000, Bet 5000, Mission
/// BBS, … `missionBBS` was previously mis-set to 11 (actually "Gamble") —
/// the two are 5 apart, not adjacent.
enum SpaceportLabel {
    static let leave = 1, buy = 2, sell = 3, buyShip = 4, done = 5, recharge = 6
    static let tradeCenter = 7, outfitter = 8, shipyard = 9, bar = 10
    static let gamble = 11, holovid = 12, hireEscort = 13, bet1000 = 14, bet5000 = 15
    static let missionBBS = 16
    // Player-info dialog (DITL #1017): its four tab buttons, plus the controls
    // that share this list (verified in the same raw dump: 29 Cancel, 35 Abort,
    // 36–39 General/Cargo/Extras/Honors, 48 Info, 61 Jettison Cargo).
    static let abort = 35
    static let infoGeneral = 36, infoCargo = 37, infoExtras = 38, infoHonors = 39
    static let info = 48
    static let jettisonCargo = 61
    // Communication buttons, indices verified by re-parsing STR# 150 with the
    // real Pascal-string parser (count=61): 21 Close Channel, 22 Greetings, 23
    // Request Assistance, 24 Offer Bribe, 45 Demand Tribute. (An earlier guess
    // of 15/16/39 was off — those are Bet 5000 / Mission BBS / Honors, which is
    // exactly what the planet-hail buttons wrongly showed.) No dedicated
    // "Request Landing" entry exists, so that button uses a literal fallback.
    static let closeChannel = 21, greetings = 22, requestAssistance = 23
    static let offerBribe = 24, demandTribute = 45
    static let requestLanding = -1   // no STR# entry — literal fallback only
}
