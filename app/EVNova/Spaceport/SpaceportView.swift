import SwiftUI
import EVNovaKit
import EVNovaEngine

/// The landed spaceport, rendered entirely from the player's own EV Nova data:
/// the `Spaceport` frame PICT (8500), the planet's landscape PICT, its spaceport
/// `dësc` text, and authentic three-slice buttons that route to the Trade Center,
/// Outfitter, Shipyard and Bar (only those the `spöb` actually offers), plus
/// Leave. This is the hub the Land action drops the player into.
struct SpaceportView: View {
    let graphics: SpaceportGraphics
    let galaxy: Galaxy
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDepart: () -> Void

    @State private var screen: Screen = .hub
    enum Screen { case hub, trade, outfit, shipyard, bar, missions }

    private var game: NovaGame { graphics.game }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The landing hub is always present; the service windows overlay it as
            // dimmed dialogs (EV Nova stacks them over the spaceport), rather than
            // replacing it full-screen.
            hub

            if screen != .hub {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture { screen = .hub }
                    .transition(.opacity)

                Group {
                    switch screen {
                    case .hub:      EmptyView()
                    case .trade:    TradeCenterView(graphics: graphics, spob: spob, pilot: pilot,
                                                    galaxy: galaxy, onDone: { screen = .hub })
                    case .outfit:   OutfitterView(graphics: graphics, spob: spob, pilot: pilot,
                                                  galaxy: galaxy, onDone: { screen = .hub })
                    case .shipyard: ShipyardView(graphics: graphics, spob: spob, pilot: pilot,
                                                 galaxy: galaxy, onDone: { screen = .hub })
                    case .bar:      BarView(graphics: graphics, spob: spob, pilot: pilot, onDone: { screen = .hub })
                    case .missions: MissionBBSView(graphics: graphics, spob: spob, pilot: pilot, onDone: { screen = .hub })
                    }
                }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: screen)
        .onAppear {
            Log.spaceport.info("Landed at spöb \(spob.id, privacy: .public) (\(spob.name, privacy: .public)) — shipyard=\(spob.hasShipyard, privacy: .public) outfitter=\(spob.hasOutfitter, privacy: .public) trade=\(spob.hasCommodityExchange, privacy: .public) bar=\(spob.hasBar, privacy: .public) uninhabited=\(spob.isUninhabited, privacy: .public)")
        }
        .onChange(of: screen) { _, newValue in
            Log.spaceport.debug("Spaceport screen -> \(String(describing: newValue), privacy: .public) at spöb \(spob.id, privacy: .public)")
        }
    }

    // MARK: Hub (frame 8500)

    @ViewBuilder private var hub: some View {
        if let frame = graphics.frame(.spaceport) {
            NovaMenu(frame: frame) { space in
                // The planet's landscape fills the frame's top black area.
                if let land = graphics.landscape(for: spob) {
                    Image(decorative: land, scale: 1).interpolation(.high).resizable()
                        .frame(width: CGFloat(land.width), height: CGFloat(land.height))
                        .novaPlace(space, -306, -256)
                }
                // Planet name, centred just below the landscape.
                NovaText(spob.name, size: 18, width: 470, align: .center)
                    .novaPlace(space, -235, 30)
                // Spaceport description, in the centre panel (wrap 301, as EV Nova).
                ScrollView(showsIndicators: false) {
                    NovaText(game.descText(spob.id), size: 11, width: 301, align: .leading)
                }
                .frame(width: 301, height: 175)
                .novaPlace(space, -149, 70)
                // Service buttons flank the description panel left and right
                // (confirmed by PICT 8500's symmetric left/right button
                // panels — see `buttonColumn`). Ship name/credits are no
                // longer duplicated here since the HUD sidebar stays visible
                // while landed.
                buttonColumn(space)
            }
        } else {
            // No interface PICT in the data — plain fallback so landing still works.
            fallbackHub
        }
    }

    /// Fixed per-role slot offsets (relative to the frame's centre), re-derived
    /// from DITL #1000 against the real 618×517 Spaceport frame (PICT 8500 —
    /// matches DLOG #1000's own bounds exactly): each side column is 4 slots
    /// (items 10/9/6/12 left, items 8/7/3/11 right; all 145×25 at x=3/471),
    /// not 3 — cy = itemTop − 258.5, e.g. right column 74.5/116.5/157.5/197.5.
    /// `leave` used to occupy the right column's 4th slot; DITL item 0 —
    /// (242,551)-(442,576), 200×25, *not* part of either column — shows it's
    /// really a separate, large, centred control below both columns (see
    /// `leaveCX`/`leaveCY`), so it's been moved out here and that 4th slot is
    /// free for a real service. Each role sits at a fixed position regardless
    /// of what else the spöb offers (a planet missing a Shipyard doesn't shift
    /// Outfitter up).
    private static let rightSlotY: [String: CGFloat] = ["shipyard": 74, "outfitter": 116, "recharge": 158]
    private static let leftSlotY: [String: CGFloat] = ["tradeCenter": 74, "bar": 116, "missionBBS": 158]
    private static let leftX: CGFloat = -304
    private static let rightX: CGFloat = 160
    /// DITL #1000 item 0: cx = 242 − 309 ≈ −67, cy = 551 − 258.5 ≈ 293, width
    /// 200 (NovaButton's `width` is the middle span, so pass 200 − 26 = 174).
    private static let leaveCX: CGFloat = -67
    private static let leaveCY: CGFloat = 293
    private static let leaveWidth: CGFloat = 174

    private typealias ButtonItem = (key: String, title: String, action: () -> Void)

    private var leftButtonItems: [ButtonItem] {
        var items: [ButtonItem] = []
        if spob.hasCommodityExchange {
            items.append(("tradeCenter", graphics.buttonLabel(SpaceportLabel.tradeCenter, fallback: "Trade Center"), { screen = .trade }))
        }
        if spob.hasBar {
            items.append(("bar", graphics.buttonLabel(SpaceportLabel.bar, fallback: "Bar"), { screen = .bar }))
        }
        // Mission BBS — a standard spaceport service at inhabited ports.
        if !spob.isUninhabited {
            items.append(("missionBBS", graphics.buttonLabel(SpaceportLabel.missionBBS, fallback: "Mission BBS"),
                          { screen = .missions }))
        }
        return items
    }

    private var rightButtonItems: [ButtonItem] {
        var items: [ButtonItem] = []
        if spob.hasShipyard {
            items.append(("shipyard", graphics.buttonLabel(SpaceportLabel.shipyard, fallback: "Shipyard"), { screen = .shipyard }))
        }
        if spob.hasOutfitter {
            items.append(("outfitter", graphics.buttonLabel(SpaceportLabel.outfitter, fallback: "Outfitter"), { screen = .outfit }))
        }
        // Recharge/refuel — the right column's real 4th slot (DITL item 3).
        // No dedicated `spöb.flags` service bit exists for it (fuel is a base
        // spaceport service, not a togglable one like the bar/shipyard/etc.),
        // so it's gated the same way Mission BBS is: any real, inhabited port.
        if !spob.isUninhabited {
            items.append(("recharge", graphics.buttonLabel(SpaceportLabel.recharge, fallback: "Recharge"), { rechargeShip() }))
        }
        return items
    }

    @ViewBuilder private func buttonColumn(_ space: NovaSpace) -> some View {
        ForEach(leftButtonItems, id: \.key) { item in
            NovaButton(graphics: graphics, title: item.title, width: 120, action: item.action)
                .novaPlace(space, Self.leftX, Self.leftSlotY[item.key] ?? 74)
        }
        ForEach(rightButtonItems, id: \.key) { item in
            NovaButton(graphics: graphics, title: item.title, width: 120, action: item.action)
                .novaPlace(space, Self.rightX, Self.rightSlotY[item.key] ?? 74)
        }
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                   width: Self.leaveWidth, action: onDepart)
            .novaPlace(space, Self.leaveCX, Self.leaveCY)
    }

    /// Tops off the tank — EV Nova refuels for free at any real spaceport, and
    /// this port already does that automatically on landing (`GameContainerView.
    /// refuel()`), so this is mostly a no-op confirmation by the time the
    /// player can tap it; wired for real in case that ever changes.
    private func rechargeShip() {
        guard let maxFuel = galaxy.loadout(shipID: pilot.state.shipType, extraOutfits: pilot.state.outfits)?.maxFuel else {
            Log.spaceport.error("Recharge tapped at spöb \(spob.id, privacy: .public) but no loadout for ship \(pilot.state.shipType, privacy: .public) — no-op")
            return
        }
        pilot.state.fuel = maxFuel
        pilot.save()
        Log.spaceport.debug("Recharged fuel to \(maxFuel, privacy: .public) at spöb \(spob.id, privacy: .public)")
    }

    // MARK: Fallback (data has no interface PICT)

    private var fallbackHub: some View {
        VStack(spacing: 16) {
            Text(spob.name).novaFont(.title, weight: .bold).foregroundStyle(.white)
            ScrollView { Text(game.descText(spob.id)).novaFont(.body).foregroundStyle(.white.opacity(0.85)) }
                .frame(maxHeight: 300)
            HStack {
                if spob.hasShipyard { Button("Shipyard") { screen = .shipyard } }
                if spob.hasOutfitter { Button("Outfitter") { screen = .outfit } }
                if spob.hasCommodityExchange { Button("Trade Center") { screen = .trade } }
                if spob.hasBar { Button("Bar") { screen = .bar } }
                Button("Leave", action: onDepart).buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .novaResponsive()
    }
}

/// The Mission BBS (bulletin board) at a spaceport — `mïsn.AvailLoc ==
/// .missionComputer` (0). Rendered on the mission-BBS frame PICT (8505),
/// listing real offers from `StoryEngine` via `MissionBoardView`.
struct MissionBBSView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var onDone: () -> Void

    private var game: NovaGame { graphics.game }

    var body: some View {
        if let frame = graphics.frame(.missionBBS) {
            NovaMenu(frame: frame, overlay: true) { space in
                NovaText("Mission BBS", size: 16, color: .white, width: 300, align: .center)
                    .novaPlace(space, -150, -150)
                ScrollView(showsIndicators: false) {
                    MissionBoardView(game: game, pilot: pilot, spob: spob, location: .missionComputer, width: 300)
                }
                .frame(width: 300, height: 220)
                .novaPlace(space, -150, -110)
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                           width: 60, action: onDone)
                    .novaPlace(space, -43, 120)
            }
        } else {
            VStack {
                Text("Mission BBS").foregroundStyle(.white)
                MissionBoardView(game: game, pilot: pilot, spob: spob, location: .missionComputer)
                Button("Done", action: onDone)
            }.padding()
        }
    }
}
