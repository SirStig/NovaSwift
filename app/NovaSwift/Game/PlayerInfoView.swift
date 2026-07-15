import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// EV Nova's player-info dialog — the four-tab panel the game opens on 'I':
/// **General / Cargo / Extras / Honors** tab buttons across the top, a text
/// pane below, "Jettison Cargo" bottom-left and Done bottom-right.
///
/// Layout straight from DLOG/DITL #1017 "Player Info" against its dedicated
/// three-slice frame (PICTs 8518 "Player info (upper)" 413×40 / 8519 middle /
/// 8520 lower 413×40, stretched to the DLOG's 413×227 — centre 206.5,113.5):
///   items 1–4  (7,8)/(107,8)/(207,8)/(307,8)  99×25 — the four tabs
///   item 5     (4,40)-(409,181)  405×141      — the text pane
///   item 6     (60,195) 150×25                — Jettison Cargo
///   item 0     (293,195) 99×25                — Done
/// Tab labels are the game's own `STR# 150` entries 36–39; the pane text is
/// composed from the live pilot the way the original describes itself.
struct PlayerInfoView: View {
    let graphics: SpaceportGraphics
    @ObservedObject var pilot: PilotStore
    /// Jettison the pilot's cargo (also clears the live ship's hold when the
    /// caller can reach it). Nil hides nothing — the button just greys out.
    var onJettison: (() -> Void)?
    var onDone: () -> Void

    @State private var tab: Tab = .general
    enum Tab: CaseIterable { case general, cargo, extras, honors }

    private var game: NovaGame { graphics.game }
    private static let frameSize = CGSize(width: 413, height: 227)

