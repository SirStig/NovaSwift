import SwiftUI
import EVNovaKit
import EVNovaEngine

// The spaceport sub-screens, each drawn on its own EV Nova frame PICT: the Trade
// Center (8510), Outfitter (8502), Shipyard (8501) and Bar (8503). Item lists,
// prices and descriptions all come from the player's own data.

private func creditString(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
}

/// Tons transacted per Buy/Sell tap. EV Nova buys one per click (and more while
/// held); we step by a handful so trading a full hold isn't a hundred taps.
private let tradeStep = 10

/// Outfitter/Shipyard item-grid metrics, verified against the vendored NovaJS
/// reference (`nova/src/spaceport/item_grid.ts`: `TILE_SIZE = [83, 54]`,
/// `BOX_COUNT = [4, 5]`) — a fixed, paged 4×5 grid of 83×54 tiles, not a
/// freeform wrapping scroll.
private let gridTileSize = CGSize(width: 83, height: 54)
private let gridCols = 4
private let gridRows = 5
private let gridPageSize = gridCols * gridRows

// MARK: - Trade Center (commodity exchange)

struct TradeCenterView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    let galaxy: Galaxy
    var onDone: () -> Void

    @State private var selected = 0
    private var game: NovaGame { graphics.game }
    private var market: [(commodity: Commodity, level: PriceLevel, price: Int)] {
        game.commodityMarket(at: spob)
    }

    var body: some View {
        if let frame = graphics.frame(.trade) {
            NovaMenu(frame: frame, overlay: true) { space in
                list.frame(width: 372).novaPlace(space, -186, -96)
                controls.novaPlace(space, -150, 92)
            }
        } else {
            fallback
        }
    }

    private var list: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                NovaText("Commodity", size: 10, color: .gray, width: 150)
                NovaText("Price", size: 10, color: .gray, width: 70, align: .center)
                NovaText("Cost/ton", size: 10, color: .gray, width: 80, align: .center)
                NovaText("Hold", size: 10, color: .gray, width: 60, align: .trailing)
            }
            ForEach(Array(market.enumerated()), id: \.offset) { i, row in
                let held = pilot.held(cargo: row.commodity.cargoID)
                HStack(spacing: 0) {
                    NovaText(game.commodityName(row.commodity), size: 11, width: 150)
                    NovaText(row.level.label, size: 11, color: levelColor(row.level), width: 70, align: .center)
                    NovaText("\(row.price)", size: 11, width: 80, align: .center)
                    NovaText(held > 0 ? "\(held)" : "—", size: 11, color: held > 0 ? .white : .gray, width: 60, align: .trailing)
                }
                .padding(.vertical, 2)
                .background(i == selected ? Color.white.opacity(0.14) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { selected = i }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                       width: 42, enabled: canBuy) { buy() }
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                       width: 42, enabled: canSell) { sell() }
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 42, action: onDone)
            NovaText(creditString(pilot.state.credits), size: 11,
                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 130, align: .trailing)
        }
    }

    private var current: (commodity: Commodity, level: PriceLevel, price: Int)? {
        market.indices.contains(selected) ? market[selected] : nil
    }
    private var canBuy: Bool {
        guard let c = current else { return false }
        return pilot.state.credits >= c.price && pilot.cargoFree(galaxy: galaxy) > 0
    }
    private var canSell: Bool {
        guard let c = current else { return false }
        return pilot.held(cargo: c.commodity.cargoID) > 0
    }
    private func buy() {
        guard let c = current else {
            Log.spaceport.error("Trade buy tapped with no commodity row selected at spöb \(spob.id, privacy: .public) — no-op")
            return
        }
        let free = pilot.cargoFree(galaxy: galaxy)
        let bought = pilot.buyCommodity(c.commodity, tons: tradeStep, unitPrice: c.price, cargoFree: free)
        if bought == 0 {
            Log.spaceport.notice("Trade buy no-op at spöb \(spob.id, privacy: .public): commodity=\(c.commodity.cargoID, privacy: .public) price=\(c.price, privacy: .public)cr/ton credits=\(pilot.state.credits, privacy: .public) cargoFree=\(free, privacy: .public)")
        } else {
            Log.spaceport.debug("Trade bought \(bought, privacy: .public)t of commodity \(c.commodity.cargoID, privacy: .public) @ \(c.price, privacy: .public)cr/ton at spöb \(spob.id, privacy: .public)")
        }
    }
    private func sell() {
        guard let c = current else {
            Log.spaceport.error("Trade sell tapped with no commodity row selected at spöb \(spob.id, privacy: .public) — no-op")
            return
        }
        let held = pilot.held(cargo: c.commodity.cargoID)
        let sold = pilot.sellCommodity(c.commodity, tons: tradeStep, unitPrice: c.price)
        if sold == 0 {
            Log.spaceport.notice("Trade sell no-op at spöb \(spob.id, privacy: .public): commodity=\(c.commodity.cargoID, privacy: .public) held=\(held, privacy: .public) — nothing to sell")
        } else {
            Log.spaceport.debug("Trade sold \(sold, privacy: .public)t of commodity \(c.commodity.cargoID, privacy: .public) @ \(c.price, privacy: .public)cr/ton at spöb \(spob.id, privacy: .public)")
        }
    }
    private func levelColor(_ l: PriceLevel) -> Color {
        switch l {
        case .low:  return Color(red: 0.5, green: 0.9, blue: 0.5)
        case .high: return Color(red: 1, green: 0.5, blue: 0.5)
        default:    return .white
        }
    }

    private var fallback: some View {
        VStack {
            ForEach(Array(market.enumerated()), id: \.offset) { _, r in
                Text("\(game.commodityName(r.commodity))  \(r.level.label)  \(r.price)cr")
                    .foregroundStyle(.white)
            }
            Button("Done", action: onDone)
        }.padding()
    }
}

