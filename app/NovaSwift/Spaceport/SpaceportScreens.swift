import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// The spaceport sub-screens, each drawn on its own EV Nova frame PICT: the Trade
// Center (8510), Outfitter (8502), Shipyard (8501) and Bar (8503). Item lists,
// prices and descriptions all come from the player's own data.

/// Default tons transacted per Buy/Sell tap. EV Nova buys one per click (and
/// more while held); we default to a handful so trading a full hold isn't a
/// hundred taps — but it's just the starting value for `TradeCenterView`'s
/// quantity control, which the player can edit to an exact tonnage (real
/// DITL #1003 "qty", the game's own type-an-amount prompt).
private let tradeStep = 10

/// Outfitter/Shipyard item-grid metrics, verified against the vendored NovaJS
/// reference (`nova/src/spaceport/item_grid.ts`: `TILE_SIZE = [83, 54]`,
/// `BOX_COUNT = [4, 5]`) — a fixed 4×5 grid of 83×54 tiles that scrolls one
/// ROW at a time (like the real game's up/down arrows), not page-by-page.
/// The grid's own rect is DITL #1002/#1004 item 4: (9,8)-(342,279), 333×271.
private let gridTileSize = CGSize(width: 83, height: 54)
private let gridCols = 4
private let gridRows = 5
private let gridSlotCount = gridCols * gridRows
private let gridHeight = gridTileSize.height * CGFloat(gridRows)

// MARK: - Trade Center (commodity exchange)

/// One row in the Trade dialog — a standard `Commodity` (which trades in both
/// directions wherever there's an exchange, at a Low/Med/High price) or a `jünk`
/// specialty good (which trades only at specific stellars, one flat BasePrice,
/// gated by `BuyOn`/`SellOn` and the SoldAt/BoughtAt stellar lists). Both are
/// stored in `state.cargo` keyed by `cargoID` (0-5 standard, 128+ junk).
private struct TradeRow: Identifiable {
    enum Origin {
        case commodity(PriceLevel)
        case junk(buy: Bool, sell: Bool)
    }
    let cargoID: Int
    let name: String
    let origin: Origin
    let price: Int
    var id: Int { cargoID }
    /// Whether Buy is allowed here at all (junk only trades where its stellar
    /// list + control bits permit; commodities always do at an exchange).
    var canBuyHere: Bool {
        switch origin { case .commodity: return true; case .junk(let b, _): return b }
    }
    var canSellHere: Bool {
        switch origin { case .commodity: return true; case .junk(_, let s): return s }
    }
}

