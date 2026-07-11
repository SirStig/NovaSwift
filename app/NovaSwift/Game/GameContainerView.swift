import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// Builds and owns the game scene, input, controller, and HUD for a play session.
@MainActor
final class GameHost {
    let scene = GameScene(size: CGSize(width: 1024, height: 768))
    let input = InputController()
    let hud = GameHUDModel()
    let controller: GameControllerInput
    /// The authentic status-bar style (ïntf + backdrop PICT), when the data has one.
    let hudStyle: AuthenticHUDStyle?
    /// The loaded game + galaxy + spaceport graphics, exposed so the container can
    /// present the landing screen (which needs `spöb` data and interface PICTs).
    let game: NovaGame?
    let galaxy: Galaxy?
    let graphics: SpaceportGraphics?

    /// Cache of ship-type id → target-display source sprite (dedicated shipyard
    /// art if present, else the in-flight sprite). Keyed with an optional value
    /// so a miss is cached too — the HUD asks on every target change.
    private var targetSpriteCache: [Int: CGImage?] = [:]

    /// The source sprite for a target ship's red silhouette (`ShipSilhouetteView`
    /// applies the red tint + scanlines). Uses the **in-flight sprite**, which
    /// carries a transparency mask, so only the ship's shape tints — the
    /// dedicated shipyard art (`shipPicture`) has a baked opaque background that
    /// would tint into a solid red rectangle. Nil when the data has no sprite.
    func targetSilhouette(shipType id: Int) -> CGImage? {
        if let cached = targetSpriteCache[id] { return cached }
        let img = game?.ship(id).flatMap { graphics?.shipFallbackPicture($0) }
        targetSpriteCache[id] = img
        return img
    }

    init(model: AppModel, systemID: Int? = nil, arrivedViaJump: Bool = false) {
        controller = GameControllerInput(input: input)
        hudStyle = GameHost.makeHUDStyle(model.data.game)
        scene.scaleMode = .resizeFill

        let pilot = model.pilot.state
        let ship: Ship
        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        var planets: [PlanetVisual] = []
        var systemName = ""
        var aiGame: NovaGame?
        var aiGalaxy: Galaxy?
        var aiSystemID = 0

        if let game = model.data.game {
            // Build the player's ship from the *pilot*: its current hull + every
            // installed outfit → real shields/armor/fuel/afterburner/cargo and a
            // resolved weapon set. The pilot's cargo is carried into the hold.
            let galaxy = Galaxy(game: game)
            aiGame = game
            aiGalaxy = galaxy
            // A fresh Galaxy means a fresh Diplomacy (`makeDiplomacy()` caches
            // per-Galaxy, and every jump rebuilds `GameHost` from scratch) — seed
            // it from the persisted pilot so standing survives across jumps.
            // Combat rating isn't seeded here; it's a per-session delta folded
            // into `PlayerState.combatRating` at sync points instead (see
            // `GameContainerView.syncCombatStanding()`).
            galaxy.makeDiplomacy().seed(legalRecord: pilot.legalRecord)
            // Player ship + sprite textures from the current pilot loadout (see
            // `buildPlayerShip`) — the exact same construction the in-place
            // takeoff reload (`GameScene.reloadForDeparture`) uses, so a newly
            // bought hull/outfit takes effect identically on both paths.
            let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
            ship = session.ship
            textures = session.textures
            engineTextures = session.engineTextures
            hud.shipName = session.shipName
            // Load the requested system (or the pilot's current one — every call
            // site passes an explicit systemID today, but this stays as a safe
            // default if that ever changes).
            let target = systemID ?? pilot.currentSystem
            let targetSystem = game.system(target) ?? game.startingSystem()
            if let system = targetSystem {
                systemName = system.name
                aiSystemID = system.id
                planets = game.stellarObjects(in: system.id).map { entry in
                    let tex = entry.sprite.flatMap { $0.frameCGImage(0) }.map { SKTexture(cgImage: $0) }
                    let radius = CGFloat(entry.sprite?.frameWidth ?? 48) / 2
                    return PlanetVisual(id: entry.spob.id, name: entry.spob.name,
                                        position: CGPoint(x: entry.spob.x, y: entry.spob.y),
                                        texture: tex, radius: radius,
                                        government: entry.spob.government,
                                        isUninhabited: entry.spob.isUninhabited)
                }
                // Start the player a little "south" of the system's actual centre
                // (the centroid of its stellar bodies, not necessarily world origin)
                // so planets are in view. (Takeoff positions the ship at the
                // departed body instead — that's handled in the in-place
                // `GameScene.reloadForDeparture`, not this fresh-build path.)
                let sysCenter = galaxy.systemContext(for: system.id).center
                ship.position = sysCenter + Vec2(0, -700)
            }
        } else {
            ship = Ship(name: "Test Craft",
                        stats: ShipStats(speed: 300, acceleration: 500, turnRate: 40))
            hud.shipName = "Test Craft"
        }
        self.game = aiGame
        self.galaxy = aiGalaxy
        self.graphics = aiGame.map { SpaceportGraphics(game: $0) }
        hud.systemName = systemName
        scene.configure(player: ship, textures: textures, engineTextures: engineTextures,
                        settings: model.settings,
                        input: input, controller: controller, hud: hud, audio: model.audio,
                        planets: planets, systemName: systemName,
                        game: aiGame, systemID: aiSystemID, galaxy: aiGalaxy,
                        arrivedViaJump: arrivedViaJump)

        // Contraband scanning: when a government ship finishes scanning the
        // player, its government checks the player's holds/equipment against its
        // `ScanMask` and fines (`ScanFine`) / logs smuggling (`SmugPenalty`).
        // The consequence needs live pilot state, so it's wired from here.
        if let scanGame = aiGame {
            let pilotStore = model.pilot
            scene.onPlayerScanned = { [weak pilotStore, weak hud] scannerGovt in
                guard let pilotStore,
                      let result = ContrabandScan.enforce(on: &pilotStore.state,
                                                           game: scanGame, govtID: scannerGovt),
                      result.foundContraband else { return }
                let name = scanGame.govt(scannerGovt)?.name ?? "Patrol"
                if result.warningOnly {
                    hud?.post("\(name): contraband detected — you are let off with a warning.")
                } else if result.fine > 0 {
                    hud?.post("\(name) fined you \(result.fine)cr for carrying contraband.")
                }
                if result.smugglingPenalty > 0 {
                    hud?.post("\(name) logs your smuggling; your standing worsens.")
                }
                pilotStore.save()
            }
        }
    }