// MARK: - Outfitter

struct OutfitterView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    let galaxy: Galaxy
    var onDone: () -> Void

    @State private var selectedID: Int?
    @State private var page = 0
    private var game: NovaGame { graphics.game }
    private var diplomacy: Diplomacy { galaxy.makeDiplomacy() }
    /// Tech-level-eligible, `BuyRandom`-rolled-in stock for today, with any
    /// items that opt into full hiding (Bible `oütf.Flags` 0x0100/0x4000)
    /// dropped when the player doesn't meet their Availability/Require and
    /// doesn't already own one.
    private var stock: [OutfRes] {
        game.outfitsSold(at: spob, day: pilot.state.date.julianDay).filter { lockState(for: $0) != .hidden }
    }
    private var selected: OutfRes? {
        stock.first { $0.id == selectedID } ?? stock.first
    }
    private func lockState(for o: OutfRes) -> LockState {
        game.lockState(for: o, pilot: pilot.state, at: spob, diplomacy: diplomacy)
    }

    var body: some View {
        if let frame = graphics.frame(.outfit) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols),
                           height: gridTileSize.height * CGFloat(gridRows))
                    .clipped().novaPlace(space, -373, -153)
                detail.frame(width: 205, height: 185).clipped().novaPlace(space, -27, -150)
                if let o = selected, let pic = graphics.outfitPicture(o) {
                    Image(decorative: pic, scale: 1).interpolation(.high).resizable().scaledToFit()
                        .frame(width: 190, height: 185).novaPlace(space, 178, -150)
                }
                info(space)
                buttons(space)
            }
        } else {
            fallback
        }
    }

    private var pageCount: Int { max(1, (stock.count + gridPageSize - 1) / gridPageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    /// One fixed page of exactly `gridCols`×`gridRows` slots (nil-padded), matching
    /// the authentic paged grid rather than a continuous scroll.
    private var pageItems: [OutfRes?] {
        let start = currentPage * gridPageSize
        let end = min(start + gridPageSize, stock.count)
        var items: [OutfRes?] = start < end ? stock[start..<end].map { $0 } : []
        items += Array(repeating: nil, count: gridPageSize - items.count)
        return items
    }

    private var grid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(gridTileSize.width), spacing: 0), count: gridCols), spacing: 0) {
                ForEach(Array(pageItems.enumerated()), id: \.offset) { _, o in
                    if let o {
                        ItemTile(name: o.name, image: graphics.outfitPicture(o),
                                 quantity: pilot.owned(outfit: o.id),
                                 selected: (selectedID ?? stock.first?.id) == o.id,
                                 locked: lockState(for: o) == .locked)
                            .onTapGesture { selectedID = o.id }
                    } else {
                        Color.clear.frame(width: gridTileSize.width, height: gridTileSize.height)
                    }
                }
            }
            Spacer(minLength: 0)
            GridPager(page: currentPage, pageCount: pageCount) { page = $0 }
        }
    }

    private var detail: some View {
        ScrollView(showsIndicators: false) {
            if let o = selected {
                NovaText(game.descText(o.id - 128 + 3000), size: 11, width: 195, align: .leading)
            }
        }
    }

    private func info(_ space: NovaSpace) -> some View {
        let o = selected
        // "You Have" is the player's credit balance (matching the Shipyard's
        // info panel and the real game, e.g. "You Have: 2.34M cr") — NOT the
        // owned-quantity of the selected item, which is instead shown as the
        // small badge on the item's grid tile.
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Item Price:", o.map { creditString($0.cost) } ?? "—")
            infoRow("You Have:", creditString(pilot.state.credits))
            infoRow("Item Mass:", o.map { "\($0.mass) tons" } ?? "—")
            infoRow("Available:", "\(pilot.freeMass(galaxy: galaxy)) tons")
        }
        .frame(width: 150, alignment: .leading)
        .novaPlace(space, 232, 54)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            NovaText(label, size: 11, color: .gray, width: 74, align: .leading)
            NovaText(value, size: 11, width: 90, align: .leading)
        }
    }

    // Buy/Sell/Done are each placed independently (matching the vendored
    // NovaJS reference `nova/src/spaceport/outfitter.ts`: buy@(-100,126),
    // sell@(0,126), done@(100,126), width 60) rather than as one offset
    // HStack group, which had drifted the whole row ~150px to the right of
    // its authentic position.
    @ViewBuilder private func buttons(_ space: NovaSpace) -> some View {
        let o = selected
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                   width: 60, enabled: o.map { pilot.canBuyOutfit($0, galaxy: galaxy) && lockState(for: $0) == .available } ?? false) {
            guard let o else {
                Log.spaceport.error("Outfitter buy tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.buyOutfit(o, galaxy: galaxy) {
                Log.spaceport.debug("Bought outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
            } else {
                Log.spaceport.notice("Outfitter buy no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) cost=\(o.cost, privacy: .public) credits=\(pilot.state.credits, privacy: .public) freeMass=\(pilot.freeMass(galaxy: galaxy), privacy: .public) — insufficient credits, mass, or max-installed reached")
            }
        }
        .novaPlace(space, -100, 126)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                   width: 60, enabled: o.map { pilot.owned(outfit: $0.id) > 0 } ?? false) {
            guard let o else {
                Log.spaceport.error("Outfitter sell tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.sellOutfit(o) {
                Log.spaceport.debug("Sold outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
            } else {
                Log.spaceport.notice("Outfitter sell no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) — none owned")
            }
        }
        .novaPlace(space, 0, 126)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 60, action: onDone)
            .novaPlace(space, 100, 126)
    }

    private var fallback: some View {
        VStack { Text("Outfitter").foregroundStyle(.white); Button("Done", action: onDone) }.padding()
    }
}

