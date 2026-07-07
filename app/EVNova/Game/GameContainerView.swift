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

    init(model: AppModel, systemID: Int? = nil) {
        controller = GameControllerInput(input: input)
        hudStyle = GameHost.makeHUDStyle(model.data.game)
        scene.scaleMode = .resizeFill

        let ship: Ship
        var textures: [SKTexture] = []
        var planets: [PlanetVisual] = []
        var systemName = ""
        var aiGame: NovaGame?
        var aiGalaxy: Galaxy?
        var aiSystemID = 0

        if let game = model.data.game, let res = model.data.defaultPlayerShip() {
            // Build the player's ship through the loadout system: hull stats +
            // preinstalled outfits → real shields/armor/fuel/afterburner/cargo and
            // a resolved weapon set. Falls back to bare flight stats if needed.
            let galaxy = Galaxy(game: game)
            aiGame = game
            aiGalaxy = galaxy
            ship = galaxy.makeLoadedShip(res.id)
                ?? Ship(name: res.name,
                        stats: ShipStats(speed: res.speed, acceleration: res.acceleration,
                                         turnRate: res.turnRate, rotationFrames: 36))
            hud.shipName = res.name
            if let sheet = game.shipSprite(res.id) {
                textures = SpriteTextures.rotationFrames(from: sheet)
            }
            // Load the requested system (or a default starting system).
            let targetSystem = systemID.flatMap { game.system($0) } ?? game.startingSystem()
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
                    GalaxyMapView(nav: nav) { nav.showingMap = false }
                        .transition(.opacity)
                }

                if showMenu {
                    GameMenuView(hud: host.hud,
                                 onResume: { showMenu = false },
                                 onOpenMap: { nav.showingMap = true })
                }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: nav.showingMap)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMenu)
        .onChange(of: showMenu) { _, open in host?.scene.isPaused = open }
        .task {
            if host == nil {
                nav.configure(game: model.data.game,
                              startSystemID: model.data.game?.startingSystem()?.id ?? 128)
                host = GameHost(model: model, systemID: nav.currentSystemID)
                navReady = true
            }
        }
        .onChange(of: nav.currentSystemID) { _, newID in
            guard navReady else { return }
            host = GameHost(model: model, systemID: newID)  // rebuild the system on jump
        }
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
        case .openMenu, .pauseGame:
            if nav.showingMap { nav.showingMap = false } else { showMenu.toggle() }
        case .galaxyMap:
            nav.showingMap.toggle()
        case .hyperjump:
            nav.showingMap = true
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
