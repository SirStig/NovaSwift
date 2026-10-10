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
    /// Push a spaceport transaction (refuel here, or a ship purchase in
    /// `ShipyardView`) into the live HUD immediately, instead of leaving it
    /// stale until takeoff rebuilds it from the pilot state.
    var onLiveSync: () -> Void = {}
    /// Whether the "Tutorial hints" setting is on — gates the one-time contextual
    /// hints (the welcome-to-the-spaceport banner, the Mission BBS how-to, …).
    var showHints: Bool = false

    @EnvironmentObject private var appModel: AppModel

    @State private var screen: Screen = .hub
    @State private var landingHintDismissed = false
    @State private var showStoryGuide = false
    @State private var storyGuideFocusKey: String?
    enum Screen { case hub, trade, outfit, shipyard, bar, missions }

    // Story runtime for the location-triggered offers this view owns —
    // mainSpaceport (on landing) and the Trade/Shipyard/Outfitter screens. (The
    // Bar and Mission BBS build their own engines for their own AvailLocations.)
    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var rolledLanding = false
    /// Re-arms the shops' idle offer poll (see `pollShopOffers`).
    @State private var shopPoll = 0
    /// Bumped to reopen the Mission BBS afresh after an accept.
    @State private var bbsGeneration = 0

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
                                                    galaxy: galaxy, onLiveSync: onLiveSync, onDone: { screen = .hub })
                    case .outfit:   OutfitterView(graphics: graphics, spob: spob, pilot: pilot,
                                                  galaxy: galaxy, showHints: showHints, onLiveSync: onLiveSync,
                                                  onDone: { screen = .hub })
                    case .shipyard: ShipyardView(graphics: graphics, spob: spob, pilot: pilot,
                                                 galaxy: galaxy, onLiveSync: onLiveSync, onDone: { screen = .hub })
                    case .bar:      BarView(graphics: graphics, spob: spob, pilot: pilot, galaxy: galaxy,
                                            onDone: { screen = .hub })
                    case .missions: MissionBBSView(graphics: graphics, spob: spob, pilot: pilot,
                                                   showHints: showHints, onDone: { screen = .hub },
                                                   onReopen: reopenMissionBBS)
                                        .id(bbsGeneration)
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
                                    onAccept: { acceptOffer(offer) }, onDecline: { declineOffer(offer) },
                                    storylineTag: storylineTag(for: offer.mission.id),
                                    onOpenStoryline: storylineTag(for: offer.mission.id).map { t in { openStoryline(t.key) } })
                    .transition(.opacity)
            }

            // Briefings, refusals and other story texts raised here, one
            // dialog each, in order.
            StoryTextOverlay(services: services)
        }
        .storylineGuideSheet(isPresented: $showStoryGuide, game: game, player: { pilot.state },
                             storylineKey: storyGuideFocusKey)
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
            // A `Q` fired by a mission accepted here closes whatever screen
            // is open; its message waits for the launch.
            services.onCloseSpaceportScreen = { screen = .hub }
            rollLandingOffer()
            autoRecharge()
        }
        .onChange(of: screen) { oldValue, newValue in
            Log.spaceport.debug("Spaceport screen -> \(String(describing: newValue), privacy: .public) at spöb \(spob.id, privacy: .public)")
            // Closing the trade centre, outfitter or shipyard resets the
            // lane-offer context (0x00448660).
            if [.trade, .outfit, .shipyard].contains(oldValue) { clearLaneOfferContext() }
            // Opening a shop can also surface an offer (its own AvailLocation),
            // exactly as EV Nova can hand you a mission when you walk into the
            // trade centre / shipyard / outfitter.
            switch newValue {
            case .trade:    rollOffer(at: .tradeCenter)
            case .shipyard: rollOffer(at: .shipyard)
            case .outfit:   rollOffer(at: .outfitter)
            default: break
            }
            shopPoll += 1
        }
        .task(id: shopPoll) { await pollShopOffers() }
    }

    /// The shops keep offering while open (0x0048d190, 0x004903c0,
    /// 0x00493fc0): every `30 + Random(30)` ticks with no offer up, the next
    /// one in the lane comes.
    private func pollShopOffers() async {
        while !Task.isCancelled {
            let ticks = 30 + Int.random(in: 0..<30)
            try? await Task.sleep(nanoseconds: UInt64(ticks) * 1_000_000_000 / 60)
            guard !Task.isCancelled else { return }
            guard services.pendingOffer == nil, services.storyText == nil else { continue }
            switch screen {
            case .trade:    rollOffer(at: .tradeCenter)
            case .shipyard: rollOffer(at: .shipyard)
            case .outfit:   rollOffer(at: .outfitter)
            default:        return
            }
        }
    }

    private func clearLaneOfferContext() {
        let eng = StoryEngine(game: game, player: pilot.state, services: services,
                              seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        eng.clearLaneOfferContext()
        pilot.state = eng.player
    }

    /// The Mission BBS button (0x0043c470): with every slot taken, or nothing
    /// on the board still eligible, the board doesn't open and a text says
    /// why. After an accept the board reopens, silently closing if empty.
    private func openMissionBBS() {
        let eng = StoryEngine(game: game, player: pilot.state, services: services,
                              seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        if let refusal = eng.missionBBSRefusal(spob: spob.id) {
            pilot.state = eng.player
            if !refusal.isEmpty { services.showStoryText(refusal, title: "") }
            return
        }
        pilot.state = eng.player
        screen = .missions
    }

    private func reopenMissionBBS() {
        let eng = StoryEngine(game: game, player: pilot.state, services: services,
                              seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        let refused = eng.missionBBSRefusal(spob: spob.id) != nil
        pilot.state = eng.player
        if refused { screen = .hub } else { bbsGeneration += 1 }
    }

    // MARK: Location-triggered mission offers

    /// The main spaceport's offer, made once as the player lands — this is what
    /// lets simply touching down hand the player a mission (a new pilot's first
    /// landing surfaces the intro/opening mission here when the data defines one).
    private func rollLandingOffer() {
        guard !rolledLanding else { return }
        rolledLanding = true
        rollOffer(at: .mainSpaceport)
    }

    /// Offer the next mission in this location's lane (0x00448670): the first
    /// eligible one not yet accepted, refused or — since the last change of
    /// screen — failed to activate. The original makes one offer when the
    /// main spaceport opens and one each time a shop does.
    private func rollOffer(at location: MissionOfferLocation) {
        guard services.pendingOffer == nil else { return }   // don't stack offers
        let eng = StoryEngine(game: game, player: pilot.state, services: services,
                              seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = eng
        let mission = eng.nextLaneOffer(at: location, spob: spob.id)
        pilot.state = eng.player                             // the offer context latch
        guard let mission else { return }
        Log.spaceport.debug("Location offer at spöb \(spob.id, privacy: .public) loc=\(String(describing: location), privacy: .public): mission \(mission.id, privacy: .public)")
        if !eng.present(mission) {
            // A can't-refuse offer with no text activated silently.
            pilot.state = eng.player
            pilot.save()
        }
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
    /// Which role sits in which slot is a separate question from where the slots
    /// are: the left column runs Bar / Mission BBS / Trade Center, top to bottom.
    private static let rightSlotY: [String: CGFloat] = ["shipyard": 74, "outfitter": 116, "recharge": 158, "leave": 198]
    private static let leftSlotY: [String: CGFloat] = ["bar": 74, "missionBBS": 116, "tradeCenter": 158]
    private static let leftX: CGFloat = -304
    private static let rightX: CGFloat = 160

    private typealias ButtonItem = (key: String, title: String, action: () -> Void)

    /// Listed top-to-bottom as they appear; `leftSlotY` is what actually places
    /// them, so a port missing a service leaves that slot empty rather than
    /// shifting the rest up.
    private var leftButtonItems: [ButtonItem] {
        var items: [ButtonItem] = []
        if spob.hasBar {
            items.append(("bar", graphics.buttonLabel(SpaceportLabel.bar, fallback: "Bar"), { screen = .bar }))
        }
        // Mission BBS — a standard spaceport service at inhabited ports.
        if !spob.isUninhabited {
            items.append(("missionBBS", graphics.buttonLabel(SpaceportLabel.missionBBS, fallback: "Mission BBS"),
                          { openMissionBBS() }))
        }
        if spob.hasCommodityExchange {
            items.append(("tradeCenter", graphics.buttonLabel(SpaceportLabel.tradeCenter, fallback: "Trade Center"), { screen = .trade }))
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
        PilotEconomy.loadout(pilot.state, galaxy: galaxy)?.maxFuel
    }
    /// Current fuel; a nil saved level (new pilot / never spent) reads as full.
    private var currentFuel: Double { pilot.state.fuel ?? (maxFuel ?? 0) }
    /// True when the tank has room — the only time Recharge is offered.
    private var needsRecharge: Bool {
        guard let maxFuel else { return false }
        return currentFuel < maxFuel - 0.5
    }
    /// Whether the player's fit includes an auto-refueller (`oütf` ModType 19).
    private var hasAutoRecharger: Bool {
        PilotEconomy.loadout(pilot.state, galaxy: galaxy)?.hasAutoRefuel ?? false
    }

    /// The auto-refueller (`Player_RefuelShipWithCredits` 0x004250f0), run on
    /// docking: the same 1 credit a unit as the Recharge button, buying as many
    /// whole units as the credits cover, with no waiver at a dominated world.
    private func autoRecharge() {
        guard hasAutoRecharger, let maxFuel,
              let fill = LandedServices.refuel(fuel: currentFuel, capacity: Int(maxFuel),
                                               credits: pilot.state.credits,
                                               dominated: false, uninhabited: false),
              fill.fuel > currentFuel else { return }
        pilot.state.credits -= fill.cost
        pilot.state.fuel = fill.fuel
        onLiveSync()
        Log.spaceport.debug("Auto-recharger filled fuel to \(fill.fuel, privacy: .public) at spöb \(spob.id, privacy: .public) for \(fill.cost, privacy: .public)cr")
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
                   width: 120, action: depart)
            .novaPlace(space, Self.rightX, Self.rightSlotY["leave"] ?? 198)
    }

    /// The Recharge button (EC-23, 0x00491f30 item 4): nothing at an
    /// uninhabited stellar; otherwise whole fuel units at 1 credit each, as
    /// many as the credits cover, or a free top-up at a dominated stellar.
    private func rechargeShip() {
        guard let maxFuel else {
            Log.spaceport.error("Recharge tapped at spöb \(spob.id, privacy: .public) but no loadout for ship \(pilot.state.shipType, privacy: .public) — no-op")
            return
        }
        guard let fill = LandedServices.refuel(fuel: currentFuel, capacity: Int(maxFuel),
                                               credits: pilot.state.credits,
                                               dominated: pilot.state.hasDominated(spob.id),
                                               uninhabited: spob.isUninhabited) else { return }
        pilot.state.credits -= fill.cost
        pilot.state.fuel = fill.fuel
        onLiveSync()
        Log.spaceport.debug("Recharged fuel to \(fill.fuel, privacy: .public) at spöb \(spob.id, privacy: .public) for \(fill.cost, privacy: .public)cr")
    }

    /// Leaving the spaceport window resets the lane-offer context
    /// (0x00448660, from 0x0047c8e0).
    private func depart() {
        clearLaneOfferContext()
        onDepart()
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
                if !spob.isUninhabited { Button("Mission BBS") { openMissionBBS() } }
                Button("Leave", action: depart).novaProminentButton()
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
    /// After an accept the original closes the board and its caller opens it
    /// again (0x0043c470, 0x00491f30): fresh, or not at all when nothing is
    /// left to offer.
    var onReopen: (() -> Void)? = nil

    @StateObject private var services = AppGameServices()
    @State private var engine: StoryEngine?
    @State private var offered: [MissionRes] = []
    @State private var hintDismissed = false
    /// Close the board once the accept's texts have been read.
    @State private var reopenAfterTexts = false
    private var game: NovaGame { graphics.game }

    var body: some View {
        Group {
            if let frame = graphics.frame(.missionBBS) {
                NovaMenu(frame: frame, overlay: true) { space in
                    HStack(spacing: 0) {
                        NovaText("Mission BBS", size: 10, width: 200, align: .leading, weight: .bold)
                        Spacer(minLength: 0)
                        // The current date (0x00441620).
                        NovaText(OriginalText(game: game).date(for: pilot.state), size: 10,
                                 color: Color(white: 0.75), width: 196, align: .trailing)
                    }
                    .frame(width: 396)
                    .novaPlace(space, -241, -97.5)
                    offerList
                        .frame(width: 195, height: 144)
                        .clipped()
                        .novaPlace(space, -245, -70.5)
                    if let offer = services.pendingOffer {
                        NovaText(offer.title, size: 10, width: 269, weight: .bold)
                            .frame(width: 269, height: 21, alignment: .leading)
                            .novaPlace(space, -22, -66.5)
                        ScrollView(showsIndicators: false) {
                            NovaText(offer.briefingText, size: 10, width: 267, align: .leading)
                        }
                        .frame(width: 267, height: 93)
                        .clipped()
                        .novaPlace(space, -22, -40.5)
                        // The BBS's own fixed labels: STR# 150 #26 "Accept" and
                        // #1 "Leave", never the mïsn's (0x004a1290).
                        NovaButton(graphics: graphics, title: graphics.buttonLabel(26, fallback: "Accept"),
                                   width: 73) { accept(offer) }
                            .novaPlace(space, 11, 69.5)
                    }
                    NovaButton(graphics: graphics,
                               title: graphics.buttonLabel(SpaceportLabel.leave, fallback: "Leave"),
                               width: 73, action: onDone)
                        .novaPlace(space, 113, 69.5)
                }
            } else {
                VStack {
                    Text("Mission BBS").foregroundStyle(.white)
                    MissionBoardView(game: game, pilot: pilot, spob: spob, location: .missionComputer)
                    Button("Leave", action: onDone)
                }.padding()
            }
        }
        .overlay { StoryTextOverlay(services: services) }
        .gameHint(GameHints.missionBBS, active: showHints, dismissed: $hintDismissed)
        .animation(.easeInOut(duration: 0.25), value: hintDismissed)
        .onAppear(perform: buildEngine)
        .onChange(of: services.storyQueue.count) { _, count in
            if count == 0, reopenAfterTexts { reopenAfterTexts = false; reopen() }
        }
    }

    private func reopen() {
        if let onReopen { onReopen() } else { onDone() }
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
                    Button { present(mission) } label: {
                        NovaText(engine?.resolvedName(for: mission) ?? mission.displayName, size: 10,
                                 color: isSelected ? .white : Color(white: 0.65), width: 189)
                            .padding(.vertical, 1.5).padding(.horizontal, 3)
                            .background(isSelected ? Color.white.opacity(0.14) : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.novaPlain)
                }
            }
        }
    }

    private func buildEngine() {
        services.onCloseSpaceportScreen = onDone        // a `Q` from an accept leaves the BBS
        let e = StoryEngine(game: game, player: pilot.state, services: services,
                            seed: StoryEngine.landingSeed(player: pilot.state, spobID: spob.id))
        engine = e
        offered = e.missionComputerList(spob: spob.id)
        if let first = offered.first { present(first) }
    }

    /// Show a listed mission; a can't-refuse one with no offer text
    /// activates on the spot, which counts as an accept.
    private func present(_ mission: MissionRes) {
        guard let engine else { return }
        if !engine.present(mission) {
            pilot.state = engine.player
            pilot.save()
            finishAccept()
        }
    }

    /// Accept: a failed activation keeps the board open (its no-room text
    /// shows over it); a success closes it, and it reopens afresh.
    private func accept(_ offer: MissionOffer) {
        guard let engine else { return }
        let ok = engine.accept(offer.mission.id)
        pilot.state = engine.player
        pilot.save()
        if ok {
            services.pendingOffer = nil
            finishAccept()
        }
    }

    private func finishAccept() {
        if services.storyText == nil { reopen() } else { reopenAfterTexts = true }
    }

}