// MARK: - Shipyard

struct ShipyardView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    let galaxy: Galaxy
    var onDone: () -> Void

    @State private var selectedID: Int?
    @State private var page = 0
    private var game: NovaGame { graphics.game }
    /// Tech-level-eligible, `BuyRandom`-rolled-in stock for today, with any
    /// hulls that opt into full hiding (Bible `shïp.Flags3` 0x0100/0x0200)
    /// dropped when the player doesn't meet their Availability/Require and
    /// don't already fly one.
    private var stock: [ShipRes] {
        game.shipsSold(at: spob, day: pilot.state.date.julianDay).filter { lockState(for: $0) != .hidden }
    }
    private var selected: ShipRes? { stock.first { $0.id == selectedID } ?? stock.first }
    private func lockState(for s: ShipRes) -> LockState {
        game.lockState(for: s, pilot: pilot.state)
    }

    var body: some View {
        if let frame = graphics.frame(.shipyard) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols),
                           height: gridTileSize.height * CGFloat(gridRows))
                    .novaPlace(space, -373, -153)
                detail.frame(width: 205, height: 150).novaPlace(space, -27, -150)
                if let s = selected, let picture = shipPicture(s) {
                    ShipyardPictureView(picture: picture)
                        .frame(width: 190, height: 185).novaPlace(space, 178, -152)
                }
                info(space)
                buttons(space)
            }
        } else {
            fallback
        }
    }

    private var pageCount: Int { max(1, (stock.count + gridPageSize - 1) / gridPageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var pageItems: [ShipRes?] {
        let start = currentPage * gridPageSize
        let end = min(start + gridPageSize, stock.count)
        var items: [ShipRes?] = start < end ? stock[start..<end].map { $0 } : []
        items += Array(repeating: nil, count: gridPageSize - items.count)
        return items
    }

    private var grid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(gridTileSize.width), spacing: 0), count: gridCols), spacing: 0) {
                ForEach(Array(pageItems.enumerated()), id: \.offset) { _, s in
                    if let s {
                        let picture = shipPicture(s)
                        ItemTile(name: s.name, image: picture?.image,
                                 pixelated: picture?.isDedicated == false,
                                 quantity: s.id == pilot.state.shipType ? 1 : 0,
                                 selected: (selectedID ?? stock.first?.id) == s.id,
                                 locked: lockState(for: s) == .locked)
                            .onTapGesture { selectedID = s.id }
                    } else {
                        Color.clear.frame(width: gridTileSize.width, height: gridTileSize.height)
                    }
                }
            }
            Spacer(minLength: 0)
            GridPager(page: currentPage, pageCount: pageCount) { page = $0 }
        }
    }

    /// The shipyard's dedicated display picture for a hull, falling back to the
    /// small in-flight sprite only if a plug-in ship doesn't define one.
    /// `isDedicated` distinguishes the two so callers can render the (tiny,
    /// pixel-art) fallback sprite crisply instead of blurring it to fill a box
    /// sized for the real, much larger shipyard art.
    private func shipPicture(_ s: ShipRes) -> (image: CGImage, isDedicated: Bool)? {
        if let pic = graphics.shipPicture(s) { return (pic, true) }
        if let frame = game.shipSprite(s.id)?.frameCGImage(0) { return (frame, false) }
        Log.spaceport.error("Shipyard: no shipyard picture or flight sprite for ship \(s.id, privacy: .public) (\(s.name, privacy: .public)) — tile will show placeholder icon")
        return nil
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = selected {
                NovaText(s.name, size: 13, weight: .bold)
                NovaText("Cargo: \(s.cargoSpace) tons", size: 11)
                NovaText("Free mass: \(s.freeMass) tons", size: 11)
                NovaText("Shield / Armor: \(s.shield) / \(s.armor)", size: 11)
                NovaText("Guns / Turrets: \(s.maxGuns) / \(s.maxTurrets)", size: 11)
            }
        }
        .frame(width: 200, alignment: .leading)
    }

    private func info(_ space: NovaSpace) -> some View {
        let s = selected
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Price:", s.map { creditString(pilot.netPrice(of: $0, game: game)) } ?? "—")
            infoRow("Trade-in:", creditString(pilot.tradeInValue(game: game)))
            infoRow("You Have:", creditString(pilot.state.credits))
        }
        .novaPlace(space, 232, 54)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            NovaText(label, size: 11, color: .gray, width: 66, align: .leading)
            NovaText(value, size: 11, width: 100, align: .leading)
        }
    }

    // Buy/Done placed independently (matching the vendored NovaJS reference
    // `nova/src/spaceport/shipyard.ts`: buy@(-20,126), done@(100,126), width 60)
    // rather than as one offset HStack group, which had drifted the whole row
    // ~110-150px to the right of its authentic position.
    @ViewBuilder private func buttons(_ space: NovaSpace) -> some View {
        let s = selected
        let canBuy = s.map {
            $0.id != pilot.state.shipType && pilot.state.credits >= pilot.netPrice(of: $0, game: game)
                && lockState(for: $0) == .available
        } ?? false
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buyShip, fallback: "Buy Ship"),
                   width: 60, enabled: canBuy) {
            guard let s else {
                Log.spaceport.error("Shipyard buy tapped with no ship selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.buyShip(s, game: game) {
                Log.spaceport.debug("Bought ship \(s.id, privacy: .public) (\(s.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(pilot.netPrice(of: s, game: game), privacy: .public)cr")
            } else {
                Log.spaceport.notice("Shipyard buy no-op at spöb \(spob.id, privacy: .public): ship=\(s.id, privacy: .public) netPrice=\(pilot.netPrice(of: s, game: game), privacy: .public) credits=\(pilot.state.credits, privacy: .public) — insufficient credits or already owned")
            }
        }
        .novaPlace(space, -20, 126)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 60, action: onDone)
            .novaPlace(space, 100, 126)
    }

    private var fallback: some View {
        VStack { Text("Shipyard").foregroundStyle(.white); Button("Done", action: onDone) }.padding()
    }
}

