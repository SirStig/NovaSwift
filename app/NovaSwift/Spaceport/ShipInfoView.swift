import SwiftUI
import NovaSwiftKit

/// EV Nova's standalone **Ship Information** card: the large ship picture (the
/// dedicated 5000-series shipyard art, which already carries the ship's nebula
/// backdrop and frame) with the class name and subtitle beneath it, a full stat
/// table (Speed / Accel / Turn / Mass / Cargo / Fuel / Shield / Armor / Guns /
/// Turrets / Crew / Cost) and the ship's Standard Weapons + Standard Outfits.
///
/// The base game had no dedicated frame PICT for this (its shipyard showed the
/// stats inline), so — like the app's other computed cards — it's drawn on a
/// plain dark panel with the house amber border rather than a decoded backdrop.
/// Reached from the Shipyard (tap the preview) and from the in-flight Ship Info
/// key (shows the targeted ship, or your own hull when nothing is targeted).
struct ShipInfoView: View {
    let graphics: SpaceportGraphics
    /// The hull to describe; nil renders a short "no ship" placeholder so the
    /// card still dismisses cleanly (e.g. a target whose `shïp` didn't resolve).
    let ship: ShipRes?
    /// Overrides the displayed cost line — the Shipyard passes the rank-adjusted
    /// net price it would actually charge; in flight it's left nil so the card
    /// falls back to the hull's base `cost`.
    var priceText: String? = nil
    var onDone: () -> Void

    private var game: NovaGame { graphics.game }
    private static let frameSize = CGSize(width: 520, height: 480)

    var body: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: Self.frameSize, viewport: geo.size)
            card
                .frame(width: Self.frameSize.width, height: Self.frameSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(novaAmber.opacity(0.4)))
                )
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var card: some View {
        if let ship {
            VStack(spacing: 8) {
                shipPicture
                NovaText(ship.displayName, size: 15, width: 460, align: .center, weight: .bold)
                if !ship.subtitle.novaDisplayName.isEmpty {
                    NovaText(ship.subtitle.novaDisplayName, size: 11, color: .gray, width: 460, align: .center)
                }
                Divider().overlay(novaAmber.opacity(0.3)).frame(width: 440)
                HStack(alignment: .top, spacing: 24) {
                    statColumn(leftStats(ship))
                    statColumn(rightStats(ship))
                    weaponsColumn(ship).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 460, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    NovaButton(graphics: graphics,
                               title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                               width: 73, action: onDone)
                }
                .frame(width: 460)
            }
            .padding(18)
        } else {
            VStack(spacing: 16) {
                NovaText("No ship information available.", size: 12)
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                           width: 73, action: onDone)
            }
            .padding(18)
        }
    }

    // MARK: - Ship picture

    /// The dedicated shipyard art (large, nebula-framed) if the hull has it,
    /// else the small in-flight sprite — same resolution order as the Shipyard's
    /// preview, drawn through the shared `ShipyardPictureView` so the pixel-art
    /// fallback stays crisp instead of blurring to fill the box.
    private var picture: (image: CGImage, isDedicated: Bool)? {
        guard let ship else { return nil }
        if let pic = graphics.shipPicture(ship) { return (pic, true) }
        if let frame = graphics.shipFallbackPicture(ship) { return (frame, false) }
        return nil
    }

    @ViewBuilder private var shipPicture: some View {
        ZStack {
            Color.black
            if let picture {
                ShipyardPictureView(picture: picture)
            } else {
                Image(systemName: "airplane")
                    .font(.system(size: 48)).foregroundStyle(.gray)
            }
        }
        .frame(width: 220, height: 200).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
    }

    // MARK: - Stat table

    private func leftStats(_ s: ShipRes) -> [(String, String)] {
        [("Speed", "\(s.speed)"),
         ("Accel", "\(s.acceleration)"),
         ("Turn", "\(s.turnRate)"),
         ("Mass", "\(s.mass)"),
         ("Cargo", "\(s.cargoSpace) t"),
         ("Fuel", fuelText(s))]
    }

    private func rightStats(_ s: ShipRes) -> [(String, String)] {
        [("Shield", "\(s.shield)"),
         ("Armor", "\(s.armor)"),
         ("Guns", "\(s.maxGuns)"),
         ("Turrets", "\(s.maxTurrets)"),
         ("Crew", "\(s.crew)"),
         ("Cost", priceText ?? s.cost.creditsAbbreviated)]
    }

    /// Fuel shown as whole hyperspace jumps (100 units = 1 jump), the unit the
    /// player actually reasons about; "—" for a hull that can't jump.
    private func fuelText(_ s: ShipRes) -> String {
        let jumps = s.fuelCapacity / 100
        guard jumps > 0 else { return "—" }
        return "\(jumps) jump\(jumps == 1 ? "" : "s")"
    }

    private func statColumn(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.0) { label, value in
                HStack(spacing: 6) {
                    NovaText(label, size: 11, color: .gray, width: 52, align: .leading)
                    NovaText(value, size: 11, width: 62, align: .leading, shrinkToFit: true)
                }
            }
        }
    }

    // MARK: - Standard weapons / outfits

    /// The hull's built-in weapons, aggregated by type into "2 × 100mm Railgun"
    /// lines. Preinstalled `outfits` are listed separately below (many hulls
    /// carry their armament as outfits rather than raw `weapons`).
    private func standardWeapons(_ s: ShipRes) -> [String] {
        aggregate(s.weapons.map { (id: $0.id, count: $0.count) }) { game.weapon($0)?.name.novaDisplayName }
    }

    private func standardOutfits(_ s: ShipRes) -> [String] {
        aggregate(s.outfits.map { (id: $0.id, count: $0.count) }) { game.outfit($0)?.displayName }
    }

    /// Sum counts per id, resolve each to a name, and format "N × name" (or just
    /// "name" for a single unit), ordered by id for a stable list.
    private func aggregate(_ items: [(id: Int, count: Int)], name: (Int) -> String?) -> [String] {
        var counts: [Int: Int] = [:]
        for item in items where item.count > 0 { counts[item.id, default: 0] += item.count }
        return counts.sorted { $0.key < $1.key }.map { id, n in
            let label = name(id) ?? "#\(id)"
            return n > 1 ? "\(n) × \(label)" : label
        }
    }

    @ViewBuilder private func weaponsColumn(_ s: ShipRes) -> some View {
        let weapons = standardWeapons(s)
        let outfits = standardOutfits(s)
        VStack(alignment: .leading, spacing: 3) {
            NovaText("Standard Weapons", size: 11, weight: .bold)
            if weapons.isEmpty {
                NovaText("None", size: 10, color: .gray)
            } else {
                ForEach(weapons, id: \.self) { NovaText($0, size: 10, width: 168, align: .leading) }
            }
            if !outfits.isEmpty {
                NovaText("Standard Outfits", size: 11, weight: .bold).padding(.top, 5)
                ForEach(outfits, id: \.self) { NovaText($0, size: 10, width: 168, align: .leading) }
            }
        }
    }
}
