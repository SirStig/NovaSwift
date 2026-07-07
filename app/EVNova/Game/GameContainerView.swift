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

    init(model: AppModel) {
        controller = GameControllerInput(input: input)
        scene.scaleMode = .resizeFill

        let ship: Ship
        var textures: [SKTexture] = []
        var planets: [PlanetVisual] = []
        var systemName = ""

        if let game = model.data.game, let res = model.data.defaultPlayerShip() {
            let stats = ShipStats(speed: res.speed, acceleration: res.acceleration,
                                  turnRate: res.turnRate, rotationFrames: 36)
            ship = Ship(name: res.name, stats: stats)
            hud.shipName = res.name
            if let sheet = game.shipSprite(res.id) {
                textures = SpriteTextures.rotationFrames(from: sheet)
            }
            // Load a real starting system and its stellar objects.
            if let system = game.startingSystem() {
                systemName = system.name
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
                        input: input, controller: controller, hud: hud,
                        planets: planets, systemName: systemName)
    }
}

/// The full-screen game view: SpriteKit scene + HUD + platform input
/// (touch on iOS/iPadOS; keyboard + mouse on macOS; game controller on both).
struct GameContainerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host: GameHost?

    var body: some View {
        ZStack {
            if let host {
                sceneLayer(host)
                GameHUDView(model: host.hud)

                #if os(iOS)
                TouchControlsOverlay(input: host.input)
                #endif

                closeButton
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .task { if host == nil { host = GameHost(model: model) } }
    }

    @ViewBuilder
    private func sceneLayer(_ host: GameHost) -> some View {
        // Flight is driven by keybindings (keyboard) + controller + touch.
        // The mouse is reserved for UI/targeting (no auto-follow steering).
        SpriteView(scene: host.scene, options: [.ignoresSiblingOrder])
            .ignoresSafeArea()
            .focusable()
            .focusEffectDisabled()
            .modifier(KeyboardControls(input: host.input, bindings: model.bindings))
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { model.exitToLauncher() } label: {
                    Image(systemName: "xmark")
                        .font(.headline).padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding()
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
            case .firePrimary: input.keyboard.firePrimary = pressed
            case .fireSecondary: input.keyboard.fireSecondary = pressed
            case .none: return .ignored // discrete action — not yet wired
            }
            return .handled
        }
    }
}
