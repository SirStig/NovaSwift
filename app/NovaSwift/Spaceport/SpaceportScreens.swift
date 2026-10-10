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

/// One row in the Trade dialog: a standard `Commodity` at its Low/Med/High
/// price, or one of the two junk rows (a junk this stellar buys, priced high;
/// one it sells, priced low). Both trade in either direction, as in the
/// original (0x0048c730). Stored in `state.cargo` keyed by `cargoID` (0-5
/// standard, 128+ junk).
private struct TradeRow: Identifiable {
    let cargoID: Int
    let name: String
    let level: PriceLevel
    let price: Int
    /// The two junk rows can name the same junk, so rows are keyed by
    /// commodity and level.
    var id: Int { cargoID * 8 + level.rawValue }
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
    /// The trade center's rows (`LandedServices.tradeRows`): the price scale
    /// follows the system reputation and domination, an active disaster
    /// replaces a price, and at most one junk row each way. Rank `PriceMod`
    /// never reaches commodities.
    private var market: [TradeRow] {
        LandedServices.tradeRows(at: spob, state: pilot.state, game: game).map { row in
            let name = Commodity.standard(cargoID: row.cargoID).map(game.commodityName)
                ?? game.junk(row.cargoID)?.name ?? "\(row.cargoID)"
            return TradeRow(cargoID: row.cargoID, name: name, level: row.level, price: row.price)
        }
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
                // Rects resolve through DITL #1001 (stock rects as fallback).
                let d = DITLPlacement(graphics.game, 1001, frame: frame)
                NovaMenu(frame: frame, overlay: true) { space in
                    let header = d.rect(2, top: 9, left: 38, bottom: 26, right: 390)
                    list.frame(width: header.width, alignment: .top).ditlPlace(space, d, header)
                    statusLine.ditlPlace(space, d, d.rect(14, top: 190, left: 41, bottom: 214, right: 387))
                    // Option-click (real EV Nova's Alt-click) / long-press is an
                    // alternate route to the same quantity prompt the "×N per
                    // tap" label above already opens — the game's own documented
                    // shortcut, alongside the tap-to-edit affordance this port added.
                    let buyRect = d.rect(12, top: 221, left: 60, bottom: 246, right: 159)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                               ditl: buyRect, enabled: canBuy,
                               onQuantity: canBuy ? { showQtyPrompt = true } : nil) { buy() }
                        .ditlPlace(space, d, buyRect)
                    let sellRect = d.rect(13, top: 221, left: 166, bottom: 246, right: 265)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                               ditl: sellRect, enabled: canSell,
                               onQuantity: canSell ? { showQtyPrompt = true } : nil) { sell() }
                        .ditlPlace(space, d, sellRect)
                    let doneRect = d.rect(0, top: 221, left: 272, bottom: 246, right: 371)
                    NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                               ditl: doneRect, action: onDone)
                        .ditlPlace(space, d, doneRect)
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
        let sellLimit = pilot.held(cargo: c.cargoID, game: game)
        return max(1, buyLimit, sellLimit)
    }

    // Column widths sum to the DITL rows' 352px; Geneva 10 fits the 13px row
    // pitch the DITL prescribes (the previous 11px text + 4px padding made
    // ~23px rows that overran the list panel).
    private var list: some View {
        VStack(spacing: 0) {
            // Column headers from STR# 2002 (0x0048d6f0): #197, the price
            // level #200, and the hold — #198 when the fleet carries more than
            // the ship, else #199.
            HStack(spacing: 0) {
                NovaText(misc(197, "Commodity"), size: 10, color: .gray, width: 160)
                NovaText(misc(200, "Price"), size: 10, color: .gray, width: 62, align: .center)
                NovaText("", size: 10, color: .gray, width: 70, align: .center)
                NovaText(misc(shipCapacity < pilot.cargoCapacity(galaxy: galaxy) ? 198 : 199, "Hold"),
                         size: 10, color: .gray, width: 60, align: .trailing)
            }
            .frame(height: 17, alignment: .top)
            ForEach(Array(market.enumerated()), id: \.offset) { i, row in
                let held = pilot.held(cargo: row.cargoID, game: game)
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
                // Tap alone left the commodity rows unselectable by the
                // controller cursor — on tvOS, where the cursor is the only
                // pointer, the Trade Center could not be used at all.
                .cursorClickable { selected = i }
            }
        }
    }

    /// DITL #1001 item 14 — the narrow strip between list and buttons: the
    /// original's status text (0x0048d6f0) — mission and junk cargo aboard,
    /// the ship's free space and, with freighter escorts, theirs — and the
    /// first active disaster's sentence.
    private var statusLine: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                NovaText(LandedServices.tradeStatus(state: pilot.state, game: game,
                                                    shipCapacity: shipCapacity,
                                                    fleetCapacity: pilot.cargoCapacity(galaxy: galaxy),
                                                    junkRows: Set(market.map(\.cargoID).filter { $0 >= 128 }))
                            .replacingOccurrences(of: "\r", with: "\n"),
                         size: 10, color: .gray, width: 346, align: .leading)
                if let line = LandedServices.tradeDisasterLine(at: spob.id, state: pilot.state, game: game) {
                    NovaText(line, size: 10, color: Color(red: 1, green: 0.55, blue: 0.3), width: 346, align: .leading)
                }
            }
        }
        .frame(width: 346, height: 24)
    }

    private var shipCapacity: Int { PilotEconomy.shipCargoCapacity(pilot.state, galaxy: galaxy) }

    private func misc(_ n: Int, _ fallback: String) -> String {
        let s = game.stringList(2002)?.string(at: n) ?? ""
        return s.isEmpty ? fallback : s
    }

    private var current: TradeRow? {
        market.indices.contains(selected) ? market[selected] : nil
    }
    private var canBuy: Bool {
        guard let c = current else { return false }
        return pilot.state.credits >= c.price && pilot.cargoFree(galaxy: galaxy) > 0
    }
    private var canSell: Bool {
        guard let c = current else { return false }
        return pilot.held(cargo: c.cargoID, game: game) > 0
    }
    private func buy() {
        guard let c = current else {
            Log.spaceport.error("Trade buy tapped with no commodity row selected at spöb \(spob.id, privacy: .public) — no-op")
            return
        }
        let free = pilot.cargoFree(galaxy: galaxy)
        let bought = pilot.buyCargo(id: c.cargoID, tons: min(pendingQty, 32000), unitPrice: c.price, cargoFree: free)
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
        let held = pilot.held(cargo: c.cargoID, game: game)
        let sold = pilot.sellCargo(id: c.cargoID, tons: min(pendingQty, 32000), unitPrice: c.price, game: game)
        if sold == 0 {
            Log.spaceport.notice("Trade sell no-op at spöb \(spob.id, privacy: .public): cargo=\(c.cargoID, privacy: .public) held=\(held, privacy: .public) — nothing to sell")
        } else {
            Log.spaceport.debug("Trade sold \(sold, privacy: .public)t of cargo \(c.cargoID, privacy: .public) @ \(c.price, privacy: .public)cr/ton at spöb \(spob.id, privacy: .public)")
            onLiveSync()
        }
    }
    /// Middle "level" column text for a row: Low/Med/High.
    private func rowLabel(_ row: TradeRow) -> String { row.level.label }
    private func rowLabelColor(_ row: TradeRow) -> Color { levelColor(row.level) }
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
    /// What the player owned when this outfitter opened: units beyond it were
    /// bought this visit and sell back at full price, the rest at half (EC-07).
    @State private var ownedAtOpen: [Int: Int]?
    /// Tech-level-eligible, `BuyRandom`-rolled-in stock for today, with any
    /// items that opt into full hiding (Bible `oütf.Flags` 0x0100/0x4000)
    /// dropped when the player doesn't meet their Availability/Require and
    /// doesn't already own one.
    private var stock: [OutfRes] {
        let sold = game.outfitsSold(at: spob, day: pilot.state.date.julianDay, owned: ownedIDs)
            .filter { lockState(for: $0) != .hidden }
        let stocked = Set(sold.map(\.id))
        let extras = sellBackOnly(excluding: stocked)
        return extras.isEmpty ? sold : sold + extras
    }

    /// Owned outfits this port will *buy back* but isn't stocking today. An
    /// outfit the grid doesn't list can't even be selected, so anything missing
    /// from here is an item the player can see on their ship and never unload.
    ///
    /// Three Bible rules put an item here:
    ///
    /// - The port's own tech level. `spöb.Flags2` 0x0400 is worded "it can buy
    ///   any nonpermanent outfits the player owns, **regardless of tech level**"
    ///   — so the *baseline*, without that flag, is that an outfitter buys back
    ///   what its tech level covers. What it happens to have in stock today is a
    ///   separate thing: `oütf.BuyRandom` re-rolls the shelves daily and
    ///   `Flags` 0x1000 suppresses same-weight siblings, and listing only that
    ///   roll meant a fitted turret was sellable one day and invisible the next.
    /// - `spöb.Flags2` 0x0400: this outfitter takes anything at all.
    /// - `oütf.Flags` 0x0800, "This item can be sold anywhere, regardless of
    ///   tech level, requirements, or mission bits" — sell-side only, so it
    ///   never widens what's for *sale* (see OUTFITTERS.md §3.5).
    ///
    /// "Nonpermanent" is the Bible's own qualifier: an `oütf.Flags` 0x0008
    /// ("can't be sold") item — a license, a story grant — is never bought back,
    /// so it isn't padded into the grid as a tile that can only be looked at.
    private func sellBackOnly(excluding stocked: Set<Int>) -> [OutfRes] {
        pilot.state.outfits
            .filter { $0.value > 0 && !stocked.contains($0.key) }
            .keys.compactMap { game.outfit($0) }
            .filter { !$0.cannotBeSold }
            .filter { spob.buysAnyOutfit || $0.ignoresRequirements
                       || game.sells(techLevel: $0.techLevel, at: spob) }
            .sorted { $0.id < $1.id }
    }

    /// Owned outfits skip the day's `BuyRandom` roll (the original zeroes it).
    private var ownedIDs: Set<Int> { Set(pilot.state.outfits.filter { $0.value > 0 }.keys) }

    /// Units of `o` owned when the outfitter opened.
    private func ownedAtOpen(_ o: OutfRes) -> Int? { ownedAtOpen.map { $0[o.id] ?? 0 } }

    /// Outfits listed for sell-back only — they can be sold here but never bought.
    private var sellOnlyIDs: Set<Int> {
        let stocked = Set(game.outfitsSold(at: spob, day: pilot.state.date.julianDay, owned: ownedIDs).map(\.id))
        return Set(sellBackOnly(excluding: stocked).map(\.id))
    }
    private var selected: OutfRes? {
        stock.first { $0.id == selectedID } ?? stock.first
    }
    private func lockState(for o: OutfRes) -> LockState {
        game.lockState(for: o, pilot: pilot.state, at: spob, diplomacy: diplomacy)
    }

    var body: some View {
        outfitterBody
            .onAppear { if ownedAtOpen == nil { ownedAtOpen = pilot.state.outfits } }
            .gameHint(GameHints.outfitter, active: showHints, dismissed: $hintDismissed)
            .animation(.easeInOut(duration: 0.25), value: hintDismissed)
            .sheet(isPresented: Binding(get: { qtyPromptMode != nil }, set: { if !$0 { qtyPromptMode = nil } })) {
                if let mode = qtyPromptMode, let o = selected {
                    TradeQuantityPrompt(title: "How many \(o.lowercasePluralDisplayName)?",
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
            guard pilot.canBuyOutfit(o, galaxy: galaxy) else { return 1 }
            let cost = pilot.effectiveCost(o, galaxy: galaxy)
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
            let bought = pilot.buyOutfit(o, count: qty, galaxy: galaxy)
            Log.spaceport.debug("Outfitter bought \(bought, privacy: .public)× outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public)")
            if bought > 0 { onLiveSync() }
        case .sell:
            let sold = pilot.sellOutfit(o, count: qty, galaxy: galaxy, ownedAtOpen: ownedAtOpen(o))
            Log.spaceport.debug("Outfitter sold \(sold, privacy: .public)× outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public)")
            if sold > 0 { onLiveSync() }
        }
    }

    @ViewBuilder private var outfitterBody: some View {
        if let frame = graphics.frame(.outfit) {
            // Every item follows DITL #1002 from the loaded data (stock
            // positions below, shifted by however far a plug-in moves them).
            let d = DITLPlacement(graphics.game, 1002, frame: frame)
            let pane = d.delta(5, stock: CGRect(x: 354, y: 10, width: 192, height: 267))
            let pict = d.delta(7, stock: CGRect(x: 557, y: 8, width: 200, height: 200))
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols), height: gridHeight)
                    .clipped()
                    .ditlPlace(space, d, 4, stock: CGRect(x: 9, y: 8, width: 333, height: 271), at: -373.5, -152.5)
                // DITL #1002 items 9/10: the real 25×25 up/down scroll-arrow
                // buttons at (148,288)/(178,288) — one row per tap.
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.up.fill",
                               enabled: currentTopRow > 0) { scroll(-1) }
                    .ditlPlace(space, d, 9, stock: CGRect(x: 148, y: 288, width: 25, height: 25), at: -234.5, 127.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.down.fill",
                               enabled: currentTopRow < maxTopRow) { scroll(1) }
                    .ditlPlace(space, d, 10, stock: CGRect(x: 178, y: 288, width: 25, height: 25), at: -204.5, 127.5)
                // Description pane — DITL #1002 item 5 (354,10)-(546,277),
                // 192×267 (was clipped to 185 tall, so long text was cut off).
                detail.frame(width: 190 + pane.dw, height: 265 + pane.dh, alignment: .topLeading)
                    .clipped().novaPlace(space, -28.5 + pane.dx, -150.5 + pane.dy)
                // Item picture — DITL #1002 item 7 (557,8)-(757,208), the full
                // 200×200 box. The art is a 200×200 canvas, so `.fill` makes it
                // fill the box edge-to-edge (was 190×185 with `.fit`, which
                // letterboxed the square art and left a black margin).
                if let o = selected, let pic = graphics.outfitPicture(o) {
                    Image(decorative: pic, scale: 1).interpolation(.high).resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200 + pict.dw, height: 200 + pict.dh).clipped()
                        .novaPlace(space, 174.5 + pict.dx, -152.5 + pict.dy)
                }
                info(space, d)
                buttons(space, d)
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
                    ItemTile(name: o.outfitterGridName, image: graphics.outfitPicture(o),
                             quantity: pilot.owned(outfit: o.id),
                             selected: (selectedID ?? stock.first?.id) == o.id,
                             locked: lockState(for: o) == .locked)
                        .onTapGesture { selectedID = o.id }
                        // Same gap as the trade rows: without this the cursor
                        // could press Buy/Sell but never choose *which* outfit.
                        .cursorClickable { selectedID = o.id }
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
        .cursorScrollable()
    }

    private func info(_ space: NovaSpace, _ d: DITLPlacement) -> some View {
        let o = selected
        // "You Have" is the player's credit balance (matching the Shipyard's
        // info panel and the real game, e.g. "You Have: 2.34M cr") — NOT the
        // owned-quantity of the selected item, which is instead shown as the
        // small badge on the item's grid tile.
        return VStack(alignment: .leading, spacing: 8) {
            infoRow("Item Price:", o.map { pilot.effectiveCost($0, galaxy: galaxy).creditsAbbreviated } ?? "—")
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
        .ditlPlace(space, d, 8, stock: CGRect(x: 618, y: 214, width: 135, height: 100), at: 235, 53)
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
    @ViewBuilder private func buttons(_ space: NovaSpace, _ d: DITLPlacement) -> some View {
        let o = selected
        // A sell-only listing (this port buys anything, but doesn't stock this
        // item) can never be bought here, however affordable it is.
        let canBuy = o.map {
            !sellOnlyIDs.contains($0.id)
                && pilot.canBuyOutfit($0, galaxy: galaxy)
                && lockState(for: $0) == .available
        } ?? false
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buy, fallback: "Buy"),
                   width: 73, enabled: canBuy,
                   onQuantity: canBuy ? { qtyPromptMode = .buy } : nil) {
            guard let o else {
                Log.spaceport.error("Outfitter buy tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.buyOutfit(o, galaxy: galaxy) {
                Log.spaceport.debug("Bought outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Outfitter buy no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) cost=\(o.cost, privacy: .public) credits=\(pilot.state.credits, privacy: .public) freeMass=\(pilot.freeMass(galaxy: galaxy), privacy: .public) — insufficient credits, mass, or max-installed reached")
            }
        }
        .ditlPlace(space, d, 6, stock: CGRect(x: 288, y: 289, width: 99, height: 25), at: -94, 128)
        let canSell = o.map { pilot.canSellOutfit($0) } ?? false
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.sell, fallback: "Sell"),
                   width: 73, enabled: canSell,
                   onQuantity: canSell ? { qtyPromptMode = .sell } : nil) {
            guard let o else {
                Log.spaceport.error("Outfitter sell tapped with no outfit selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            if pilot.sellOutfit(o, galaxy: galaxy, ownedAtOpen: ownedAtOpen(o)) {
                Log.spaceport.debug("Sold outfit \(o.id, privacy: .public) (\(o.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(o.cost, privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Outfitter sell no-op at spöb \(spob.id, privacy: .public): outfit=\(o.id, privacy: .public) — none owned, unsellable, or free mass would go negative")
            }
        }
        .ditlPlace(space, d, 3, stock: CGRect(x: 394, y: 289, width: 99, height: 25), at: 12, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 73, action: onDone)
            .ditlPlace(space, d, 0, stock: CGRect(x: 500, y: 289, width: 99, height: 25), at: 118, 128)
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
    /// Tech-level-eligible stock on today's galaxy-wide `BuyRandom` roll (a
    /// purchase redraws its class), with any hulls that opt into full hiding
    /// (Bible `shïp.Flags3` 0x0100/0x0200) dropped when the player doesn't
    /// meet their Availability/Require and don't already fly one.
    private var stock: [ShipRes] {
        let day = pilot.state.date.julianDay
        let state = pilot.state
        guard spob.hasShipyard else { return [] }
        return game.shipyardList(
            at: spob, hire: false,
            stocked: { s in
                NovaGame.stocked(buyRandom: s.buyRandom,
                                 roll: NovaGame.dailyStockRoll(day: day, itemID: s.id, salt: 1,
                                                               redraw: state.stockRerollCount(shipType: s.id, hire: false, day: day)))
            },
            availabilityPasses: { NCBTest($0.availBits).evaluate(state) },
            requirePasses: { ($0.require & game.contributedBits(pilot: state)) == $0.require })
    }
    /// The net price of `s` here: its price after the tech markdown, rank
    /// scale and rounding, less the trade-in (EC-09).
    private func netPrice(_ s: ShipRes) -> Int { pilot.netPrice(of: s, at: spob, galaxy: galaxy) }
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
                                 netPrice($0).creditsAbbreviated
                             },
                             onDone: { showInfo = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showInfo)
    }

    @ViewBuilder private var shipyardMenu: some View {
        if let frame = graphics.frame(.shipyard) {
            // Every item follows DITL #1004 from the loaded data (stock
            // positions below, shifted by however far a plug-in moves them).
            let d = DITLPlacement(graphics.game, 1004, frame: frame)
            let pane = d.delta(5, stock: CGRect(x: 354, y: 10, width: 192, height: 267))
            let pict = d.delta(7, stock: CGRect(x: 557, y: 8, width: 200, height: 200))
            NovaMenu(frame: frame, overlay: true) { space in
                grid.frame(width: gridTileSize.width * CGFloat(gridCols), height: gridHeight)
                    .clipped()
                    .ditlPlace(space, d, 4, stock: CGRect(x: 9, y: 8, width: 333, height: 271), at: -373.5, -152.5)
                // DITL #1004 items 11/12: the real 25×25 up/down scroll-arrow
                // buttons at (141,288)/(171,288) — one row per tap.
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.up.fill",
                               enabled: currentTopRow > 0) { scroll(-1) }
                    .ditlPlace(space, d, 11, stock: CGRect(x: 141, y: 288, width: 25, height: 25), at: -241.5, 126.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.down.fill",
                               enabled: currentTopRow < maxTopRow) { scroll(1) }
                    .ditlPlace(space, d, 12, stock: CGRect(x: 171, y: 288, width: 25, height: 25), at: -211.5, 126.5)
                // Description pane — DITL #1004 item 5 (354,10)-(546,277),
                // 192×267 (was clipped to 185 tall, cutting the class blurb).
                detail.frame(width: 190 + pane.dw, height: 265 + pane.dh, alignment: .topLeading)
                    .clipped().novaPlace(space, -28.5 + pane.dx, -150.5 + pane.dy)
                // Ship picture — DITL #1004 item 7 (557,8)-(757,208), 200×200.
                if let s = selected, let picture = shipPicture(s) {
                    ShipyardPictureView(picture: picture)
                        .frame(width: 200 + pict.dw, height: 200 + pict.dh).clipped()
                        .novaPlace(space, 174.5 + pict.dx, -152.5 + pict.dy)
                }
                info(space, d)
                buttons(space, d)
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
                        .cursorClickable { selectedID = s.id }
                } else {
                    Color.clear.frame(width: gridTileSize.width, height: gridTileSize.height)
                }
            }
        }
        // Arrow keys move the selection (0x008722b0); Space is item 10, Info.
        .gridPaging(currentPage: currentTopRow, pageCount: maxTopRow + 1,
                    keyboard: GridKeyboardSelection(
                        selectedIndex: stock.firstIndex { $0.id == (selectedID ?? stock.first?.id) },
                        count: stock.count,
                        onSelect: { selectedID = stock[$0].id },
                        onSpace: { if selected != nil { showInfo = true } })) { topRow = $0 }
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
        .cursorScrollable()
    }

    private func info(_ space: NovaSpace, _ d: DITLPlacement) -> some View {
        let s = selected
        return VStack(alignment: .leading, spacing: 10) {
            infoRow("Price:", s.map { netPrice($0).creditsAbbreviated } ?? "—")
            infoRow("Trade-in:", pilot.tradeInValue(at: spob, galaxy: galaxy).creditsAbbreviated)
            infoRow("You Have:", pilot.state.credits.creditsAbbreviated)
        }
        // DITL #1004 item 8 (614,214)-(757,314) against the real 765×323
        // Shipyard frame (PICT 8501 — matches DLOG #1004's own bounds
        // exactly): cx = 614 − 382.5 ≈ 232, cy = 214 − 161.5 ≈ 52.
        .ditlPlace(space, d, 8, stock: CGRect(x: 614, y: 214, width: 143, height: 100), at: 232, 52)
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
    @ViewBuilder private func buttons(_ space: NovaSpace, _ d: DITLPlacement) -> some View {
        let s = selected
        let canBuy = s.map {
            $0.id != pilot.state.shipType && pilot.state.credits >= netPrice($0)
                && lockState(for: $0) == .available
        } ?? false
        // DITL #1004 item 9 (253,289)-(342,314), 89×25 — the "Info" button (STR#
        // 150 index 48), which the original shipyard sits left of Buy Ship/Done to
        // open the detailed ship-info dialog. cx = 253 − 382.5 = −129.5.
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.info, fallback: "Info"),
                   width: 63, enabled: s != nil) { showInfo = true }
            .ditlPlace(space, d, 9, stock: CGRect(x: 253, y: 289, width: 89, height: 25), at: -129.5, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.buyShip, fallback: "Buy Ship"),
                   width: 83, enabled: canBuy) {
            guard let s else {
                Log.spaceport.error("Shipyard buy tapped with no ship selected at spöb \(spob.id, privacy: .public) — no-op")
                return
            }
            let price = netPrice(s)
            if pilot.buyShip(s, at: spob, galaxy: galaxy) {
                Log.spaceport.debug("Bought ship \(s.id, privacy: .public) (\(s.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(price, privacy: .public)cr")
                onLiveSync()
            } else {
                Log.spaceport.notice("Shipyard buy no-op at spöb \(spob.id, privacy: .public): ship=\(s.id, privacy: .public) netPrice=\(price, privacy: .public) credits=\(pilot.state.credits, privacy: .public) — insufficient credits or already owned")
            }
        }
        .ditlPlace(space, d, 0, stock: CGRect(x: 365, y: 289, width: 109, height: 25), at: -18, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 83, action: onDone)
            .ditlPlace(space, d, 6, stock: CGRect(x: 480, y: 289, width: 109, height: 25), at: 98, 128)
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
    let galaxy: Galaxy
    var onDone: () -> Void

    @EnvironmentObject private var appModel: AppModel

    @State private var showGambling = false
    @State private var showHire = false
    @State private var showHolovid = false
    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    /// Bumped to schedule the next bar offer (see `offerPatrons`).
    @State private var nextOffer = 0
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
    // Bar missions are NOT a browsable list (that's the Mission BBS). As in
    // the original (0x00448670 and the bar loop), every eligible bar mission
    // is offered in turn, highest DispWeight first, in the authentic Single
    // Mission dialog (DITL #1016) over the bar: the first a quarter second
    // after walking in, each next one 0.5–1 s after the last closes.
    // Accept/refuse run the real engine flow, so all mission bits fire.
    var body: some View {
        ZStack {
            Group {
                if let frame = graphics.frame(.bar) {
                    // Rects resolve through DITL #1013 (stock rects as fallback).
                    let d = DITLPlacement(graphics.game, 1013, frame: frame)
                    NovaMenu(frame: frame, overlay: true) { space in
                        let text = d.rect(6, top: 10, left: 16, bottom: 116, right: 246)
                        ScrollView(showsIndicators: false) {
                            NovaText(barText, size: 10, width: text.width, align: .leading)
                        }
                        .cursorScrollable()
                        .frame(width: text.width, height: text.height)
                        .ditlPlace(space, d, text)
                        // Escorts are hired from the port's shipyard stock, so the
                        // option is only live where there's a shipyard to hire from.
                        let hire = d.rect(4, top: 125, left: 6, bottom: 151, right: 152)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.hireEscort, fallback: "Hire Escort"),
                                   ditl: hire, enabled: spob.hasShipyard) { showHire = true }
                            .ditlPlace(space, d, hire)
                        let holo = d.rect(2, top: 154, left: 6, bottom: 180, right: 152)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.holovid, fallback: "Holovid"),
                                   ditl: holo) { showHolovid = true }
                            .ditlPlace(space, d, holo)
                        let gamble = d.rect(1, top: 125, left: 156, bottom: 151, right: 255)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.gamble, fallback: "Gamble"),
                                   ditl: gamble) { showGambling = true }
                            .ditlPlace(space, d, gamble)
                        let leave = d.rect(0, top: 154, left: 156, bottom: 180, right: 255)
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                                   ditl: leave, action: onDone)
                            .ditlPlace(space, d, leave)
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
                HireEscortView(graphics: graphics, spob: spob, pilot: pilot, galaxy: galaxy,
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
        .overlay { StoryTextOverlay(services: services) }
        .onAppear { services.onCloseSpaceportScreen = onDone }   // a `Q` from an accept leaves the bar
        .task(id: nextOffer) { await offerPatron(after: nextOffer == 0 ? 15 : 30 + Int.random(in: 0..<30)) }
        .storylineGuideSheet(isPresented: $showStoryGuide, game: game, player: { pilot.state },
                             storylineKey: storyGuideFocusKey)
    }

    /// The bar's offer timer (60 Hz ticks): wait, then let the next patron in
    /// the lane make their pitch (0x00448670). Accept and decline arm the next
    /// wait; an empty lane ends the round until the player comes back in.
    private func offerPatron(after ticks: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ticks) * 1_000_000_000 / 60)
        guard !Task.isCancelled, services.pendingOffer == nil else { return }
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        let mission = e.nextLaneOffer(at: .bar, spob: spob.id)
        pilot.state = e.player                                   // the offer context latch
        guard let mission else {
            Log.spaceport.debug("Bar at spöb \(spob.id, privacy: .public): no more bar missions this visit")
            return
        }
        Log.spaceport.debug("Bar patron offers mission \(mission.id, privacy: .public) at spöb \(spob.id, privacy: .public)")
        if !e.present(mission) {
            // A can't-refuse offer with no text activated silently.
            pilot.state = e.player
            pilot.save()
            nextOffer += 1
        }
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        nextOffer += 1
    }

    private func decline(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        nextOffer += 1
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
    /// The one news body the original shows (MS-20): this station's crön
    /// news if any, else a generic item from STR# 8101.
    private var news: [String] {
        let engine = StoryEngine(game: game, player: pilot.state,
                                 seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        let cron = engine.stationNews(forGovt: stationGovt)
        return cron.isEmpty ? engine.genericNews().map { [$0] } ?? [] : cron
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
                .cursorScrollable()
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
                .cursorScrollable()
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