struct TradeCenterView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    let galaxy: Galaxy
    /// Push a purchase/sale into the live HUD immediately (see
    /// `SpaceportView.onLiveSync`) — cargo bought here changes `cargoFree`,
    /// which the HUD's cargo readout needs to reflect right away.
    var onLiveSync: () -> Void = {}
    var onDone: () -> Void
    @Environment(\.novaTheme) private var theme

    @State private var selected = 0
    /// Tons the next Buy/Sell tap transacts — editable via `qtyControl`'s
    /// `TradeQuantityPrompt` (real DITL #1003) instead of only the fixed
    /// `tradeStep` default.
    @State private var pendingQty = tradeStep
    @State private var showQtyPrompt = false
    private var game: NovaGame { graphics.game }
    private var market: [TradeRow] {
        // Apply active öops disaster price deltas, then any rank PriceMod discount
        // for this port's government, on top of the base market (a food surplus
        // drops food; an affiliated rank shaves a percentage off every good).
        let activeOops: [Int] = pilot.state.activeDisasters.map { Array($0.keys) } ?? []
        let rankMult: Double = pilot.rankPriceMultiplier(govt: spob.government, game: game)
        var rows: [TradeRow] = game.commodityMarket(at: spob).map { row in
            let delta = game.disasterPriceDelta(spobID: spob.id, commodity: row.commodity, activeOops: activeOops)
            let price = max(1, Int((Double(row.price + delta) * rankMult).rounded()))
            return TradeRow(cargoID: row.commodity.cargoID, name: game.commodityName(row.commodity),
                            origin: .commodity(row.level), price: price)
        }
        // jünk specialty goods for *this* stellar: buyable where spob.id is in its
        // SoldAt list (and BuyOn passes), sellable where it's in BoughtAt (and
        // SellOn passes). A junk type the player is *carrying* is always listed so
        // they can see and unload it, even where it can't be traded. Junk has one
        // flat BasePrice (no Low/Med/High tier) — only the rank discount applies.
        for j in game.junks() {
            let buyHere = j.lows.contains(spob.id) && NCBTest(j.buyOn).evaluate(pilot.state)
            let sellHere = j.highs.contains(spob.id) && NCBTest(j.sellOn).evaluate(pilot.state)
            guard buyHere || sellHere || pilot.held(cargo: j.id) > 0 else { continue }
            let price = max(1, Int((Double(j.basePrice) * rankMult).rounded()))
            rows.append(TradeRow(cargoID: j.id, name: j.name,
                                 origin: .junk(buy: buyHere, sell: sellHere), price: price))
        }
        return rows
    }

    // Layout straight from DLOG/DITL #1001 "Trade" against the real 426×252
    // frame (PICT 8510; DLOG bounds agree exactly — centre 213,126):
    //   item 2      (38,9)-(390,26)     — column header strip
    //   items 3–10  (38,25)-(390,125)   — eight 352×13 commodity rows
    //   item 14     (41,190)-(387,214)  — the narrow status strip between the
    //                                     list panel and the button strip
    //   items 12/13/0 (60/166/272,221) 99×25 — Buy / Sell / Done, all INSIDE
    //                                     the frame's bottom grey strip
    // (Items 1/15/16 sit at y≥299, past the 252px frame — the stale-bounds
    // junk this dialog family carries; the previous layout had used invented
    // positions that pushed the whole control row below the artwork.)
    var body: some View {
        Group {
            if let frame = graphics.frame(.trade) {
                NovaMenu(frame: frame, overlay: true) { space in
                    list.frame(width: 352, alignment: .top).novaPlace(space, -175, -117)
                    statusLine.novaPlace(space, -172, 64)
                    // Option-click (real EV Nova's Alt-click) / long-press is an
                    // alternate route to the same quantity prompt the "×N per
                    // tap" label above already opens — the game's own documented
                    // shortcut, alongside the tap-to-edit affordance this port added.
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                               width: 73, enabled: canBuy,
                               onQuantity: canBuy ? { showQtyPrompt = true } : nil) { buy() }
                        .novaPlace(space, -153, 95)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                               width: 73, enabled: canSell,
                               onQuantity: canSell ? { showQtyPrompt = true } : nil) { sell() }
                        .novaPlace(space, -47, 95)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                               width: 73, action: onDone)
                        .novaPlace(space, 59, 95)
                }
            } else {
                fallback
            }
        }
        .sheet(isPresented: $showQtyPrompt) {
            TradeQuantityPrompt(title: qtyPromptTitle, range: 1...qtyUpperBound, initial: pendingQty,
                                 onConfirm: { pendingQty = $0; showQtyPrompt = false },
                                 onCancel: { showQtyPrompt = false })
        }
    }

    private var qtyPromptTitle: String {
        current.map { "How many tons of \($0.name)?" } ?? "How many tons?"
    }
    /// Advisory max for the prompt's field — the greater of what's affordable/
    /// holdable to buy and what's held to sell, so either action stays in
    /// range; `buyCargo`/`sellCargo` clamp again for real.
    private var qtyUpperBound: Int {
        guard let c = current else { return max(1, pendingQty) }
        let buyLimit = c.price > 0 ? min(pilot.cargoFree(galaxy: galaxy), pilot.state.credits / c.price) : pilot.cargoFree(galaxy: galaxy)
        let sellLimit = pilot.held(cargo: c.cargoID)
        return max(1, buyLimit, sellLimit)
    }

    // Column widths sum to the DITL rows' 352px; Geneva 10 fits the 13px row
    // pitch the DITL prescribes (the previous 11px text + 4px padding made
    // ~23px rows that overran the list panel).
    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NovaText("Commodity", size: 10, color: .gray, width: 160)
                NovaText("Price", size: 10, color: .gray, width: 62, align: .center)
                NovaText("Cost/ton", size: 10, color: .gray, width: 70, align: .center)
                NovaText("Hold", size: 10, color: .gray, width: 60, align: .trailing)
            }
            .frame(height: 17, alignment: .top)
            ForEach(Array(market.enumerated()), id: \.offset) { i, row in
                let held = pilot.held(cargo: row.cargoID)
                HStack(spacing: 0) {
                    NovaText(row.name, size: 10, color: theme.listText, width: 160)
                    NovaText(rowLabel(row), size: 10, color: rowLabelColor(row), width: 62, align: .center)
                    NovaText("\(row.price)", size: 10, color: theme.listText, width: 70, align: .center)
                    NovaText(held > 0 ? "\(held)" : "—", size: 10, color: held > 0 ? theme.listText : .gray, width: 60, align: .trailing)
                }
                .frame(height: 13)
                .background(i == selected ? theme.listHilite : theme.listBkgnd)
                .contentShape(Rectangle())
                .onTapGesture { selected = i }
            }
        }
    }

    /// DITL #1001 item 14 — the narrow strip between list and buttons. The
    /// game shows status text here; this port uses it for the credits readout,
    /// the tap-to-edit transaction quantity (real DITL #1003 "qty" prompt), and
    /// — when an `öops` disaster is active at this stellar — its name, per the
    /// Bible's "what's happening here" trade banner (`JUNK_OOPS_DESIGN.md` §B.5).
    private var statusLine: some View {
        HStack(spacing: 0) {
            Button { showQtyPrompt = true } label: {
                NovaText("×\(pendingQty) per tap", size: 10, color: .gray, width: 90)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let banner = disasterBanner {
                NovaText(banner, size: 10, color: Color(red: 1, green: 0.55, blue: 0.3), width: 126)
            }
            Spacer(minLength: 0)
            NovaText(pilot.state.credits.creditsAbbreviated, size: 10,
                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 130, align: .trailing)
        }
        .frame(width: 346, height: 24)
    }

    /// Active `öops` disaster names for this stellar, joined for display, or
    /// `nil` when none are active here right now.
    private var disasterBanner: String? {
        let activeOops = pilot.state.activeDisasters.map { Array($0.keys) } ?? []
        let names = game.activeDisasterNames(spobID: spob.id, activeOops: activeOops)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var current: TradeRow? {
        market.indices.contains(selected) ? market[selected] : nil
    }
    private var canBuy: Bool {
        guard let c = current, c.canBuyHere else { return false }
        return pilot.state.credits >= c.price && pilot.cargoFree(galaxy: galaxy) > 0
    }
    private var canSell: Bool {
        guard let c = current, c.canSellHere else { return false }
        return pilot.held(cargo: c.cargoID) > 0
    }
    private func buy() {
        guard let c = current else {
            Log.spaceport.error("Trade buy tapped with no commodity row selected at spöb \(spob.id, privacy: .public) — no-op")
            return
        }
        let free = pilot.cargoFree(galaxy: galaxy)
        let bought = pilot.buyCargo(id: c.cargoID, tons: pendingQty, unitPrice: c.price, cargoFree: free)
        if bought == 0 {
            Log.spaceport.notice("Trade buy no-op at spöb \(spob.id, privacy: .public): cargo=\(c.cargoID, privacy: .public) price=\(c.price, privacy: .public)cr/ton credits=\(pilot.state.credits, privacy: .public) cargoFree=\(free, privacy: .public)")
        } else {
            Log.spaceport.debug("Trade bought \(bought, privacy: .public)t of cargo \(c.cargoID, privacy: .public) @ \(c.price, privacy: .public)cr/ton at spöb \(spob.id, privacy: .public)")
            onLiveSync()
        }
    }
    private func sell() {
        guard let c = current else {
            Log.spaceport.error("Trade sell tapped with no commodity row selected at spöb \(spob.id, privacy: .public) — no-op")
            return
        }
        let held = pilot.held(cargo: c.cargoID)
        let sold = pilot.sellCargo(id: c.cargoID, tons: pendingQty, unitPrice: c.price)
        if sold == 0 {
            Log.spaceport.notice("Trade sell no-op at spöb \(spob.id, privacy: .public): cargo=\(c.cargoID, privacy: .public) held=\(held, privacy: .public) — nothing to sell")
        } else {
            Log.spaceport.debug("Trade sold \(sold, privacy: .public)t of cargo \(c.cargoID, privacy: .public) @ \(c.price, privacy: .public)cr/ton at spöb \(spob.id, privacy: .public)")
            onLiveSync()
        }
    }
    /// Middle "level" column text for a row: a standard commodity shows its
    /// Low/Med/High tier; a junk good shows the direction it trades here (Buy at
    /// a SoldAt stellar, Sell at a BoughtAt stellar, "—" when only carried).
    private func rowLabel(_ row: TradeRow) -> String {
        switch row.origin {
        case .commodity(let level): return level.label
        case .junk(let buy, let sell):
            if buy && sell { return "Trade" }
            if buy { return "Buy" }
            if sell { return "Sell" }
            return "—"
        }
    }
    private func rowLabelColor(_ row: TradeRow) -> Color {
        switch row.origin {
        case .commodity(let level): return levelColor(level)
        case .junk(let buy, let sell):
            if buy { return Color(red: 0.5, green: 0.9, blue: 0.5) }
            if sell { return Color(red: 1, green: 0.5, blue: 0.5) }
            return .gray
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
                Text("\(r.name)  \(rowLabel(r))  \(r.price)cr")
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
    var showHints: Bool = false
    /// Push a purchase/sale into the live HUD immediately (see
    /// `SpaceportView.onLiveSync`) — every outfit needs to *apply* the instant
    /// it's bought, not just look right in this dialog's own numbers.
    var onLiveSync: () -> Void = {}
    var onDone: () -> Void

    @State private var selectedID: Int?
    @State private var topRow = 0
    @State private var hintDismissed = false
    /// Non-nil while the quantity prompt is open — which of Buy/Sell opened it
    /// decides which transaction `transact(_:_:_:)` runs on confirm.
    @State private var qtyPromptMode: QtyPromptMode?
    private enum QtyPromptMode { case buy, sell }
    private var game: NovaGame { graphics.game }
    private var diplomacy: Diplomacy { galaxy.makeDiplomacy() }
    /// Port rank `PriceMod` discount for this spöb's govt (1.0 = none) — folded
    /// into the displayed price and every buy/sell transaction here.
    private var rankMult: Double { pilot.rankPriceMultiplier(govt: spob.government, game: game) }
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
        outfitterBody
            .gameHint(GameHints.outfitter, active: showHints, dismissed: $hintDismissed)
            .animation(.easeInOut(duration: 0.25), value: hintDismissed)
            .sheet(isPresented: Binding(get: { qtyPromptMode != nil }, set: { if !$0 { qtyPromptMode = nil } })) {
                if let mode = qtyPromptMode, let o = selected {
                    TradeQuantityPrompt(title: "How many \(o.displayName)?",
                                         range: 1...max(1, qtyUpperBound(mode, o)), initial: 1, unitLabel: "items",
                                         onConfirm: { qty in transact(mode, o, qty); qtyPromptMode = nil },
                                         onCancel: { qtyPromptMode = nil })
                }
            }
    }

    /// Advisory max for the quantity prompt's field — buy is capped by
    /// afford/mass/installed-cap headroom (checked properly, one unit at a
    /// time, by `buyOutfit(_:count:...)` itself); sell by how many are owned.
    private func qtyUpperBound(_ mode: QtyPromptMode, _ o: OutfRes) -> Int {
        switch mode {
        case .buy:
            guard pilot.canBuyOutfit(o, galaxy: galaxy, priceMultiplier: rankMult) else { return 1 }
            let cost = pilot.effectiveCost(o, galaxy: galaxy, priceMultiplier: rankMult)
            let affordable = cost > 0 ? pilot.state.credits / cost : Int.max
            let cap = pilot.maxInstallable(o, galaxy: galaxy)
            return cap > 0 ? min(affordable, max(0, cap - pilot.owned(outfit: o.id))) : affordable
        case .sell:
            return pilot.owned(outfit: o.id)
        }
    }

    private func transact(_ mode: QtyPromptMode, _ o: OutfRes, _ qty: Int) {
        switch mode {
        case .buy:
            let bought = pilot.buyOutfit(o, count: qty, galaxy: galaxy, priceMultiplier: rankMult)
            Log.spaceport.debug("Outfitter bought \(bought, privacy: .public)× outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public)")
            if bought > 0 { onLiveSync() }
        case .sell:
            let sold = pilot.sellOutfit(o, count: qty, galaxy: galaxy, priceMultiplier: rankMult)
            Log.spaceport.debug("Outfitter sold \(sold, privacy: .public)× outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public)")
            if sold > 0 { onLiveSync() }
        }
    }

    @ViewBuilder private var outfitterBody: some View {
        if let frame = graphics.frame(.outfit) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols), height: gridHeight)
                    .clipped().novaPlace(space, -373.5, -152.5)
                // DITL #1002 items 9/10: the real 25×25 up/down scroll-arrow
                // buttons at (148,288)/(178,288) — one row per tap.
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.up.fill",
                               enabled: currentTopRow > 0) { scroll(-1) }
                    .novaPlace(space, -234.5, 127.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.down.fill",
                               enabled: currentTopRow < maxTopRow) { scroll(1) }
                    .novaPlace(space, -204.5, 127.5)
                // Description pane — DITL #1002 item 5 (354,10)-(546,277),
                // 192×267 (was clipped to 185 tall, so long text was cut off).
                detail.frame(width: 190, height: 265, alignment: .topLeading)
                    .clipped().novaPlace(space, -28.5, -150.5)
                // Item picture — DITL #1002 item 7 (557,8)-(757,208), the full
                // 200×200 box. The art is a 200×200 canvas, so `.fill` makes it
                // fill the box edge-to-edge (was 190×185 with `.fit`, which
                // letterboxed the square art and left a black margin).
                if let o = selected, let pic = graphics.outfitPicture(o) {
                    Image(decorative: pic, scale: 1).interpolation(.high).resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200).clipped()
                        .novaPlace(space, 174.5, -152.5)
                }
                info(space)
                buttons(space)
            }
        } else {
            fallback
        }
    }

    private var rowCount: Int { max(1, (stock.count + gridCols - 1) / gridCols) }
    private var maxTopRow: Int { max(0, rowCount - gridRows) }
    private var currentTopRow: Int { min(topRow, maxTopRow) }
    private func scroll(_ delta: Int) { topRow = min(max(currentTopRow + delta, 0), maxTopRow) }
    /// The visible 4×5 window starting at `currentTopRow` (nil-padded).
    private var visibleItems: [OutfRes?] {
        let start = currentTopRow * gridCols
        let end = min(start + gridSlotCount, stock.count)
        var items: [OutfRes?] = start < end ? stock[start..<end].map { $0 } : []
        items += Array(repeating: nil, count: gridSlotCount - items.count)
        return items
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(gridTileSize.width), spacing: 0), count: gridCols), spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, o in
                if let o {
                    ItemTile(name: o.displayName, image: graphics.outfitPicture(o),
                             quantity: pilot.owned(outfit: o.id),
                             selected: (selectedID ?? stock.first?.id) == o.id,
                             locked: lockState(for: o) == .locked)
                        .onTapGesture { selectedID = o.id }
                } else {
                    Color.clear.frame(width: gridTileSize.width, height: gridTileSize.height)
                }
            }
        }
        // Mouse wheel / trackpad, touch drag, arrow keys and controller all
        // scroll by single rows (GridPagingModifier steps of 1 == one row).
        .gridPaging(currentPage: currentTopRow, pageCount: maxTopRow + 1) { topRow = $0 }
    }

    private var detail: some View {
        ScrollView(showsIndicators: false) {
            if let o = selected {
                NovaText(game.descText(o.id - 128 + 3000), size: 10, width: 184, align: .leading)
                    .padding(.top, 3).padding(.leading, 3)
            }
        }
    }

    private func info(_ space: NovaSpace) -> some View {
        let o = selected
        // "You Have" is the player's credit balance (matching the Shipyard's
        // info panel and the real game, e.g. "You Have: 2.34M cr") — NOT the
        // owned-quantity of the selected item, which is instead shown as the
        // small badge on the item's grid tile.
        return VStack(alignment: .leading, spacing: 8) {
            infoRow("Item Price:", o.map { pilot.effectiveCost($0, galaxy: galaxy, priceMultiplier: rankMult).creditsAbbreviated } ?? "—")
            infoRow("You Have:", pilot.state.credits.creditsAbbreviated)
            infoRow("Item Mass:", o.map { "\($0.mass) tons" } ?? "—")
            infoRow("Free Mass:", "\(pilot.freeMass(galaxy: galaxy)) tons")
            // Not in the real DITL #1002 layout (that dialog only ever showed free
            // *mass*, never cargo tons) — added so a Cargo Expansion's actual
            // effect (and a Mass Expansion freeing room to buy one) is visible the
            // instant it's bought, right here, instead of only in the Trade Center
            // or after the next takeoff. Reads live off `pilot` (`@ObservedObject`),
            // so it updates the moment `buyOutfit`/`sellOutfit` mutate `state`.
            infoRow("Cargo:", "\(pilot.cargoUsed())/\(pilot.cargoCapacity(galaxy: galaxy)) tons")
        }
        .frame(width: 150, alignment: .leading)
        // DITL #1002 item 8 (618,214)-(753,314) against the real 765×321 Outfit
        // frame (PICT 8502 — matches DLOG #1002's own bounds exactly): cx =
        // 618 − 382.5 ≈ 235, cy = 214 − 160.5 ≈ 53.
        .novaPlace(space, 235, 53)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            NovaText(label, size: 11, color: .gray, width: 74, align: .leading)
            NovaText(value, size: 11, width: 90, align: .leading, shrinkToFit: true)
        }
    }

    // Buy/Sell/Done are each placed independently rather than as one offset
    // HStack group (which had drifted the whole row ~150px to the right of
    // its authentic position). Positions re-derived directly from DITL #1002
    // items 6/3/0 — (288,289), (394,289), (500,289), all 99×25 — against the
    // real 765×321 Outfit frame (PICT 8502, confirmed via `novaswift-extract
    // pict`/`dlog`): cy = 289 − 160.5 ≈ 128 for the row; cx = itemLeft − 382.5.
    // (This lands within a couple px of the vendored NovaJS reference's
    // buy@(-100,126)/sell@(0,126)/done@(100,126) — that fix was already close;
    // this just anchors it to the game's own real dialog layout instead.)
    @ViewBuilder private func buttons(_ space: NovaSpace) -> some View {
        let o = selected
        let canBuy = o.map { pilot.canBuyOutfit($0, galaxy: galaxy, priceMultiplier: rankMult) && lockState(for: $0) == .available } ?? false
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                   width: 73, enabled: canBuy,
                   onQuantity: canBuy ? { qtyPromptMode = .buy } : nil) {
            guard let o else {
                Log.spaceport.error("Outfitter buy tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.buyOutfit(o, galaxy: galaxy, priceMultiplier: rankMult) {
                Log.spaceport.debug("Bought outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Outfitter buy no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) cost=\(o.cost, privacy: .public) credits=\(pilot.state.credits, privacy: .public) freeMass=\(pilot.freeMass(galaxy: galaxy), privacy: .public) — insufficient credits, mass, or max-installed reached")
            }
        }
        .novaPlace(space, -94, 128)
        let canSell = o.map { pilot.owned(outfit: $0.id) > 0 } ?? false
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                   width: 73, enabled: canSell,
                   onQuantity: canSell ? { qtyPromptMode = .sell } : nil) {
            guard let o else {
                Log.spaceport.error("Outfitter sell tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.sellOutfit(o, galaxy: galaxy, priceMultiplier: rankMult) {
                Log.spaceport.debug("Sold outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Outfitter sell no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) — none owned")
            }
        }
        .novaPlace(space, 12, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 73, action: onDone)
            .novaPlace(space, 118, 128)
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
    /// Push the purchase into the live HUD immediately (see `SpaceportView.onLiveSync`).
    var onLiveSync: () -> Void = {}
    var onDone: () -> Void

    @State private var selectedID: Int?
    @State private var topRow = 0
    /// The full Ship Info card, opened by tapping the large preview picture.
    @State private var showInfo = false
    private var game: NovaGame { graphics.game }
    /// Port rank `PriceMod` discount for this spöb's govt (1.0 = none) — applied
    /// to the new-hull cost in the displayed net price and the buy transaction.
    private var rankMult: Double { pilot.rankPriceMultiplier(govt: spob.government, game: game) }
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
        ZStack {
            shipyardMenu
            // Full Ship Info card over the shipyard (its own dimmed dialog, the
            // Bar sub-panel pattern) — tap-out or Done to dismiss.
            if showInfo {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showInfo = false }
                    .transition(.opacity)
                ShipInfoView(graphics: graphics, ship: selected,
                             priceText: selected.map {
                                 pilot.netPrice(of: $0, game: game, priceMultiplier: rankMult).creditsAbbreviated
                             },
                             onDone: { showInfo = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showInfo)
    }

    @ViewBuilder private var shipyardMenu: some View {
        if let frame = graphics.frame(.shipyard) {
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols), height: gridHeight)
                    .clipped().novaPlace(space, -373.5, -152.5)
                // DITL #1004 items 11/12: the real 25×25 up/down scroll-arrow
                // buttons at (141,288)/(171,288) — one row per tap.
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.up.fill",
                               enabled: currentTopRow > 0) { scroll(-1) }
                    .novaPlace(space, -241.5, 126.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.down.fill",
                               enabled: currentTopRow < maxTopRow) { scroll(1) }
                    .novaPlace(space, -211.5, 126.5)
                // Description pane — DITL #1004 item 5 (354,10)-(546,277),
                // 192×267 (was clipped to 185 tall, cutting the class blurb).
                detail.frame(width: 190, height: 265, alignment: .topLeading)
                    .clipped().novaPlace(space, -28.5, -150.5)
                // Ship picture — DITL #1004 item 7 (557,8)-(757,208), 200×200.
                if let s = selected, let picture = shipPicture(s) {
                    ShipyardPictureView(picture: picture)
                        .frame(width: 200, height: 200).clipped()
                        .novaPlace(space, 174.5, -152.5)
                }
                info(space)
                buttons(space)
            }
        } else {
            fallback
        }
    }

    private var rowCount: Int { max(1, (stock.count + gridCols - 1) / gridCols) }
    private var maxTopRow: Int { max(0, rowCount - gridRows) }
    private var currentTopRow: Int { min(topRow, maxTopRow) }
    private func scroll(_ delta: Int) { topRow = min(max(currentTopRow + delta, 0), maxTopRow) }
    private var visibleItems: [ShipRes?] {
        let start = currentTopRow * gridCols
        let end = min(start + gridSlotCount, stock.count)
        var items: [ShipRes?] = start < end ? stock[start..<end].map { $0 } : []
        items += Array(repeating: nil, count: gridSlotCount - items.count)
        return items
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(gridTileSize.width), spacing: 0), count: gridCols), spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, s in
                if let s {
                    let picture = shipPicture(s)
                    // No quantity badge for ships — unlike outfits, you can't
                    // own more than one of a hull, so a numeric "1" badge on
                    // your current ship's tile is meaningless noise (the real
                    // Shipyard grid doesn't show one at all).
                    ItemTile(name: s.displayName, image: picture?.image,
                             pixelated: picture?.isDedicated == false,
                             selected: (selectedID ?? stock.first?.id) == s.id,
                             locked: lockState(for: s) == .locked)
                        .onTapGesture { selectedID = s.id }
                } else {
                    Color.clear.frame(width: gridTileSize.width, height: gridTileSize.height)
                }
            }
        }
        .gridPaging(currentPage: currentTopRow, pageCount: maxTopRow + 1) { topRow = $0 }
    }

    /// The shipyard's dedicated display picture for a hull, falling back to the
    /// small in-flight sprite only if a plug-in ship doesn't define one.
    /// `isDedicated` distinguishes the two so callers can render the (tiny,
    /// pixel-art) fallback sprite crisply instead of blurring it to fill a box
    /// sized for the real, much larger shipyard art.
    private func shipPicture(_ s: ShipRes) -> (image: CGImage, isDedicated: Bool)? {
        if let pic = graphics.shipPicture(s) { return (pic, true) }
        if let frame = graphics.shipFallbackPicture(s) { return (frame, false) }
        Log.spaceport.error("Shipyard: no shipyard picture or flight sprite for ship \(s.id, privacy: .public) (\(s.name, privacy: .public)) — tile will show placeholder icon")
        return nil
    }

    /// Ship class descriptions live at `dësc` 13000–13767, one per hull, indexed
    /// from the first ship id. This is where the second-hand hulls explain
    /// themselves ("…not far from being consigned to the junk heap"), which is
    /// why the tile only ever shows the plain class name.
    private func classDescription(_ s: ShipRes) -> String {
        game.descText(13000 + s.id - 128)
    }

    // Wrapped in a ScrollView (like the Outfitter's) so the class description —
    // which for second-hand hulls runs several lines — scrolls instead of
    // clipping at the panel's bottom edge.
    private var detail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if let s = selected {
                    NovaText(s.displayName, size: 12, weight: .bold)
                    NovaText("Cargo: \(s.cargoSpace) tons", size: 10)
                    NovaText("Free mass: \(s.freeMass) tons", size: 10)
                    NovaText("Shield / Armor: \(s.shield) / \(s.armor)", size: 10)
                    NovaText("Guns / Turrets: \(s.maxGuns) / \(s.maxTurrets)", size: 10)
                    let blurb = classDescription(s)
                    if !blurb.isEmpty {
                        NovaText(blurb, size: 10, width: 184, align: .leading)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.top, 3).padding(.leading, 3)
            .frame(width: 190, alignment: .leading)
        }
    }

    private func info(_ space: NovaSpace) -> some View {
        let s = selected
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Price:", s.map { pilot.netPrice(of: $0, game: game, priceMultiplier: rankMult).creditsAbbreviated } ?? "—")
            infoRow("Trade-in:", pilot.tradeInValue(game: game).creditsAbbreviated)
            infoRow("You Have:", pilot.state.credits.creditsAbbreviated)
        }
        // DITL #1004 item 8 (614,214)-(757,314) against the real 765×323
        // Shipyard frame (PICT 8501 — matches DLOG #1004's own bounds
        // exactly): cx = 614 − 382.5 ≈ 232, cy = 214 − 161.5 ≈ 52.
        .novaPlace(space, 232, 52)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            NovaText(label, size: 11, color: .gray, width: 66, align: .leading)
            NovaText(value, size: 11, width: 100, align: .leading, shrinkToFit: true)
        }
    }

    // Buy/Done placed independently rather than as one offset HStack group
    // (which had drifted the whole row ~110-150px to the right of its
    // authentic position). Positions re-derived directly from DITL #1004
    // items 0/6 — (365,289) and (480,289), both 109×25 — against the real
    // 765×323 Shipyard frame: cy = 289 − 161.5 ≈ 128; cx = itemLeft − 382.5.
    // (Within a couple px of the vendored NovaJS reference's buy@(-20,126)/
    // done@(100,126) — that fix was already close; this anchors it to the
    // game's own real dialog layout instead.)
    @ViewBuilder private func buttons(_ space: NovaSpace) -> some View {
        let s = selected
        let canBuy = s.map {
            $0.id != pilot.state.shipType && pilot.state.credits >= pilot.netPrice(of: $0, game: game, priceMultiplier: rankMult)
                && lockState(for: $0) == .available
        } ?? false
        // DITL #1004 item 9 (253,289)-(342,314), 89×25 — the "Info" button (STR#
        // 150 index 48), which the original shipyard sits left of Buy Ship/Done to
        // open the detailed ship-info dialog. cx = 253 − 382.5 = −129.5.
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.info, fallback: "Info"),
                   width: 63, enabled: s != nil) { showInfo = true }
            .novaPlace(space, -129.5, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buyShip, fallback: "Buy Ship"),
                   width: 83, enabled: canBuy) {
            guard let s else {
                Log.spaceport.error("Shipyard buy tapped with no ship selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.buyShip(s, game: game, priceMultiplier: rankMult) {
                Log.spaceport.debug("Bought ship \(s.id, privacy: .public) (\(s.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(pilot.netPrice(of: s, game: game, priceMultiplier: rankMult), privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Shipyard buy no-op at spöb \(spob.id, privacy: .public): ship=\(s.id, privacy: .public) netPrice=\(pilot.netPrice(of: s, game: game, priceMultiplier: rankMult), privacy: .public) credits=\(pilot.state.credits, privacy: .public) — insufficient credits or already owned")
            }
        }
        .novaPlace(space, -18, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 83, action: onDone)
            .novaPlace(space, 98, 128)
    }

    private var fallback: some View {
        VStack { Text("Shipyard").foregroundStyle(.white); Button("Done", action: onDone) }.padding()
    }
}

