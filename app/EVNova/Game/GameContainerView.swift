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
        if let game = model.data.game, let res = model.data.defaultPlayerShip() {
            let stats = ShipStats(speed: res.speed, acceleration: res.acceleration,
                                  turnRate: res.turnRate, rotationFrames: 36)
            ship = Ship(name: res.name, stats: stats)
            hud.shipName = res.name
            if let sheet = game.shipSprite(res.id) {
                textures = SpriteTextures.rotationFrames(from: sheet)
            }
        } else {
            ship = Ship(name: "Test Craft",
                        stats: ShipStats(speed: 300, acceleration: 500, turnRate: 40))
            hud.shipName = "Test Craft"
        }
        scene.configure(player: ship, textures: textures, settings: model.settings,
                        input: input, controller: controller, hud: hud)
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
        GeometryReader { geo in
            SpriteView(scene: host.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .focusable()
                .modifier(KeyboardControls(input: host.input))
                #if os(macOS)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let loc):
                        let dx = loc.x - geo.size.width / 2
                        let dy = loc.y - geo.size.height / 2
                        if hypot(dx, dy) > 24 {
                            host.input.mouse.desiredHeading = Double(atan2(dx, -dy))
                        } else {
                            host.input.mouse.desiredHeading = nil
                        }
                    case .ended:
                        host.input.mouse.desiredHeading = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in host.input.mouse.firePrimary = true }
                        .onEnded { _ in host.input.mouse.firePrimary = false }
                )
                #endif
        }
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

/// Routes hardware-keyboard presses (arrows / WASD / space) into the input sink.
private struct KeyboardControls: ViewModifier {
    let input: InputController
    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .up]) { press in
            let pressed = press.phase == .down
            switch press.key {
            case .leftArrow:  input.setKeyTurnLeft(pressed);  return .handled
            case .rightArrow: input.setKeyTurnRight(pressed); return .handled
            case .upArrow:    input.setKeyThrust(pressed);    return .handled
            case .downArrow:  input.setKeyReverse(pressed);   return .handled
            case .space:      input.setKeyFire(pressed);      return .handled
            default:
                if let c = press.characters.first, input.handleKeyChar(c, pressed: pressed) {
                    return .handled
                }
                return .ignored
            }
        }
    }
}
