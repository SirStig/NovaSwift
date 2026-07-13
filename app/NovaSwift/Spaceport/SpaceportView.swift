import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

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
    /// Whether the "Tutorial hints" setting is on — gates the one-time contextual
    /// hints (the welcome-to-the-spaceport banner, the Mission BBS how-to, …).
    var showHints: Bool = false

    @State private var screen: Screen = .hub
    @State private var landingHintDismissed = false
    enum Screen { case hub, trade, outfit, shipyard, bar, missions }

    // Story runtime for the location-triggered offers this view owns —
    // mainSpaceport (on landing) and the Trade/Shipyard/Outfitter screens. (The
    // Bar and Mission BBS build their own engines for their own AvailLocations.)
    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []
    @State private var rolledLanding = false

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
                                                  galaxy: galaxy, showHints: showHints, onDone: { screen = .hub })
                    case .shipyard: ShipyardView(graphics: graphics, spob: spob, pilot: pilot,
                                                 galaxy: galaxy, onDone: { screen = .hub })
                    case .bar:      BarView(graphics: graphics, spob: spob, pilot: pilot, onDone: { screen = .hub })
                    case .missions: MissionBBSView(graphics: graphics, spob: spob, pilot: pilot,
                                                   showHints: showHints, onDone: { screen = .hub })
                    }
                }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            // A location-triggered mission offer (landing / trade / shipyard /
            // outfitter) stacks over everything, as its own authentic dialog.
            if let offer = services.pendingOffer {
                Color.black.opacity(0.5).ignoresSafeArea().transition(.opacity)
                MissionSingleDialog(graphics: graphics, offer: offer, offered: [offer.mission],
                                    onPage: { _ in },
                                    onAccept: { acceptOffer(offer) }, onDecline: { declineOffer(offer) })
                    .transition(.opacity)
            }
        }
        // First landing: a quiet banner pointing the player at the Mission BBS,
        // Bar and shops. Only on the hub (hidden while a shop dialog is open) and
        // only until dismissed once.
        .gameHint(GameHints.spaceportServices,
                  active: showHints && screen == .hub,
                  dismissed: $landingHintDismissed)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: screen)
        .animation(.easeInOut(duration: 0.25), value: landingHintDismissed)
        .onAppear {
            Log.spaceport.info("Landed at spöb \(spob.id, privacy: .public) (\(spob.name, privacy: .public)) — shipyard=\(spob.hasShipyard, privacy: .public) outfitter=\(spob.hasOutfitter, privacy: .public) trade=\(spob.hasCommodityExchange, privacy: .public) bar=\(spob.hasBar, privacy: .public) uninhabited=\(spob.isUninhabited, privacy: .public)")
            rollLandingOffer()
        }
        .onChange(of: screen) { _, newValue in
            Log.spaceport.debug("Spaceport screen -> \(String(describing: newValue), privacy: .public) at spöb \(spob.id, privacy: .public)")
            // Opening a shop can also surface an offer (its own AvailLocation),
            // exactly as EV Nova can hand you a mission when you walk into the
            // trade centre / shipyard / outfitter.
            switch newValue {
            case .trade:    rollOffer(at: .tradeCenter)
            case .shipyard: rollOffer(at: .shipyard)
            case .outfit:   rollOffer(at: .outfitter)
            default: break
            }
        }
    }

    // MARK: Location-triggered mission offers

    /// The one-per-landing mainSpaceport roll — this is what lets simply
    /// touching down hand the player a mission (a new pilot's first landing
    /// surfaces the intro/opening mission here when the data defines one).
    private func rollLandingOffer() {
        guard !rolledLanding else { return }
        rolledLanding = true
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        rollOffer(at: .mainSpaceport, engine: e)
    }

    /// Present the top eligible offer for `location` (if any) — availability is
    /// fully gated by `missionsOffered` (AvailBits test + AvailRandom % + record/
    /// rating/ship/stellar), so nothing surfaces that the pilot can't get yet.
    private func rollOffer(at location: MissionOfferLocation, engine e: StoryEngine? = nil) {
        guard services.pendingOffer == nil else { return }   // don't stack offers
        let eng = e ?? engine ?? StoryEngine(game: game, player: pilot.state, services: services,
                                             seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = eng
        offered = eng.missionsOffered(at: location, spob: spob.id)
        guard let mission = offered.first(where: { !eng.briefing(for: $0).isEmpty }) else { return }
        Log.spaceport.debug("Location offer at spöb \(spob.id, privacy: .public) loc=\(String(describing: location), privacy: .public): mission \(mission.id, privacy: .public)")
        eng.present(mission)
    }

    private func acceptOffer(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
    }

    private func declineOffer(_ offer: MissionOffer) {
        guard let engine else { return }
        engine.decline(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
    }

    // MARK: Hub (frame 8500)

    @ViewBuilder private var hub: some View {
        if let frame = graphics.frame(.spaceport) {
            NovaMenu(frame: frame) { space in
                // The landing view's top area — DITL #1000 item 4 (3,3)-(615,288),
                // 612×285. A planet fills it with its landscape PICT; a station
                // (no landing PICT — its `landingPictID` is 0xFFFF) has none, so
                // fall back to the station's own space sprite, centred, rather
                // than leaving the whole area black.
                if let land = graphics.landscape(for: spob) {
                    Image(decorative: land, scale: 1).interpolation(.high).resizable()
                        .frame(width: CGFloat(land.width), height: CGFloat(land.height))
                        .novaPlace(space, -306, -256)
                } else if let sprite = game.spobSprite(spob.id)?.frameCGImage(0) {
                    // Station sprites are low-res (40–300px); fitting one to the
                    // full 612×285 area upscaled it 2–3× into a blur. Fit it to
                    // the area but cap the upscale at 1.5× so it stays crisp,
                    // centred in the top black region.
                    let w = CGFloat(sprite.width), h = CGFloat(sprite.height)
                    let s = min(1.5, min(560 / w, 265 / h))
                    let dw = w * s, dh = h * s
                    Image(decorative: sprite, scale: 1).interpolation(.high).resizable()
                        .frame(width: dw, height: dh)
                        .novaPlace(space, -dw / 2, -113 - dh / 2)
                }
                // Planet/station name — DITL #1000 item 2 (159,297)-(462,315),
                // 303×18, centred just below the top image (was ~8px too high,
                // overlapping the image's bottom edge).
                NovaText(spob.name, size: 15, width: 303, align: .center)
                    .novaPlace(space, -150, 39)
                // Spaceport description, in the centre panel (wrap 301, as EV Nova;
                // Geneva 10 ≈ the reference's 9pt, kept one up for readability and
                // matching every other in-frame body text in this port).
                ScrollView(showsIndicators: false) {
                    NovaText(game.descText(spob.id), size: 10, width: 301, align: .leading)
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
    /// cy = itemTop − 258.5, i.e. right column 74.5/116.5/157.5/197.5.
    /// **Leave** goes in the right column's 4th slot, directly under Recharge
    /// — DITL item 0's own y=551 rect sits ~34px *below* the 517px-tall frame
    /// (the stale-bounds junk this dialog family carries), so a big centred
    /// button there floated in black under the artwork. Using the real 4th
    /// slot keeps it inside the frame and reads cleanly under Recharge.
    private static let rightSlotY: [String: CGFloat] = ["shipyard": 74, "outfitter": 116, "recharge": 158, "leave": 198]
    private static let leftSlotY: [String: CGFloat] = ["tradeCenter": 74, "bar": 116, "missionBBS": 158]
    private static let leftX: CGFloat = -304
    private static let rightX: CGFloat = 160

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
        // Recharge/refuel — the right column's 4th slot. Per the Bible, refuel
        // is a *paid* service by default (free only via a govt's Roadside-
        // Assistance flag or a rank's free-repair flag). So it appears only at
        // an inhabited port AND only when the tank isn't already full — "hides
        // when you don't need to recharge".
        if !spob.isUninhabited, needsRecharge {
            let label = graphics.buttonLabel(SpaceportLabel.recharge, fallback: "Recharge")
            items.append(("recharge", label, { rechargeShip() }))
        }
        return items
    }

    // MARK: Refuel (paid)

    private var maxFuel: Double? {
        galaxy.loadout(shipID: pilot.state.shipType, extraOutfits: pilot.state.outfits)?.maxFuel
    }
    /// Current fuel; a nil saved level (new pilot / never spent) reads as full.
    private var currentFuel: Double { pilot.state.fuel ?? (maxFuel ?? 0) }
    /// True when the tank has room — the only time Recharge is offered.
    private var needsRecharge: Bool {
        guard let maxFuel else { return false }
        return currentFuel < maxFuel - 0.5
    }
    /// Free refuel if the port's government runs "Roadside Assistance" (govt
    /// `Flags2` 0x0010) or the player holds a rank from that govt with the
    /// free-repair/refuel flag (0x0800) — both the Bible's routes to free
    /// service. Otherwise it's paid.
    private var rechargeIsFree: Bool {
        let govtID = spob.government
        if govtID >= 128, let g = game.govt(govtID), g.roadsideAssistance { return true }
        return pilot.state.activeRanks.contains { game.rank($0)?.govt == govtID && (game.rank($0)?.flags ?? 0) & 0x0800 != 0 }
    }
    /// Cost to top off: ~1cr per missing fuel unit (a ~jump's worth ≈ 100cr),
    /// zero when a friendly government/rank comps it.
    private var rechargeCost: Int {
        guard let maxFuel, !rechargeIsFree else { return 0 }
        return max(0, Int((maxFuel - currentFuel).rounded()))
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
        // Leave sits directly below Recharge in the right column's 4th slot.
        NovaButton(graphics: graphics, title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                   width: 120, action: onDepart)
            .novaPlace(space, Self.rightX, Self.rightSlotY["leave"] ?? 198)
    }

    /// Pay to top off the tank. Free when the port's govt/your rank comps it;
    /// otherwise it costs `rechargeCost` and no-ops if the player can't afford
    /// it (the button only shows when the tank has room in the first place).
    private func rechargeShip() {
        guard let maxFuel else {
            Log.spaceport.error("Recharge tapped at spöb \(spob.id, privacy: .public) but no loadout for ship \(pilot.state.shipType, privacy: .public) — no-op")
            return
        }
        let cost = rechargeCost
        guard pilot.state.credits >= cost else {
            Log.spaceport.notice("Recharge no-op at spöb \(spob.id, privacy: .public): cost \(cost, privacy: .public)cr > credits \(pilot.state.credits, privacy: .public)")
            return
        }
        pilot.state.credits -= cost
        pilot.state.fuel = maxFuel
        pilot.save()
        Log.spaceport.debug("Recharged fuel to \(maxFuel, privacy: .public) at spöb \(spob.id, privacy: .public) for \(cost, privacy: .public)cr")
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
/// with real offers from `StoryEngine`.
///
/// Layout straight from DLOG/DITL #1006 "Mission Select" against the real
/// 510×201 frame (PICT 8505; DLOG bounds agree exactly — centre 255,100.5),
/// matching the original's two-pane design:
///   item 7  (14,3)-(410,18)      — header text strip
///   item 1  (10,30)-(205,174)    — mission list, left black panel
///   item 2  (205,30)-(220,174)   — its scrollbar strip
///   item 4  (233,34)-(502,55)    — selected mission's title + pay
///   item 3  (233,60)-(500,153)   — its briefing text, right black panel
///   item 0  (266,170) 99×25      — Accept
///   item 6  (368,170) 99×25      — Done
/// Selecting a row presents that mission through the real `StoryEngine`
/// (`present` → offer with substituted briefing text); Accept runs the full
/// accept flow so every control bit fires. Done just leaves — browsing the
/// board never fires OnRefuse, exactly like the game's mission computer.
struct MissionBBSView: View {
    let graphics: SpaceportGraphics
    let spob: SpobRes
    @ObservedObject var pilot: PilotStore
    var showHints: Bool = false
    var onDone: () -> Void

    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []
    @State private var hintDismissed = false
    private var game: NovaGame { graphics.game }

    var body: some View {
        Group {
            if let frame = graphics.frame(.missionBBS) {
                NovaMenu(frame: frame, overlay: true) { space in
                    NovaText("Mission BBS", size: 10, width: 396, align: .leading, weight: .bold)
                        .novaPlace(space, -241, -97.5)
                    offerList
                        .frame(width: 195, height: 144)
                        .clipped()
                        .novaPlace(space, -245, -70.5)
                    if let offer = services.pendingOffer {
                        HStack(spacing: 4) {
                            NovaText(offer.title, size: 10, width: 185, weight: .bold)
                            Spacer(minLength: 0)
                            NovaText(creditsLabel(offer.mission.pay), size: 10,
                                     color: Color(red: 1, green: 0.85, blue: 0.4), width: 80, align: .trailing)
                        }
                        .frame(width: 269, height: 21)
                        .novaPlace(space, -22, -66.5)
                        ScrollView(showsIndicators: false) {
                            NovaText(offer.briefingText, size: 10, width: 267, align: .leading)
                        }
                        .frame(width: 267, height: 93)
                        .clipped()
                        .novaPlace(space, -22, -40.5)
                        NovaButton(graphics: graphics, title: offer.acceptButton, width: 73) { accept(offer) }
                            .novaPlace(space, 11, 69.5)
                    }
                    NovaButton(graphics: graphics,
                               title: graphics.buttonLabel(SpaceportLabel.done, fallback: "Done"),
                               width: 73, action: onDone)
                        .novaPlace(space, 113, 69.5)
                }
            } else {
                VStack {
                    Text("Mission BBS").foregroundStyle(.white)
                    MissionBoardView(game: game, pilot: pilot, spob: spob, location: .missionComputer)
                    Button("Done", action: onDone)
                }.padding()
            }
        }
        .gameHint(GameHints.missionBBS, active: showHints, dismissed: $hintDismissed)
        .animation(.easeInOut(duration: 0.25), value: hintDismissed)
        .onAppear(perform: buildEngine)
    }

    private var offerList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if offered.isEmpty {
                    NovaText("No missions available.", size: 10, color: Color(white: 0.6), width: 191)
                        .padding(.top, 2).padding(.leading, 2)
                }
                ForEach(offered, id: \.id) { mission in
                    let isSelected = services.pendingOffer?.mission.id == mission.id
                    Button { engine?.present(mission) } label: {
                        NovaText(engine?.resolvedName(for: mission) ?? mission.displayName, size: 10,
                                 color: isSelected ? .white : Color(white: 0.65), width: 189)
                            .padding(.vertical, 1.5).padding(.horizontal, 3)
                            .background(isSelected ? Color.white.opacity(0.14) : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func buildEngine() {
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        offered = e.missionsOffered(at: .missionComputer, spob: spob.id)
        if let first = offered.first { e.present(first) }
    }

    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        _ = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        services.pendingOffer = nil
        offered = engine.missionsOffered(at: .missionComputer, spob: spob.id)
        if let first = offered.first { engine.present(first) }
    }

    private func creditsLabel(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " cr"
    }
}
