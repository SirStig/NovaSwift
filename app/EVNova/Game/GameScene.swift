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
    private var shipRadius: CGFloat = 16

    private var starLayers: [StarLayer] = []
    private var planetVisuals: [PlanetVisual] = []
    private var planetNodes: [SKNode] = []
    private let projectileLayer = SKNode()
    private var projectileNodes: [SKShapeNode] = []
    private var systemName = ""
    private var lastUpdate: TimeInterval = 0
    private var hudClock: TimeInterval = 0
    private let radarRange: CGFloat = 8000

    // NPC rendering: the catalog for per-hull sprites, a layer for NPC ships, a
    // layer for transient effects (explosions / beams), and the live node pool.
    private var galaxy: Galaxy?
    private let npcLayer = SKNode()
    private let effectsLayer = SKNode()
    private var npcNodes: [Int: NPCNode] = [:]
    private var npcTextureCache: [Int: [SKTexture]] = [:]

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
    }

    // MARK: Setup

    func configure(player ship: Ship, textures: [SKTexture], settings: GameSettings,
                   input: InputController, controller: GameControllerInput?, hud: GameHUDModel?,
                   audio: GameAudio? = nil,
                   planets: [PlanetVisual] = [], systemName: String = "",
                   game: NovaGame? = nil, systemID: Int = 0, galaxy: Galaxy? = nil) {
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
    }

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1)
        scaleMode = .resizeFill
        camera = cameraNode
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

        // Engine exhaust plume (behind the hull). Hidden unless thrusting.
        thruster = makeThruster()
        thruster.isHidden = true
        node.addChild(thruster)

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
        addChild(node)
        shipNode = node
    }

    /// A simple additive flame: an outer amber and inner white teardrop.
    private func makeThruster() -> SKNode {
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
        container.addChild(flame(7, 26, SKColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 0.9)))
        container.addChild(flame(3.5, 16, SKColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 0.95)))
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
        updateHUD(dt: dt)
    }

    private func updateThruster(active: Bool, angle: Double, boosted: Bool = false) {
        thruster.isHidden = !active
        guard active else { return }
        // Sit at the tail (opposite heading) and point backward, with a flicker.
        let back = -angle
        let tail = CGPoint(x: sin(angle) * -shipRadius * 0.7, y: cos(angle) * -shipRadius * 0.7)
        thruster.position = tail
        thruster.zRotation = CGFloat(back)
        // The afterburner plume is longer and brighter than normal thrust.
        let base: CGFloat = boosted ? 1.5 : 1.0
        thruster.setScale(base * .random(in: 0.85...1.15))
        thruster.alpha = boosted ? .random(in: 0.9...1.0) : .random(in: 0.75...1.0)
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
            updateNPCThruster(node, npc: npc)
            updateNPCHealth(node, npc: npc)
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

        let thruster = makeThruster()
        thruster.isHidden = true
        thruster.setScale(0.8)
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
        return n
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
        thruster.alpha = .random(in: 0.6...0.9)
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

    /// Blue for friends, red for anyone hostile to the player, grey otherwise.
    private func factionColor(for npc: Ship) -> SKColor {
        if world.diplomacy?.isHostileToPlayer(npc.government) == true {
            return SKColor(red: 0.95, green: 0.35, blue: 0.3, alpha: 1)
        }
        return SKColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 1)
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

        // Radar: planets relative to the ship, normalized and clamped to the scope.
        // Screen north is up, so world +y maps to radar -y.
        let shipPos = p.position
        hud.planetBlips = planetVisuals.map { pv in
            var dx = (Double(pv.position.x) - shipPos.x) / Double(radarRange)
            var dy = -(Double(pv.position.y) - shipPos.y) / Double(radarRange)
            let m = (dx * dx + dy * dy).squareRoot()
            if m > 1 { dx /= m; dy /= m } // clamp to the rim
            return CGPoint(x: dx, y: dy)
        }
        // Ship contacts: every live NPC, relative to the player and clamped to the
        // scope rim.
        hud.blips = world.npcs.map { npc in
            var dx = (npc.position.x - shipPos.x) / Double(radarRange)
            var dy = -(npc.position.y - shipPos.y) / Double(radarRange)
            let m = (dx * dx + dy * dy).squareRoot()
            if m > 1 { dx /= m; dy /= m }
            return CGPoint(x: dx, y: dy)
        }
    }
}
