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
                    case .bar:      BarView(graphics: graphics, spob: spob, onDone: { screen = .hub })
                    case .missions: MissionBBSView(graphics: graphics, spob: spob, onDone: { screen = .hub })
                    }
                }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: screen)
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
                .novaPlace(space, -149, 66)
                // Player readout on the left panel.
                leftPanel.novaPlace(space, -300, 62)
                // Service buttons on the right panel.
                buttonColumn(space)
            }
        } else {
            // No interface PICT in the data — plain fallback so landing still works.
            fallbackHub
        }
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            NovaText(pilot.state.shipName.isEmpty ? game.ship(pilot.state.shipType)?.name ?? "" : pilot.state.shipName,
                     size: 11, color: Color(white: 0.85), width: 130, align: .leading)
            NovaText(credits(pilot.state.credits), size: 11, color: Color(red: 1, green: 0.85, blue: 0.4),
                     width: 130, align: .leading)
        }
    }

    private func buttonColumn(_ space: NovaSpace) -> some View {
        var items: [(String, () -> Void)] = []
        if spob.hasShipyard {
            items.append((graphics.buttonLabel(SpaceportLabel.shipyard, fallback: "Shipyard"), { screen = .shipyard }))
        }
        if spob.hasOutfitter {
            items.append((graphics.buttonLabel(SpaceportLabel.outfitter, fallback: "Outfitter"), { screen = .outfit }))
        }
        if spob.hasCommodityExchange {
            items.append((graphics.buttonLabel(SpaceportLabel.tradeCenter, fallback: "Trade Center"), { screen = .trade }))
        }
        if spob.hasBar {
            items.append((graphics.buttonLabel(SpaceportLabel.bar, fallback: "Bar"), { screen = .bar }))
        }
        // Mission BBS — a standard spaceport service at inhabited ports.
        if !spob.isUninhabited {
            items.append((graphics.buttonLabel(SpaceportLabel.missionBBS, fallback: "Mission BBS"),
                          { screen = .missions }))
        }
        items.append((graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"), onDepart))

        // Vertically centre the column of service buttons within the frame, so
        // they fit regardless of how many the spöb offers.
        let btnH: CGFloat = 25, gap: CGFloat = 9
        let totalH = CGFloat(items.count) * btnH + CGFloat(items.count - 1) * gap
        let firstTop = -totalH / 2   // relative to the frame's vertical centre
        return ForEach(Array(items.enumerated()), id: \.offset) { i, item in
            NovaButton(graphics: graphics, title: item.0, width: 120, action: item.1)
                .novaPlace(space, 150, firstTop + CGFloat(i) * (btnH + gap))
        }
    }

    // MARK: Fallback (data has no interface PICT)

    private var fallbackHub: some View {
        VStack(spacing: 16) {
            Text(spob.name).font(.title.bold()).foregroundStyle(.white)
            ScrollView { Text(game.descText(spob.id)).foregroundStyle(.white.opacity(0.85)) }
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
    }

    private func credits(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}

/// The Mission BBS (bulletin board) at a spaceport. Rendered on the mission-BBS
/// frame PICT (8505) as a dialog. The mission runtime is being built separately;
/// this presents the authentic frame and a placeholder until missions are wired.
struct MissionBBSView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    var onDone: () -> Void

    var body: some View {
        if let frame = graphics.frame(.missionBBS) {
            NovaMenu(frame: frame, overlay: true) { space in
                NovaText("Mission BBS", size: 16, color: .white, width: 300, align: .center)
                    .novaPlace(space, -150, -150)
                NovaText("No missions available at this time.",
                         size: 12, color: Color(white: 0.7), width: 300, align: .center)
                    .novaPlace(space, -150, -110)
                NovaButton(graphics: graphics,
                           title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                           width: 60, action: onDone)
                    .novaPlace(space, -43, 120)
            }
        } else {
            VStack { Text("Mission BBS").foregroundStyle(.white); Button("Done", action: onDone) }.padding()
        }
    }
}