    /// The player's live ship + its sprite textures, built from the current pilot
    /// loadout (hull + installed outfits → shields/armor/fuel/afterburner/cargo +
    /// resolved weapons). Shared by the initial `GameHost` build and the in-place
    /// takeoff reload (`GameScene.reloadForDeparture`) so a newly bought hull or
    /// outfit takes effect identically on both paths. Fuel/armor/shield are seeded
    /// from the pilot's saved levels (nil = full — new pilot / just repaired), so
    /// they persist across a takeoff; the pilot's cargo is carried into the hold.
    struct PlayerSession {
        let ship: Ship
        let textures: [SKTexture]
        let engineTextures: [SKTexture]
        let shipName: String
    }
    static func buildPlayerShip(model: AppModel, galaxy: Galaxy, game: NovaGame) -> PlayerSession {
        let pilot = model.pilot.state
        let shipID = pilot.shipType
        let res = game.ship(shipID)
        let ship = galaxy.makeLoadedShip(shipID, extraOutfits: pilot.outfits)
            ?? Ship(name: res?.displayName ?? "Ship",
                    stats: ShipStats(speed: res?.speed ?? 300, acceleration: res?.acceleration ?? 400,
                                     turnRate: res?.turnRate ?? 30, rotationFrames: 36))
        ship.cargo = pilot.cargo
        if let lo = galaxy.loadout(shipID: shipID, extraOutfits: pilot.outfits) {
            ship.fuel = pilot.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
        }
        ship.armor = pilot.armor.map { min($0, ship.maxArmor) } ?? ship.maxArmor
        ship.shield = pilot.shield.map { min($0, ship.maxShield) } ?? ship.maxShield
        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        if let sheet = game.shipSprite(shipID) { textures = SpriteTextures.rotationFrames(from: sheet) }
        if let glow = game.engineGlowSprite(shipID) { engineTextures = SpriteTextures.rotationFrames(from: glow) }
        let name = pilot.shipName.isEmpty ? (res?.displayName ?? "") : pilot.shipName
        return PlayerSession(ship: ship, textures: textures, engineTextures: engineTextures, shipName: name)
    }

    /// Decode the authentic status bar: the ïntf interface definition + its
    /// backdrop PICT, from the player's own data. Returns nil if unavailable
    /// (the container then falls back to `GameHUDView`, our own non-authentic HUD).
    static func makeHUDStyle(_ game: NovaGame?) -> AuthenticHUDStyle? {
        guard let game else {
            Log.hud.debug("makeHUDStyle: no game loaded — falling back to GameHUDView")
            return nil
        }
        guard let intf = game.interface() else {
            Log.hud.error("makeHUDStyle: no ïntf(128) resource — falling back to GameHUDView")
            return nil
        }
        guard let pictData = game.resources.resource(NovaType.pict, intf.backgroundPictID)?.data else {
            Log.hud.error("makeHUDStyle: backdrop PICT #\(intf.backgroundPictID) missing — falling back to GameHUDView")
            return nil
        }
        guard let sheet = try? PICT.decode(pictData) else {
            Log.hud.error("makeHUDStyle: PICT #\(intf.backgroundPictID) failed to decode — falling back to GameHUDView")
            return nil
        }
        guard let cg = sheet.makeCGImage() else {
            Log.hud.error("makeHUDStyle: PICT #\(intf.backgroundPictID) decoded but makeCGImage() failed — falling back to GameHUDView")
            return nil
        }
        // A radar/status rect with zero or negative width/height (a bad ïntf
        // byte-offset decode against real game data, vs. the synthetic layout
        // the unit tests use) silently collapses that element's SwiftUI frame
        // to nothing — it renders, but is invisible. Log every rect once so a
        // "minimap doesn't show anything" report is instantly diagnosable from
        // Console instead of guessing.
        let rects: [(String, NovaRect)] = [
            ("radarArea", intf.radarArea), ("shieldArea", intf.shieldArea),
            ("armorArea", intf.armorArea), ("fuelArea", intf.fuelArea),
            ("navArea", intf.navArea), ("weaponArea", intf.weaponArea),
            ("targetArea", intf.targetArea), ("cargoArea", intf.cargoArea),
        ]
        for (name, r) in rects {
            if r.width <= 0 || r.height <= 0 {
                Log.hud.error("makeHUDStyle: ïntf.\(name, privacy: .public) decoded to a degenerate rect \(String(describing: r), privacy: .public) (width=\(r.width, privacy: .public) height=\(r.height, privacy: .public)) — it will render invisibly")
            } else {
                Log.hud.debug("makeHUDStyle: ïntf.\(name, privacy: .public) = \(String(describing: r), privacy: .public)")
            }
        }
        return AuthenticHUDStyle(image: cg, intf: intf)
    }
}

