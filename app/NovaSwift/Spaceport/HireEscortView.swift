import SwiftUI
import NovaSwiftKit

// The hire-escort browser reuses the Shipyard's grid metrics verbatim so it
// looks and lays out identically (these mirror the private constants in
// SpaceportScreens.swift; a bar's "Hire Escort" screen IS a shipyard screen in
// the original, just renting instead of buying).
private let hireGridTileSize = CGSize(width: 83, height: 54)
private let hireGridCols = 4
private let hireGridRows = 5
private let hireGridSlotCount = hireGridCols * hireGridRows
private let hireGridHeight = hireGridTileSize.height * CGFloat(hireGridRows)

private func hireCreditString(_ n: Int) -> String {
    "\(n) cr"
}

/// The spaceport bar's **Hire Escort** browser — the original's hire-escort
/// dialog, which is the Shipyard UI (same frame PICT 8501, DITL #1004 layout)
/// applied to renting escorts instead of buying hulls. Which hulls are on offer
/// today is gated per-ship by `shïp.HireRandom` (a percent-chance-per-day roll,
/// same `escortAvailableToday` mechanism the shipyard uses for `BuyRandom`), so
/// only a random subset shows up on any given day. Hiring charges an up-front
/// fee (`escortHireFee`) and then a recurring **daily fee** (`escortDailyFee`)
/// billed by the day clock; the escort joins you on takeoff. The detail pane
/// shows the ship's pilot description (`dësc` 14000-range, "shown in the
/// hire-escort dialog" per the Bible), which is what distinguishes this from the
/// shipyard's class description.
struct HireEscortView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    @State private var selectedID: Int?
    @State private var topRow = 0
    private var game: NovaGame { graphics.game }
    /// Today's galaxy day — the seed for the per-day availability roll.
    private var day: Int { pilot.state.date.julianDay }

    /// Ships offered for hire here today. The pool is what this planet's
    /// *shipyard* deals in — `game.shipsSold(at:day:)` is tech-level-eligible and
    /// returns nothing when the spöb has no shipyard, so a bar without a shipyard
    /// offers no escorts (you can only hire hulls the port actually stocks). From
    /// that pool, only the hulls whose `HireRandom` roll passes today are on
    /// offer, so it's a random planet-specific subset that changes day to day —
    /// never every ship. Grouped by escort category, then fee, the way the escort
    /// menu clusters fighters/medium/warships/freighters. Passing `day: nil` uses
    /// the shipyard's tech eligibility without its separate `BuyRandom` stock
    /// roll — hire availability is the `HireRandom` roll's job.
    private var stock: [ShipRes] {
        game.shipsSold(at: spob, day: nil)
            .filter { $0.hireRandom > 0 && pilot.escortAvailableToday($0, at: spob, day: day) }
            .sorted { ($0.escortCategory, $0.escortHireFee) < ($1.escortCategory, $1.escortHireFee) }
    }
    private var selected: ShipRes? { stock.first { $0.id == selectedID } ?? stock.first }

    private static func categoryLabel(_ c: Int) -> String {
        switch c {
        case 0: return "Fighter"
        case 1: return "Medium Ship"
        case 2: return "Warship"
        case 3: return "Freighter"
        default: return "Escort"
        }
    }

    var body: some View {
        if let frame = graphics.frame(.shipyard) {
            NovaMenu(frame: frame, overlay: true) { space in
                // DITL #1004 item positions, matched to the Shipyard exactly.
                grid.frame(width: hireGridTileSize.width * CGFloat(hireGridCols), height: hireGridHeight)
                    .clipped().novaPlace(space, -373.5, -152.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.up.fill",
                               enabled: currentTopRow > 0) { scroll(-1) }
                    .novaPlace(space, -241.5, 126.5)
                NovaIconButton(graphics: graphics, systemName: "arrowtriangle.down.fill",
                               enabled: currentTopRow < maxTopRow) { scroll(1) }
                    .novaPlace(space, -211.5, 126.5)
                detail.frame(width: 190, height: 265, alignment: .topLeading)
                    .clipped().novaPlace(space, -28.5, -150.5)
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

    private var rowCount: Int { max(1, (stock.count + hireGridCols - 1) / hireGridCols) }
    private var maxTopRow: Int { max(0, rowCount - hireGridRows) }
    private var currentTopRow: Int { min(topRow, maxTopRow) }
    private func scroll(_ delta: Int) { topRow = min(max(currentTopRow + delta, 0), maxTopRow) }
    private var visibleItems: [ShipRes?] {
        let start = currentTopRow * hireGridCols
        let end = min(start + hireGridSlotCount, stock.count)
        var items: [ShipRes?] = start < end ? stock[start..<end].map { $0 } : []
        items += Array(repeating: nil, count: hireGridSlotCount - items.count)
        return items
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(hireGridTileSize.width), spacing: 0), count: hireGridCols), spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, s in
                if let s {
                    let picture = shipPicture(s)
                    let remaining = pilot.escortHireRemaining(s, at: spob, day: day)
                    // The quantity badge is this station's remaining daily stock
                    // of the hull (1–5, varies by type); a hull hired out for the
                    // day dims as "locked" (sold out) rather than vanishing.
                    ItemTile(name: s.displayName, image: picture?.image,
                             pixelated: picture?.isDedicated == false,
                             quantity: remaining,
                             selected: (selectedID ?? stock.first?.id) == s.id,
                             locked: remaining == 0)
                        .onTapGesture { selectedID = s.id }
                } else {
                    Color.clear.frame(width: hireGridTileSize.width, height: hireGridTileSize.height)
                }
            }
        }
        .gridPaging(currentPage: currentTopRow, pageCount: maxTopRow + 1) { topRow = $0 }
    }

    /// Dedicated shipyard art for the hull, falling back to the small in-flight
    /// sprite (crisply) if a plug-in ship defines none — same as the Shipyard.
    private func shipPicture(_ s: ShipRes) -> (image: CGImage, isDedicated: Bool)? {
        if let pic = graphics.shipPicture(s) { return (pic, true) }
        if let frame = graphics.shipFallbackPicture(s) { return (frame, false) }
        return nil
    }

    /// The ship's pilot description (`dësc` 14000-range, "shown in the
    /// hire-escort dialog"), falling back to the class description (`dësc`
    /// 13000-range) the shipyard uses when a hull defines no pilot blurb.
    private func pilotDescription(_ s: ShipRes) -> String {
        let pilot = game.descText(14000 + s.id - 128)
        return pilot.isEmpty ? game.descText(13000 + s.id - 128) : pilot
    }

    private var detail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if let s = selected {
                    NovaText(s.displayName, size: 12, weight: .bold)
                    NovaText(Self.categoryLabel(s.escortCategory), size: 10, color: novaAmber)
                    NovaText("Shield / Armor: \(s.shield) / \(s.armor)", size: 10)
                    NovaText("Guns / Turrets: \(s.maxGuns) / \(s.maxTurrets)", size: 10)
                    let blurb = pilotDescription(s)
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
        return VStack(alignment: .leading, spacing: 8) {
            infoRow("Hire:", s.map { hireCreditString($0.escortHireFee) } ?? "—")
            infoRow("Per day:", s.map { hireCreditString($0.escortDailyFee) } ?? "—")
            infoRow("Available:", s.map { "\(pilot.escortHireRemaining($0, at: spob, day: day))" } ?? "—")
            infoRow("You Have:", hireCreditString(pilot.state.credits))
        }
        .novaPlace(space, 232, 46)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            NovaText(label, size: 11, color: .gray, width: 66, align: .leading)
            NovaText(value, size: 11, width: 100, align: .leading)
        }
    }

    @ViewBuilder private func buttons(_ space: NovaSpace) -> some View {
        let s = selected
        let remaining = s.map { pilot.escortHireRemaining($0, at: spob, day: day) } ?? 0
        let canHire = (s.map { pilot.state.credits >= $0.escortHireFee } ?? false) && remaining > 0
        NovaButton(graphics: graphics,
                   title: graphics.buttonLabel(SpaceportLabel.hireEscort, fallback: "Hire Escort"),
                   width: 83, enabled: canHire) {
            guard let s else { return }
            if pilot.hireEscort(s, at: spob, day: day) {
                Log.spaceport.debug("Hired escort \(s.id, privacy: .public) (\(s.name, privacy: .public)) at spöb \(spob.id, privacy: .public) for \(s.escortHireFee, privacy: .public)cr")
            }
        }
        .novaPlace(space, -18, 128)
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                   width: 83, action: onDone)
            .novaPlace(space, 98, 128)
    }

    private var fallback: some View {
        VStack(spacing: 8) {
            NovaText("Ships for Hire", size: 15, color: .white, weight: .bold)
            if stock.isEmpty {
                NovaText("No ships are available for hire here today.", size: 12,
                         color: Color(white: 0.6), width: 260, align: .center)
            } else {
                ForEach(stock, id: \.id) { s in
                    HStack {
                        NovaText(s.name, size: 12)
                        Spacer()
                        NovaText("\(s.escortHireFee)cr", size: 11)
                        NovaButton(graphics: graphics,
                                   title: graphics.buttonLabel(SpaceportLabel.hireEscort, fallback: "Hire"),
                                   width: 84, enabled: pilot.state.credits >= s.escortHireFee) {
                            _ = pilot.hireEscort(s, at: spob, day: day)
                        }
                    }
                }
            }
            NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 90, action: onDone)
        }
        .padding(16).frame(width: 420)
        .background(Color(white: 0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(novaAmber.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .novaResponsive()
    }
}
