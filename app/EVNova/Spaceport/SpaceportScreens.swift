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
    private var game: NovaGame { graphics.game }
    private var stock: [OutfRes] { game.outfitsSold(at: spob) }
    private var selected: OutfRes? {
        stock.first { $0.id == selectedID } ?? stock.first
    }

    var body: some View {
        if let frame = graphics.frame(.outfit) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: 318, height: 250).clipped().novaPlace(space, -373, -153)
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

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                ForEach(stock, id: \.id) { o in
                    ItemTile(name: o.name, image: graphics.outfitPicture(o),
                             quantity: pilot.owned(outfit: o.id),
                             selected: (selectedID ?? stock.first?.id) == o.id)
                        .onTapGesture { selectedID = o.id }
                }
            }
            .padding(4)
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
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Item Price:", o.map { creditString($0.cost) } ?? "—")
            infoRow("You Have:", o.map { "\(pilot.owned(outfit: $0.id))" } ?? "0")
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

    private func buttons(_ space: NovaSpace) -> some View {
        let o = selected
        return HStack(spacing: 14) {
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                       width: 52, enabled: o.map { pilot.canBuyOutfit($0, galaxy: galaxy) } ?? false) {
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
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                       width: 52, enabled: o.map { pilot.owned(outfit: $0.id) > 0 } ?? false) {
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
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 52, action: onDone)
        }
        .novaPlace(space, 62, 128)
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
    private var game: NovaGame { graphics.game }
    private var stock: [ShipRes] { game.shipsSold(at: spob) }
    private var selected: ShipRes? { stock.first { $0.id == selectedID } ?? stock.first }

    var body: some View {
        if let frame = graphics.frame(.shipyard) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: 318, height: 300).novaPlace(space, -373, -153)
                detail.frame(width: 205, height: 150).novaPlace(space, -27, -150)
                if let s = selected, let cg = shipImage(s) {
                    Image(decorative: cg, scale: 1).interpolation(.high).resizable().scaledToFit()
                        .frame(width: 190, height: 185).novaPlace(space, 178, -152)
                }
                info(space)
                buttons(space)
            }
        } else {
            fallback
        }
    }

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                ForEach(stock, id: \.id) { s in
                    ItemTile(name: s.name, image: shipImage(s),
                             quantity: s.id == pilot.state.shipType ? 1 : 0,
                             selected: (selectedID ?? stock.first?.id) == s.id)
                        .onTapGesture { selectedID = s.id }
                }
            }
            .padding(4)
        }
    }

    /// The shipyard's dedicated display picture for a hull, falling back to the
    /// small in-flight sprite only if a plug-in ship doesn't define one.
    private func shipImage(_ s: ShipRes) -> CGImage? {
        if let pic = graphics.shipPicture(s) { return pic }
        if let frame = game.shipSprite(s.id)?.frameCGImage(0) { return frame }
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

    private func buttons(_ space: NovaSpace) -> some View {
        let s = selected
        let canBuy = s.map { $0.id != pilot.state.shipType && pilot.state.credits >= pilot.netPrice(of: $0, game: game) } ?? false
        return HStack(spacing: 30) {
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buyShip, fallback: "Buy Ship"),
                       width: 70, enabled: canBuy) {
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
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 60, action: onDone)
        }
        .novaPlace(space, 90, 122)
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

// MARK: - Shared item tile

/// One tile in an outfitter/shipyard grid: the item's picture (or a placeholder),
/// its name, and an owned-quantity badge.
struct ItemTile: View {
    let name: String
    let image: CGImage?
    var quantity: Int = 0
    var selected: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).interpolation(.high).resizable().scaledToFit()
                } else {
                    Image(systemName: "shippingbox").foregroundStyle(.gray)
                }
            }
            .frame(width: 88, height: 34)
            NovaText(name, size: 9, width: 88, align: .center)
        }
        .frame(width: 92, height: 54)
        .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.03))
        .overlay(alignment: .topTrailing) {
            if quantity > 0 {
                NovaText("\(quantity)", size: 9, color: Color(red: 1, green: 0.85, blue: 0.4))
                    .padding(2)
            }
        }
        .overlay(Rectangle().strokeBorder(selected ? Color.white.opacity(0.5) : .clear))
        .contentShape(Rectangle())
    }
}