/// The full-screen game view: SpriteKit scene + HUD + platform input
/// (touch on iOS/iPadOS; keyboard + mouse on macOS; game controller on both).
struct GameContainerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var host: GameHost?
    @StateObject private var nav = NavigationModel(game: nil, startSystemID: 128)
    @State private var navReady = false
    /// The system id `host` was actually built for. `nav.configure(...)` in the
    /// initial `.task` sets `nav.currentSystemID` synchronously, but SwiftUI
    /// delivers `.onChange(of: nav.currentSystemID)` on the *next* update cycle
    /// — by then `navReady` is already `true`, so that guard alone doesn't
    /// stop the initial configure from being misread as a jump. That spurious
    /// "jump rebuild" created a *second* `GameHost` (own `GameScene` +
    /// `InputController`) moments after the first, while `KeyboardControls`
    /// bound to whichever host was current when SwiftUI re-ran `body` — a
    /// stale/duplicate `InputController` split exactly matching "ship won't
    /// move" (keys write to one instance, the ticking/visible scene reads
    /// from the other — confirmed via the `ObjectIdentifier` logging in
    /// `KeyboardControls` vs. `GameScene.update`'s heartbeat). Comparing
    /// against the system the current host already represents makes the
    /// rebuild idempotent regardless of that delivery-order race.
    @State private var hostSystemID: Int?
    @State private var showMenu = false
    /// The in-game debug suite panel (developer tools), gated by debug mode.
    @State private var showDebugSuite = false
    /// Live debug/performance state for this play session, handed to each
    /// `GameScene` the container (re)builds. Persists across host rebuilds.
    @StateObject private var debug = DebugController()
    /// The spöb the player is currently landed on (nil = flying).
    @State private var landedSpobID: Int?
    /// Keyboard focus for the flight scene. `.focusable()` alone never actually
    /// grabs focus — without binding + explicitly setting this, `.onKeyPress` in
    /// `KeyboardControls` silently never fires and the ship can't be flown at
    /// all. Re-asserted whenever a menu/map/spaceport overlay that took focus
    /// away closes back to flight.
    @FocusState private var isSceneFocused: Bool
    /// The open hail/communication dialog, if any (nil = closed).
    @State private var hailDialogState: HailDialogState?
    /// Mobile action-menu panels the on-screen controls can open over flight.
    @State private var showMissionsPanel = false
    @State private var showPilotInfoPanel = false
    @State private var showEscortsPanel = false
    /// Bumped when an escort order is issued so the command window re-renders
    /// with the new highlighted order (engine state changes don't publish).
    @State private var escortRefresh = 0
    /// The disabled ship currently being boarded (nil = plunder dialog closed).
    @State private var boardManifest: World.BoardingManifest?
    /// Bumped after taking loot so the plunder dialog re-reads the manifest.
    @State private var boardRefresh = 0
    /// Credit cost of "Request Assistance" by how the hailed crew feels about
    /// the player (`GameScene.AssistanceTier`) — allies help for free; a
    /// crew that dislikes the player (negative but not-yet-hostile legal
    /// record) charges a premium and only sometimes agrees at all. No
    /// distance/danger scaling beyond this tier — a deliberate scope cut.
    private let assistanceCostNeutral = 300
    private let assistanceCostWary = 900
    /// Chance a "wary" (dislikes-you-but-not-hostile) crew agrees at all.
    private let assistanceWaryAcceptChance = 0.5

    var body: some View {
        ZStack {
            if let host {
                sceneLayer(host)
                    .focused($isSceneFocused)
                if let style = host.hudStyle {
                    // Constrained to the same capped sidebar width `sceneLayer`
                    // reserves for it (see `Self.sidebarWidth`), and clipped, so
                    // the two never disagree — without this the HUD's own
                    // height-driven `.right` scale would still balloon past the
                    // play viewport's edge on extreme portrait aspect ratios.
                    GeometryReader { geo in
                        AuthenticHUDView(model: host.hud, style: style, showRadar: model.settings.showRadar,
                                         targetSprite: { host.targetSilhouette(shipType: $0) })
                            .frame(width: Self.sidebarWidth(in: geo.size, style: style), height: geo.size.height,
                                   alignment: .trailing)
                            .clipped()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                    .opacity(model.settings.hudOpacity)
                } else {
                    GameHUDView(model: host.hud, showRadar: model.settings.showRadar)                      // fallback (no ïntf in data)
                        .opacity(model.settings.hudOpacity)
                }

                topLeftMenuButton

                if nav.showingMap {
                    GalaxyMapView(nav: nav, pilot: model.pilot, onJump: { _ = attemptJump() }) { nav.showingMap = false }
                        .transition(.opacity)
                }

                MessageLogView(hud: host.hud)

                #if os(iOS)
                // Mounted ABOVE the passive HUD/message/menu-button layers so its
                // buttons (and the expandable action grid) are never drawn under
                // — or blocked by — them; hidden whenever a modal owns the screen
                // so it can't intercept those. The play area stays free for
                // tap/drag-to-fly steering and target taps. Right-hand clusters
                // inset by the status-bar HUD width so they never overlap it.
                if flightControlsVisible {
                    GeometryReader { geo in
                        TouchControlsOverlay(
                            input: host.input, hud: host.hud,
                            viewportSize: geo.size,
                            tapToFly: model.settings.controlScheme == .tapToTurn,
                            rightInset: Self.sidebarWidth(in: geo.size, style: host.hudStyle),
                            onDiscrete: handleDiscrete,
                            onOpenPanel: openMobilePanel)
                    }
                }
                #endif

                // The land prompt sits above the controls; on iOS it's a tappable
                // pill that lands you (replacing the desktop "Press L" hint).
                LandPromptView(hud: host.hud, onLand: { handleDiscrete(.land) })

                if let state = hailDialogState {
                    HailDialogView(
                        state: state, portrait: hailPortrait(state), graphics: host.graphics,
                        showAssistButton: hailShowsAssistButton(state),
                        assistEnabled: hailAssistEnabled(state),
                        onGreetings: {
                            hailDialogState?.responseText = state.hostile
                                ? "They don't seem interested in talking."
                                : "Just a routine hail, nothing more."
                        },
                        onRequestAssistance: {
                            if case let .ship(entityID, _) = state.kind { requestAssistance(entityID: entityID) }
                        },
                        onRequestLanding: { requestPlanetLanding() },
                        onDemandTribute: { demandPlanetTribute() },
                        onClose: { hailDialogState = nil })
                }

                // Mobile action-menu panels (opened from the on-screen controls).
                mobilePanels

                if showMenu {
                    GameMenuView(hud: host.hud,
                                 onResume: { showMenu = false },
                                 onOpenMap: { nav.showingMap = true },
                                 onOpenEscorts: { showEscortsPanel = true },
                                 showDebug: model.settings.debugModeEnabled,
                                 onOpenDebug: { showMenu = false; showDebugSuite = true })
                }

                // Debug suite: an on-screen entry point + live metrics chip while
                // debug mode is on, and the full developer panel when opened. The
                // simulation keeps running underneath so the readout stays live.
                if model.settings.debugModeEnabled {
                    debugControls
                    if showDebugSuite {
                        DebugSuiteView(debug: debug) { showDebugSuite = false }
                            .zIndex(30)
                            .transition(.opacity)
                    }
                }

                // The landed spaceport, drawn from the player's own EV Nova data.
                // Constrained to the same play-viewport width `sceneLayer` uses
                // (not the full window) so the status-bar HUD on the right stays
                // visible — the real game never hides the ship's own readout
                // behind the landing screen.
                if let id = landedSpobID, let graphics = host.graphics,
                   let galaxy = host.galaxy, let spob = host.game?.spob(id) {
                    GeometryReader { geo in
                        let sidebarWidth = Self.sidebarWidth(in: geo.size, style: host.hudStyle)
                        let playWidth = max(0, geo.size.width - sidebarWidth)
                        SpaceportView(graphics: graphics, galaxy: galaxy, spob: spob,
                                      pilot: model.pilot, onDepart: depart)
                            .frame(width: playWidth, height: geo.size.height)
                            .position(x: playWidth / 2, y: geo.size.height / 2)
                    }
                    .transition(.opacity)
                }
            } else {
                GameLoadingView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: nav.showingMap)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMenu)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showDebugSuite)
        .animation(.easeInOut(duration: 0.2), value: landedSpobID)
        .onChange(of: isSceneFocused) { _, focused in
            Log.input.debug("isSceneFocused -> \(focused, privacy: .public)")
        }
        .onChange(of: showMenu) { _, open in
            setScenePaused(open, reason: "showMenu=\(open)")
            // Deferred a tick: setting `@FocusState` in the same transaction that
            // dismisses the overlay stealing focus can silently lose the race on
            // macOS — the scene view has to actually reclaim key status first.
            if !open { grabSceneFocus(reason: "menu closed") }
        }
        .onChange(of: nav.showingMap) { _, open in
            if !open { grabSceneFocus(reason: "map closed") }   // map closed: same
        }
        .onChange(of: nav.route) { _, _ in
            syncNavCourseToHUD(host)
        }
        .onChange(of: hailDialogState != nil) { _, open in
            setScenePaused(open, reason: "hailDialogState=\(open)")
            if !open { grabSceneFocus(reason: "hail dialog closed") }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding/quitting is the one moment a manual save/jump/land
            // won't have already caught — e.g. shopping at a spaceport and then
            // leaving the app without departing again. Durable-save whatever the
            // live pilot has right now so it isn't lost.
            if phase != .active {
                syncCombatStanding()
                model.autosave(reason: .timer)
            }
        }
        .onChange(of: landedSpobID) { _, id in
            setScenePaused(id != nil, reason: "landedSpobID=\(id.map(String.init) ?? "nil")")
            if let id {
                advanceGameDay()                                // landing→depart is one calendar day
                DispatchQueue.main.async {
                    // Inhabited ports restore hull + shields to full for free
                    // (shields regen while docked; hull is patched up). Fuel is
                    // NOT topped off here — refuelling is the paid "Recharge"
                    // service, per the Bible (free only via govt/rank flags).
                    repairOnLanding(spobID: id)
                    syncCombatStanding()
                    model.autosave(reason: .land)               // EV Nova saves on every landing
                }
                model.audio.startAmbient(soundID: host?.game?.spob(id)?.ambientSoundID)
            } else {
                grabSceneFocus(reason: "departed spaceport")   // departed the spaceport: back to flight
                model.audio.stopAmbient()
            }
        }
        .task {
            if host == nil {
                // Resume where the pilot actually left off — `pilot.state` is
                // guaranteed populated by now (finishLoadingIntoGame always calls
                // ensureStarted before this screen shows). Only fall back to the
                // scenario's generic default if that's somehow unresolvable.
                let startSystem = model.data.game?.system(model.pilot.state.currentSystem)?.id
                    ?? model.data.game?.startingSystem()?.id ?? 128
                nav.configure(game: model.data.game, startSystemID: startSystem)
                host = GameHost(model: model, systemID: nav.currentSystemID)
                hostSystemID = nav.currentSystemID
                debug.attach(host?.scene)                              // point the debug suite at the live scene
                setScenePaused(false, reason: "initial host build")   // never start frozen (nothing should set this true yet, but be sure)
                syncNav(host)
                navReady = true
                // Deferred a tick: `host` becoming non-nil and `sceneLayer`
                // actually entering the view tree happen in this same
                // transaction, so grabbing focus in the same breath as creating
                // it can silently lose — the focusable view has to exist first.
                // This is the single most common cause of "ship can't be flown
                // at all" on a fresh pilot: no error, the key events just never
                // arrive because nothing ever became key.
                grabSceneFocus(reason: "initial host build")
                applyControlScheme()
            }
        }
        .onChange(of: model.settings.controlScheme) { _, _ in applyControlScheme() }
        .onChange(of: nav.currentSystemID) { _, newID in
            // `navReady` alone doesn't catch the initial `nav.configure(...)`
            // notification racing this handler (see `hostSystemID`'s doc
            // comment) — skip if `host` already represents this system,
            // whether that's the real reason (redundant delivery) or not.
            guard navReady, newID != hostSystemID else { return }
            hostSystemID = newID
            // The rebuild below touches three different ObservableObjects
            // (pilot, nav, and `host` itself) — piling that onto the same
            // transaction that's still delivering the currentSystemID change
            // trips SwiftUI's "publishing changes from within view updates"
            // and can silently drop the rebuild. Defer it a tick so it runs
            // as its own, clean update.
            DispatchQueue.main.async {
                // Persist the live ship's post-jump fuel before it's torn down
                // (a jump never refuels — only landing does), and mark the
                // system explored.
                model.pilot.state.fuel = host?.scene.playerShip?.fuel
                model.pilot.state.currentSystem = newID       // follow the pilot to the new system
                model.pilot.state.exploredSystems.insert(newID)
                syncCombatStanding()   // the about-to-be-discarded Diplomacy is the source of truth
                model.pilot.save()
                model.autosave(reason: .jump)                 // durable per-pilot save on hyperjump
                host = GameHost(model: model, systemID: newID, arrivedViaJump: true) // rebuild on jump
                debug.attach(host?.scene)                     // re-point the debug suite (a jump ends any stress test)
                setScenePaused(false, reason: "jump rebuild")
                syncNav(host)
                applyControlScheme()
                // A second deferred tick, same reason as the `.task` case above:
                // `host` just changed identity, so the new `sceneLayer` view
                // needs its own transaction to enter the tree before it can
                // become key — reasserting focus in the same breath it's
                // rebuilt in loses the race.
                grabSceneFocus(reason: "jump rebuild")
            }
        }
    }

    /// Sets `scene.isPaused` and logs the transition — this flag is the one
    /// thing that can freeze the *entire* simulation loop (ship, NPCs, HUD all
    /// stop updating), so any "nothing moves" report should start by checking
    /// Console for an unexpected `true` here that never flips back.
    private func setScenePaused(_ paused: Bool, reason: String) {
        host?.scene.isPaused = paused
        Log.scene.debug("isPaused -> \(paused, privacy: .public) (\(reason, privacy: .public))")
    }

    /// Requests keyboard focus for the flight scene, confirming a beat later
    /// that it actually stuck and retrying (bounded) if not. A single
    /// `DispatchQueue.main.async { isSceneFocused = true }` can still lose the
    /// race if the focusable scene view hasn't finished entering the view
    /// hierarchy on that tick — this is the fix for "ship won't move" reports
    /// where keyboard input silently never reaches `KeyboardControls.onKeyPress`.
    /// Logs every attempt/outcome (subsystem com.novaswift.app, category Input) so
    /// the failure mode is visible in Console without attaching a debugger.
    private func grabSceneFocus(reason: String, attempt: Int = 0) {
        DispatchQueue.main.async {
            isSceneFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if isSceneFocused {
                    Log.input.debug("grabSceneFocus(\(reason, privacy: .public)) confirmed, attempt \(attempt)")
                } else if attempt < 5 {
                    Log.input.debug("grabSceneFocus(\(reason, privacy: .public)) attempt \(attempt) didn't stick — retrying")
                    grabSceneFocus(reason: reason, attempt: attempt + 1)
                } else {
                    Log.input.error("grabSceneFocus(\(reason, privacy: .public)) gave up after \(attempt) attempts — keyboard input will not reach the scene")
                }
            }
        }
    }

    /// Leave the spaceport: rebuild the ship/system from the (possibly changed)
    /// pilot so new outfits/hull/cargo take effect, with shields/armor restored —
    /// as EV Nova does on takeoff — and resume flight. Fuel carries over as-is
    /// (landing already topped it off; taking off doesn't spend or grant any).
    private func depart() {
        let departedSpob = landedSpobID     // capture before the line below clears it
        landedSpobID = nil
        // Deferred a tick: `landedSpobID = nil` above fires its own `onChange` in
        // the same transaction as the SpaceportView's `.transition(.opacity)`
        // removal; doing the reload as its own clean update avoids piling model
        // mutations onto that in-flight one.
        DispatchQueue.main.async {
            model.pilot.save()
            model.autosave(reason: .manual)   // catch any shopping done during this landing
            // Takeoff = reload the current system *in place* in the existing
            // scene (rebuilding the ship from the possibly-changed pilot loadout),
            // NOT a fresh `GameHost`. Rebuilding the host swaps the `SpriteView`'s
            // scene, which SwiftUI can only do by tearing the view down and back
            // up (`.id` on the SpriteView) — and that one blank frame during the
            // swap is the "weird screen flash on depart." Reusing the same scene
            // keeps its identity stable (no `.id` teardown → no flash) and leaves
            // keyboard input wired to the same `InputController`. Same pattern the
            // hyperjump uses. Falls back to a full rebuild only if something's
            // missing (no live host/galaxy/game, or an unknown spöb).
            if let host, let galaxy = host.galaxy, let game = host.game, let spob = departedSpob {
                let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
                host.hud.shipName = session.shipName
                host.scene.reloadForDeparture(spobID: spob, player: session.ship,
                                              textures: session.textures,
                                              engineTextures: session.engineTextures)
                setScenePaused(false, reason: "depart (in place)")
                syncNav(host)
                grabSceneFocus(reason: "depart")
            } else {
                host = GameHost(model: model, systemID: nav.currentSystemID)
                hostSystemID = nav.currentSystemID
                debug.attach(host?.scene)
                setScenePaused(false, reason: "depart (rebuild)")
                syncNav(host)
                grabSceneFocus(reason: "depart")
            }
        }
    }

    /// Reattach `nav`'s live-fuel/multi-jump sources to the current session's
    /// ship — needed every time `host` is (re)built, since neither survives a
    /// system rebuild on its own.
    private func syncNav(_ host: GameHost?) {
        nav.attachShip(host?.scene.playerShip)
        if let galaxy = host?.galaxy {
            nav.maxJumpHops = model.pilot.maxJumpHops(galaxy: galaxy)
        }
        syncNavCourseToHUD(host)
    }

    /// Pushes the plotted hyperspace course (if any) into the HUD's Nav
    /// readout — needed both whenever `host` is rebuilt (a fresh `hud` starts
    /// with no course) and whenever the course itself changes (plotted,
    /// advanced, or cleared from the map) without a host rebuild.
    private func syncNavCourseToHUD(_ host: GameHost?) {
        guard let hud = host?.hud else { return }
        if let destID = nav.destinationID, let name = nav.system(destID)?.name {
            hud.navCourseSystemName = name
            hud.navCourseJumps = nav.route.count
        } else {
            hud.navCourseSystemName = ""
            hud.navCourseJumps = 0
        }
    }

    /// Advance the galaxy calendar by one day and announce the new date in the
    /// message log. EV Nova ticks a day on every hyperjump and every landing;
    /// `StoryEngine.advanceOneDay` also runs the day's crön/deadline processing,
    /// so time-gated story events and mission time limits progress with it.
    private func advanceGameDay() {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state)
        engine.advanceOneDay()
        model.pilot.state = engine.player
        host?.hud.post(Self.logDate(model.pilot.state.date))
    }

    /// Short calendar date for the message log, e.g. "23 Jun 1177".
    private static func logDate(_ d: GameDate) -> String {
        let m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let mon = (1...12).contains(d.month) ? m[d.month - 1] : "\(d.month)"
        return "\(d.day) \(mon) \(d.year)"
    }

    /// Free hull + shield restore on landing — but **only at an inhabited port**
    /// (a planet/station people actually live on). Uninhabited rocks give
    /// nothing free: no repair, no shield restore (and no Recharge either). Fuel
    /// is never topped off here — refuelling is the paid Recharge service.
    /// Writes both the live ship (instant HUD feedback) and the persisted pilot,
    /// so the repaired state survives the takeoff `GameHost` rebuild; if the
    /// port is uninhabited we persist the *current* (damaged) values instead, so
    /// the damage carries out with the player.
    private func repairOnLanding(spobID: Int) {
        guard let ship = host?.scene.playerShip else { return }
        let inhabited = host?.game?.spob(spobID)?.isUninhabited == false
        if inhabited {
            ship.shield = ship.maxShield
            ship.armor = ship.maxArmor
        }
        model.pilot.state.armor = ship.armor
        model.pilot.state.shield = ship.shield
    }

    /// Persists whatever combat/legal-standing consequences played out this
    /// session into the pilot: legal record (attacking a government's ships
    /// dents standing with it — see `Diplomacy.recordDisable`/`recordKill`)
    /// and combat rating (Appendix I — sum of destroyed ships' `Strength`).
    /// Call at every point the live `World`/`Diplomacy` might otherwise be
    /// discarded (landing, jump-out) or the app might be backgrounded —
    /// mirrors `repairOnLanding`'s "sync live scene state into the persisted
    /// pilot" pattern for the same reason (a jump rebuilds `GameHost`, and
    /// with it a brand-new, unseeded-until-`GameHost.init` `Diplomacy`).
    private func syncCombatStanding() {
        guard let scene = host?.scene else { return }
        for (govt, value) in scene.liveLegalRecord {
            model.pilot.state.legalRecord[govt] = value
        }
        let delta = scene.consumeCombatRatingDelta()
        if delta != 0 { model.pilot.state.combatRating += delta }
    }

    /// The single path a hyperjump commits through, whether triggered from the
    /// map's JUMP button or the `J` key. Rather than instantly swapping systems
    /// (which read as "the HUD says I've arrived but I still see the old system"),
    /// this hands the whole thing to the live scene: it flies the jump maneuver
    /// (turn → tear away → white flash) and swaps the world *in place* at the
    /// flash peak. The `commit` closure — run by the scene at that peak — is what
    /// actually advances the model (spend fuel, follow the pilot, save), so
    /// `nav.currentSystemID`/the HUD only change at the moment you truly arrive.
    @discardableResult
    private func attemptJump() -> Bool {
        guard let host, !host.scene.isJumping else { return false }
        let hops = nav.nextJumpHopCount
        guard hops > 0, nav.canAfford(hops: hops) else { return false }
        let destID = nav.route[hops - 1]
        let outbound = outboundHeading(from: nav.currentSystemID, to: destID)
        let instant = host.galaxy.map { model.pilot.hasInstantJump(galaxy: $0) } ?? false
        let speed = host.galaxy.map { model.pilot.jumpSpeedFactor(galaxy: $0) } ?? 1
        nav.showingMap = false
        host.scene.beginJump(to: destID, outboundHeading: outbound, instant: instant, speed: speed) {
            // Flash peak: commit the arrival in the model. `commitArrival` spends
            // the fuel and pins the destination even if the route drifted during
            // the animation, so nav and the loaded system can't disagree.
            hostSystemID = destID                              // set first: keeps onChange from also rebuilding the host
            _ = nav.commitArrival(at: destID, hops: hops)
            model.pilot.state.fuel = host.scene.playerShip?.fuel
            model.pilot.state.currentSystem = destID
            model.pilot.state.exploredSystems.insert(destID)
            advanceGameDay()                                   // each hyperjump is one calendar day
            model.pilot.save()
            model.autosave(reason: .jump)                      // EV Nova saves on every hyperjump
            syncNav(host)                                      // refresh course/HUD (ship instance persists the swap)
        }
        return true
    }

    /// Compass heading (world radians, 0 = up) from one system toward another on
    /// the galactic map — the direction the ship turns to before jumping. The map
    /// stores +y downward, so it's flipped into the world's +y-up convention
    /// (`Vec2.angle` == `atan2(x, y)`).
    private func outboundHeading(from: Int, to: Int) -> Double {
        guard let g = model.data.game, let a = g.system(from), let b = g.system(to),
              a.x != b.x || a.y != b.y else { return 0 }
        return atan2(Double(b.x - a.x), Double(-(b.y - a.y)))
    }

    /// How much width the authentic status bar (`AuthenticHUDView`, whose own
    /// `NovaCanvas(fit: .right)` scales to fill the window height) actually
    /// occupies, capped to a fraction of the window so a height-driven scale
    /// can never consume the whole window on extreme portrait aspect ratios
    /// (iPhone). Shared by `sceneLayer` (to size the play viewport) and the
    /// HUD layer itself (to actually constrain it) so the two always agree.
    private static func sidebarWidth(in size: CGSize, style: AuthenticHUDStyle?) -> CGFloat {
        guard let style, style.nativeSize.height > 0 else { return 0 }
        let scale = size.height / style.nativeSize.height
        let natural = style.nativeSize.width * scale
        return min(natural, size.width * 0.35)
    }

    @ViewBuilder
    private func sceneLayer(_ host: GameHost) -> some View {
        // Flight is driven by keybindings (keyboard) + controller + touch.
        // The mouse is reserved for UI/targeting (no auto-follow steering).
        GeometryReader { geo in
            // The authentic status bar reserves screen width on the right, the
            // same way the original game's play area never extended under its
            // sidebar. Shrink the play viewport to match instead of letting the
            // SpriteKit scene (and its ship-centred camera) fill the whole
            // window with the sidebar drawn over the top of it.
            let sidebarWidth = Self.sidebarWidth(in: geo.size, style: host.hudStyle)
            let playWidth = max(0, geo.size.width - sidebarWidth)
            // Click/tap a ship to target it, a planet to set it as the nav
            // destination, or empty space to clear both selections — handled
            // natively in `GameScene.mouseDown`/`touchesBegan`, not via a
            // SwiftUI gesture (unreliable layered on `SpriteView`'s native view).
            SpriteView(scene: host.scene, options: [.ignoresSiblingOrder])
                .frame(width: playWidth, height: geo.size.height)
                .position(x: playWidth / 2, y: geo.size.height / 2)
                // Tie this view's identity to the scene instance. `SpriteView`
                // presents its `scene:` only when the underlying native view is
                // first created; handing it a *new* scene at the same structural
                // position — which `depart()` does when it rebuilds `host` to
                // pick up a newly-bought hull/outfits — does NOT re-present it.
                // The old scene keeps ticking (and reading the old
                // `InputController`) while the keyboard now writes to the new
                // host's input: keys reach one instance, the visible/ticking
                // scene reads the other. That split is the "movement breaks
                // after departing a planet/station" bug. Keying on the scene's
                // identity forces SwiftUI to rebuild the SpriteView (presenting
                // the new scene) on a host swap, while leaving the in-place
                // hyperjump — which reuses the same `host.scene` — untouched.
                .id(ObjectIdentifier(host.scene))
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
    }

    /// The on-screen flight controls show only during actual flight — hidden
    /// while landed or whenever a modal (map, menu, hail, a mobile panel, the
    /// plunder dialog, the debug suite) owns the screen, so they neither draw
    /// over nor steal touches from it.
    private var flightControlsVisible: Bool {
        landedSpobID == nil && !nav.showingMap && !showMenu && hailDialogState == nil
            && !showMissionsPanel && !showPilotInfoPanel && !showEscortsPanel
            && boardManifest == nil && !showDebugSuite
    }

    /// Push the touch steering mode (Settings ▸ Touch scheme) down to the live
    /// scene. Called on every host build and whenever the setting changes, so a
    /// jump-rebuilt scene keeps the player's choice.
    private func applyControlScheme() {
        host?.scene.tapToFlyEnabled = (model.settings.controlScheme == .tapToTurn)
    }

    /// The mobile action-menu panels (missions / pilot info / escorts), reusing
    /// the same authentic dialogs the in-game menu hosts. Extracted from `body`
    /// to keep that expression inside the type-checker's budget.
    @ViewBuilder private var mobilePanels: some View {
        if showMissionsPanel, let graphics = model.uiGraphics, let game = model.data.game {
            MissionInfoView(graphics: graphics, game: game, pilot: model.pilot,
                            onClose: { showMissionsPanel = false })
                .transition(.opacity)
        }
        if showPilotInfoPanel, let graphics = model.uiGraphics {
            Color.black.opacity(0.5).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showPilotInfoPanel = false }
            PlayerInfoView(graphics: graphics, pilot: model.pilot,
                           onJettison: { jettisonHold() },
                           onDone: { showPilotInfoPanel = false })
                .transition(.opacity)
        }
        if showEscortsPanel, let scene = host?.scene {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showEscortsPanel = false }
            let _ = escortRefresh   // re-read the roster after each order
            EscortsView(escorts: scene.escortRoster(),
                        currentOrder: scene.escortOrder,
                        onCommand: { scene.commandEscorts($0); escortRefresh += 1 },
                        onClose: { showEscortsPanel = false })
                .shrinkToFitViewport()
                .transition(.opacity)
        }
        if let m = boardManifest, let scene = host?.scene {
            let _ = boardRefresh   // re-read after taking loot
            PlunderView(
                graphics: host?.graphics,
                targetName: m.name,
                cargoLines: m.cargo.map { PlunderLine(label: commodityLabel($0.commodity),
                                                      amount: "\($0.tons)") },
                creditsAboard: m.credits, ammoAboard: 0, energyAboard: 0,
                captureChance: m.captureChance,
                onTakeCargo: { plunderTakeCargo(scene, shipID: m.shipID) },
                onTakeCredits: { plunderTakeCredits(scene, shipID: m.shipID) },
                onTakeAmmo: {}, onTakeEnergy: {},
                onCaptureShip: { plunderCapture(scene, shipID: m.shipID) },
                onDemandTribute: { plunderTakeCredits(scene, shipID: m.shipID) },
                onDismiss: { boardManifest = nil })
                .transition(.opacity)
        }
    }

    /// A commodity's display name for the plunder manifest (best-effort — most
    /// hulks have empty holds, so this is rarely exercised).
    private func commodityLabel(_ id: Int) -> String {
        if let c = Commodity(rawValue: id) { return host?.game?.commodityName(c) ?? "Cargo" }
        return "Cargo"
    }

    private func refreshBoard(_ scene: GameScene, shipID: Int) {
        boardManifest = scene.boardManifest(shipID)
        boardRefresh += 1
    }

    private func plunderTakeCredits(_ scene: GameScene, shipID: Int) {
        let credits = scene.plunderCredits(shipID)
        guard credits > 0 else { return }
        model.pilot.state.credits += credits
        model.pilot.save()
        host?.hud.post("Took \(credits) credits.")
        refreshBoard(scene, shipID: shipID)
    }

    private func plunderTakeCargo(_ scene: GameScene, shipID: Int) {
        let taken = scene.plunderCargo(shipID)
        guard !taken.isEmpty else { return }
        for (commodity, tons) in taken { model.pilot.state.cargo[commodity, default: 0] += tons }
        model.pilot.save()
        let total = taken.reduce(0) { $0 + $1.tons }
        host?.hud.post("Took \(total) tons of cargo.")
        refreshBoard(scene, shipID: shipID)
    }

    /// Grant a boarded përs ship's ItemClass outfit loot to the pilot (given
    /// automatically on boarding, per the Bible's "given out ... when boarded").
    private func grantBoardingLoot(_ m: World.BoardingManifest) {
        guard let scene = host?.scene else { return }
        let loot = scene.plunderOutfits(m.shipID)
        guard !loot.isEmpty else { return }
        for oid in loot { model.pilot.state.grantOutfit(oid) }
        model.pilot.save()
        let names = Set(loot.compactMap { host?.game?.outfit($0)?.name })
        host?.hud.post("Salvaged \(loot.count) item(s)\(names.isEmpty ? "" : ": \(names.sorted().joined(separator: ", "))").")
    }

    private func plunderCapture(_ scene: GameScene, shipID: Int) {
        if scene.attemptCapture(shipID) {
            host?.hud.post("Ship captured — it joins your escorts.")
            boardManifest = nil
        } else {
            host?.hud.post("Capture attempt failed.")
            refreshBoard(scene, shipID: shipID)
        }
    }

    /// Open one of the mobile action-menu panels over flight.
    private func openMobilePanel(_ panel: MobilePanel) {
        switch panel {
        case .missions:  showMissionsPanel = true
        case .pilotInfo: showPilotInfoPanel = true
        case .escorts:   showEscortsPanel = true
        }
    }

    /// Dump the hold — the mobile Pilot-info panel's "Jettison Cargo".
    private func jettisonHold() {
        model.pilot.state.cargo = [:]
        model.pilot.save()
    }

    private func handleDiscrete(_ action: GameAction) {
        // Ignore sim-affecting flight commands mid-jump — the scene has locked
        // control for the maneuver; landing or re-jumping through it would corrupt
        // the sequence (and pressing J would otherwise pop the map open).
        if host?.scene.isJumping == true {
            switch action { case .land, .hyperjump: return; default: break }
        }
        switch action {
        case .land:
            // Set down on the nearest landable stellar if we're in reach and slow.
            if landedSpobID == nil, let id = host?.scene.attemptLand() { landedSpobID = id }
        case .openMenu, .pauseGame:
            if landedSpobID != nil { return }
            if nav.showingMap { nav.showingMap = false } else { showMenu.toggle() }
        case .galaxyMap:
            nav.showingMap.toggle()
        case .hyperjump:
            // With a course plotted, J engages the hyperdrive along it; with no
            // course, it opens the map so you can plot one.
            if !attemptJump() { nav.showingMap = true }
        case .targetNearest:
            host?.scene.selectNearestTarget()
        case .nearestHostile:
            host?.scene.selectNearestHostile()
        case .targetNext:
            host?.scene.cycleTarget()
        case .clearTarget:
            host?.scene.clearTarget()
        case .hailTarget:
            hail()
        case .selectSecondaryNext:
            host?.scene.cycleSecondaryWeapon(forward: true)
        case .selectSecondaryPrev:
            host?.scene.cycleSecondaryWeapon(forward: false)
        case .toggleCloak:
            host?.scene.togglePlayerCloak()
        case .board:
            // Board the targeted hulk if it's disabled and in reach.
            if let m = host?.scene.attemptBoard() {
                boardManifest = m
                grantBoardingLoot(m)   // përs ItemClass loot is handed over on boarding
            }
        default:
            break
        }
    }

    /// Hail whatever `GameScene.attemptHail()` resolves to — the current
    /// selection, ship or planet — and open the communication dialog.
    /// Silently does nothing with no selection — matches `attemptLand()`'s
    /// "no prompt, no action" pattern.
    private func hail() {
        guard let scene = host?.scene, let result = scene.attemptHail() else { return }
        switch result {
        case let .ship(entityID, name, shipTypeID, govt, hostile):
            model.audio.playHailVoice(govt: govt, hostile: hostile)
            hailDialogState = HailDialogState(
                kind: .ship(entityID: entityID, shipTypeID: shipTypeID),
                name: name, govtLabel: govt.targetCode, hostile: hostile,
                responseText: hostile ? "They aren't interested in talking." : "This is \(name). Go ahead.")
        case let .planet(spobID, name, govt, landable):
            // Hostile when the player is deeply wanted by the stellar's govt
            // (a wanted rating turns its defenders on you) — read straight from
            // the pilot's own legal record so it needs no scene internals.
            let record = govt.flatMap { model.pilot.state.legalRecord[$0.id] } ?? 0
            let hostile = record <= -150
            hailDialogState = HailDialogState(
                kind: .planet(spobID: spobID), name: name, govtLabel: govt?.targetCode ?? "", hostile: hostile,
                landable: landable,
                // "Channel open to X" is the manual's own wording for a stellar hail.
                responseText: landable ? "Channel open to \(name)."
                                       : "Channel open to \(name). Landing clearance is not currently granted.")
        }
    }

    /// Price of asking `tier` for assistance, or nil if it won't help at all.
    private func assistanceCost(for tier: GameScene.AssistanceTier) -> Int? {
        switch tier {
        case .ally: return 0
        case .neutral: return assistanceCostNeutral
        case .wary: return assistanceCostWary
        case .unavailable: return nil
        }
    }

    /// Deduct credits and send the hailed ship over to dock with the player
    /// (see `AIBrain.assist`/`World.deliverAssistance`) — free for allies,
    /// paid for a neutral crew, and only sometimes accepted (at a premium,
    /// charged only on acceptance) by a crew that dislikes the player but
    /// isn't outright hostile. Declines in-dialog if the player can't afford
    /// it or the crew turns the request down.
    private func requestAssistance(entityID: Int) {
        guard var state = hailDialogState,
              let tier = host?.scene.assistanceTier(entityID: entityID),
              let cost = assistanceCost(for: tier) else { return }
        guard model.pilot.state.credits >= cost else {
            state.responseText = "You don't have enough credits for that."
            hailDialogState = state
            return
        }
        if tier == .wary, Double.random(in: 0..<1) > assistanceWaryAcceptChance {
            state.responseText = "Not interested. Try hailing someone who actually likes you."
            hailDialogState = state
            return   // declined — no charge
        }
        model.pilot.state.credits -= cost
        host?.scene.requestAssistance(entityID: entityID)
        state.assistRequested = true
        state.responseText = cost == 0 ? "Of course — they're on their way." : "They're on their way."
        hailDialogState = state
    }

    /// Ask a stellar for landing clearance. A non-hostile world grants it (the
    /// dialog switches to "cleared to land"); a hostile one refuses — you'd have
    /// to bribe or dominate it. Updates the open dialog in place.
    private func requestPlanetLanding() {
        guard var state = hailDialogState, case .planet = state.kind else { return }
        if state.hostile {
            state.responseText = "Request denied. You are not welcome here."
        } else {
            state.landable = true
            state.responseText = "Landing clearance granted. You are cleared to land."
        }
        hailDialogState = state
    }

    /// Demand tribute from a stellar — EV Nova's path to forcefully dominating a
    /// planet/station. The world refuses and turns hostile; defeating its
    /// defenders is what actually dominates it. Full domination combat (spawning
    /// the defense fleet, tribute income, forced landing rights) is a follow-up
    /// that belongs in `GameScene`; this opens hostilities and posts the notice.
    private func demandPlanetTribute() {
        guard var state = hailDialogState, case .planet = state.kind else { return }
        state.hostile = true
        state.landable = false
        state.responseText = "\"You'll get nothing from us!\" The stellar's defenders turn hostile."
        hailDialogState = state
        host?.hud.post("\(state.name) refuses your demand for tribute.")
    }

    private func hailShowsAssistButton(_ state: HailDialogState) -> Bool {
        if case .ship = state.kind { return true }
        return false
    }

    private func hailAssistEnabled(_ state: HailDialogState) -> Bool {
        guard case let .ship(entityID, _) = state.kind, !state.assistRequested else { return false }
        return (host?.scene.assistanceTier(entityID: entityID) ?? .unavailable) != .unavailable
    }

    private func hailPortrait(_ state: HailDialogState) -> CGImage? {
        switch state.kind {
        case let .ship(_, shipTypeID):
            guard let res = host?.game?.ship(shipTypeID) else { return nil }
            return host?.graphics?.shipPicture(res)
        case let .planet(spobID):
            // A stellar comm shows the world/station itself — its **space
            // sprite** (the sphere or station you see in-system), not the
            // ground-level landing landscape. Fall back to the landscape only if
            // the spob defines no sprite.
            if let sprite = host?.game?.spobSprite(spobID)?.frameCGImage(0) { return sprite }
            guard let spob = host?.game?.spob(spobID) else { return nil }
            return host?.graphics?.landscape(for: spob)
        }
    }

    /// The developer entry point shown while debug mode is on: a debug button
    /// and a live fps/ship chip, tucked under the menu button (clear of the
    /// right-edge status bar). Both open the full debug suite.
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showDebugSuite = true } label: {
                        Image(systemName: "ladybug.fill")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color(red: 0.35, green: 0.95, blue: 0.5).opacity(0.5)))
                            .foregroundStyle(Color(red: 0.35, green: 0.95, blue: 0.5))
                    }
                    .buttonStyle(.plain)
                    DebugMetricsChip(debug: debug) { showDebugSuite = true }
                }
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 14)
        .padding(.top, 68)   // below the hamburger menu button
        .opacity(showDebugSuite || showMenu ? 0 : 1)
        .allowsHitTesting(!showDebugSuite && !showMenu)
        .zIndex(15)
    }

    // The single in-game entry point: one unobtrusive button in the top-left
    // (clear of the right-edge status bar) that opens the consolidated menu.
    private var topLeftMenuButton: some View {
        VStack {
            HStack {
                Button { showMenu = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.semibold))
                        .padding(11)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.top, 12)
                .opacity(showMenu ? 0 : 1)
                Spacer()
            }
            Spacer()
        }
    }
}