    var body: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: Self.frameSize, viewport: geo.size)
            frameBody
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var frameBody: some View {
        let space = NovaSpace(width: Self.frameSize.width, height: Self.frameSize.height)
        ZStack(alignment: .topLeading) {
            frameArt
            tabButton(.general, SpaceportLabel.infoGeneral, "General", cx: -199.5)
            tabButton(.cargo,   SpaceportLabel.infoCargo,   "Cargo",   cx: -99.5)
            tabButton(.extras,  SpaceportLabel.infoExtras,  "Extras",  cx: 0.5)
            tabButton(.honors,  SpaceportLabel.infoHonors,  "Honors",  cx: 100.5)

            ScrollView(showsIndicators: false) {
                NovaText(paneText, size: 10, width: 393, align: .leading)
                    .padding(.top, 4).padding(.leading, 6)
            }
            .frame(width: 405, height: 141)
            .clipped()
            .novaPlace(space, -202.5, -73.5)

            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.jettisonCargo, fallback: "Jettison Cargo"),
                       width: 124, enabled: onJettison != nil && pilot.state.usedCargoSpace > 0) {
                onJettison?()
            }
            .novaPlace(space, -146.5, 81.5)

            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       width: 73, action: onDone)
                .novaPlace(space, 86.5, 81.5)
        }
        .frame(width: Self.frameSize.width, height: Self.frameSize.height, alignment: .topLeading)
    }

    /// The dialog's own stretchable frame: fixed 40px caps, middle stretched to
    /// the DLOG height (the caps carry the tab strip / control strip art).
    @ViewBuilder private var frameArt: some View {
        if let top = graphics.pict(8518), let mid = graphics.pict(8519), let bottom = graphics.pict(8520) {
            VStack(spacing: 0) {
                Image(decorative: top, scale: 1).resizable().frame(height: 40)
                Image(decorative: mid, scale: 1).resizable()
                Image(decorative: bottom, scale: 1).resizable().frame(height: 40)
            }
            .frame(width: Self.frameSize.width, height: Self.frameSize.height)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                .frame(width: Self.frameSize.width, height: Self.frameSize.height)
        }
    }

    /// One tab button at DITL row y=8. The active tab renders in the art's
    /// clicked (depressed) state, exactly how the game marks the open tab.
    private func tabButton(_ t: Tab, _ labelIndex: Int, _ fallback: String, cx: CGFloat) -> some View {
        InfoTabButton(graphics: graphics,
                      title: graphics.buttonLabel(labelIndex, fallback: fallback),
                      selected: tab == t) { tab = t }
            .novaPlace(NovaSpace(width: Self.frameSize.width, height: Self.frameSize.height),
                       cx, -105.5)
    }

    // MARK: - Pane text

    private var paneText: String {
        switch tab {
        case .general: return generalText
        case .cargo:   return cargoText
        case .extras:  return extrasText
        case .honors:  return honorsText
        }
    }

    private var generalText: String {
        let p = pilot.state
        var lines: [String] = []
        let shipClass = game.ship(p.shipType)?.displayName ?? "ship"
        let shipName = p.shipName.isEmpty ? shipClass : p.shipName
        lines.append("You are Captain \(p.pilotName), of the \(shipClass) \(shipName).")
        lines.append("")
        lines.append("You have \(p.credits.creditsAbbreviated).")
        lines.append("Your combat rating is \(CombatRating.title(forRating: p.combatRating)).")
        if let govt = game.system(p.currentSystem)?.government,
           let name = game.govt(govt)?.name {
            let record = p.effectiveLegalRecord(govt: govt, atSystem: p.currentSystem)
            let status: String
            switch record {
            case ..<(-200): return lines.joined(separator: "\n") + "\nYou are an enemy of the \(name)."
            case ..<0:      status = "You are wanted by the \(name)."
            case 0:         status = "You have no legal record with the \(name)."
            default:        status = "You are in good standing with the \(name)."
            }
            lines.append(status)
        }
        lines.append("The date is \(PlayerInfoView.longDate(p.date)).")
        return lines.joined(separator: "\n")
    }

    private var cargoText: String {
        let cargo = pilot.state.cargo.filter { $0.value > 0 }
        guard !cargo.isEmpty else { return "You are not carrying any cargo." }
        var lines = ["Current cargo aboard your ship:", ""]
        for (type, tons) in cargo.sorted(by: { $0.key < $1.key }) {
            let name = Commodity(rawValue: type).map { game.commodityName($0) } ?? "Cargo #\(type)"
            lines.append("\(tons) tons of \(name)")
        }
        return lines.joined(separator: "\n")
    }

    private var extrasText: String {
        let owned = pilot.state.outfits.filter { $0.value > 0 }
        guard !owned.isEmpty else { return "Your ship carries no extra equipment." }
        // The original reads as prose: "Current outfit for your ship: a light
        // blaster, 2 fuel scoops, …" — one comma-joined sentence.
        let items = owned.sorted { $0.key < $1.key }.map { id, qty -> String in
            let name = game.outfit(id)?.displayName ?? "outfit #\(id)"
            return qty > 1 ? "\(qty) × \(name)" : name
        }
        return "Current outfit for your ship:\n\n" + items.joined(separator: ", ") + "."
    }

    private var honorsText: String {
        let ranks = pilot.state.activeRanks
            .compactMap { game.rank($0)?.conversationName }
            .filter { !$0.isEmpty }
            .sorted()
        guard !ranks.isEmpty else { return "You have not been granted any special honors." }
        return "You hold the following titles and honors:\n\n" + ranks.joined(separator: "\n")
    }

    /// "June 23rd, 1177" — the long calendar form the game uses in prose.
    private static func longDate(_ d: GameDate) -> String {
        let months = ["January","February","March","April","May","June","July",
                      "August","September","October","November","December"]
        let month = (1...12).contains(d.month) ? months[d.month - 1] : "\(d.month)"
        let suffix: String
        switch d.day % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch d.day % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" }
        }
        return "\(month) \(d.day)\(suffix), \(d.year) NC"
    }
}

/// A player-info tab: the standard three-slice button, drawn in its clicked
/// (depressed) art while its tab is the open one.
private struct InfoTabButton: View {
    let graphics: SpaceportGraphics
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let slices = graphics.buttonSlices(selected ? .clicked : .normal)
            HStack(spacing: 0) {
                slice(slices.left, 13)
                slice(slices.middle, 73)
                slice(slices.right, 13)
            }
            .frame(width: 99, height: 25)
            .overlay(
                Text(title)
                    .font(.custom(NovaFontRole.button.family, size: 12))
                    .foregroundStyle(selected ? Color(white: 0.75) : .white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func slice(_ image: CGImage?, _ w: CGFloat) -> some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.high).resizable()
                .frame(width: w, height: 25)
        } else {
            Color(white: 0.2).frame(width: w, height: 25)
        }
    }
}
