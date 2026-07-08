import SpriteKit
import EVNovaKit
import EVNovaEngine

/// A stellar object to render in the scene (planet / station / wormhole).
struct PlanetVisual {
    let id: Int
    let name: String
    let position: CGPoint     // in-system coordinates
    let texture: SKTexture?
    let radius: CGFloat
    let government: Int
    /// A dead rock / derelict station with no functioning population — greyed on radar.
    let isUninhabited: Bool
}

/// The live game scene. Runs the `EVNovaEngine` simulation and draws it: an
/// infinite parallax starfield, the player ship (real EV Nova sprite when data
/// is loaded, a vector placeholder otherwise) with an engine exhaust plume, a
/// follow camera, and a HUD driven via `GameHUDModel`.
final class GameScene: SKScene {
    private var world: World!
    private var input: InputController!
    private var controllerInput: GameControllerInput?
    private var hud: GameHUDModel?
    private var settings = GameSettings()
    private var audio: GameAudio?
    private var wasFiring = false

    private let cameraNode = SKCameraNode()
    private var shipNode: SKNode!
    private var shipSprite: SKSpriteNode?
    private var rotationTextures: [SKTexture] = []
    private var placeholder: SKShapeNode?
    private var thruster: SKNode!
    /// Smoothed (not raw-random-per-frame) flame alpha/scale — see `NPCNode`.
    private var thrusterAlpha: CGFloat = 0.85
    private var thrusterFlameScale: CGFloat = 1.0
    private var shipRadius: CGFloat = 16

    private var starLayers: [StarLayer] = []
    private var planetVisuals: [PlanetVisual] = []
    private var planetNodes: [SKNode] = []
    private let projectileLayer = SKNode()
    private var projectileNodes: [SKShapeNode] = []
    private var systemName = ""
    /// True when this scene was just built because the player jumped in from
    /// hyperspace (not a fresh game start, a landing depart, or a load) — the
    /// only case that should show the player's own warp-in effect.
    private var arrivedViaJump = false
    private var lastUpdate: TimeInterval = 0
    private var hudClock: TimeInterval = 0
    // Radar scope radius in world units. Stellar objects sit within ~900 units
    // of the system centre (p90 across the base data) and combat happens within
    // a couple of thousand, so 3000 keeps the scope readable edge to edge.
    private let radarRange: CGFloat = 3000
    // Ship art is native-pixel-sized (authored for 640×480-era screens) and the
    // camera previously ran at SpriteKit's default scale of 1.0 (1 world unit =
    // 1 screen point), so on a modern window the play area showed only a tiny
    // sliver of the system — far less than `radarRange` implies — while making
    // everything feel crowded/too-close. Zooming the camera out widens the
    // visible world per window without touching any world-space simulation math.
    private let cameraZoom: CGFloat = 1.75

    // Landing: the nearest landable stellar object, and whether the player is
    // close/slow enough to set down on it right now. `attemptLand()` (called by
    // the container on the Land action) returns that spöb id when landing is
    // allowed; the HUD shows `landPrompt` while a pad is in reach.
    private(set) var nearestLandableID: Int?
    private(set) var canLandNow = false
    private let landingSpeedLimit: Double = 130
    /// Read-only handle to the live player ship (fuel top-up / cargo sync on land).
    var playerShip: Ship? { world?.player }
    /// The spöb to land on if the player may set down this instant, else nil.
    func attemptLand() -> Int? { canLandNow ? nearestLandableID : nil }

    // NPC rendering: the catalog for per-hull sprites, a layer for NPC ships, a
    // layer for transient effects (explosions / beams), and the live node pool.
    private var galaxy: Galaxy?
    private let npcLayer = SKNode()
    private let effectsLayer = SKNode()
    private var npcNodes: [Int: NPCNode] = [:]
    private var npcTextureCache: [Int: [SKTexture]] = [:]
    // An arrival effect to play when a node is first built for a ship that just
    // jumped in from hyperspace (warp streak) or lifted off a planet (grow out).
    private enum EntranceFX { case warpIn, launch }
    private var pendingEntrance: [Int: EntranceFX] = [:]