/// Shown while `GameHost` builds the live scene (ship + planet sprites, HUD
/// art) for the destination system — a synchronous decode that can take a
/// visible moment on mobile hardware. Matches `LoadingView`'s starfield/
/// wordmark treatment so this brief gap reads as an intentional loading
/// screen rather than a stalled black one.
private struct GameLoadingView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            StarfieldBackground()

            VStack(spacing: 18) {
                AppLogo()
                    .frame(width: 88, height: 88)
                    .shadow(color: novaAmber.opacity(0.28), radius: 28)
                    .scaleEffect(pulse ? 1.03 : 1.0)

                Text("NOVA SWIFT")
                    .novaFont(.title, weight: .heavy, size: 34)
                    .tracking(8)
                    .foregroundStyle(.white)

                LinearGradient(colors: [.clear, novaAmber.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 260, height: 1)

                ProgressView()
                    .tint(novaAmber)
                    .scaleEffect(1.2)
                    .padding(.top, 8)

                Text("Entering the system…")
                    .novaFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// The land prompt at the bottom-centre of the screen. On macOS it's the plain
/// EV Nova on-screen text hint ("Press L to land on …"). On iOS the desktop
/// keyboard hint is meaningless, so when you're cleared to set down it becomes a
/// **tappable amber "Land" pill** — the actual control, not a description of one
/// — falling back to a plain "Slow down…" hint when you're too fast.
private struct LandPromptView: View {
    @ObservedObject var hud: GameHUDModel
    var onLand: () -> Void = {}

    var body: some View {
        VStack {
            Spacer()
            content
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .novaResponsive()
        .animation(.easeInOut(duration: 0.15), value: hud.landPrompt)
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if hud.landReady, !hud.landName.isEmpty {
            Button(action: onLand) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Land on \(hud.landName)").lineLimit(1)
                }
                .font(.custom(NovaFontRole.hud.family, size: NovaFontRole.hud.baseSize).weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(novaAmber))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if !hud.landName.isEmpty {
            hint("Slow down to land on \(hud.landName)").allowsHitTesting(false)
        }
        #else
        if !hud.landPrompt.isEmpty { hint(hud.landPrompt).allowsHitTesting(false) }
        #endif
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .novaFont(.hud, weight: .semibold)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .transition(.opacity)
    }
}

/// The rolling bottom-left message log: the calendar date on each jump/land,
/// hail replies, mission notices and any other transient game message, as plain
/// stacked text that fades out on its own timer (`GameHUDModel.post`). No panel
/// or border — just the log, like the original.
private struct MessageLogView: View {
    @ObservedObject var hud: GameHUDModel
    var body: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hud.messages) { m in
                        Text(m.text)
                            .novaFont(.hud, weight: .semibold)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                            .transition(.opacity)
                    }
                }
                Spacer()
            }
            .padding(.leading, 16).padding(.bottom, 24)
        }
        .novaResponsive()
        .allowsHitTesting(false)
    }
}