// MARK: - Bar

struct BarView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    @EnvironmentObject private var appModel: AppModel

    @State private var showGambling = false
    @State private var showHire = false
    @State private var showHolovid = false
    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var rolledPatron = false
    @State private var showStoryGuide = false
    @State private var storyGuideFocusKey: String?
    private var game: NovaGame { graphics.game }
    /// EV Nova's bar description lives at `dësc` (spöb id + 9872).
    private var barText: String {
        let t = game.descText(spob.id + 9872)
        return t.isEmpty ? "The spaceport bar is quiet tonight." : t
    }

    // Layout straight from DLOG/DITL #1013 "Bar" against the real 263×185
    // frame (PICT 8503 — centre 131.5,92.5):
    //   item 6  (16,10)-(246,116)   — the bar description, in the top black panel
    //   item 4  (6,125)  146×26     — wide button, grey strip top-left
    //   item 2  (6,154)  146×26     — wide button, grey strip bottom-left
    //   item 1  (156,125) 99×26     — button, grey strip top-right
    //   item 0  (156,154) 99×26     — button, grey strip bottom-right
    // (Items 3/5/7-9 sit at y≥214, past the 185px frame — stale-bounds junk;
    // the previous layout had used those, floating Gamble/Leave below the
    // artwork over the hub text, which also exposed the button art's baked
    // grey bezel against a black background.)
    //
    // Bar missions are NOT a browsable list (that's the Mission BBS). Like the
    // real game, a patron approaches at most once per visit: the StoryEngine
    // rolls the bar-location offers (control-bit gates + random-appearance %)
    // and one of them, picked at random, is presented in the authentic Single
    // Mission dialog (DITL #1016) over the bar. Accept/refuse run the real
    // engine flow, so all mission bits fire.
    var body: some View {
        ZStack {
            Group {
                if let frame = graphics.frame(.bar) {
                    NovaMenu(frame: frame, overlay: true) { space in
                        ScrollView(showsIndicators: false) {
                            NovaText(barText, size: 10, width: 230, align: .leading)
                        }
                        .frame(width: 230, height: 106)
                        .novaPlace(space, -115.5, -82.5)
                        // Escorts are hired from the port's shipyard stock, so the
                        // option is only live where there's a shipyard to hire from.
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.hireEscort, fallback: "Hire Escort"),
                                   width: 120, enabled: spob.hasShipyard) { showHire = true }
                            .novaPlace(space, -125.5, 32.5)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.holovid, fallback: "Holovid"),
                                   width: 120) { showHolovid = true }
                            .novaPlace(space, -125.5, 61.5)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.gamble, fallback: "Gamble"),
                                   width: 73) { showGambling = true }
                            .novaPlace(space, 24.5, 32.5)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                                   width: 73, action: onDone)
                            .novaPlace(space, 24.5, 61.5)
                    }
                } else {
                    VStack {
                        Text(barText).foregroundStyle(.white).padding()
                        HStack {
                            Button("Gamble") { showGambling = true }
                            Button("Leave", action: onDone)
                        }
                    }
                }
            }

            if let offer = services.pendingOffer {
                Color.black.opacity(0.5).ignoresSafeArea().transition(.opacity)
                MissionSingleDialog(graphics: graphics, offer: offer, offered: [offer.mission],
                                    onPage: { _ in },
                                    onAccept: { accept(offer) }, onDecline: { decline(offer) },
                                    storylineTag: storylineTag(for: offer.mission.id),
                                    onOpenStoryline: storylineTag(for: offer.mission.id).map { t in { openStoryline(t.key) } })
            }

            if showGambling {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { showGambling = false }
                    .transition(.opacity)
                GamblingView(graphics: graphics, pilot: pilot, onDone: { showGambling = false })
            }

            if showHire {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { showHire = false }
                    .transition(.opacity)
                HireEscortView(graphics: graphics, spob: spob, pilot: pilot,
                               onDone: { showHire = false })
            }

            if showHolovid {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { showHolovid = false }
                    .transition(.opacity)
                HolovidView(graphics: graphics, spob: spob, pilot: pilot,
                            onDone: { showHolovid = false })
            }
        }
        .onAppear(perform: rollPatron)
        .storylineGuideSheet(isPresented: $showStoryGuide, game: game, player: { pilot.state },
                             storylineKey: storyGuideFocusKey)
    }

    /// One roll per bar visit: build the engine, gather the bar's real offers
    /// (already control-bit- and random-%-gated by `missionsOffered`), and have
    /// a random one of the eligible patrons make their pitch.
    private func rollPatron() {
        guard !rolledPatron else { return }
        rolledPatron = true
        let today = pilot.state.date.julianDay
        // One patron offer per bar per day. If this bar already took its daily
        // roll, don't roll again on re-entry — the original never re-pestered
        // the player with the same patron every time they walked back in, which
        // is what made the bar feel like it was throwing missions constantly.
        guard !pilot.state.barOffered(spob: spob.id, day: today) else { return }
        // Per-landing seed so which bar missions pass their random-appearance
        // roll actually varies day to day (the fixed default seed made the bar
        // present the same patron on every single visit).
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        // Mark the bar as having taken its daily roll *now* — whether or not a
        // patron actually turns up — so a re-entry today is a no-op.
        pilot.state.markBarOffered(spob: spob.id, day: today)
        pilot.save()
        // `missionsOffered` already applied each mission's AvailBits test and
        // random % — the survivors are genuinely on offer here right now. The
        // bar picks the highest-weighted one to make its pitch (deterministic
        // within a landing), skipping any with no briefing text to show.
        let offers = e.missionsOffered(at: .bar, spob: spob.id)
        guard let mission = offers.first(where: { !e.briefing(for: $0).isEmpty }) else {
            Log.spaceport.debug("Bar at spöb \(spob.id, privacy: .public): no eligible bar mission with briefing today")
            return
        }
        Log.spaceport.debug("Bar patron offers mission \(mission.id, privacy: .public) at spöb \(spob.id, privacy: .public) (of \(offers.count, privacy: .public) eligible)")
        e.present(mission)
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
    }

    private func decline(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
    }

    /// From the table prewarmed once per data set at load time
    /// (`GameDataController.prewarm()`) — no per-call rescan.
    private func storylineTag(for missionID: Int) -> MissionStorylineTag? {
        guard appModel.settings.showMissionStorylineTags else { return nil }
        return appModel.data.storylineTags[missionID]
    }

    private func openStoryline(_ key: String) {
        storyGuideFocusKey = key
        showStoryGuide = true
    }
}