    private final class StarLayer {
        let container = SKNode()
        var stars: [SKSpriteNode] = []
        var bases: [CGPoint] = []
        let parallax: CGFloat
        let tile: CGFloat
        init(parallax: CGFloat, tile: CGFloat) { self.parallax = parallax; self.tile = tile }
    }

    /// The SpriteKit nodes backing one live NPC ship: hull (real sprite or a
    /// faction-tinted placeholder), an engine plume, and a damage bar.
    private final class NPCNode {
        let container = SKNode()
        var sprite: SKSpriteNode?
        var placeholder: SKShapeNode?
        var thruster: SKNode?
        var healthFill: SKShapeNode?
        var healthBar: SKNode?
        var textures: [SKTexture] = []
        var radius: CGFloat = 16
        var lastArmor: Double = -1
        /// Smoothed (not raw-random-per-frame) flame alpha/scale so the plume
        /// reads as a flicker, not a strobe.
        var thrusterAlpha: CGFloat = 0.8
        var thrusterFlameScale: CGFloat = 1.0
    }

    // MARK: Setup

    func configure(player ship: Ship, textures: [SKTexture], settings: GameSettings,
                   input: InputController, controller: GameControllerInput?, hud: GameHUDModel?,
                   audio: GameAudio? = nil,
                   planets: [PlanetVisual] = [], systemName: String = "",
                   game: NovaGame? = nil, systemID: Int = 0, galaxy: Galaxy? = nil,
                   arrivedViaJump: Bool = false) {
        // With game data we build a fully-wired, *populated* world (diplomacy +
        // spawner + system geometry) so the system fills with NPC traders, patrols
        // and pirates. Without it we fall back to a lone-ship physics world.
        if let game, systemID != 0 {
            let (w, gx) = GameSession.makeWorld(game: game, systemID: systemID,
                                                player: ship, galaxy: galaxy)
            self.world = w
            self.galaxy = gx
        } else {
            self.world = World(player: ship)
        }
        self.rotationTextures = textures
        self.settings = settings
        self.input = input
        self.controllerInput = controller
        self.hud = hud
        self.audio = audio
        self.planetVisuals = planets
        self.systemName = systemName
        self.arrivedViaJump = arrivedViaJump
    }

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1)
        scaleMode = .resizeFill
        camera = cameraNode
        cameraNode.setScale(cameraZoom)
        addChild(cameraNode)
        buildStarfield()
        buildPlanets()
        npcLayer.zPosition = 9
        addChild(npcLayer)
        projectileLayer.zPosition = 11
        addChild(projectileLayer)
        effectsLayer.zPosition = 12
        addChild(effectsLayer)
        buildShip()
        if arrivedViaJump {
            // The player just jumped in: place the ship/camera immediately (don't
            // wait a frame) and play the same warp-in pop + streak NPCs get on
            // hyperspace arrival, so a jump reads as arriving somewhere, not a
            // silent scene swap.
            let p = world.player
            let scenePos = CGPoint(x: p.position.x, y: p.position.y)
            shipNode.position = scenePos
            cameraNode.position = scenePos
            applyEntrance(.warpIn, to: shipNode, at: scenePos, heading: p.angle)
        }
        // Arriving in the system.
        audio?.play(.hyperspaceArrive)
    }

    private func buildPlanets() {
        for p in planetVisuals {
            let node: SKNode
            if let tex = p.texture {
                let sprite = SKSpriteNode(texture: tex)
                sprite.texture?.filteringMode = .nearest
                node = sprite
            } else {
                // Fallback disc for stellars whose art we can't decode yet (e.g. PICT).
                let disc = SKShapeNode(circleOfRadius: max(24, p.radius))
                disc.fillColor = SKColor(red: 0.25, green: 0.35, blue: 0.6, alpha: 1)
                disc.strokeColor = SKColor(white: 1, alpha: 0.3)
                node = disc
            }
            node.position = p.position
            node.zPosition = 5
            let label = SKLabelNode(fontNamed: "Menlo")
            label.text = p.name
            label.fontSize = 11
            label.fontColor = SKColor(white: 0.8, alpha: 0.8)
            label.verticalAlignmentMode = .top
            label.position = CGPoint(x: 0, y: -p.radius - 6)
            node.addChild(label)
            addChild(node)
            planetNodes.append(node)
        }
    }

    private func buildStarfield() {
        let density = max(0.2, settings.starfieldDensity)
        let specs: [(parallax: CGFloat, count: Int, size: CGFloat, brightness: CGFloat)] = [
            (0.25, Int(90 * density), 1.5, 0.35),
            (0.5,  Int(70 * density), 2.0, 0.55),
            (0.9,  Int(40 * density), 2.5, 0.85),
        ]
        let tile: CGFloat = 1600
        for spec in specs {
            let layer = StarLayer(parallax: spec.parallax, tile: tile)
            layer.container.zPosition = -100
            for _ in 0..<spec.count {
                let base = CGPoint(x: .random(in: -tile/2...tile/2), y: .random(in: -tile/2...tile/2))
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
            shipRadius = max(first.size().width, first.size().height) / 2
        } else {
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
            shipRadius = 16
        }

        // Engine exhaust plume (behind the hull). Hidden unless thrusting. Sized
        // relative to the hull (16 = the old fixed placeholder radius, kept as
        // the reference scale so default-sized ships look unchanged).
        thruster = makeThruster(scale: max(0.5, shipRadius / 16))
        thruster.isHidden = true
        node.addChild(thruster)

        addChild(node)
        shipNode = node
    }

    /// A simple additive flame: an outer amber and inner white teardrop. `scale`
    /// sizes it relative to the hull it's mounted on (a fighter and a capital
    /// ship shouldn't get the same absolute-size flame).
    private func makeThruster(scale: CGFloat = 1.0) -> SKNode {
        let container = SKNode()
        func flame(_ w: CGFloat, _ h: CGFloat, _ color: SKColor) -> SKShapeNode {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: -h), control: CGPoint(x: w, y: -h * 0.4))
            p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -w, y: -h * 0.4))
            let s = SKShapeNode(path: p)
            s.fillColor = color; s.strokeColor = .clear; s.blendMode = .add
            return s
        }
        container.addChild(flame(7 * scale, 26 * scale, SKColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 0.9)))
        container.addChild(flame(3.5 * scale, 16 * scale, SKColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 0.95)))
        return container
    }

    // MARK: Loop

    override func update(_ currentTime: TimeInterval) {
        guard world != nil else { return }
        let dt = lastUpdate == 0 ? 1.0 / 60.0 : min(currentTime - lastUpdate, 1.0 / 20.0)
        lastUpdate = currentTime

        controllerInput?.poll()
        let intent = input?.intent ?? .init()
        world.intent = intent
        world.step(dt)

        let p = world.player
        let scenePos = CGPoint(x: p.position.x, y: p.position.y)

        // The world fires each ready weapon mount itself (respecting reload and
        // ammo). We drain its events for SFX and render the live projectiles it
        // spawned, so firing reflects the real weapon system, not the raw input.
        for event in world.drainEvents() {
            switch event {
            case let .weaponFired(shooterID, at, _):
                // The player's shots report right at the listener; NPC fire is
                // positional and quieter so a busy system doesn't roar.
                if shooterID == 0 {
                    audio?.play(208, at: CGPoint(x: at.x, y: at.y), listener: scenePos)
                }
            case let .beam(from, to, hit):
                spawnBeam(from: CGPoint(x: from.x, y: from.y),
                          to: CGPoint(x: to.x, y: to.y), hit: hit)
            case let .explosion(at, radius):
                spawnExplosion(at: CGPoint(x: at.x, y: at.y), radius: CGFloat(radius))
            case let .shipArrived(entityID, _, fromHyperspace):
                // Only inbound hyperspace jumps get the warp effect (played when the
                // node is built); mid-system populate spawns appear silently.
                if fromHyperspace { pendingEntrance[entityID] = .warpIn }
            case let .shipLaunched(entityID, _):
                pendingEntrance[entityID] = .launch
            case let .shipDeparted(entityID, at, heading):
                warpOutNode(id: entityID, at: CGPoint(x: at.x, y: at.y), heading: heading)
            case let .shipLanded(entityID, spobID, at):
                landNode(id: entityID, spobID: spobID, at: CGPoint(x: at.x, y: at.y))
            case let .shipDisabled(_, at):
                spawnDisableFlash(at: CGPoint(x: at.x, y: at.y))
            default:
                break
            }
        }
        wasFiring = intent.firePrimary
        syncProjectiles()
        syncNPCs()
        shipNode.position = scenePos

        if let sprite = shipSprite, !rotationTextures.isEmpty {
            sprite.texture = rotationTextures[min(p.spriteFrame, rotationTextures.count - 1)]
        } else if let tri = placeholder {
            tri.zRotation = -CGFloat(p.angle)
        }

        updateThruster(active: intent.thrust || p.afterburnerActive, angle: p.angle,
                       boosted: p.afterburnerActive)

        cameraNode.position = scenePos
        updateStarfield(cameraAt: scenePos)
        updateLanding(player: p)
        updateHUD(dt: dt)
    }

    /// Find the nearest landable stellar body and decide whether the player is in
    /// range and slow enough to land. Sets the HUD's land prompt accordingly.
    private func updateLanding(player p: Ship) {
        var bestID: Int?
        var bestDist = Double.greatestFiniteMagnitude
        var bestReach = 0.0
        for body in world.systemContext.bodies where body.canLand {
            let d = (body.position - p.position).length
            if d < bestDist { bestDist = d; bestID = body.id; bestReach = body.radius + 55 }
        }
        nearestLandableID = bestID
        let inReach = bestID != nil && bestDist <= bestReach
        canLandNow = inReach && p.velocity.length <= landingSpeedLimit
        if let id = bestID, inReach {
            let name = world.systemContext.bodies.first { $0.id == id }
                .flatMap { _ in planetVisuals.first { $0.id == id }?.name } ?? "the spaceport"
            hud?.landPrompt = canLandNow ? "Press L to land on \(name)"
                                         : "Slow down to land on \(name)"
        } else {
            hud?.landPrompt = ""
        }
    }

    private func updateThruster(active: Bool, angle: Double, boosted: Bool = false) {
        thruster.isHidden = !active
        guard active else { return }
        // Sit at the tail (opposite heading) and point backward, with a flicker.
        let back = -angle
        let tail = CGPoint(x: sin(angle) * -shipRadius * 0.7, y: cos(angle) * -shipRadius * 0.7)
        thruster.position = tail
        thruster.zRotation = CGFloat(back)
        // The afterburner plume is longer and brighter than normal thrust. Flame
        // size follows the hull's own radius (set once in buildShip) so a fighter
        // and a capital ship don't get the same-sized flame. The jitter is
        // low-pass filtered (blend toward a new random target each frame, not
        // snapped straight to it) so it reads as a flicker, not a strobe.
        let boostMul: CGFloat = boosted ? 1.5 : 1.0
        thrusterFlameScale = thrusterFlameScale * 0.85 + CGFloat.random(in: 0.85...1.15) * 0.15
        thruster.setScale(boostMul * thrusterFlameScale)
        let targetAlpha: CGFloat = boosted ? .random(in: 0.9...1.0) : .random(in: 0.75...1.0)
        thrusterAlpha = thrusterAlpha * 0.85 + targetAlpha * 0.15
        thruster.alpha = thrusterAlpha
    }

    /// Mirror the world's live projectiles into a pool of dot nodes (reusing nodes
    /// across frames, hiding the surplus). Beams are instantaneous and handled via
    /// events, so only travelling projectiles are drawn here.
    private func syncProjectiles() {
        let shots = world.projectiles
        while projectileNodes.count < shots.count {
            let dot = SKShapeNode(circleOfRadius: 2.2)
            dot.fillColor = SKColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
            dot.strokeColor = .clear
            dot.blendMode = .add
            projectileLayer.addChild(dot)
            projectileNodes.append(dot)
        }
        for (i, node) in projectileNodes.enumerated() {
            if i < shots.count {
                let s = shots[i]
                node.position = CGPoint(x: s.position.x, y: s.position.y)
                node.isHidden = false
            } else {
                node.isHidden = true
            }
        }
    }

    // MARK: NPC ships

    /// Reconcile the scene's NPC nodes with the world's live NPC roster: spawn
    /// nodes for arrivals, update transforms/plume/damage for the living, and
    /// remove nodes for ships that died or jumped out.
    private func syncNPCs() {
        var seen = Set<Int>()
        for npc in world.npcs {
            seen.insert(npc.entityID)
            let node = npcNodes[npc.entityID] ?? makeNPCNode(for: npc)
            node.container.position = CGPoint(x: npc.position.x, y: npc.position.y)
            if let sprite = node.sprite, !node.textures.isEmpty {
                sprite.texture = node.textures[min(npc.spriteFrame, node.textures.count - 1)]
            } else if let tri = node.placeholder {
                tri.zRotation = -CGFloat(npc.angle)
            }
            if npc.disabled {
                // A drifting hulk: dimmed, engines dead, no health readout.
                setDisabledLook(node, on: true)
                node.thruster?.isHidden = true
                node.healthBar?.isHidden = true
            } else {
                setDisabledLook(node, on: false)
                updateNPCThruster(node, npc: npc)
                updateNPCHealth(node, npc: npc)
            }
        }
        for (id, node) in npcNodes where !seen.contains(id) {
            node.container.removeFromParent()
            npcNodes[id] = nil
        }
    }

    private func makeNPCNode(for npc: Ship) -> NPCNode {
        let n = NPCNode()
        n.container.zPosition = 9

        let textures = npcTextures(for: npc.shipTypeID)
        n.textures = textures
        if let first = textures.first {
            let sprite = SKSpriteNode(texture: first)
            sprite.texture?.filteringMode = .nearest
            n.container.addChild(sprite)
            n.sprite = sprite
            n.radius = max(first.size().width, first.size().height) / 2
        } else {
            // Faction-tinted arrowhead when we can't resolve the hull sprite.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 14))
            path.addLine(to: CGPoint(x: -10, y: -11))
            path.addLine(to: CGPoint(x: 0, y: -4))
            path.addLine(to: CGPoint(x: 10, y: -11))
            path.closeSubpath()
            let tri = SKShapeNode(path: path)
            tri.fillColor = factionColor(for: npc)
            tri.strokeColor = SKColor(white: 1, alpha: 0.5)
            tri.lineWidth = 1
            n.container.addChild(tri)
            n.placeholder = tri
            n.radius = CGFloat(npc.radius)
        }

        // Sized relative to this hull (16 = the old fixed placeholder radius,
        // kept as the reference scale) instead of one fixed size for every ship.
        let thruster = makeThruster(scale: max(0.5, n.radius / 16) * 0.8)
        thruster.isHidden = true
        n.container.addChild(thruster)
        n.thruster = thruster

        // A slim armor/shield bar that only appears once the ship is hurt.
        let barWidth: CGFloat = max(20, n.radius * 1.6)
        let barBG = SKShapeNode(rectOf: CGSize(width: barWidth, height: 3), cornerRadius: 1.5)
        barBG.fillColor = SKColor(white: 0, alpha: 0.5)
        barBG.strokeColor = .clear
        let fill = SKShapeNode(rectOf: CGSize(width: barWidth, height: 3), cornerRadius: 1.5)
        fill.fillColor = SKColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1)
        fill.strokeColor = .clear
        let barHolder = SKNode()
        barHolder.position = CGPoint(x: 0, y: n.radius + 8)
        barHolder.addChild(barBG)
        barHolder.addChild(fill)
        barHolder.isHidden = true
        n.container.addChild(barHolder)
        n.healthBar = barHolder
        n.healthFill = fill

        npcLayer.addChild(n.container)
        npcNodes[npc.entityID] = n
        if let fx = pendingEntrance.removeValue(forKey: npc.entityID) {
            applyEntrance(fx, to: n.container,
                          at: CGPoint(x: npc.position.x, y: npc.position.y), heading: npc.angle)
        }
        return n
    }

    /// Dim (or restore) a node to read as a powered-down hulk.
    private func setDisabledLook(_ n: NPCNode, on: Bool) {
        let a: CGFloat = on ? 0.45 : 1.0
        n.sprite?.alpha = a
        n.placeholder?.alpha = a
        if let sprite = n.sprite {
            sprite.colorBlendFactor = on ? 0.5 : 0
            sprite.color = SKColor(white: 0.2, alpha: 1)
        }
    }

    // MARK: Jump / landing effects

    /// Fade + scale a freshly-built node in, either as a hyperspace jump-in (a
    /// quick bright pop) or a launch that grows up out of a planet.
    private func applyEntrance(_ fx: EntranceFX, to container: SKNode, at point: CGPoint, heading: Double) {
        switch fx {
        case .warpIn:
            container.alpha = 0
            container.setScale(0.6)
            container.run(.group([.fadeIn(withDuration: 0.18),
                                  .sequence([.scale(to: 1.12, duration: 0.14),
                                             .scale(to: 1.0, duration: 0.1)])]))
            spawnWarpStreak(at: point, heading: heading)
        case .launch:
            container.alpha = 0
            container.setScale(0.08)
            container.run(.group([.fadeIn(withDuration: 0.4),
                                  .scale(to: 1.0, duration: 0.5)]))
        }
    }

    /// A bright hyperspace streak: a stretched additive flash along `heading`
    /// (random if nil, e.g. an inbound jump whose facing we don't stress about).
    private func spawnWarpStreak(at point: CGPoint, heading: Double?) {
        let ang = heading ?? Double.random(in: 0..<(2 * .pi))
        let len: CGFloat = 220
        let dir = CGPoint(x: sin(ang), y: cos(ang))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -dir.x * len, y: -dir.y * len))
        path.addLine(to: CGPoint(x: dir.x * len, y: dir.y * len))
        let streak = SKShapeNode(path: path)
        streak.position = point
        streak.strokeColor = SKColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 0.9)
        streak.lineWidth = 3
        streak.blendMode = .add
        streak.zPosition = 12
        streak.xScale = 0.2
        effectsLayer.addChild(streak)
        streak.run(.sequence([.group([.scaleX(to: 1.0, y: 0.2, duration: 0.18),
                                      .fadeOut(withDuration: 0.22)]),
                              .removeFromParent()]))
    }

    /// Streak a departing ship out to hyperspace: detach its node, zip it forward
    /// along `heading`, and flash out. (The world already removed the ship.)
    private func warpOutNode(id: Int, at point: CGPoint, heading: Double) {
        let streak = { self.spawnWarpStreak(at: point, heading: heading) }
        guard let container = detachNPCNode(id) else { streak(); return }
        let dir = CGVector(dx: sin(heading) * 1600, dy: cos(heading) * 1600)
        effectsLayer.addChild(container)
        container.run(.sequence([.group([.move(by: dir, duration: 0.24),
                                         .fadeOut(withDuration: 0.24)]),
                                 .removeFromParent()]))
        streak()
    }

    /// Set a landing ship down into its spaceport: detach its node and shrink +
    /// fade it into the planet's centre.
    private func landNode(id: Int, spobID: Int, at point: CGPoint) {
        guard let container = detachNPCNode(id) else { return }
        let target = planetVisuals.first { $0.id == spobID }.map { $0.position } ?? point
        effectsLayer.addChild(container)
        container.run(.sequence([.group([.move(to: target, duration: 0.5),
                                         .scale(to: 0.05, duration: 0.5),
                                         .fadeOut(withDuration: 0.5)]),
                                 .removeFromParent()]))
    }

    /// A brief electric crackle where a ship was disabled.
    private func spawnDisableFlash(at point: CGPoint) {
        let ring = SKShapeNode(circleOfRadius: 14)
        ring.position = point
        ring.strokeColor = SKColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.9)
        ring.fillColor = .clear
        ring.lineWidth = 2
        ring.blendMode = .add
        ring.zPosition = 13
        effectsLayer.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 2.0, duration: 0.3),
                                    .fadeOut(withDuration: 0.3)]),
                            .removeFromParent()]))
    }

    /// Pull a live NPC's node out of the pool so subsequent syncs won't touch it,
    /// handing the caller its container to animate independently.
    private func detachNPCNode(_ id: Int) -> SKNode? {
        guard let n = npcNodes.removeValue(forKey: id) else { return nil }
        n.thruster?.isHidden = true
        n.healthBar?.isHidden = true
        // Reparenting requires no existing parent; npcLayer and effectsLayer share
        // the scene's coordinate space so the world position carries over.
        n.container.removeFromParent()
        return n.container
    }

    private func updateNPCThruster(_ n: NPCNode, npc: Ship) {
        guard let thruster = n.thruster else { return }
        // We don't see the NPC's intent, so infer "thrusting" from moving forward
        // near its own heading at a decent clip.
        let heading = (sin(npc.angle), cos(npc.angle))
        let forward = npc.velocity.x * heading.0 + npc.velocity.y * heading.1
        let active = npc.velocity.length > npc.stats.maxSpeed * 0.25 && forward > 0
        thruster.isHidden = !active
        guard active else { return }
        let tail = CGPoint(x: sin(npc.angle) * -Double(n.radius) * 0.7,
                           y: cos(npc.angle) * -Double(n.radius) * 0.7)
        thruster.position = tail
        thruster.zRotation = -CGFloat(npc.angle)
        // Low-pass filtered flicker (see updateThruster) so it doesn't strobe.
        let target: CGFloat = .random(in: 0.6...0.9)
        n.thrusterAlpha = n.thrusterAlpha * 0.85 + target * 0.15
        thruster.alpha = n.thrusterAlpha
    }

    private func updateNPCHealth(_ n: NPCNode, npc: Ship) {
        guard let holder = n.healthBar, let fill = n.healthFill else { return }
        let frac = max(0, min(1, npc.healthFraction))
        // Only redraw when it actually changed; hide the bar at full health.
        if npc.armor == n.lastArmor { return }
        n.lastArmor = npc.armor
        holder.isHidden = frac >= 0.999
        fill.xScale = CGFloat(max(0.001, frac))
        // Green when healthy, through amber, to red when critical.
        fill.fillColor = SKColor(red: CGFloat(1 - frac) * 0.9 + 0.1,
                                 green: CGFloat(frac) * 0.9,
                                 blue: 0.25, alpha: 1)
    }

    /// The rotation textures for a hull id, decoded from the player's data once
    /// and cached (many NPCs share a hull).
    private func npcTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcTextureCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        if shipTypeID >= 128, let sheet = galaxy?.game.shipSprite(shipTypeID) {
            textures = SpriteTextures.rotationFrames(from: sheet)
        }
        npcTextureCache[shipTypeID] = textures
        return textures
    }

    /// This ship's relationship to the player: hostile / neutral / friendly-or-
    /// owned / disabled. Drives both the minimap dot color and the placeholder
    /// hull tint, so the two stay consistent.
    private func relationship(for npc: Ship) -> RadarRelationship {
        if npc.disabled { return .disabled }
        if world.diplomacy?.isHostileToPlayer(npc.government) == true { return .hostile }
        if npc.government == world.player.government
            || world.diplomacy?.areAllied(npc.government, world.player.government) == true {
            return .friendlyOrOwned
        }
        return .neutral
    }

    /// A stellar object's relationship to the player, for radar coloring: grey
    /// for uninhabited/non-functional bodies, otherwise by owning government.
    private func relationship(forPlanet pv: PlanetVisual) -> RadarRelationship {
        if pv.isUninhabited { return .disabled }
        if world.diplomacy?.isHostileToPlayer(pv.government) == true { return .hostile }
        if pv.government == world.player.government
            || world.diplomacy?.areAllied(pv.government, world.player.government) == true {
            return .friendlyOrOwned
        }
        return .neutral
    }

    private func factionColor(for npc: Ship) -> SKColor {
        switch relationship(for: npc) {
        case .hostile: return SKColor(red: 0.95, green: 0.3, blue: 0.25, alpha: 1)
        case .neutral: return SKColor(red: 0.95, green: 0.85, blue: 0.25, alpha: 1)
        case .friendlyOrOwned: return SKColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 1)
        case .disabled: return SKColor(white: 0.55, alpha: 1)
        }
    }

    // MARK: Combat effects

    /// A brief bright line for an instant-hit beam.
    private func spawnBeam(from: CGPoint, to: CGPoint, hit: Bool) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        let line = SKShapeNode(path: path)
        line.strokeColor = hit ? SKColor(red: 1, green: 0.6, blue: 0.3, alpha: 0.9)
                                : SKColor(white: 0.8, alpha: 0.6)
        line.lineWidth = hit ? 2.5 : 1.5
        line.blendMode = .add
        line.zPosition = 12
        effectsLayer.addChild(line)
        line.run(.sequence([.fadeOut(withDuration: 0.12), .removeFromParent()]))
    }

    /// An expanding, fading flash for an explosion.
    private func spawnExplosion(at point: CGPoint, radius: CGFloat) {
        let flash = SKShapeNode(circleOfRadius: max(10, radius * 0.6))
        flash.position = point
        flash.fillColor = SKColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 0.9)
        flash.strokeColor = SKColor(red: 1.0, green: 0.9, blue: 0.6, alpha: 0.9)
        flash.blendMode = .add
        flash.zPosition = 13
        effectsLayer.addChild(flash)
        flash.run(.sequence([
            .group([.scale(to: 2.2, duration: 0.35), .fadeOut(withDuration: 0.35)]),
            .removeFromParent()
        ]))
    }

    private func updateStarfield(cameraAt cam: CGPoint) {
        func wrap(_ v: CGFloat, _ t: CGFloat) -> CGFloat {
            var r = v.truncatingRemainder(dividingBy: t)
            if r > t / 2 { r -= t }
            if r < -t / 2 { r += t }
            return r
        }
        for layer in starLayers {
            layer.container.position = cam
            for (i, star) in layer.stars.enumerated() {
                let base = layer.bases[i]
                star.position = CGPoint(x: wrap(base.x - cam.x * layer.parallax, layer.tile),
                                        y: wrap(base.y - cam.y * layer.parallax, layer.tile))
            }
        }
    }

    private func updateHUD(dt: TimeInterval) {
        guard let hud else { return }
        hudClock += dt
        guard hudClock >= 0.08 else { return } // ~12 Hz
        hudClock = 0
        let p = world.player
        hud.speed = Int(p.velocity.length)
        hud.maxSpeed = max(1, Int(p.stats.maxSpeed))
        hud.thrusting = world.intent.thrust
        hud.afterburning = p.afterburnerActive
        hud.controllerConnected = controllerInput?.isConnected ?? false
        hud.systemName = systemName

        // Real ship-system state: shields, armor, fuel (with whole-jump readout),
        // cargo, and the active weapon + ammo.
        hud.shield = p.maxShield > 0 ? p.shield / p.maxShield : 0
        hud.armor = p.maxArmor > 0 ? p.armor / p.maxArmor : 1
        hud.fuel = p.maxFuel > 0 ? p.fuel / p.maxFuel : 0
        hud.jumps = Int((p.fuel / 100).rounded(.down))
        hud.cargoUsed = p.cargoUsed
        hud.cargoCapacity = p.cargoCapacity
        if let mount = p.weapons.first {
            hud.weaponName = mount.spec.name
            hud.weaponAmmo = mount.ammo   // -1 = unlimited
        } else {
            hud.weaponName = ""
            hud.weaponAmmo = -1
        }
        var deg = p.angle * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        hud.headingDegrees = deg

        // Radar: planets relative to the ship, normalized. Stellars beyond the
        // scope clamp to the rim (you can always steer toward a planet); ships
        // beyond it simply drop off, as in the original. Screen north is up, so
        // world +y maps to radar -y.
        let shipPos = p.position
        hud.planetBlips = planetVisuals.map { pv in
            var dx = (Double(pv.position.x) - shipPos.x) / Double(radarRange)
            var dy = -(Double(pv.position.y) - shipPos.y) / Double(radarRange)
            let m = (dx * dx + dy * dy).squareRoot()
            if m > 1 { dx /= m; dy /= m } // clamp to the rim
            return RadarContact(x: dx, y: dy, relationship: relationship(forPlanet: pv))
        }
        hud.blips = world.npcs.compactMap { npc in
            let dx = (npc.position.x - shipPos.x) / Double(radarRange)
            let dy = -(npc.position.y - shipPos.y) / Double(radarRange)
            guard dx * dx + dy * dy <= 1 else { return nil }
            return RadarContact(x: dx, y: dy, relationship: relationship(for: npc))
        }
    }
}
