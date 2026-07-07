import SwiftUI
import SpriteKit
import EVNovaKit
import EVNovaEngine

/// Builds and owns the game scene + input for a play session. Created once per
/// session so the scene is fully configured before SpriteView presents it.
@MainActor
final class GameHost {
    let scene: GameScene
    let input = InputController()

    init(model: AppModel) {
        scene = GameScene(size: CGSize(width: 1024, height: 768))
        scene.scaleMode = .resizeFill

        let ship: Ship
        var textures: [SKTexture] = []
        if let game = model.data.game, let res = model.data.defaultPlayerShip() {
            let stats = ShipStats(speed: res.speed, acceleration: res.acceleration,
                                  turnRate: res.turnRate, rotationFrames: 36)
            ship = Ship(name: res.name, stats: stats)
            if let sheet = game.shipSprite(res.id) {
                textures = SpriteTextures.rotationFrames(from: sheet)
            }
        } else {
            // Placeholder ship so the app is playable before data is imported.
            ship = Ship(name: "Test Craft",
                        stats: ShipStats(speed: 300, acceleration: 500, turnRate: 40))
        }
        scene.configure(player: ship, textures: textures, settings: model.settings, input: input)
    }
}

/// The full-screen game view: SpriteKit scene + hardware-keyboard handling +
/// on-screen touch controls + a back button.
struct GameContainerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host: GameHost?

    var body: some View {
        ZStack {
            if let host {
                SpriteView(scene: host.scene, options: [.ignoresSiblingOrder])
                    .ignoresSafeArea()
                    .focusable()
                    .modifier(KeyboardControls(input: host.input))

                TouchControlsOverlay(input: host.input)
                    .allowsHitTesting(true)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            model.exitToLauncher()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline).padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding()
                    }
                    Spacer()
                }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        }
        .task { if host == nil { host = GameHost(model: model) } }
    }
}

/// Routes hardware-keyboard presses (arrows / WASD / space) into the input sink.
private struct KeyboardControls: ViewModifier {
    let input: InputController
    func body(content: Content) -> some View {
        content.onKeyPress(phases: [.down, .up]) { press in
            let pressed = press.phase == .down
            switch press.key {
            case .leftArrow:  input.setTurnLeft(pressed);   return .handled
            case .rightArrow: input.setTurnRight(pressed);  return .handled
            case .upArrow:    input.setThrust(pressed);     return .handled
            case .downArrow:  input.setReverse(pressed);    return .handled
            case .space:      input.setFirePrimary(pressed); return .handled
            default:
                if let c = press.characters.first, input.handleKeyChar(c, pressed: pressed) {
                    return .handled
                }
                return .ignored
            }
        }
    }
}
