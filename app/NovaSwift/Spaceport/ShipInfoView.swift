import SwiftUI
import NovaSwiftKit

/// EV Nova's **detailed ship-info dialog** — the screen the Shipyard's "Info"
/// button opens (Nova Bible: the "detailed ship info dialog").
///
/// The base game ships two variants, and we reproduce both from the player's own
/// resources when the UI is in an authentic mode (Classic / Enhanced):
///   • **DLOG/DITL #1019 "Shipyard Info + photo"** on frame **PICT #8507** — the
///     614×537 card with the large ship picture on its nebula backdrop, the class
///     name, a stat table and the Standard Weapons list. Used when the hull has a
///     picture.
///   • **DLOG/DITL #1005 "Shipyard Info"** on frame **PICT #8506** — the 250×285
///     text-only card, used when a hull has no picture.
/// Item rects below are transcribed straight from those DITLs (Mac left,top–
/// right,bottom), placed via `NovaMenu`/`novaPlace` in the frame's native space.
///
/// In the **Nova Swift** presentation (`modernDialogs`), it instead renders the
/// port's own modern card — matching how the rest of the port keeps an authentic
/// look for Classic/Enhanced and a modern one for Nova Swift.
struct ShipInfoView: View {
    @EnvironmentObject private var model: AppModel
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

    var body: some View {
        if model.settings.modernDialogs {
            modernCard
        } else {
            authentic
        }
    }

    // MARK: - Authentic dialog (Classic / Enhanced)

    /// The real EV Nova ship-info dialog: photo variant (#1019/#8507) when the
    /// hull has a picture, else the text variant (#1005/#8506). Falls back to the
    /// modern card only if the frame PICTs aren't in the player's data or there's
    /// no ship.
    @ViewBuilder private var authentic: some View {
        if let ship, let photo = picture(ship), let frame = graphics.pict(8507) {
            photoDialog(ship, photo: photo, frame: frame)
        } else if let ship, let frame = graphics.pict(8506) {
            textDialog(ship, frame: frame)
        } else {
            modernCard
        }
    }

