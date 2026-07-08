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

    init(model: AppModel, systemID: Int? = nil) {
        controller = GameControllerInput(input: input)
        hudStyle = GameHost.makeHUDStyle(model.data.game)
        scene.scaleMode = .resizeFill

        let pilot = model.pilot.state
        let ship: Ship
        var textures: [SKTexture] = []
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
            // Load the requested system (or the pilot's current one).
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
                                        texture: tex, radius: radius)
                }
                // Start the player a little "south" of the system centre so planets are in view.
                ship.position = Vec2(0, -700)
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
        scene.configure(player: ship, textures: textures, settings: model.settings,
                        input: input, controller: controller, hud: hud, audio: model.audio,
                        planets: planets, systemName: systemName,
                        game: aiGame, systemID: aiSystemID, galaxy: aiGalaxy)
    }

    /// Decode the authentic status bar: the ïntf interface definition + its
    /// backdrop PICT, from the player's own data. Returns nil if unavailable.
    static func makeHUDStyle(_ game: NovaGame?) -> AuthenticHUDStyle? {
        guard let game, let intf = game.interface(),
              let pictData = game.resources.resource(NovaType.pict, intf.backgroundPictID)?.data,
              let sheet = try? PICT.decode(pictData),
              let cg = sheet.makeCGImage() else { return nil }
        return AuthenticHUDStyle(image: cg, intf: intf)
    }
}

/// The full-screen game view: SpriteKit scene + HUD + platform input
/// (touch on iOS/iPadOS; keyboard + mouse on macOS; game controller on both).
struct GameContainerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host: GameHost?
    @StateObject private var nav = NavigationModel(game: nil, startSystemID: 128)
    @State private var navReady = false
    @State private var showMenu = false
    /// The spöb the player is currently landed on (nil = flying).
    @State private var landedSpobID: Int?

    var body: some View {
        ZStack {
            if let host {
                sceneLayer(host)
                if let style = host.hudStyle {
                    AuthenticHUDView(model: host.hud, style: style)   // real EV Nova status bar
                } else {
                    GameHUDView(model: host.hud)                      // fallback (no ïntf in data)
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
        .onChange(of: showMenu) { _, open in host?.scene.isPaused = open }
        .onChange(of: landedSpobID) { _, id in
            host?.scene.isPaused = (id != nil)
            if id != nil {
                DispatchQueue.main.async {
                    refuel()                                   // landing tops off the tank, free
                    model.autosave(reason: .land)               // EV Nova saves on every landing
                }
            }
        }
        .task {
            if host == nil {
                nav.configure(game: model.data.game,
                              startSystemID: model.data.game?.startingSystem()?.id ?? 128)
                host = GameHost(model: model, systemID: nav.currentSystemID)
                syncNav(host)
                navReady = true
            }
        }
        .onChange(of: nav.currentSystemID) { _, newID in
            guard navReady else { return }
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
                host = GameHost(model: model, systemID: newID) // rebuild the system on jump
                syncNav(host)
            }
        }
    }

    /// Leave the spaceport: rebuild the ship/system from the (possibly changed)
    /// pilot so new outfits/hull/cargo take effect, with shields/armor restored —
    /// as EV Nova does on takeoff — and resume flight. Fuel carries over as-is
    /// (landing already topped it off; taking off doesn't spend or grant any).
    private func depart() {
        landedSpobID = nil
        host = GameHost(model: model, systemID: nav.currentSystemID)
        syncNav(host)
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
        nav.jumpAlongRoute()
    }

    @ViewBuilder
    private func sceneLayer(_ host: GameHost) -> some View {
        // Flight is driven by keybindings (keyboard) + controller + touch.
        // The mouse is reserved for UI/targeting (no auto-follow steering).
        SpriteView(scene: host.scene, options: [.ignoresSiblingOrder])
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
        default:
            break
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
            guard let action = bindings.action(for: token) else { return .ignored }
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
                if pressed { onDiscrete(action) }
            }
            return .handled
        }
    }
}