/// State for the open hail/communication dialog (`HailDialogView`).
/// `responseText`/`assistRequested` mutate in place as the player clicks buttons,
/// so the dialog updates without closing.
struct HailDialogState {
    enum Kind {
        case ship(entityID: Int, shipTypeID: Int)
        case planet(spobID: Int)
    }
    let kind: Kind
    let name: String
    let govtLabel: String
    /// Mutable: demanding tribute turns a stellar hostile in place.
    var hostile: Bool
    /// Whether the player currently has landing clearance here (planet hails).
    var landable = true
    var responseText: String
    var assistRequested = false
}

/// Routes hardware-keyboard presses into flight intents using the user's
/// keybindings. Continuous actions (turn/thrust/fire) are held; discrete actions
/// (target/jump/map/…) will dispatch once their systems exist.
private struct KeyboardControls: ViewModifier {
    let input: InputController
    let bindings: KeyBindings
    var onDiscrete: (GameAction) -> Void = { _ in }

    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .up]) { press in
            let pressed = press.phase == .down
            let token = KeyToken.from(press)
            // If keys reach the scene at all but nothing binds, or nothing ever
            // logs here on press, it confirms the ship-won't-move failure is
            // upstream of this view (focus never grabbed — see grabSceneFocus)
            // rather than a bad/missing keybinding.
            guard let action = bindings.action(for: token) else {
                Log.input.debug("key \(String(describing: token), privacy: .public) -> no binding")
                return .ignored
            }
            Log.input.debug("key \(String(describing: token), privacy: .public) -> \(String(describing: action), privacy: .public) pressed=\(pressed, privacy: .public)")
            switch action.flightEffect {
            case .turnLeft: input.keyboard.turnLeft = pressed
            case .turnRight: input.keyboard.turnRight = pressed
            case .thrust: input.keyboard.thrust = pressed
            case .reverse: input.keyboard.reverse = pressed
            case .afterburner: input.keyboard.afterburner = pressed
            case .firePrimary: input.keyboard.firePrimary = pressed
            case .fireSecondary: input.keyboard.fireSecondary = pressed
            case .none:
                // Discrete action (map / jump / target / …): fire once on key-down.
                // `onDiscrete` ends up mutating `@State`/`@Published` (showMenu,
                // nav.showingMap, nav.currentSystemID via a jump, landedSpobID…).
                // Doing that synchronously here publishes changes while SwiftUI
                // is still mid-dispatch of this very key event — "Publishing
                // changes from within view updates", which doesn't just warn on
                // this path, it corrupts the attribute graph and crashes/hangs
                // the scene (see GeometryReader/AttributeInvalidatingSubscriber
                // in the crash trace). Defer to the next run-loop tick so the
                // key event's own update finishes first.
                if pressed { DispatchQueue.main.async { onDiscrete(action) } }
            }
            // Read back immediately, off the same `input` reference this handler
            // was given, tagged with its identity — if `GameScene.update`'s own
            // heartbeat ever logs a *different* identity than this one, two
            // separate `InputController` instances are in play (e.g. a stale
            // capture across a host rebuild) and that's the whole bug.
            if case .none = action.flightEffect {} else {
                Log.input.debug("  -> wrote to InputController#\(ObjectIdentifier(input).debugDescription, privacy: .public) keyboard.thrust=\(input.keyboard.thrust, privacy: .public) intent.thrust=\(input.intent.thrust, privacy: .public)")
            }
            return .handled
        }
    }
}
