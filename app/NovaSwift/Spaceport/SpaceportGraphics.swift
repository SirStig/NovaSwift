import SwiftUI
import NovaSwiftKit

/// Decodes and caches the EV Nova interface graphics the spaceport screens draw
/// themselves from — **all from the player's own data**, never our own artwork:
///   • frame PICTs (Spaceport 8500, Shipyard 8501, Outfit 8502, Bar 8503/8504,
///     Trade 8510, Mission BBS 8505),
///   • the three-slice button PICTs (7500–7508) and their masks (7600–7608),
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
        guard let sheet = PICT.decodeLogged(data, id: id), let cg = sheet.makeCGImage() else {
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

    /// The (left, middle, right) slices for a button state, composited the way
    /// `NovaUi_InitThreeStateButtonArt` 0x004a2f50 builds its canvases: the
    /// caps (7500/7502 + 3·state) take their transparency from the matching
    /// mask PICTs (7600/7602 + 3·state; black = drawn, white = not), and the
    /// middle slice is drawn unmasked (`NovaUi_DrawThreeStateButton` copies it
    /// with a plain CopyBits). A missing art PICT is a 12×24 opaque black slot;
    /// a missing mask leaves its slot fully opaque — so a TC that ships no
    /// masks gets square, opaque caps, exactly as in the original.
    func buttonSlices(_ state: ButtonState) -> (left: CGImage?, middle: CGImage?, right: CGImage?) {
        let s: ThreeStateButton.State
        switch state {
        case .normal:  s = .normal
        case .clicked: s = .pressed
        case .grey:    s = .grey
        }
        return (maskedSlice(s, 0), slice(ThreeStateButton.artID(state: s, slice: 1)), maskedSlice(s, 2))
    }

    private func slice(_ id: Int) -> CGImage? {
        if let c = buttonSliceCache[id] { return c }
        let img = pict(id) ?? Self.blackSlot()
        buttonSliceCache[id] = img
        return img
    }

    private func maskedSlice(_ state: ThreeStateButton.State, _ index: Int) -> CGImage? {
        let id = ThreeStateButton.artID(state: state, slice: index)
        if let c = buttonSliceCache[id] { return c }
        guard let art = pict(id) else {
            let black = Self.blackSlot()
            buttonSliceCache[id] = black
            return black
        }
        let maskID = ThreeStateButton.maskID(state: state, slice: index)
        let masked: CGImage
        if game.resources.resource(NovaType.pict, maskID) != nil, let mask = pict(maskID) {
            masked = Self.apply(mask: mask, to: art) ?? art
        } else {
            masked = art   // no mask PICT: the slot's mask stays solid black → opaque
        }
        buttonSliceCache[id] = masked
        return masked
    }

    /// An opaque black 12×24 block: the slot the original leaves (painted
    /// black) for a missing button PICT.
    private static func blackSlot() -> CGImage? {
        let w = ThreeStateButton.missingSlotWidth, h = ThreeStateButton.missingSlotHeight
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Apply a mask PICT (drawn scaled into the art's slot, as `nv_DrawPict`
    /// does) as alpha: dark mask pixels keep the art, light ones clear it.
    private static func apply(mask: CGImage, to art: CGImage) -> CGImage? {
        let w = art.width, h = art.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        func rgba(_ img: CGImage) -> [UInt8]? {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        guard var px = rgba(art), let m = rgba(mask) else { return nil }
        for i in stride(from: 0, to: px.count, by: 4)
        where !ThreeStateButton.maskOpaque(r: m[i], g: m[i + 1], b: m[i + 2]) {
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
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
    /// "Bet" — the typed-amount wager (EC-26).
    static let bet = 59
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
    /// The payment window's buttons and the stellar comm's Release (STR# 150).
    static let acceptPrice = 30, lowerPrice = 31, release = 32
    static let requestLanding = -1   // no STR# entry — literal fallback only
}