    /// DLOG #1019 "Shipyard Info + photo" — 614×537, centre (307, 268.5).
    private func photoDialog(_ ship: ShipRes, photo: (image: CGImage, isDedicated: Bool), frame: CGImage) -> some View {
        NovaMenu(frame: frame, overlay: true) { space in
            // [6] ship picture (7,6)-(607,406) 600×400 — the dedicated shipyard art
            // (nebula backdrop baked in) filling the frame's picture box, drawn via
            // the same renderer as the Shipyard preview.
            ShipyardPictureView(picture: photo).frame(width: 600, height: 400).clipped()
                .novaPlace(space, -300, -262.5)
            // [2] class name (7,413)-(607,437) 600×24
            NovaText(ship.displayName, size: 15, width: 600, align: .center, weight: .bold)
                .novaPlace(space, -300, 144.5)
            // [4] stat table (11,442)-(267,534) 256×92
            authStatBlock(ship).frame(width: 256, height: 92, alignment: .topLeading)
                .novaPlace(space, -296, 173.5)
            // [7] Standard Weapons (266,442)-(608,501) 342×59
            authWeaponsBlock(ship, width: 340).frame(width: 342, height: 59, alignment: .topLeading)
                .novaPlace(space, -41, 173.5)
            // [0] OK (503,507)-(602,532) 99×25
            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 73, action: onDone)
                .novaPlace(space, 196, 238.5)
        }
    }

    /// DLOG #1005 "Shipyard Info" — 250×285, centre (125, 142.5). Text-only: the
    /// body [4] carries the stats, weapons and class description together.
    private func textDialog(_ ship: ShipRes, frame: CGImage) -> some View {
        NovaMenu(frame: frame, overlay: true) { space in
            // [2] class name (3,3)-(243,27) 240×24
            NovaText(ship.displayName, size: 13, width: 240, align: .center, weight: .bold)
                .novaPlace(space, -122, -139.5)
            // [4] body (9,32)-(243,246) 234×214
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    authStatBlock(ship)
                    authWeaponsBlock(ship, width: 226)
                    let blurb = classDescription(ship)
                    if !blurb.isEmpty {
                        NovaText(blurb, size: 9, width: 226, align: .leading).padding(.top, 2)
                    }
                }
            }
            .frame(width: 234, height: 214, alignment: .topLeading)
            .novaPlace(space, -116, -110.5)
            // [0] OK (86,253)-(160,278) 74×25
            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 48, action: onDone)
                .novaPlace(space, -39, 110.5)
        }
    }

    /// Compact two-column stat grid, the EV Nova detailed-info layout: flight/hull
    /// figures on the left, defenses/mounts/economy on the right.
    private func authStatBlock(_ s: ShipRes) -> some View {
        HStack(alignment: .top, spacing: 12) {
            authStatColumn([("Speed", "\(s.speed)"), ("Accel", "\(s.acceleration)"),
                            ("Turn", "\(s.turnRate)"), ("Mass", "\(s.mass)"),
                            ("Cargo", "\(s.cargoSpace)"), ("Fuel", "\(s.fuelCapacity / 100)")])
            authStatColumn([("Shield", "\(s.shield)"), ("Armor", "\(s.armor)"),
                            ("Guns", "\(s.maxGuns)"), ("Turrets", "\(s.maxTurrets)"),
                            ("Crew", "\(s.crew)"), ("Cost", priceText ?? s.cost.creditsAbbreviated)])
        }
    }

    private func authStatColumn(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.0) { label, value in
                HStack(spacing: 4) {
                    NovaText(label, size: 9, color: .gray, width: 44, align: .leading)
                    NovaText(value, size: 9, width: 66, align: .leading, shrinkToFit: true)
                }
            }
        }
    }

    /// "Standard Weapons" header + the hull's built-in armament, comma-joined the
    /// way the original prints it ("1 Fusion Pulse Turret, 2 100mm Railguns").
    private func authWeaponsBlock(_ s: ShipRes, width: CGFloat) -> some View {
        let weapons = standardWeapons(s)
        return VStack(alignment: .leading, spacing: 2) {
            NovaText("Standard Weapons", size: 10, weight: .bold)
            NovaText(weapons.isEmpty ? "None" : weapons.joined(separator: ", "),
                     size: 9, color: weapons.isEmpty ? .gray : .white, width: width, align: .leading)
        }
    }

    private func classDescription(_ s: ShipRes) -> String {
        game.descText(13000 + s.id - 128)
    }

    // MARK: - Modern card (Nova Swift)

    private static let frameSize = CGSize(width: 520, height: 480)

    @ViewBuilder private var modernCard: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: Self.frameSize, viewport: geo.size)
            modernCardBody
                .frame(width: Self.frameSize.width, height: Self.frameSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(novaAmber.opacity(0.4)))
                )
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var modernCardBody: some View {
        if let ship {
            VStack(spacing: 8) {
                modernPicture
                NovaText(ship.displayName, size: 15, width: 460, align: .center, weight: .bold)
                if !ship.subtitle.novaDisplayName.isEmpty {
                    NovaText(ship.subtitle.novaDisplayName, size: 11, color: .gray, width: 460, align: .center)
                }
                Divider().overlay(novaAmber.opacity(0.3)).frame(width: 440)
                HStack(alignment: .top, spacing: 24) {
                    modernStatColumn(modernLeftStats(ship))
                    modernStatColumn(modernRightStats(ship))
                    modernWeaponsColumn(ship).frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder private var modernPicture: some View {
        ZStack {
            Color.black
            if let ship, let picture = picture(ship) {
                ShipyardPictureView(picture: picture)
            } else {
                Image(systemName: "airplane").font(.system(size: 48)).foregroundStyle(.gray)
            }
        }
        .frame(width: 220, height: 200).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
    }

    private func modernLeftStats(_ s: ShipRes) -> [(String, String)] {
        [("Speed", "\(s.speed)"), ("Accel", "\(s.acceleration)"), ("Turn", "\(s.turnRate)"),
         ("Mass", "\(s.mass)"), ("Cargo", "\(s.cargoSpace) t"), ("Fuel", modernFuel(s))]
    }

    private func modernRightStats(_ s: ShipRes) -> [(String, String)] {
        [("Shield", "\(s.shield)"), ("Armor", "\(s.armor)"), ("Guns", "\(s.maxGuns)"),
         ("Turrets", "\(s.maxTurrets)"), ("Crew", "\(s.crew)"), ("Cost", priceText ?? s.cost.creditsAbbreviated)]
    }

    private func modernFuel(_ s: ShipRes) -> String {
        let jumps = s.fuelCapacity / 100
        guard jumps > 0 else { return "—" }
        return "\(jumps) jump\(jumps == 1 ? "" : "s")"
    }

    private func modernStatColumn(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.0) { label, value in
                HStack(spacing: 6) {
                    NovaText(label, size: 11, color: .gray, width: 52, align: .leading)
                    NovaText(value, size: 11, width: 62, align: .leading, shrinkToFit: true)
                }
            }
        }
    }

    @ViewBuilder private func modernWeaponsColumn(_ s: ShipRes) -> some View {
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

    // MARK: - Shared data

    /// The dedicated shipyard art (large, nebula-framed) if the hull has it, else
    /// the small in-flight sprite — the Shipyard's resolution order, `isDedicated`
    /// telling the renderer which sampling to use.
    private func picture(_ s: ShipRes) -> (image: CGImage, isDedicated: Bool)? {
        if let pic = graphics.shipPicture(s) { return (pic, true) }
        if let frame = graphics.shipFallbackPicture(s) { return (frame, false) }
        return nil
    }

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
}