// MARK: - Holovid (news)

/// The bar's **Holovid** screen — EV Nova's spaceport news broadcast. The beta
/// history calls this the "holovid dialog," where generic, disaster, and crön
/// news are shown; a `gövt` can supply a custom `NewsPic` backdrop, otherwise
/// the generic PICT 9000 is used. News is read here on demand (the original
/// never force-popped it on every landing) and comes from the same feed the day
/// clock drives, `StoryEngine.stationNews(forGovt:)`, resolved for this
/// station's government (local news, with the independent pool as fallback).
struct HolovidView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    private var game: NovaGame { graphics.game }

    /// The station government's own news id (≥128), used both to pick its custom
    /// backdrop and to resolve which local news applies.
    private var stationGovt: Int? { spob.government >= 128 ? spob.government : nil }

    /// Custom `gövt.NewsPic` backdrop, falling back to the generic news PICT 9000
    /// (Bible: `NewsPic < 128` ⇒ generic).
    private var newsPictID: Int {
        if let g = stationGovt.flatMap({ game.govt($0) }), g.newsPic >= 128 { return g.newsPic }
        return 9000
    }

    /// This station's live news feed, read on demand. Empty when nothing in the
    /// galaxy is currently generating news.
    private var news: [String] {
        StoryEngine(game: game, player: pilot.state,
                    seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
            .stationNews(forGovt: stationGovt)
    }

    var body: some View {
        let items = news
        let bodyText = items.isEmpty
            ? "The news networks are quiet. Nothing of note is happening in this region of the galaxy right now."
            : items.joined(separator: "\n\n")
        if let frame = graphics.pict(newsPictID) {
            let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
            let textW = fw * 0.80
            NovaMenu(frame: frame, overlay: true) { space in
                ScrollView(showsIndicators: false) {
                    NovaText(bodyText, size: 11, width: textW, align: .leading)
                }
                .frame(width: textW, height: fh * 0.58, alignment: .topLeading)
                .novaPlace(space, -textW / 2, -fh / 2 + 20)
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                           width: 96, action: onDone)
                    .novaPlace(space, -48, fh / 2 - 40)
            }
        } else {
            // No news backdrop art in the data — plain framed panel.
            VStack(spacing: 12) {
                NovaText("Galactic News Network", size: 14, weight: .bold)
                ScrollView(showsIndicators: false) {
                    NovaText(bodyText, size: 11, width: 300, align: .leading)
                }
                .frame(width: 300, height: 200)
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                           width: 96, action: onDone)
            }
            .padding(20)
            .frame(width: 360)
            .background(Color(white: 0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .novaResponsive()
        }
    }
}