// MARK: - Bar

struct BarView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    var onDone: () -> Void

    private var game: NovaGame { graphics.game }
    /// EV Nova's bar description lives at `dësc` (spöb id + 9872).
    private var barText: String {
        let t = game.descText(spob.id + 9872)
        return t.isEmpty ? "The spaceport bar is quiet tonight." : t
    }

    var body: some View {
        if let frame = graphics.frame(.bar) {
            NovaMenu(frame: frame, overlay: true) { space in
                ScrollView(showsIndicators: false) {
                    NovaText(barText, size: 11, width: 220, align: .leading)
                }
                .frame(width: 220, height: 120)
                .novaPlace(space, -112, -80)
                NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Leave"),
                           width: 60, action: onDone)
                    .novaPlace(space, -43, 62)
            }
        } else {
            VStack { Text(barText).foregroundStyle(.white).padding(); Button("Leave", action: onDone) }
        }
    }
}

/// The shipyard's large ship-preview picture. Dedicated shipyard art (large,
/// meant to fill the panel) scales smoothly to fit as before; the small
/// in-flight sprite fallback is instead capped to a modest integer upscale
/// and drawn with crisp, pixel-art (nearest-neighbor) sampling so a 24×24
/// sprite reads as a small crisp ship icon instead of a blurry, blown-up smear.
private struct ShipyardPictureView: View {
    let picture: (image: CGImage, isDedicated: Bool)

