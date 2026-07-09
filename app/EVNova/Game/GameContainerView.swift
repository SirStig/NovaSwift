import SwiftUI
import SpriteKit
import EVNovaKit
import EVNovaEngine

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
            let shipID = pilot.shipType
            let res = game.ship(shipID)
            ship = galaxy.makeLoadedShip(shipID, extraOutfits: pilot.outfits)
                ?? Ship(name: res?.name ?? "Ship",
                        stats: ShipStats(speed: res?.speed ?? 300, acceleration: res?.acceleration ?? 400,
                                         turnRate: res?.turnRate ?? 30, rotationFrames: 36))
            ship.cargo = pilot.cargo
            // Fuel doesn't reset on takeoff/jump — seed it from the pilot's saved
            // level (nil = new pilot / never set, so start with a full tank).
            if let lo = galaxy.loadout(shipID: shipID, extraOutfits: pilot.outfits) {
                ship.fuel = pilot.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
            }
            hud.shipName = pilot.shipName.isEmpty ? (res?.name ?? "") : pilot.shipName
            if let sheet = game.shipSprite(shipID) {
                textures = SpriteTextures.rotationFrames(from: sheet)
            }
            // The ship's own authored engine-glow overlay, if this hull has one
            // (real per-hull thruster art from the shän engine layer).
            if let glow = game.engineGlowSprite(shipID) {
                engineTextures = SpriteTextures.rotationFrames(from: glow)
            }
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
                // so planets are in view.
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
                        AuthenticHUDView(model: host.hud, style: style, showRadar: model.settings.showRadar)
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

                #if os(iOS)
                TouchControlsOverlay(input: host.input)
                #endif

                topLeftMenuButton

                if nav.showingMap {
                    GalaxyMapView(nav: nav, pilot: model.pilot, onJump: { _ = attemptJump() }) { nav.showingMap = false }
                        .transition(.opacity)
                }

                LandPromptView(hud: host.hud)
                HailBannerView(hud: host.hud)

                if let state = hailDialogState {
                    hailDialogView(state)
                }

                if showMenu {
                    GameMenuView(hud: host.hud,
                                 onResume: { showMenu = false },
                                 onOpenMap: { nav.showingMap = true })
                }

                // The landed spaceport, drawn from the player's own EV Nova data.
                if let id = landedSpobID, let graphics = host.graphics,
                   let galaxy = host.galaxy, let spob = host.game?.spob(id) {
                    SpaceportView(graphics: graphics, galaxy: galaxy, spob: spob,
                                  pilot: model.pilot, onDepart: depart)
                        .transition(.opacity)
                }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: nav.showingMap)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMenu)
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
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding/quitting is the one moment a manual save/jump/land
            // won't have already caught — e.g. shopping at a spaceport and then
            // leaving the app without departing again. Durable-save whatever the
            // live pilot has right now so it isn't lost.
            if phase != .active { model.autosave(reason: .timer) }
        }
        .onChange(of: landedSpobID) { _, id in
            setScenePaused(id != nil, reason: "landedSpobID=\(id.map(String.init) ?? "nil")")
            if id != nil {
                DispatchQueue.main.async {
                    refuel()                                   // landing tops off the tank, free
                    model.autosave(reason: .land)               // EV Nova saves on every landing
                }
            } else {
                grabSceneFocus(reason: "departed spaceport")   // departed the spaceport: back to flight
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
            }
        }
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
                model.pilot.save()
                model.autosave(reason: .jump)                 // durable per-pilot save on hyperjump
                host = GameHost(model: model, systemID: newID, arrivedViaJump: true) // rebuild on jump
                setScenePaused(false, reason: "jump rebuild")
                syncNav(host)
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
    /// Logs every attempt/outcome (subsystem com.evnova.app, category Input) so
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
        landedSpobID = nil
        model.pilot.save()
        model.autosave(reason: .manual)   // catch any shopping done during this landing
        host = GameHost(model: model, systemID: nav.currentSystemID)
        hostSystemID = nav.currentSystemID
        setScenePaused(false, reason: "depart")
        syncNav(host)
        // `landedSpobID = nil` above also fires `onChange(of: landedSpobID)`,
        // which reasserts focus — but that fires against the *old* host/scene
        // since this rebuild hasn't landed yet. Defer once more here so focus
        // is grabbed after the just-rebuilt scene view actually exists.
        grabSceneFocus(reason: "depart")
    }

    /// Reattach `nav`'s live-fuel/multi-jump sources to the current session's
    /// ship — needed every time `host` is (re)built, since neither survives a
    /// system rebuild on its own.
    private func syncNav(_ host: GameHost?) {
        nav.attachShip(host?.scene.playerShip)
        if let galaxy = host?.galaxy {
            nav.maxJumpHops = model.pilot.maxJumpHops(galaxy: galaxy)
        }
    }

    /// Top off the tank for free — EV Nova refuels on landing at any world you
    /// can set down on. Updates both the live ship (instant HUD feedback) and
    /// the pilot's persisted level (so it survives the next `GameHost` rebuild).
    private func refuel() {
        guard let galaxy = host?.galaxy,
              let maxFuel = galaxy.loadout(shipID: model.pilot.state.shipType,
                                           extraOutfits: model.pilot.state.outfits)?.maxFuel else { return }
        host?.scene.playerShip?.fuel = maxFuel
        model.pilot.state.fuel = maxFuel
    }

    /// The single path a hyperjump commits through, whether triggered from the
    /// map's JUMP button or the `J` key: spends fuel and advances `nav` together.
    @discardableResult
    private func attemptJump() -> Bool {
        let didJump = nav.jumpAlongRoute()
        if didJump { model.audio.play(.hyperspaceCharge) }   // spin-up, before the scene rebuild
        return didJump
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
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
    }

    private func handleDiscrete(_ action: GameAction) {
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
        default:
            break
        }
    }

    /// Hail whatever `GameScene.attemptHail()` resolves to — the locked ship
    /// target, else the click-selected planet, else the nearest ship in
    /// range — and open the communication dialog. Silently does nothing with
    /// no valid target — matches `attemptLand()`'s "no prompt, no action" pattern.
    private func hail() {
        guard let scene = host?.scene, let result = scene.attemptHail() else { return }
        switch result {
        case let .ship(entityID, name, shipTypeID, govt, hostile):
            model.audio.playHailVoice(govt: govt, hostile: hostile)
            hailDialogState = HailDialogState(
                kind: .ship(entityID: entityID, shipTypeID: shipTypeID),
                name: name, govtLabel: govt.targetCode, hostile: hostile,
                responseText: hostile ? "They aren't interested in talking." : "This is \(name). Go ahead.")
        case let .planet(name, govt, landable):
            hailDialogState = HailDialogState(
                kind: .planet, name: name, govtLabel: govt?.targetCode ?? "", hostile: false,
                // "Channel open to X" is the manual's own wording for a stellar hail.
                responseText: landable ? "Channel open to \(name)."
                                       : "Channel open to \(name). Landing clearance is not currently granted.")
        }
    }

    /// Deduct credits and send the hailed ship over to dock with the player
    /// (see `AIBrain.assist`/`World.deliverAssistance`), or decline in-dialog
    /// if the player can't afford it.
    private func requestAssistance(entityID: Int) {
        guard var state = hailDialogState else { return }
        guard model.pilot.state.credits >= assistanceCost else {
            state.responseText = "You don't have enough credits for that."
            hailDialogState = state
            return
        }
        model.pilot.state.credits -= assistanceCost
        host?.scene.requestAssistance(entityID: entityID)
        state.assistRequested = true
        state.responseText = "They're on their way."
        hailDialogState = state
    }

    /// Button list for the hail dialog — a plain (non-`@ViewBuilder`) helper,
    /// since `@ViewBuilder` reinterprets `if`/`switch` as conditional *View*
    /// content even when their body has no view in it, which breaks ordinary
    /// imperative array-building like this.
    private func hailButtons(for state: HailDialogState) -> [NovaDialogButton] {
        var buttons: [NovaDialogButton] = [
            NovaDialogButton(title: "Greetings") {
                hailDialogState?.responseText = state.hostile
                    ? "They don't seem interested in talking."
                    : "Just a routine hail, nothing more."
            },
        ]
        if case let .ship(entityID, _) = state.kind {
            let canAssist = !state.assistRequested && (host?.scene.canRequestAssistance(entityID: entityID) ?? false)
            buttons.append(NovaDialogButton(title: "Request Assistance", enabled: canAssist) {
                requestAssistance(entityID: entityID)
            })
        }
        buttons.append(NovaDialogButton(title: "Close Channel", isDefault: true) { hailDialogState = nil })
        return buttons
    }

    /// The communication dialog: portrait (ships only — no per-government art
    /// exists in the data), name/government, a response line, and up to three
    /// choices (Greetings / Request Assistance / Close Channel).
    @ViewBuilder
    private func hailDialogView(_ state: HailDialogState) -> some View {
        NovaDialog(title: state.name, width: 420, buttons: hailButtons(for: state)) {
            HStack(alignment: .top, spacing: 14) {
                if case let .ship(_, shipTypeID) = state.kind,
                   let res = host?.game?.ship(shipTypeID), let portrait = host?.graphics?.shipPicture(res) {
                    Image(decorative: portrait, scale: 1)
                        .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .background(Color.black.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !state.govtLabel.isEmpty {
                        NovaText(state.govtLabel, size: 12, color: state.hostile ? .red : .secondary)
                    }
                    NovaText(state.responseText, size: 13)
                }
                Spacer(minLength: 0)
            }
        }
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

/// A small centred prompt shown while a landable stellar object is in reach
/// ("Press L to land on …"). Reads the live HUD model so it appears/updates as
/// the player approaches.
private struct LandPromptView: View {
    @ObservedObject var hud: GameHUDModel
    var body: some View {
        VStack {
            Spacer()
            if !hud.landPrompt.isEmpty {
                Text(hud.landPrompt)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hud.landPrompt)
        .allowsHitTesting(false)
    }
}

/// A brief bottom-left banner for ambient, non-interactive system messages —
/// currently just "`<ally>` transfers fuel and makes repairs." after a paid
/// assist delivers (`GameScene`'s `.assistanceDelivered` handler sets and
/// self-clears `hud.hailMessage`). Interactive hailing opens `HailDialogState`
/// instead, not this banner.
private struct HailBannerView: View {
    @ObservedObject var hud: GameHUDModel
    var body: some View {
        VStack {
            Spacer()
            HStack {
                if !hud.hailMessage.isEmpty {
                    Text(hud.hailMessage)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.leading, 16).padding(.bottom, 24)
        }
        .animation(.easeInOut(duration: 0.2), value: hud.hailMessage)
        .allowsHitTesting(false)
    }
}

/// State for the open hail/communication dialog (`GameContainerView.hailDialogView`).
/// `responseText`/`assistRequested` mutate in place as the player clicks buttons,
/// so the dialog updates without closing.
private struct HailDialogState {
    enum Kind {
        case ship(entityID: Int, shipTypeID: Int)
        case planet
    }
    let kind: Kind
    let name: String
    let govtLabel: String
    let hostile: Bool
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