/// The shipyard's large ship-preview picture. Dedicated shipyard art (large,
/// meant to fill the panel) scales smoothly to fit as before; the small
/// in-flight sprite fallback is instead capped to a modest integer upscale
/// and drawn with crisp, pixel-art (nearest-neighbor) sampling so a 24×24
/// sprite reads as a small crisp ship icon instead of a blurry, blown-up smear.
struct ShipyardPictureView: View {
    let picture: (image: CGImage, isDedicated: Bool)

    var body: some View {
        if picture.isDedicated {
            // The dedicated shipyard art is a full 200×200 canvas (ship on its
            // own backdrop), so fill the box edge-to-edge rather than fitting it
            // (which left a margin around the near-square art).
            Image(decorative: picture.image, scale: 1)
                .interpolation(.high).resizable().aspectRatio(contentMode: .fill)
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
    @Environment(\.novaTheme) private var theme

    // Tile chrome matches the vendored NovaJS reference (`item_grid.ts`
    // `ItemTile.draw()`): a black-filled 83×54 cell with a thin border — the
    // theme's grid colours (cölr.gridDim unselected / gridBright selected;
    // 0x404040 / 0xFF0000 in the base game) — not a translucent white overlay.
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
        .overlay(Rectangle().strokeBorder(selected ? theme.gridBright : theme.gridDim, lineWidth: 1))
        .opacity(locked ? 0.45 : 1)
        .saturation(locked ? 0 : 1)
        .contentShape(Rectangle())
    }
}