    var body: some View {
        if picture.isDedicated {
            Image(decorative: picture.image, scale: 1)
                .interpolation(.high).resizable().scaledToFit()
        } else {
            let native = CGSize(width: picture.image.width, height: picture.image.height)
            let cappedScale: CGFloat = 4
            let size = CGSize(width: native.width * cappedScale, height: native.height * cappedScale)
            Image(decorative: picture.image, scale: 1)
                .interpolation(.none).resizable()
                .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Shared item tile

/// One tile in an outfitter/shipyard grid: the item's picture (or a placeholder),
/// its name, and an owned-quantity badge.
struct ItemTile: View {
    let name: String
    let image: CGImage?
    /// True when `image` is a small in-flight sprite standing in for missing
    /// dedicated art (see `ShipyardView.shipPicture`) — sampled with crisp
    /// nearest-neighbor scaling instead of the blur smooth interpolation gives
    /// a tiny sprite stretched to fill this tile.
    var pixelated: Bool = false
    var quantity: Int = 0
    var selected: Bool = false
    /// Mission/story-gated: still shown (Bible default), but can't be bought
    /// right now. Dimmed the way the Bible's `cölr.GridDim` describes.
    var locked: Bool = false

    // Tile chrome matches the vendored NovaJS reference (`item_grid.ts`
    // `ItemTile.draw()`): a black-filled 83×54 cell with a thin border — dim
    // gray (0x404040) unselected, bright red (0xFF0000) selected — not a
    // translucent white overlay.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            VStack(spacing: 0) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(pixelated ? .none : .high)
                        .resizable().scaledToFit()
                        .padding(.top, 1)
                } else {
                    Image(systemName: "shippingbox").foregroundStyle(.gray)
                }
                Spacer(minLength: 0)
                NovaText(name, size: 10, width: gridTileSize.width, align: .center)
            }
            if quantity > 0 {
                NovaText("\(quantity)", size: 10, align: .trailing)
                    .padding(.trailing, 2).padding(.top, 1)
            }
        }
        .frame(width: gridTileSize.width, height: gridTileSize.height)
        .overlay(Rectangle().strokeBorder(selected ? Color(red: 1, green: 0, blue: 0) : Color(white: 0.25), lineWidth: 1))
        .opacity(locked ? 0.45 : 1)
        .saturation(locked ? 0 : 1)
        .contentShape(Rectangle())
    }
}

/// Discrete-page up/down control for the Outfitter/Shipyard grids. The real
/// game's paging arrows are a small clickable control near the grid's bottom
/// edge; the exact baked icon asset wasn't identified in the base data
/// (`cicn` 10000–10023 are cursor graphics, not scroll arrows), so this uses
/// plain chevrons in the game's button-red accent rather than invented art.
private struct GridPager: View {
    let page: Int
    let pageCount: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.up", enabled: page > 0) { onChange(page - 1) }
            arrow("chevron.down", enabled: page < pageCount - 1) { onChange(page + 1) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2).padding(.top, 2)
    }

    private func arrow(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .background(Circle().fill(enabled ? Color(red: 0.75, green: 0.15, blue: 0.15) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
