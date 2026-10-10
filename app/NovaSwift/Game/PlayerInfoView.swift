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
/// `PlayerInfoPages`, the original's stat grid and lists (UI-13).
struct PlayerInfoView: View {
    let graphics: SpaceportGraphics
    @ObservedObject var pilot: PilotStore
    /// The live ship's figures for the stat grid (turn, thrust, speed, shield,
    /// armor, energy); nil leaves those rows out.
    var shipFigures: PlayerInfoPages.ShipFigures? = nil
    /// Jettison the pilot's cargo (also clears the live ship's hold when the
    /// caller can reach it). Nil hides nothing — the button just greys out.
    var onJettison: (() -> Void)?
    var onDone: () -> Void

    @State private var tab: Tab = .general
    /// The original confirms a jettison first (STR# 2002 #291).
    @State private var confirmingJettison = false
    enum Tab: CaseIterable { case general, cargo, extras, honors }

    private var game: NovaGame { graphics.game }
    private static let stockFrameSize = CGSize(width: 413, height: 227)

    /// DLOG/DITL #1017 from the loaded data: the stretchable frame takes the
    /// DLOG's size and every item its DITL rect (stock values as fallback).
    private var ditl: DITLPlacement {
        let stock = DITLPlacement(game, 1017, window: Self.stockFrameSize)
        return DITLPlacement(game, 1017, window: stock.windowSize)
    }
    private var frameSize: CGSize { ditl.window }

    var body: some View {
        GeometryReader { geo in
            let scale = novaFrameScale(frame: frameSize, viewport: geo.size)
            frameBody
                .cursorScaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var frameBody: some View {
        let space = NovaSpace(width: frameSize.width, height: frameSize.height)
        let d = ditl
        let paneRect = d.rect(5, top: 40, left: 4, bottom: 181, right: 409)
        let jettison = d.rect(6, top: 195, left: 60, bottom: 220, right: 210)
        let done = d.rect(0, top: 195, left: 293, bottom: 220, right: 392)
        ZStack(alignment: .topLeading) {
            frameArt
            tabButton(.general, SpaceportLabel.infoGeneral, "General", d.rect(1, top: 8, left: 7, bottom: 33, right: 106))
            tabButton(.cargo,   SpaceportLabel.infoCargo,   "Cargo",   d.rect(2, top: 8, left: 107, bottom: 33, right: 206))
            tabButton(.extras,  SpaceportLabel.infoExtras,  "Extras",  d.rect(3, top: 8, left: 207, bottom: 33, right: 306))
            tabButton(.honors,  SpaceportLabel.infoHonors,  "Honors",  d.rect(4, top: 8, left: 307, bottom: 33, right: 406))

            ScrollView(showsIndicators: false) {
                pane
            }
            .cursorScrollable()
            .frame(width: paneRect.width, height: paneRect.height)
            .clipped()
            .ditlPlace(space, d, paneRect)

            // Drawn only on the Cargo page, and only with something to throw
            // out (0x004a1c40, 0x0046f140).
            if tab == .cargo, onJettison != nil, pages.canJettison {
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.jettisonCargo, fallback: "Jettison Cargo"),
                           ditl: jettison) {
                    confirmingJettison = true
                }
                .ditlPlace(space, d, jettison)
            }

            NovaButton(graphics: graphics,
                       title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                       ditl: done, action: onDone)
                .ditlPlace(space, d, done)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .topLeading)
        .classicConfirm(isPresented: $confirmingJettison,
                                prompt: game.stringList(2002)?.string(at: 291) ?? "",
                                okTitle: graphics.buttonLabel(50, fallback: "Yes"),
                                cancelTitle: graphics.buttonLabel(51, fallback: "No"), fit: false) { onJettison?() }
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
            .frame(width: frameSize.width, height: frameSize.height)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                .frame(width: frameSize.width, height: frameSize.height)
        }
    }

    /// One tab button at DITL row y=8. The active tab renders in the art's
    /// clicked (depressed) state, exactly how the game marks the open tab.
    private func tabButton(_ t: Tab, _ labelIndex: Int, _ fallback: String, _ rect: CGRect) -> some View {
        InfoTabButton(graphics: graphics,
                      title: graphics.buttonLabel(labelIndex, fallback: fallback),
                      selected: tab == t) { tab = t }
            .ditlPlace(NovaSpace(width: frameSize.width, height: frameSize.height), ditl, rect)
    }

    // MARK: - Pane text

    private var pages: PlayerInfoPages { PlayerInfoPages(game: game, player: pilot.state) }

    /// The pane: the original's two-column stat grid on page 1 (0x0049a540;
    /// UI-13), text on the others.
    @ViewBuilder private var pane: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    gridColumn(pages.leftColumn(shipFigures), labelWidth: 75, valueWidth: 120)
                    gridColumn(pages.rightColumn(shipFigures), labelWidth: 70, valueWidth: 120)
                }
                NovaText(pages.dailyEconomy(), size: 10, width: 393, align: .leading)
            }
            .padding(.top, 4).padding(.leading, 6)
        case .cargo:
            paneText(pages.cargo(shipCapacity: PilotEconomy.shipCargoCapacity(pilot.state, galaxy: Galaxy(game: game)),
                                 fleetCapacity: PilotEconomy.cargoCapacity(pilot.state, galaxy: Galaxy(game: game))))
        case .extras:
            paneText(pages.extras(tradeInValue: PilotEconomy.tradeInValue(pilot.state, game: game)))
        case .honors:
            paneText(pages.honors())
        }
    }

    private func paneText(_ s: String) -> some View {
        NovaText(s, size: 10, width: 393, align: .leading)
            .padding(.top, 4).padding(.leading, 6)
    }

    private func gridColumn(_ rows: [PlayerInfoPages.Row], labelWidth: CGFloat, valueWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    NovaText(row.label, size: 9, color: Color(white: 0.6), width: labelWidth, align: .leading)
                    NovaText(row.value, size: 9, width: valueWidth, align: .leading)
                }
            }
        }
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
            ThreeStateButtonArt(slices: graphics.buttonSlices(selected ? .clicked : .normal),
                                totalWidth: 99, label: title,
                                state: selected ? .clicked : .normal,
                                labelColor: selected ? Color(white: 0.75) : .white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.novaPlain)
    }
}
