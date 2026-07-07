import SpriteKit
import EVNovaKit
import EVNovaEngine

/// The live game scene. Runs the `EVNovaEngine` simulation and draws it: an
/// infinite parallax starfield, the player ship (real EV Nova sprite when data
/// is loaded, a vector placeholder otherwise), a follow camera and a small HUD.
///
/// The scene reads input from a shared `InputController` each frame and never
/// owns game rules itself — it renders `World` state.
final class GameScene: SKScene {
    private var world: World!
    private var input: InputController!
    private var settings = GameSettings()

    private let cameraNode = SKCameraNode()
    private var shipNode: SKNode!
    private var shipSprite: SKSpriteNode?      // set when a real sprite is used
    private var rotationTextures: [SKTexture] = []
    private var placeholder: SKShapeNode?      // set when no data

    private var starLayers: [StarLayer] = []
    private var hud: SKLabelNode!
    private var lastUpdate: TimeInterval = 0

    /// One parallax layer of wrapping stars. `bases` are the stars' fixed
    /// positions; each frame we wrap `base - camera*parallax` into a tile so the
    /// field repeats infinitely with depth.
    private final class StarLayer {
        let container = SKNode()
        var stars: [SKSpriteNode] = []
        var bases: [CGPoint] = []
        let parallax: CGFloat   // 0 = far (barely moves), 1 = near
        let tile: CGFloat
        init(parallax: CGFloat, tile: CGFloat) { self.parallax = parallax; self.tile = tile }
    }

    // MARK: Setup

    func configure(player ship: Ship, textures: [SKTexture], settings: GameSettings, input: InputController) {
        self.world = World(player: ship)
        self.rotationTextures = textures
        self.settings = settings
        self.input = input
    }

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1)
        scaleMode = .resizeFill
        camera = cameraNode
        addChild(cameraNode)

        buildStarfield()
        buildShip()
        buildHUD()
    }

    private func buildStarfield() {
        let density = max(0.2, settings.starfieldDensity)
        let layerSpecs: [(parallax: CGFloat, count: Int, size: CGFloat, brightness: CGFloat)] = [
            (0.25, Int(90 * density), 1.5, 0.35),
            (0.5,  Int(70 * density), 2.0, 0.55),
            (0.9,  Int(40 * density), 2.5, 0.85),
        ]
        let tile: CGFloat = 1600
        for spec in layerSpecs {
            let layer = StarLayer(parallax: spec.parallax, tile: tile)
            layer.container.zPosition = -100
            for _ in 0..<spec.count {
                let base = CGPoint(x: .random(in: -tile/2...tile/2),
                                   y: .random(in: -tile/2...tile/2))
                let star = SKSpriteNode(color: SKColor(white: spec.brightness, alpha: 1),
                                        size: CGSize(width: spec.size, height: spec.size))
                star.position = base
                layer.container.addChild(star)
                layer.stars.append(star)
                layer.bases.append(base)
            }
            addChild(layer.container)
            starLayers.append(layer)
        }
    }

    private func buildShip() {
        let node = SKNode()
        node.zPosition = 10
        if let first = rotationTextures.first {
            let sprite = SKSpriteNode(texture: first)
            sprite.texture?.filteringMode = .nearest
            node.addChild(sprite)
            shipSprite = sprite
        } else {
            // Vector placeholder so the app is playable before data is imported.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 16))
            path.addLine(to: CGPoint(x: -11, y: -12))
            path.addLine(to: CGPoint(x: 0, y: -5))
            path.addLine(to: CGPoint(x: 11, y: -12))
            path.closeSubpath()
            let tri = SKShapeNode(path: path)
            tri.fillColor = SKColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1)
            tri.strokeColor = .white
            tri.lineWidth = 1
            node.addChild(tri)
            placeholder = tri
        }
        addChild(node)
        shipNode = node
    }

    private func buildHUD() {
        hud = SKLabelNode(fontNamed: "Menlo")
        hud.fontSize = 13
        hud.fontColor = SKColor(white: 0.85, alpha: 0.9)
        hud.horizontalAlignmentMode = .left
        hud.verticalAlignmentMode = .top
        hud.zPosition = 1000
        cameraNode.addChild(hud)
    }

    // MARK: Loop

    override func update(_ currentTime: TimeInterval) {
        guard world != nil else { return }
        let dt = lastUpdate == 0 ? 1.0 / 60.0 : min(currentTime - lastUpdate, 1.0 / 20.0)
        lastUpdate = currentTime

        world.intent = input?.intent ?? .init()
        world.step(dt)

        let p = world.player
        let scenePos = CGPoint(x: p.position.x, y: p.position.y)
        shipNode.position = scenePos

        if let sprite = shipSprite, !rotationTextures.isEmpty {
            sprite.texture = rotationTextures[min(p.spriteFrame, rotationTextures.count - 1)]
        } else if let tri = placeholder {
            tri.zRotation = -CGFloat(p.angle) // compass (cw) → SpriteKit (ccw)
        }

        cameraNode.position = scenePos
        updateStarfield(cameraAt: scenePos)

        let speed = Int(p.velocity.length)
        hud.position = CGPoint(x: -size.width / 2 + 16, y: size.height / 2 - 12)
        hud.text = "\(p.name)   speed \(speed)"
    }

    /// Wrap each star layer around the camera so the field is effectively infinite,
    /// offset by parallax for depth. A star at fixed `base` appears on screen at
    /// `wrap(base - camera*parallax)`, so near layers slide faster than far ones.
    private func updateStarfield(cameraAt cam: CGPoint) {
        func wrap(_ v: CGFloat, _ t: CGFloat) -> CGFloat {
            var r = v.truncatingRemainder(dividingBy: t)
            if r > t / 2 { r -= t }
            if r < -t / 2 { r += t }
            return r
        }
        for layer in starLayers {
            layer.container.position = cam // container follows camera; stars offset within
            for (i, star) in layer.stars.enumerated() {
                let base = layer.bases[i]
                star.position = CGPoint(x: wrap(base.x - cam.x * layer.parallax, layer.tile),
                                        y: wrap(base.y - cam.y * layer.parallax, layer.tile))
            }
        }
    }
}
