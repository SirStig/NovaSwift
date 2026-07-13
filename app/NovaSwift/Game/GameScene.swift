import SpriteKit
import CoreImage
import NovaSwiftKit
import NovaSwiftEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Gate flags, so the scene can draw the gate glow and route "land on it"
    /// to gate travel rather than the spaceport.
    var isHypergate: Bool = false
    var isWormhole: Bool = false
    var isGate: Bool { isHypergate || isWormhole }
}

/// The live game scene. Runs the `NovaSwiftEngine` simulation and draws it: an
/// infinite parallax starfield, the player ship (real EV Nova sprite when data
/// is loaded, a vector placeholder otherwise) with an engine exhaust plume, a
/// follow camera, and a HUD driven via `GameHUDModel`.
final class GameScene: SKScene {
    private var world: World! {
        didSet {
            // Re-apply pêrs state to every freshly-built world (system rebuilds,
            // takeoff) so grudges/spawn-eligibility survive jumps.
            world?.playerPersGrudges = persGrudges
            if let e = persSpawnEligible { world?.persSpawnEligible = e }
        }
    }
    /// Whether the player's ship carries an IFF outfit (oütf ModType 14,
    /// "colorized radar"). Host-supplied from the pilot's loadout. EV Nova only
    /// colorizes radar blips by allegiance when an IFF outfit is installed; without
    /// one, ship contacts are drawn in a single neutral color. Defaults to false
    /// (no IFF) so the faithful monochrome behavior is the safe fallback.
    var playerHasIFF = false
    /// Host-supplied in-game day (`PlayerState.date.julianDay`), read live at each
    /// world (re)build to vary the spawn RNG seed per visit — otherwise a system
    /// spawns the identical ships every single time it's entered (the world is
    /// rebuilt from a fixed seed on every arrival). The calendar advances at least a
    /// day per jump, so re-entering a system gives a fresh cast; within one visit the
    /// day doesn't change, so spawns stay deterministic frame-to-frame.
    var worldSeedDayProvider: (() -> Int)?

    /// Mixes the system id with the in-game day into a world RNG seed. Wrapping
    /// arithmetic (SplitMix64-style constants) so it can never trap on overflow.
    static func worldSeed(systemID: Int, day: Int) -> UInt64 {
        var h = UInt64(bitPattern: Int64(systemID)) &* 0x9E37_79B9_7F4A_7C15
        h = (h ^ UInt64(bitPattern: Int64(day))) &* 0xD1B5_4A32_D192_ED03
        h ^= h >> 29
        return h &+ 0x5EED_1234
    }

    /// The seed for the world currently being (re)built: `systemID` + live day.
    private func currentWorldSeed(systemID: Int) -> UInt64 {
        Self.worldSeed(systemID: systemID, day: worldSeedDayProvider?() ?? 0)
    }

    /// pêrs ids the player has wronged (grudge) — host-supplied from pilot state.
    var persGrudges: Set<Int> = []
    /// Host gate: whether a pêrs may spawn now (ActiveOn NCB + not defeated).
    var persSpawnEligible: ((Int) -> Bool)?
    /// Fired when the player earns a grudge / defeats a named person; the host
    /// persists these to the pilot.
    var onPersGrudge: ((Int) -> Void)?
    var onPersDefeated: ((Int) -> Void)?
    /// Fired once when the player's own ship is destroyed. `hadEscapePod`
    /// picks the host's reaction: rescue-at-nearest-port vs. game over.
    var onPlayerDestroyed: ((_ hadEscapePod: Bool) -> Void)?
    private var input: InputController!
    private var controllerInput: GameControllerInput?
    #if os(iOS)
    private var tiltInput: TiltInput?
    #endif

    /// When true (Settings ▸ Touch scheme = "Tap to Turn"), touching the space
    /// view points the ship where you touch; a tap that doesn't drag no longer
    /// selects a target (the on-screen action buttons do that instead). When
    /// false (the default "Virtual Cockpit"), a tap selects a target and the
    /// arc buttons steer. Set by the container from the live settings.
    var tapToFlyEnabled = false
    /// Live finger offset from the view centre while steering by touch, in view
    /// points (x → right, y → down). Converted to a compass heading every frame
    /// so the steer stays correct as the follow-camera tracks the ship. nil when
    /// not actively steering — the last heading is then held (the ship coasts on
    /// its set bearing rather than snapping straight).
    private var steerViewOffset: CGVector?
    private var hud: GameHUDModel?
    private var settings = GameSettings()
    /// Texture filtering for all sprites — crisp `.nearest` for the faithful
    /// pixel-art look, `.linear` when the player turns on "Smooth sprite scaling".
    private var spriteFilter: SKTextureFilteringMode { settings.smoothSprites ? .linear : .nearest }
    private var audio: GameAudio?
    private var wasFiring = false
    // Edge-triggered warning state: true once the klaxon/red-alert for that
    // threshold has played, reset only after recovering with a little hysteresis
    // so crossing back and forth right at the line doesn't retrigger every frame.
    private var shieldWarned = false
    private var hullWarned = false

    private let cameraNode = SKCameraNode()
    private var shipNode: SKNode!
    /// One-shot latch so the player's multi-burst death animation only runs once.
    private var playerDeathSequenceStarted = false
    private var shipSprite: SKSpriteNode?
    private var rotationTextures: [SKTexture] = []
    private var placeholder: SKShapeNode?
    private var thruster: SKNode!
    /// Smoothed (not raw-random-per-frame) flame alpha/scale — see `NPCNode`.
    private var thrusterAlpha: CGFloat = 0.85
    private var thrusterFlameScale: CGFloat = 1.0
    /// The hull's own authored engine-glow overlay (shän engine layer), when
    /// the data has one — real per-ship thruster art, indexed by the same
    /// rotation frame as the hull sprite. Additively blended, centred on the
    /// hull. Falls back to the synthetic `thruster` flame when absent.
    private var engineGlowTextures: [SKTexture] = []
    private var engineGlowSprite: SKSpriteNode?
    /// The hull's shield-bubble overlay (shän shield layer), present only when a
    /// "Shields" graphics plug-in populated it. Single-frame; its opacity is
    /// driven by a decaying flare that spikes whenever the shields absorb a hit.
    private var shieldTextures: [SKTexture] = []
    private var shieldSprite: SKSpriteNode?
    private var shieldFlare: CGFloat = 0
    private var lastPlayerShield: Double = -1
    /// The hull's running-lights overlay (shän light layer) — blinking hull
    /// lights, indexed by the same frame as the base hull and modulated by the
    /// shän's blink mode. And the weapon-glow overlay (shän weapon layer), a
    /// muzzle flash flared on firing and faded per `weapDecay`.
    private var lightTextures: [SKTexture] = []
    private var lightNode: SKSpriteNode?
    private var weaponGlowTextures: [SKTexture] = []
    private var weaponGlowNode: SKSpriteNode?
    private var weaponGlowFlare: CGFloat = 0
    /// Base-image multi-set animation config (banking / animation / frames-per-
    /// rotation) for the player hull, plus the per-ship clocks that drive it.
    private var hullAnim = HullAnim()
    private var animClock: Double = 0
    private var blinkClock: Double = 0
    private var lastPlayerAngle: Double = .nan
    /// Clamped per-frame delta, cached so `syncNPCs()` (no dt param) can decay
    /// each NPC's shield flare at the same rate as the player's.
    private var frameDT: TimeInterval = 1.0 / 60.0
    private var shipRadius: CGFloat = 16

    private var starLayers: [StarLayer] = []
    private var planetVisuals: [PlanetVisual] = []
    private var planetNodes: [SKNode] = []
    private let projectileLayer = SKNode()
    /// Pooled projectile sprites. SKSpriteNodes sharing one texture batch into a
    /// single draw call, unlike the per-node SKShapeNodes they replaced — the
    /// difference is what keeps a busy firefight from dropping frames.
    private var projectileNodes: [SKSpriteNode] = []
    /// Pooled beam sprites, mirrored from `world.activeBeams` every frame so a
    /// beam stays welded to its (moving, turning) shooter. A stretched shared
    /// texture, so beams batch and never re-tessellate a path.
    private var beamNodes: [SKSpriteNode] = []
    /// Shared textures for the pools above (built once, lazily).
    private lazy var projectileTexture: SKTexture = GameScene.makeDotTexture()
    private lazy var beamTexture: SKTexture = GameScene.makeBeamTexture()

    /// Pooled expanding explosion/hit flashes, animated in `updateFlashes`
    /// instead of allocating an `SKShapeNode` + `SKAction` per world event.
    private struct Flash {
        let node: SKSpriteNode
        var age: Double
        let duration: Double
        let startDiameter: CGFloat
        let endDiameter: CGFloat
    }
    private var activeFlashes: [Flash] = []
    private var flashPool: [SKSpriteNode] = []
    /// Decoded shot-graphic frames per weapon spïn id (data-keyed, kept across systems).
    private var weaponGraphicCache: [Int: [SKTexture]] = [:]
    /// Monotonic clock for looping shot-spin / effect animation.
    private var effectClock: Double = 0
    private var systemName = ""
    /// True when this scene was just built because the player jumped in from
    /// hyperspace (not a fresh game start, a landing depart, or a load) — the
    /// only case that should show the player's own warp-in effect.
    private var arrivedViaJump = false

    // MARK: Hyperspace jump sequence
    /// Phases of the player's own hyperspace jump. `.none` = ordinary flight;
    /// during a jump the scene locks manual control and flies the maneuver:
    /// turn to the outbound heading, tear away as the stars streak, white-flash,
    /// then pop out already moving in the destination system. See `beginJump`.
    private enum JumpPhase { case none, align, accelerate, flash, arrive }
    private var jumpPhase: JumpPhase = .none
    private var jumpClock: Double = 0
    /// Heading the ship turns to before the jump (toward the destination system
    /// on the galactic map).
    private var jumpOutboundHeading: Double = 0
    /// Instant-jump outfit installed → skip the slow align/spin-up.
    private var jumpInstant = false
    /// Jump-animation speed-up from hyperspace-speed outfits (1 = stock timing).
    private var jumpSpeed: Double = 1
    /// Destination system loaded at the white-flash peak.
    private var jumpDestSystemID = 0
    /// Ran once at the flash peak to commit the jump in the app model (spend
    /// fuel, advance the route, follow the pilot, save). Supplied by the container.
    private var jumpCommit: (() -> Void)?
    private var jumpCommitted = false
    /// When the jump is a *gate* transport, the destination gate's spöb id — the
    /// player emerges out of it (rather than at the hyperspace edge) and it plays
    /// the open→close flourish. nil for an ordinary hyperjump.
    private var jumpArriveGateID: Int?

    /// Invoked when a government ship completes a scan of the player, with that
    /// ship's government id. The host wires this to the contraband scan-and-fine
    /// (`ContrabandScan.enforce`), which needs live pilot state the scene doesn't
    /// hold. nil = no consequence (e.g. the no-data demo path).
    var onPlayerScanned: ((Int) -> Void)?
    /// Fired once each time the player opens fire with the primary weapon (the
    /// rising edge of the fire trigger). Used by the flight-training tutorial to
    /// detect the "shoot" step; nil in normal play.
    var onPlayerFired: (() -> Void)?
    /// True while a jump wants manual input suppressed (the whole sequence).
    var isJumping: Bool { jumpPhase != .none }
    /// Full-viewport white flash + radial star streaks, parented to the camera.
    private var jumpFlash: SKSpriteNode?
    private var jumpStreaks: SKNode?
    /// System murk (`sÿst.Murk`) fog overlay — a camera-space dark veil whose
    /// opacity tracks `World.effectiveMurk(for:)`.
    private var murkFog: SKSpriteNode?

    private var lastUpdate: TimeInterval = 0
    private var hudClock: TimeInterval = 0
    private var moveDiagClock: TimeInterval = 0
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
    /// The click/hotkey-selected nav destination (planet/station) —
    /// independent of `nearestLandableID`, which stays proximity-only and
    /// keeps driving the land prompt. Mutually exclusive with
    /// `world.player.currentTargetID`: selecting a planet clears the ship
    /// target and vice versa, so only one thing is ever selected at a time.
    private(set) var selectedPlanetID: Int?
    private let landingSpeedLimit: Double = 130
    /// Read-only handle to the live player ship (fuel top-up / cargo sync on land).
    var playerShip: Ship? { world?.player }
    /// The spöb to land on if the player may set down this instant, else nil.
    func attemptLand() -> Int? { canLandNow ? nearestLandableID : nil }

    // MARK: Hypergate / wormhole state
    /// Hypergates the player has switched on this session (wormholes are always
    /// live and need no activation). Drives the gate's on-screen glow and whether
    /// landing on it opens the gate map. Cleared per-system on reload.
    private var openGateIDs: Set<Int> = []
    /// spöb id → its render node, so gate glow/flash can find the right planet
    /// node without a linear scan. Rebuilt in `buildPlanets`, cleared on reload.
    private var planetNodeByID: [Int: SKNode] = [:]
    /// Set by `reloadSystem` when the arrival is *out of a gate*, consumed by the
    /// gate open→close flourish once the new system's nodes are built.
    private var pendingGateArrivalID: Int?
    /// A body the player can set down on: an inhabited port (`canLand`) OR any
    /// gate — you land on a gate to use it, even one flagged uninhabited.
    private func isPlayerLandTarget(_ body: StellarBody) -> Bool { body.canLand || body.isGate }

    /// Auto-landing autopilot target (a landable body id), or nil when not
    /// engaged. While set, the scene flies the ship to that body and calls
    /// `onAutoLandArrived` once it's in range and slow (see `stepAutoLand`).
    private(set) var autoLandTargetID: Int?
    var isAutoLanding: Bool { autoLandTargetID != nil }
    /// Invoked when the autopilot reaches the pad — the container then commits
    /// the landing (opens the spaceport).
    var onAutoLandArrived: ((Int) -> Void)?

    /// A mission's special ship met its player-side goal (`mïsn.ShipGoal` —
    /// destroyed / disabled / boarded / observed / chased off). The container
    /// feeds this back into the story engine (`missionShipDestroyed` etc.) so the
    /// objective count decrements and the mission completes when the last one is
    /// done (or, if it has a return leg, when the player next lands there).
    /// `byPlayer` distinguishes a kill the player made from one an ally made.
    var onMissionShipGoalReached: ((_ missionID: Int, _ goal: MissionShipGoal, _ byPlayer: Bool) -> Void)?

    /// A mission escort/rescue ship the player was meant to protect was destroyed
    /// — the container fails the mission via `engine.missionShipLost`.
    var onMissionShipLost: ((_ missionID: Int, _ goal: MissionShipGoal) -> Void)?

    /// The player's own ship was disabled — fails any mission flagged "fail if
    /// player is disabled" (`mïsn.Flags2` 0x0004).
    var onPlayerDisabled: (() -> Void)?
    /// The player was boarded — fails any mission flagged "fail if boarded"
    /// (`mïsn.Flags` 0x8000).
    var onPlayerBoarded: (() -> Void)?

    /// A stellar scrambled a wave of its Demand-Tribute defense fleet (from the
    /// planet's `spöb.DefenseDude`). Fires on the first wave and again on each
    /// relaunch as the field is cleared, so the HUD can announce every wave.
    var onStellarDefendersLaunched: ((_ spobID: Int, _ count: Int, _ remainingPool: Int) -> Void)?
    /// A stellar's Demand-Tribute defenses were broken and it surrendered — the
    /// container persists the domination (`StoryEngine.dominateStellar`), which
    /// fires `OnDominate` and starts the daily tribute income.
    var onStellarDominated: ((_ spobID: Int) -> Void)?

    /// Whether the live world already holds ships tagged with `missionID` — the
    /// container checks this before (re)spawning a mission's ships so entering a
    /// system doesn't stack duplicate sets.
    func hasMissionShips(_ missionID: Int) -> Bool {
        world?.npcs.contains { $0.missionID == missionID } ?? false
    }

    /// Demand tribute from stellar `spobID` on behalf of the player — the
    /// in-flight path to forcefully dominating a planet/station. Syncs the
    /// player's live combat rating and already-dominated set into the world (the
    /// domination flow reads both: the rating gate refuses a weak demand, the set
    /// short-circuits an already-owned planet), then runs the engine demand. The
    /// returned `TributeOutcome` drives the hail dialog's immediate reply; the
    /// wave-launch and surrender events surface asynchronously through
    /// `onStellarDefendersLaunched` / `onStellarDominated` as the fight plays out.
    func demandTribute(spobID: Int, combatRating: Int, alreadyDominated: Set<Int>) -> TributeOutcome? {
        guard let world else { return nil }
        world.playerCombatRating = combatRating
        world.dominatedStellars.formUnion(alreadyDominated)
        return world.demandTribute(spobID: spobID)
    }

    /// Place a mission's special ships into the live system (forwards to
    /// `World.spawnMissionShips`). The container decides *when* (the mission's
    /// `ShipSyst` matches the current system) and supplies the resolved fields.
    @discardableResult
    func spawnMissionShips(missionID: Int, dudeID: Int, count: Int,
                           goal: MissionShipGoal, behavior: MissionShipBehavior,
                           government: Int?,
                           arrival: World.ArrivalMode = .hyperspace) -> [Int] {
        world?.spawnMissionShips(missionID: missionID, dudeID: dudeID, count: count,
                                 goal: goal, behavior: behavior, government: government,
                                 arrival: arrival) ?? []
    }

    /// Engage auto-landing toward the currently-selected planet, or the nearest
    /// landable body if none/the selection can't be landed on. Returns false if
    /// there's nothing landable to fly to.
    func beginAutoLandOnSelected() -> Bool {
        if let sel = selectedPlanetID, beginAutoLand(spobID: sel) { return true }
        if let near = nearestLandableID, beginAutoLand(spobID: near) { return true }
        return false
    }

    @discardableResult
    func beginAutoLand(spobID: Int) -> Bool {
        guard world?.systemContext.bodies.contains(where: { $0.id == spobID && isPlayerLandTarget($0) }) == true else { return false }
        autoLandTargetID = spobID
        selectedPlanetID = spobID
        hud?.post("Auto-landing engaged.")
        return true
    }

    func cancelAutoLand() {
        guard autoLandTargetID != nil else { return }
        autoLandTargetID = nil
        hud?.post("Auto-landing disengaged.")
    }

    /// Apply the player's turn preferences (invert / sensitivity) to a raw intent.
    private func playerIntent(_ raw: ControlIntent) -> ControlIntent {
        var i = raw
        if settings.invertTurn { swap(&i.turnLeft, &i.turnRight) }   // "Invert turn direction"
        i.turnScale = settings.controlSensitivity                    // "Turn sensitivity"
        return i
    }

    /// One frame of the auto-landing autopilot: hand control back the instant the
    /// player touches the stick; otherwise fly toward the target body, braking
    /// into the approach, and commit the landing once in range and slow.
    private func stepAutoLand() -> ControlIntent {
        let manual = input?.intent ?? .init()
        if manual.turnLeft || manual.turnRight || manual.thrust || manual.reverse {
            cancelAutoLand()
            return playerIntent(manual)
        }
        guard let id = autoLandTargetID, let world,
              let body = world.systemContext.bodies.first(where: { $0.id == id && isPlayerLandTarget($0) }) else {
            cancelAutoLand(); return .init()
        }
        let p = world.player
        let to = body.position - p.position
        let dist = to.length
        let reach = body.radius + 55
        let speed = p.velocity.length
        if dist <= reach && speed <= landingSpeedLimit {
            autoLandTargetID = nil
            onAutoLandArrived?(id)              // container opens the spaceport
            return .init()
        }
        var i = ControlIntent()
        i.desiredHeading = atan2(to.x, to.y)   // 0 = +y (up), clockwise — matches the engine
        var da = (i.desiredHeading! - p.angle).truncatingRemainder(dividingBy: 2 * .pi)
        if da > .pi { da -= 2 * .pi }
        if da < -.pi { da += 2 * .pi }
        let aligned = abs(da) < 0.5
        if dist > reach * 1.8 {
            if aligned { i.thrust = true }             // cruise in while pointed at it
        } else if speed > landingSpeedLimit * 0.75 {
            i.reverse = true                           // brake into the pad
        } else if aligned && dist > reach {
            i.thrust = true                            // nudge the last stretch
        }
        return i
    }

    // NPC rendering: the catalog for per-hull sprites, a layer for NPC ships, a
    // layer for transient effects (explosions / beams), and the live node pool.
    private var galaxy: Galaxy?
    private let npcLayer = SKNode()
    private let effectsLayer = SKNode()

    // Debug suite hooks. `debug` is the live controller the performance readout
    // feeds and the stress test drives; `systemID` is retained so the stress
    // test can rebuild the ambient spawner it tears down. Both are inert unless
    // debug mode is on.
    weak var debug: DebugController?
    private var systemID = 0
    // Frame-timing accumulators for the performance readout, flushed to `debug`
    // on `perfReportClock`. `perfRawAccum`/`perfFrames` build the windowed
    // average; `perfWorstFrame` tracks the window's worst single frame (the one
    // that actually reads as a stutter).
    private var perfReportClock: TimeInterval = 0
    private var perfRawAccum: TimeInterval = 0
    private var perfWorstFrame: TimeInterval = 0
    private var perfFrames = 0

    // AI debug overlay (draws each NPC's state, target, nav goal, and formation
    // link when `debug?.aiDebugEnabled`). Three combined-path line nodes — one
    // per relationship, rebuilt each frame — plus a pooled state label per ship.
    private let aiDebugLayer = SKNode()
    private var aiTargetLines: SKShapeNode?
    private var aiDestLines: SKShapeNode?
    private var aiLeaderLines: SKShapeNode?
    private var aiLabelNodes: [Int: SKLabelNode] = [:]
    private var aiDebugBuilt = false

    // Animated targeting brackets: one reusable node for the ship target, one
    // for the planet nav-selection, positioned/recolored straight from live
    // sim data every frame (not tied to `npcNodes`/`planetNodes` render-node
    // lifecycle, so they can never desync from what's actually selected).
    private let selectionLayer = SKNode()
    private let shipBracket = SKShapeNode()
    private let planetBracket = SKShapeNode()
    private var lockedShipBracketID: Int?
    private var lockedPlanetBracketID: Int?
    private var npcNodes: [Int: NPCNode] = [:]
    private var asteroidNodes: [Int: AsteroidNode] = [:]
    private var asteroidTextureCache: [Int: [SKTexture]] = [:]
    /// Active `loopSound` beam voices, keyed by "`shooterID`:`mountIndex`" —
    /// repositioned every frame in `update(_:)` so a firing ship's continuous
    /// beam loop pans/attenuates as it (or the player) moves, and stopped when
    /// the world emits `.beamLoopStop` or the shooter no longer resolves.
    private var activeBeamLoops: [String: (shooterID: Int, soundID: Int)] = [:]
    private var npcTextureCache: [Int: [SKTexture]] = [:]
    private var npcEngineGlowCache: [Int: [SKTexture]] = [:]
    private var npcShieldCache: [Int: [SKTexture]] = [:]
    private var npcLightCache: [Int: [SKTexture]] = [:]
    private var npcWeaponGlowCache: [Int: [SKTexture]] = [:]
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
        var engineGlow: SKSpriteNode?
        var engineGlowTextures: [SKTexture] = []
        var shield: SKSpriteNode?
        var shieldTextures: [SKTexture] = []
        var shieldFlare: CGFloat = 0
        var lastShield: Double = -1
        var light: SKSpriteNode?
        var lightTextures: [SKTexture] = []
        var weaponGlow: SKSpriteNode?
        var weaponGlowTextures: [SKTexture] = []
        var weaponGlowFlare: CGFloat = 0
        var hullAnim = HullAnim()
        var animClock: Double = 0
        var blinkClock: Double = 0
        var lastAngle: Double = .nan
        var healthFill: SKSpriteNode?
        var healthBar: SKNode?
        var textures: [SKTexture] = []
        var radius: CGFloat = 16
        var lastArmor: Double = -1
        /// Smoothed (not raw-random-per-frame) flame alpha/scale so the plume
        /// reads as a flicker, not a strobe.
        var thrusterAlpha: CGFloat = 0.8
        var thrusterFlameScale: CGFloat = 1.0
    }

    /// The SpriteKit node backing one live asteroid: just a rotating real-sprite
    /// hull, no thruster/health-bar/engine glow (asteroids have none of those).
    private final class AsteroidNode {
        let container = SKNode()
        var sprite: SKSpriteNode?
        var textures: [SKTexture] = []
    }

    // MARK: Setup

    func configure(player ship: Ship, textures: [SKTexture], engineTextures: [SKTexture] = [],
                   shieldTextures: [SKTexture] = [],
                   lightTextures: [SKTexture] = [], weaponGlowTextures: [SKTexture] = [],
                   hullAnim: HullAnim = HullAnim(),
                   settings: GameSettings,
                   input: InputController, controller: GameControllerInput?, hud: GameHUDModel?,
                   audio: GameAudio? = nil,
                   planets: [PlanetVisual] = [], systemName: String = "",
                   game: NovaGame? = nil, systemID: Int = 0, galaxy: Galaxy? = nil,
                   arrivedViaJump: Bool = false,
                   playerDamageScaleOverride: Double? = nil) {
        // With game data we build a fully-wired, *populated* world (diplomacy +
        // spawner + system geometry) so the system fills with NPC traders, patrols
        // and pirates. Without it we fall back to a lone-ship physics world.
        if let game, systemID != 0 {
            var tuning = CombatTuning.default
            // Difficulty scales incoming player damage; the flight-training
            // tutorial passes 0 so a practice flight can never hurt the trainee.
            tuning.playerDamageScale = playerDamageScaleOverride ?? settings.difficulty.playerDamageScale
            let (w, gx) = GameSession.makeWorld(game: game, systemID: systemID,
                                                player: ship, galaxy: galaxy, combatTuning: tuning,
                                                seed: currentWorldSeed(systemID: systemID))
            self.world = w
            self.galaxy = gx
        } else {
            self.world = World(player: ship)
        }
        self.systemID = systemID
        self.rotationTextures = textures
        self.engineGlowTextures = engineTextures
        self.shieldTextures = shieldTextures
        self.lightTextures = lightTextures
        self.weaponGlowTextures = weaponGlowTextures
        self.hullAnim = hullAnim
        self.lastPlayerShield = -1
        self.shieldFlare = 0
        self.weaponGlowFlare = 0
        self.animClock = 0
        self.blinkClock = 0
        self.lastPlayerAngle = .nan
        self.settings = settings
        self.input = input
        self.controllerInput = controller
        controller?.deadzone = Float(settings.stickDeadzone)   // "Stick dead zone" setting
        #if os(iOS)
        tiltInput = TiltInput(input: input)
        updateTiltActive()                                     // start motion updates if scheme == .tilt
        #endif
        Haptics.enabled = settings.hapticsEnabled
        applyColorblindFilter()
        self.hud = hud
        self.audio = audio
        self.planetVisuals = planets
        self.systemName = systemName
        self.arrivedViaJump = arrivedViaJump
    }

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1)
        scaleMode = .resizeFill
        #if os(macOS)
        // Needed for `mouseMoved` (the "Aim toward mouse cursor" option) to fire;
        // the window may not be attached yet, so set it next runloop too.
        view.window?.acceptsMouseMovedEvents = true
        DispatchQueue.main.async { [weak view] in view?.window?.acceptsMouseMovedEvents = true }
        #endif
        camera = cameraNode
        cameraNode.setScale(cameraZoom)
        addChild(cameraNode)
        buildJumpOverlays()
        buildMurkFog()
        buildStarfield()
        buildPlanets()
        npcLayer.zPosition = 9
        addChild(npcLayer)
        projectileLayer.zPosition = 11
        addChild(projectileLayer)
        effectsLayer.zPosition = 12
        addChild(effectsLayer)
        selectionLayer.zPosition = 13
        for bracket in [shipBracket, planetBracket] {
            bracket.fillColor = .clear
            bracket.lineWidth = 1.5
            bracket.isHidden = true
            selectionLayer.addChild(bracket)
        }
        addChild(selectionLayer)
        // AI debug overlay sits above ships/selection but below transient
        // effects; stays empty until the debug suite turns it on.
        aiDebugLayer.zPosition = 14
        addChild(aiDebugLayer)
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

    // MARK: Click/tap-to-select
    //
    // Handled natively here (not via a SwiftUI `.gesture()` on the hosting
    // `SpriteView`) because a SwiftUI gesture layered on top of the real
    // `NSView`/`UIView` a `SpriteView` wraps is unreliable — the native
    // view's own responder chain competes with SwiftUI's gesture bridging
    // for the same event. `location(in:)` is camera-aware, so this needs no
    // manual camera-transform math.
    #if os(macOS)
    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        Log.input.debug("mouseDown -> scenePoint=(\(p.x, privacy: .public),\(p.y, privacy: .public))")
        selectAt(scenePoint: p)
    }

    override func mouseMoved(with event: NSEvent) { updateMouseAim(event) }
    override func mouseDragged(with event: NSEvent) { updateMouseAim(event) }

    /// "Aim toward mouse cursor": steer the ship toward the pointer while the
    /// setting is on. The player sits at the camera centre, so the cursor's
    /// offset from there is the desired heading (0 = up, clockwise — the engine's
    /// convention). Cleared when the setting is off so it never lingers.
    private func updateMouseAim(_ event: NSEvent) {
        guard settings.mouseAiming, jumpPhase == .none, autoLandTargetID == nil else {
            input?.mouse.desiredHeading = nil; return
        }
        let p = event.location(in: self)
        let dx = p.x - cameraNode.position.x
        let dy = p.y - cameraNode.position.y
        guard hypot(dx, dy) > 10 else { return }        // ignore tiny jitter at centre
        input?.mouse.desiredHeading = atan2(Double(dx), Double(dy))
    }
    #else
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if tapToFlyEnabled {
            steerViewOffset = viewOffset(of: t)
        } else {
            let p = t.location(in: self)
            Log.input.debug("touchesBegan -> scenePoint=(\(p.x, privacy: .public),\(p.y, privacy: .public))")
            selectAt(scenePoint: p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tapToFlyEnabled, let t = touches.first else { return }
        steerViewOffset = viewOffset(of: t)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        steerViewOffset = nil   // stop steering; the last heading is held
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        steerViewOffset = nil
    }

    /// A touch's offset from the presenting view's centre (which the follow
    /// camera keeps pinned to the ship), in view points.
    private func viewOffset(of t: UITouch) -> CGVector {
        guard let v = view else { return .zero }
        let loc = t.location(in: v)
        return CGVector(dx: loc.x - v.bounds.midX, dy: loc.y - v.bounds.midY)
    }
    #endif

    private func buildPlanets() {
        for p in planetVisuals {
            let node: SKNode
            if let tex = p.texture {
                let sprite = SKSpriteNode(texture: tex)
                sprite.texture?.filteringMode = spriteFilter
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
            // Planet name label: the original never showed these in flight, so it's
            // opt-in (Settings ▸ Interface). Named so `applyDisplaySettings` can
            // toggle it live without rebuilding the system.
            let label = SKLabelNode(fontNamed: "Menlo")
            label.name = "planetLabel"
            label.text = p.name
            label.fontSize = 11
            label.fontColor = SKColor(white: 0.8, alpha: 0.8)
            label.verticalAlignmentMode = .top
            label.position = CGPoint(x: 0, y: -p.radius - 6)
            label.isHidden = !settings.showPlanetLabels
            node.addChild(label)
            addChild(node)
            planetNodes.append(node)
            planetNodeByID[p.id] = node
            // Wormholes always shimmer (anyone can use them); a hypergate glows
            // only once switched on (via a click or an arrival). Re-applied here
            // so the glow survives a system reload.
            if p.isWormhole {
                setGateGlow(node: node, radius: p.radius, kind: .wormhole)
            } else if p.isHypergate && openGateIDs.contains(p.id) {
                setGateGlow(node: node, radius: p.radius, kind: .hypergate)
            }
        }
    }

    /// The world-space size a star tile needs to be to fully cover the visible
    /// viewport (plus margin) at the current window size and camera zoom, so
    /// the parallax wrap never leaves a gap or shows a seam. Previously a
    /// fixed 1600×1600 tile could be smaller than the actual viewport on a
    /// large window, which is why the starfield didn't "fit" the visible space.
    private var requiredStarTile: CGFloat {
        max(1600, max(size.width, size.height) * cameraZoom * 1.3)
    }

    private func buildStarfield() {
        let density = max(0.2, settings.starfieldDensity)
        let specs: [(parallax: CGFloat, count: Int, size: CGFloat, brightness: CGFloat)] = [
            (0.25, Int(90 * density), 1.5, 0.35),
            (0.5,  Int(70 * density), 2.0, 0.55),
            (0.9,  Int(40 * density), 2.5, 0.85),
        ]
        // Real EV Nova star sprite (spïn #700 "Stars"): a 4×4 grid of 5×5px
        // frames. When it's resolvable, real frames replace the synthetic dot;
        // otherwise we fall back to the plain colored square.
        let starFrames = galaxy?.game.starfieldSprite().map { SpriteTextures.rotationFrames(from: $0, rotationCount: 16) }
        let tile = requiredStarTile
        for spec in specs {
            let layer = StarLayer(parallax: spec.parallax, tile: tile)
            layer.container.zPosition = -100
            for _ in 0..<spec.count {
                let base = CGPoint(x: .random(in: -tile/2...tile/2), y: .random(in: -tile/2...tile/2))
                let star: SKSpriteNode
                if let frames = starFrames, !frames.isEmpty {
                    star = SKSpriteNode(texture: frames.randomElement())
                    star.texture?.filteringMode = spriteFilter
                    star.alpha = spec.brightness
                    star.setScale(spec.size / 3.0)
                } else {
                    star = SKSpriteNode(color: SKColor(white: spec.brightness, alpha: 1),
                                        size: CGSize(width: spec.size, height: spec.size))
                }
                star.position = base
                layer.container.addChild(star)
                layer.stars.append(star)
                layer.bases.append(base)
            }
            addChild(layer.container)
            starLayers.append(layer)
        }
    }

    /// Rebuild the starfield if the window/view grew enough that the current
    /// tile no longer covers the visible area (e.g. a resized macOS window or
    /// an iOS rotation) — otherwise stars would only fill the old, smaller area.
    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard !starLayers.isEmpty, requiredStarTile > starLayers[0].tile else { return }
        for layer in starLayers { layer.container.removeFromParent() }
        starLayers.removeAll()
        buildStarfield()
    }

    private func buildShip() {
        let node = SKNode()
        node.zPosition = 10

        // Real engine-glow art, added first so it renders behind the hull.
        if let first = engineGlowTextures.first {
            let glow = SKSpriteNode(texture: first)
            glow.texture?.filteringMode = spriteFilter
            glow.blendMode = .add
            glow.isHidden = true
            node.addChild(glow)
            engineGlowSprite = glow
        }

        if let first = rotationTextures.first {
            let sprite = SKSpriteNode(texture: first)
            sprite.texture?.filteringMode = spriteFilter
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

        // Running-lights + weapon-glow overlays: real per-hull art on top of the
        // hull, additively blended. Lights blink; weapon glow flashes on firing.
        if let first = lightTextures.first {
            let lights = SKSpriteNode(texture: first)
            lights.texture?.filteringMode = spriteFilter
            lights.blendMode = .add
            lights.zPosition = 0.5
            lights.isHidden = true
            node.addChild(lights)
            lightNode = lights
        }
        if let first = weaponGlowTextures.first {
            let wg = SKSpriteNode(texture: first)
            wg.texture?.filteringMode = spriteFilter
            wg.blendMode = .add
            wg.zPosition = 0.5
            wg.isHidden = true
            node.addChild(wg)
            weaponGlowNode = wg
        }

        // Engine exhaust plume (behind the hull). Hidden unless thrusting. Sized
        // relative to the hull (16 = the old fixed placeholder radius, kept as
        // the reference scale so default-sized ships look unchanged).
        thruster = makeThruster(scale: max(0.5, shipRadius / 16))
        thruster.isHidden = true
        node.addChild(thruster)

        // Shield bubble on top of everything (zPosition above the hull sibling).
        // Pre-sized art, so drawn at native size; hidden until a hit flares it.
        if let first = shieldTextures.first {
            let shield = SKSpriteNode(texture: first)
            shield.texture?.filteringMode = spriteFilter
            shield.zPosition = 1
            shield.isHidden = true
            node.addChild(shield)
            shieldSprite = shield
        }

        addChild(node)
        shipNode = node
    }

    /// A simple additive flame as a *single* batched `SKSpriteNode` (not the two
    /// per-ship `SKShapeNode`s it replaced — those were non-batching draw calls
    /// on every ship and a real frame-rate cost in a crowded fight). The flame
    /// art (amber body + white core) is baked into one shared texture; `scale`
    /// sizes it to the hull. Anchored at its top so it hangs off the tail mount.
    private func makeThruster(scale: CGFloat = 1.0) -> SKNode {
        let flame = SKSpriteNode(texture: GameScene.flameTexture)
        flame.anchorPoint = CGPoint(x: 0.5, y: 1.0)     // top-centre = the nozzle
        flame.blendMode = .add
        flame.size = CGSize(width: 18 * scale, height: 34 * scale)
        return flame
    }

    /// Shared additive flame texture: an amber teardrop with a hot white core,
    /// widest at the top (nozzle) tapering to the tip. Built once.
    private static let flameTexture: SKTexture = {
        let w = 32, h = 64
        return imageTexture(width: w, height: h) { ctx in
            // CG origin is bottom-left, y up; SpriteKit maps image-top → sprite +y,
            // so the wide/hot end must be drawn at the top of the bitmap.
            func teardrop(width: CGFloat, color: SKColor) {
                let cx = CGFloat(w) / 2
                let top = CGFloat(h) * 0.96, tip = CGFloat(h) * 0.06
                let p = CGMutablePath()
                p.move(to: CGPoint(x: cx, y: top))
                p.addQuadCurve(to: CGPoint(x: cx, y: tip), control: CGPoint(x: cx + width, y: CGFloat(h) * 0.55))
                p.addQuadCurve(to: CGPoint(x: cx, y: top), control: CGPoint(x: cx - width, y: CGFloat(h) * 0.55))
                ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath()
            }
            teardrop(width: CGFloat(w) * 0.42, color: SKColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 0.9))
            teardrop(width: CGFloat(w) * 0.20, color: SKColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 0.95))
        }
    }()

    // MARK: Loop

    override func update(_ currentTime: TimeInterval) {
        guard world != nil else { return }
        // Raw, un-clamped frame delta — the true measure of render/sim cost per
        // frame, before `dt` is capped below for physics stability. Feeds the
        // debug performance readout only.
        let rawFrame = lastUpdate == 0 ? 0 : currentTime - lastUpdate
        let dt = lastUpdate == 0 ? 1.0 / 60.0 : min(currentTime - lastUpdate, 1.0 / 20.0)
        lastUpdate = currentTime
        if debug != nil { samplePerformance(rawFrame: rawFrame, dt: dt) }

        // Game-speed option: scale the *simulation* timestep (not the real frame
        // delta used for perf/diagnostics above). `x1` runs below real-time for
        // the faithful slow cruise; higher settings speed the whole world up
        // uniformly — accel, top speed, turning and travel all ride this one dt.
        // The stability clamp is applied to the real delta first, so a high
        // multiplier can't blow the physics up on a hitched frame.
        let simDT = dt * settings.gameSpeed.multiplier
        frameDT = simDT

        controllerInput?.poll()
        #if os(iOS)
        if settings.controlScheme == .tilt { tiltInput?.poll(sensitivity: settings.tiltSensitivity) }
        #endif

        // Tap/drag-to-fly steering: turn the finger's offset from the view centre
        // (= the follow-camera-centred ship) into a compass heading the ship
        // rotates toward. Done per-frame, not just on touch-move, so a held-still
        // finger keeps steering. When steering stops the last heading persists
        // (coast on bearing); when the mode is off we clear it so no stale
        // heading fights the arc buttons.
        if tapToFlyEnabled {
            if let off = steerViewOffset, jumpPhase == .none {
                input?.touch.desiredHeading = atan2(off.dx, -off.dy)
            }
        } else {
            input?.touch.desiredHeading = nil
        }

        // During a hyperspace jump the scene flies the ship (locking manual
        // control); otherwise the player's own intent drives it.
        let intent: ControlIntent
        if jumpPhase != .none {
            intent = stepJump(simDT)
        } else if autoLandTargetID != nil {
            intent = stepAutoLand()
        } else {
            intent = playerIntent(input?.intent ?? .init())
        }
        world.intent = intent
        world.step(simDT)

        let p = world.player

        // Debug suite live cheats (god mode, infinite fuel). Enforced every
        // frame so they hold against the world's own regen/drain; a no-op unless
        // a developer has flipped a switch in the suite.
        if debug != nil { applyDebugCheats(to: p) }

        // Once-a-second heartbeat, independent of the throttled HUD readout —
        // if this never appears in Console at all, `update(_:)` itself isn't
        // running (the scene is effectively frozen despite `isPaused == false`
        // being logged elsewhere); if it appears but `vel` stays exactly zero
        // while `thrust=true`, the freeze is inside `Ship.step`/ship stats
        // (e.g. zero acceleration) rather than the input pipeline.
        moveDiagClock += dt
        if moveDiagClock >= 1.0 {
            moveDiagClock = 0
            // Identity + raw per-source flag, to catch a stale/duplicate
            // InputController capture: if this identity ever differs from the
            // one `KeyboardControls` logs on keypress, the read and write sides
            // are talking to two different objects and that's the whole bug.
            let inputID = self.input.map { ObjectIdentifier($0).debugDescription } ?? "nil"
            Log.scene.debug("""
                update heartbeat: dt=\(dt, privacy: .public) InputController#\(inputID, privacy: .public) \
                rawKeyboardThrust=\(self.input?.keyboard.thrust ?? false, privacy: .public) \
                thrust=\(intent.thrust, privacy: .public) \
                turnL=\(intent.turnLeft, privacy: .public) turnR=\(intent.turnRight, privacy: .public) \
                pos=(\(p.position.x, privacy: .public),\(p.position.y, privacy: .public)) \
                vel=(\(p.velocity.x, privacy: .public),\(p.velocity.y, privacy: .public)) \
                speed=\(p.velocity.length, privacy: .public) accel=\(p.stats.acceleration, privacy: .public) \
                maxSpeed=\(p.stats.maxSpeed, privacy: .public)
                """)
        }
        let scenePos = CGPoint(x: p.position.x, y: p.position.y)

        // The world fires each ready weapon mount itself (respecting reload and
        // ammo). We drain its events for SFX and render the live projectiles it
        // spawned, so firing reflects the real weapon system, not the raw input.
        for event in world.drainEvents() {
            switch event {
            case let .weaponFired(shooterID, at, _, soundID):
                // Positional for every shooter — the player's own shots report
                // right at the listener (near-zero distance = full volume), NPC
                // fire attenuates/pans naturally by distance.
                if let soundID {
                    audio?.play(soundID, at: CGPoint(x: at.x, y: at.y), listener: scenePos)
                }
                // Flash the shooter's weapon-glow overlay (shän weapon layer), if
                // its hull has one. Player is entityID 0; NPCs match by entity.
                if shooterID == 0 {
                    if weaponGlowNode != nil { weaponGlowFlare = 1 }
                } else if let node = npcNodes[shooterID], node.weaponGlow != nil {
                    node.weaponGlowFlare = 1
                }
            case let .beam(_, _, from, _, _, soundID):
                // Geometry is drawn from `world.activeBeams` in `syncBeams()`;
                // this event only carries the pulse-beam fire sound. Retrigger
                // the player's own beam only on the rising edge so a held
                // trigger doesn't stutter; NPC beams aren't gated by `wasFiring`.
                if let soundID, !wasFiring {
                    audio?.play(soundID, at: CGPoint(x: from.x, y: from.y), listener: scenePos)
                }
            case let .beamLoopStart(shooterID, mountIndex, soundID):
                // Beam geometry is now drawn from `world.activeBeams` in
                // `syncBeams()`; this event only drives the continuous audio loop.
                let key = "\(shooterID):\(mountIndex)"
                if let soundID {
                    activeBeamLoops[key] = (shooterID, soundID)
                }
            case let .beamLoopStop(shooterID, mountIndex):
                let key = "\(shooterID):\(mountIndex)"
                activeBeamLoops.removeValue(forKey: key)
                audio?.stopLoop(key: key)
            case let .explosion(at, radius, soundID):
                spawnExplosion(at: CGPoint(x: at.x, y: at.y), radius: CGFloat(radius))
                audio?.play(soundID ?? 303, at: CGPoint(x: at.x, y: at.y), listener: scenePos)
                addShake(at: CGPoint(x: at.x, y: at.y), radius: CGFloat(radius))
            case .targetAcquired:
                audio?.play(.targetLock)
                Haptics.play(.selection)
            case let .shipArrived(entityID, _, fromHyperspace):
                // Only inbound hyperspace jumps get the warp effect (played when the
                // node is built); mid-system populate spawns appear silently.
                if fromHyperspace { pendingEntrance[entityID] = .warpIn }
            case let .shipLaunched(entityID, _):
                // Lifting off a planet is silent in the original — no takeoff SFX
                // (the old snd 390 "Airlock" cue on the player's own launch read as
                // a weird "escape hatch" noise). NPC launches were already silent.
                pendingEntrance[entityID] = .launch
            case let .shipEmergedFromGate(entityID, gateSpobID, _):
                // A gate flashes open, the ship grows out of it, then it closes.
                pendingEntrance[entityID] = .launch
                playGateArrivalFlourish(gateSpobID)
            case let .shipDeparted(entityID, at, heading):
                warpOutNode(id: entityID, at: CGPoint(x: at.x, y: at.y), heading: heading)
            case let .shipLanded(entityID, spobID, at):
                landNode(id: entityID, spobID: spobID, at: CGPoint(x: at.x, y: at.y))
                if entityID == 0 { audio?.play(.docking); Haptics.play(.medium) }
            case let .shipDisabled(entityID, at):
                spawnDisableFlash(at: CGPoint(x: at.x, y: at.y))
                if entityID == 0 { onPlayerDisabled?() }
            case let .shipBoarded(entityID, _):
                if entityID == 0 { onPlayerBoarded?() }
            case let .shipScanned(scannerID, targetID, _):
                // Only the player's own scan matters to the player — post the
                // message and wire the contraband-fine consequence. NPC-on-NPC
                // scans happen silently (no on-screen sweep); the green ring read
                // as clutter over every passing ship.
                if targetID == 0 {
                    hud?.post("You are being scanned.")
                    // -1 govt = independent (no scan law).
                    if let govt = world.ship(id: scannerID)?.government, govt >= 0 {
                        onPlayerScanned?(govt)
                    }
                }
            case let .assistanceDelivered(entityID):
                let name = world.ship(id: entityID)?.name ?? "Ally"
                hud?.post("\(name) transfers fuel and makes repairs.")
                audio?.play(.docking)
            case let .personGrudge(pid):
                persGrudges.insert(pid)
                onPersGrudge?(pid)
            case let .personDefeated(pid):
                onPersDefeated?(pid)
            case let .playerDestroyed(hadEscapePod):
                // Kill any lingering fire/beam loop the moment the player dies (both
                // paths), and — only for a real game-over, not an escape-pod ejection
                // — play out the multi-burst wreck explosion while the host counts
                // down to the menu.
                audio?.stopAllLoops()
                if !hadEscapePod { beginPlayerDeathSequence() }
                onPlayerDestroyed?(hadEscapePod)
            case let .missionShipGoalReached(missionID, _, goal, byPlayer):
                onMissionShipGoalReached?(missionID, goal, byPlayer)
            case let .missionShipLost(missionID, goal):
                onMissionShipLost?(missionID, goal)
            case let .stellarDefendersLaunched(spobID, count, remaining):
                onStellarDefendersLaunched?(spobID, count, remaining)
            case let .stellarDominated(spobID):
                onStellarDominated?(spobID)
            case let .shipDestroyed(entityID, _, _):
                // A player escort tied to a persistent record just died — drop it
                // from the pilot roster so it doesn't respawn next system (and a
                // hired one stops being billed). Resolved via the entity→record
                // map since the Ship may already be torn down.
                if let recordID = escortRecordByEntity[entityID] {
                    escortRecordByEntity[entityID] = nil
                    onEscortLost?(recordID)
                }
            default:
                break
            }
        }
        // "Auto-target after firing": on the shot that opens fire with nothing
        // locked, lock onto the nearest hostile.
        if settings.autoTargetAfterFiring, intent.firePrimary, !wasFiring,
           world.player.currentTargetID == nil {
            selectNearestHostile()
        }
        if intent.firePrimary, !wasFiring { onPlayerFired?() }
        wasFiring = intent.firePrimary
        effectClock += dt
        updateBeamLoopPositions(listener: scenePos)
        updateFlashes(dt)
        syncProjectiles()
        syncBeams()
        syncNPCs()
        syncAsteroids()
        updateSelectionBrackets()
        updateAIDebug()
        shipNode.position = scenePos

        // Base hull + its shän overlays all share one frame index: the live
        // rotation set (banking → turn direction, animation → a clock) times
        // framesPerSet, plus the heading. The engine-glow, running-light and
        // weapon-glow sheets carry the same set/heading layout, so they reuse it.
        let heading = hullAnim.heading(forAngle: p.angle)
        let turn = turnSign(fromAngle: lastPlayerAngle, toAngle: p.angle, dt: dt)
        lastPlayerAngle = p.angle
        animClock += dt
        blinkClock += dt
        let baseSet = hullAnim.baseSet(turnSign: turn, animClock: animClock, disabled: false)
        if let sprite = shipSprite, !rotationTextures.isEmpty {
            sprite.texture = rotationTextures[hullAnim.frameIndex(set: baseSet, heading: heading, count: rotationTextures.count)]
        } else if let tri = placeholder {
            tri.zRotation = -CGFloat(p.angle)
        }
        if let glow = engineGlowSprite, !engineGlowTextures.isEmpty {
            glow.texture = engineGlowTextures[hullAnim.frameIndex(set: baseSet, heading: heading, count: engineGlowTextures.count)]
        }
        if let lights = lightNode, !lightTextures.isEmpty {
            lights.texture = lightTextures[hullAnim.frameIndex(set: baseSet, heading: heading, count: lightTextures.count)]
            let intensity = hullAnim.lightIntensity(clock: blinkClock)
            lights.isHidden = intensity <= 0.02
            lights.alpha = intensity
        }
        if let wg = weaponGlowNode, !weaponGlowTextures.isEmpty {
            weaponGlowFlare *= hullAnim.weaponGlowDecay(dt: dt)
            wg.texture = weaponGlowTextures[hullAnim.frameIndex(set: baseSet, heading: heading, count: weaponGlowTextures.count)]
            wg.isHidden = weaponGlowFlare <= 0.02
            wg.alpha = weaponGlowFlare
        }
        if let shield = shieldSprite {
            shieldFlare = Self.advanceShieldFlare(shieldFlare, shieldNow: p.shield,
                                                  shieldWas: lastPlayerShield,
                                                  maxShield: p.maxShield, dt: dt)
            applyShieldFlare(shieldFlare, to: shield)
        }
        lastPlayerShield = p.shield

        updateThruster(active: intent.thrust || p.afterburnerActive, angle: p.angle,
                       boosted: p.afterburnerActive)

        cameraNode.position = shakenCameraPosition(scenePos, dt: dt)
        updateStarfield(cameraAt: scenePos)
        updateMurkFog()
        updateLanding(player: p)
        updateHUD(dt: dt)
    }

    /// Find the nearest landable stellar body and decide whether the player is in
    /// range and slow enough to land. Sets the HUD's land prompt accordingly.
    private func updateLanding(player p: Ship) {
        var bestID: Int?
        var bestDist = Double.greatestFiniteMagnitude
        var bestReach = 0.0
        for body in world.systemContext.bodies where isPlayerLandTarget(body) {
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
            hud?.landName = name
            hud?.landReady = canLandNow
        } else {
            hud?.landPrompt = ""
            hud?.landName = ""
            hud?.landReady = false
        }
    }

    /// Edge-triggered low-shield/critical-hull klaxons. Fires once per crossing
    /// below the threshold; a little hysteresis on the recovery side (threshold
    /// + 5%) keeps a value hovering right at the line from retriggering every
    /// ~12 Hz HUD tick.
    private func updateWarnings(shieldFraction: Double, armorFraction: Double) {
        if shieldFraction <= 0.25 {
            if !shieldWarned { audio?.play(.lowShieldWarning); shieldWarned = true }
        } else if shieldFraction > 0.30 {
            shieldWarned = false
        }
        if armorFraction <= 0.15 {
            if !hullWarned { audio?.play(.criticalHullWarning); hullWarned = true }
        } else if armorFraction > 0.20 {
            hullWarned = false
        }
    }

    // MARK: Hailing + target-lock

    /// Who `.hailTarget` reaches: whatever is currently selected — the locked
    /// ship target, or else the selected planet/station. Nil (no hail) when
    /// nothing is selected; hailing never falls back to a nearby-but-unselected
    /// ship, so pressing Hail with no selection does nothing rather than
    /// contacting a ship the player never actually chose.
    enum HailResult {
        case ship(entityID: Int, name: String, shipTypeID: Int, govt: GovtRes, hostile: Bool)
        case planet(spobID: Int, name: String, govt: GovtRes?, landable: Bool)
    }

    func attemptHail() -> HailResult? {
        if let tid = world.player.currentTargetID, let ship = world.ship(id: tid) {
            guard let game = galaxy?.game, let govt = game.govt(ship.government) else { return nil }
            return .ship(entityID: ship.entityID, name: ship.name, shipTypeID: ship.shipTypeID,
                        govt: govt, hostile: world.diplomacy?.isHostileToPlayer(ship.government) == true)
        }
        if let pid = selectedPlanetID, let pv = planetVisuals.first(where: { $0.id == pid }) {
            let landable = world.systemContext.bodies.first { $0.id == pid }?.canLand ?? false
            return .planet(spobID: pid, name: pv.name, govt: galaxy?.game.govt(pv.government), landable: landable)
        }
        return nil
    }

    /// How willing `entityID` is to help, driving both eligibility and price
    /// in `GameContainerView`: allies help for free, a truly neutral crew
    /// wants paying, a crew that's come to dislike the player (a negative but
    /// not-yet-hostile legal record) will only sometimes agree and charges
    /// more for the risk, and an outright hostile/busy/untalkative ship won't
    /// help at all.
    enum AssistanceTier { case ally, neutral, wary, unavailable }

    func assistanceTier(entityID: Int) -> AssistanceTier {
        guard let ship = world.ship(id: entityID), ship.isAlive, !ship.disabled,
              world.diplomacy?.isHostileToPlayer(ship.government) != true,
              let govt = galaxy?.game.govt(ship.government), !govt.nonTalkative,
              let brain = ship.brain,
              ![.attacking, .fleeing, .departing, .landing, .assisting].contains(brain.state)
        else { return .unavailable }
        if world.diplomacy?.areAllied(ship.government, world.player.government) == true { return .ally }
        let record = world.diplomacy?.playerRecord[ship.government] ?? 0
        return record < 0 ? .wary : .neutral
    }

    /// Start a paid assist run: the ship flies to the player, docks, and
    /// delivers fuel/repairs (see `AIBrain.assist`/`World.deliverAssistance`).
    func requestAssistance(entityID: Int) {
        world.ship(id: entityID)?.brain?.beginAssisting()
    }

    /// Select ship `id`, clearing any planet selection — only one thing is
    /// ever selected at a time.
    private func selectShip(_ id: Int) {
        world.selectTarget(id: id)
        selectedPlanetID = nil
    }

    /// Select planet/station `id`, clearing any ship target — only one thing
    /// is ever selected at a time.
    private func selectPlanet(_ id: Int) {
        selectedPlanetID = id
        world.clearPlayerTarget()
    }

    func selectNearestTarget() {
        guard world.selectNearestTarget(hostileOnly: false) != nil else { return }
        selectedPlanetID = nil
    }

    func selectNearestHostile() {
        guard world.selectNearestTarget(hostileOnly: true) != nil else { return }
        selectedPlanetID = nil
    }

    /// Toggle the player's cloaking device (oütf ModType 17). No-op if unfitted.
    func togglePlayerCloak() {
        world.togglePlayerCloak()
        if world.player.hasCloak {
            hud?.post(world.player.cloakEngaged ? "Cloaking device engaged." : "Cloaking device disengaged.")
        }
    }

    /// Scramble every docked fighter from the player's own bays right now.
    func launchPlayerFighters() {
        guard !world.player.fighterBays.isEmpty else { return }
        world.playerLaunchFighters()
    }

    /// Call every deployed player fighter back to dock, regardless of combat.
    func recallPlayerFighters() {
        guard !world.player.fighterBays.isEmpty else { return }
        world.playerRecallFighters()
    }

    /// One entry in the combined Tab-cycle order: every in-range ship plus
    /// every planet in the system, ordered by distance from the player, so
    /// Tab reaches planets too — not just ships found by clicking.
    private func cycleCandidates() -> [(isShip: Bool, id: Int, dist: Double)] {
        let p = world.player.position
        // Tab-cycling (and the nearest/hostile hotkeys) target **ships only** —
        // planets/stations are selected by clicking them, not by the ship
        // targeting cycle, matching EV Nova.
        var items: [(isShip: Bool, id: Int, dist: Double)] = []
        for npc in world.npcs where npc.isAlive && !npc.disabled {
            let d = (npc.position - p).length
            if d <= World.targetLockRange { items.append((true, npc.entityID, d)) }
        }
        return items.sorted { $0.dist < $1.dist }
    }

    /// Cycle the single selection forward through every in-range ship plus
    /// every planet in the system, ordered by distance, wrapping around.
    func cycleTarget() {
        let candidates = cycleCandidates()
        guard !candidates.isEmpty else { return }
        let currentIdx = candidates.firstIndex { c in
            c.isShip ? c.id == world.player.currentTargetID : c.id == selectedPlanetID
        }
        let next = candidates[(currentIdx.map { $0 + 1 } ?? 0) % candidates.count]
        if next.isShip { selectShip(next.id) } else { selectPlanet(next.id) }
    }

    /// Drop the current selection entirely, ship or planet — after this,
    /// nothing is selected.
    func clearTarget() {
        world.clearPlayerTarget()
        selectedPlanetID = nil
    }

    /// Step the selected secondary weapon (the one the secondary trigger fires),
    /// reflecting the change in the HUD readout immediately so the switch is
    /// visible even between throttled HUD updates. Returns the new weapon's name
    /// (for a transient on-screen confirmation), or nil with no secondaries.
    @discardableResult
    func cycleSecondaryWeapon(forward: Bool) -> String? {
        guard let player = world?.player, !player.secondaryWeaponIDs.isEmpty else { return nil }
        player.cycleSecondary(forward: forward)
        if let mount = player.effectiveSecondaryMount {
            hud?.weaponName = mount.spec.name.novaDisplayName
            hud?.weaponAmmo = mount.ammo
            return mount.spec.name.novaDisplayName
        }
        return nil
    }

    // MARK: Player escorts (command window)

    /// A snapshot of one player escort for the command UI.
    struct EscortInfo: Identifiable {
        /// The live scene `entityID` (per-spawn). Use `recordID` to map to the
        /// persistent roster; `id` only needs to be Identifiable-stable per frame.
        let id: Int
        /// The persistent `EscortRecord.id`, when this live ship was spawned from
        /// the roster (captured/hired/mission escorts). nil for any escort not
        /// tied to a record (e.g. debug-spawned wing).
        let recordID: Int?
        let name: String
        let shipType: Int
        let shieldFraction: Double
        let armorFraction: Double
    }

    /// The player's current escort wing (captured / recruited ships).
    func escortRoster() -> [EscortInfo] {
        (world?.playerEscorts ?? []).map {
            EscortInfo(id: $0.entityID, recordID: $0.escortRecordID, name: $0.name,
                       shipType: $0.shipTypeID,
                       shieldFraction: $0.shieldFraction, armorFraction: $0.armorFraction)
        }
    }

    /// Whether `entityID` is one of the player's own escorts — the gate the
    /// container uses to open the Escorts command window (DITL #1022) instead of
    /// the generic comm dialog when you hail a targeted ship, as EV Nova does.
    func isPlayerEscort(_ entityID: Int) -> Bool {
        world?.playerEscorts.contains { $0.entityID == entityID } ?? false
    }

    /// The wing's shared standing order (nil if mixed / no escorts).
    var escortOrder: EscortOrder? { world?.playerEscortOrder }

    /// Issue a standing order to the whole escort wing.
    func commandEscorts(_ order: EscortOrder) { world?.setPlayerEscortOrder(order) }

    // MARK: Persistent escort roster ↔ live wing

    /// entityID → persistent `EscortRecord.id`, so a destroyed escort can be
    /// removed from the pilot save even after its `Ship` is gone from the world.
    private var escortRecordByEntity: [Int: Int] = [:]

    /// Fired when an escort tied to a persistent record leaves the live wing by
    /// being destroyed — the container removes it from the pilot roster. Passes
    /// the `EscortRecord.id`.
    var onEscortLost: ((Int) -> Void)?

    /// Tag an already-spawned live ship as the escort for persistent record
    /// `recordID`, so per-escort commands and loss bookkeeping resolve to it.
    func tagEscort(entityID: Int, recordID: Int) {
        world?.ship(id: entityID)?.escortRecordID = recordID
        escortRecordByEntity[entityID] = recordID
    }

    /// Spawn a ship of `shipType` next to the player, recruit it into the wing,
    /// and tag it with persistent `recordID`. Used both for a fresh bar hire and
    /// for respawning the saved wing on entering a system. Returns success.
    @discardableResult
    func spawnRosterEscort(shipType: Int, recordID: Int) -> Bool {
        guard let galaxy, world != nil else { return false }
        let player = world.player
        let bearing = world.rng.double(in: 0...(2 * .pi))
        let dist = world.rng.double(in: 300...600)
        let pos = player.position + Vec2(sin(bearing), cos(bearing)) * dist
        let ang = (player.position - pos).angle
        guard let ship = galaxy.makeLoadedShip(shipType, government: player.government,
                                               at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: 0...1)) else { return false }
        world.addNPC(ship, arrival: .hyperspace)
        world.recruitEscort(ship)
        tagEscort(entityID: ship.entityID, recordID: recordID)
        return true
    }

    /// Respawn the saved escort wing on entering a system — each `(recordID,
    /// shipType)` becomes a live ship flying with the player, as EV Nova's
    /// escorts follow their flagship between systems.
    ///
    /// Idempotent by record id: a record whose escort is already live in this
    /// world is skipped, so it's safe to call on every `syncNav` (some of which
    /// are course/HUD refreshes of the *same* world, not fresh builds) without
    /// spawning duplicates. A fresh world has no live escorts, so all records
    /// spawn; this is also where an upgraded record's new hull first appears
    /// (the old ship is gone with the previous world), matching EV Nova's
    /// "upgrade applies at the next landing/takeoff".
    func respawnEscorts(_ records: [(recordID: Int, shipType: Int)]) {
        guard let world else { return }
        let live = Set(world.playerEscorts.compactMap { $0.escortRecordID })
        for r in records where !live.contains(r.recordID) {
            spawnRosterEscort(shipType: r.shipType, recordID: r.recordID)
        }
    }

    /// Remove the live ship for persistent escort `recordID` from the wing (a
    /// release-from-servitude or an unaffordable-fee departure). No-op if it isn't
    /// currently spawned (e.g. released while between systems).
    func despawnEscort(recordID: Int) {
        guard let world else { return }
        for ship in world.playerEscorts where ship.escortRecordID == recordID {
            ship.brain?.leaderID = nil
            world.removeShip(entityID: ship.entityID)
            escortRecordByEntity[ship.entityID] = nil
        }
    }

    /// The live ship currently representing persistent escort `recordID`, if any.
    func liveEscort(recordID: Int) -> Ship? {
        world?.playerEscorts.first { $0.escortRecordID == recordID }
    }

    // MARK: Boarding

    /// How close (world units) the player must be to a disabled hulk to board it.
    private let boardingRange: Double = 280

    /// The loot from a boardable hulk in reach — the current target if it's a
    /// disabled ship in range, otherwise the nearest disabled ship in range
    /// (so the Board control "just works" near a wreck, since the target-cycle
    /// hotkeys deliberately skip disabled ships). nil when nothing is boardable.
    func attemptBoard() -> World.BoardingManifest? {
        guard let w = world else { return nil }
        let pos = w.player.position
        func boardable(_ s: Ship) -> Bool {
            s.isAlive && s.disabled && s !== w.player && (s.position - pos).length <= boardingRange
        }
        // Prefer the explicit target, else the nearest disabled hulk in range.
        // Use `board` (not `boardingManifest`) so the actual dock emits
        // `.shipBoarded` — and, for a `rescue`-goal mission derelict, the
        // goal-reached event that completes the rescue.
        if let tid = w.player.currentTargetID, let s = w.ship(id: tid), boardable(s) {
            return w.board(shipID: tid)
        }
        let nearest = w.npcs.filter(boardable)
            .min { ($0.position - pos).length < ($1.position - pos).length }
        guard let hulk = nearest else { return nil }
        world?.selectTarget(id: hulk.entityID)   // lock it so the plunder targets it
        return w.board(shipID: hulk.entityID)
    }

    /// The (possibly updated) manifest for a boarded ship, for refreshing the
    /// plunder dialog after taking loot.
    func boardManifest(_ id: Int) -> World.BoardingManifest? { world?.boardingManifest(for: id) }

    /// The `pêrs` id of an entity, if it's a named character (for hail quotes).
    func personID(forEntity id: Int) -> Int? { world?.ship(id: id)?.personID }
    /// Whether the entity's ship is currently a disabled hulk.
    func isEntityDisabled(_ id: Int) -> Bool { world?.ship(id: id)?.disabled ?? false }
    /// Whether the entity's ship is currently engaged in combat with the
    /// player — feeds `pêrs.HailQuote`'s "only when the ship begins to attack
    /// the player" flag (0x0010).
    func isEntityAttackingPlayer(_ id: Int) -> Bool {
        guard let brain = world?.ship(id: id)?.brain else { return false }
        return brain.state == .attacking && brain.targetID == World.playerEntityID
    }
    /// Send a named `pêrs`'s live ship (looked up by its `pêrs` id, not entity
    /// id) off toward the hyperspace edge — `pêrs.Flags` 0x0800 ("make ship
    /// leave after accepting its LinkMission"). A no-op if that person isn't
    /// currently spawned in this system.
    func sendPersonDeparting(personID: Int) {
        world?.npcs.first { $0.personID == personID }?.brain?.state = .departing
    }
    /// Record a fresh grudge on the live world so a wronged person turns hostile
    /// immediately, without waiting for the next system rebuild.
    func addLiveGrudge(_ personID: Int) { world?.playerPersGrudges.insert(personID) }

    /// Push the current pêrs grudge set + spawn-eligibility gate onto the live
    /// world. Called by the host after it sets those (post-`configure`), so the
    /// starting system reflects a pilot's existing grudges immediately.
    func syncPersStateToWorld() {
        world?.playerPersGrudges = persGrudges
        if let e = persSpawnEligible { world?.persSpawnEligible = e }
    }

    /// Take the credits aboard a boarded hulk; returns the amount.
    func plunderCredits(_ id: Int) -> Int { world?.takePlunderCredits(from: id) ?? 0 }

    /// Move a boarded hulk's cargo into the hold; returns what was taken.
    func plunderCargo(_ id: Int) -> [(commodity: Int, tons: Int)] { world?.takePlunderCargo(from: id) ?? [] }

    /// Take a boarded përs hulk's ItemClass outfit loot (outfit ids); once only.
    func plunderOutfits(_ id: Int) -> [Int] { world?.takePlunderOutfits(from: id) ?? [] }

    /// Roll to capture a boarded hulk into the escort wing; returns success.
    /// Attempt to board-and-capture ship `id`. On success returns the captured
    /// hull's live entityID / shïp type / name so the container can register it
    /// as a persistent (free) escort record and tag the ship; nil on failure.
    func attemptCapture(_ id: Int) -> (entityID: Int, shipType: Int, name: String)? {
        guard let world, world.attemptCapture(shipID: id, roll: Int.random(in: 0..<100)),
              let ship = world.ship(id: id) else { return nil }
        return (ship.entityID, ship.shipTypeID, ship.name)
    }

    /// Click/tap hit-test in scene space (== world space here): nearest ship
    /// first, then nearest planet; clears the selection if nothing was hit.
    /// Called by `GameContainerView` off a tap gesture on the `SpriteView`.
    @discardableResult
    func selectAt(scenePoint: CGPoint) -> Bool {
        let p = Vec2(Double(scenePoint.x), Double(scenePoint.y))
        var nearestShipDist = -1.0
        for npc in world.npcs { nearestShipDist = min(nearestShipDist < 0 ? .greatestFiniteMagnitude : nearestShipDist, (npc.position - p).length) }
        var nearestPlanetDist = -1.0
        for pv in planetVisuals {
            let dx = Double(pv.position.x) - p.x, dy = Double(pv.position.y) - p.y
            let d = (dx * dx + dy * dy).squareRoot()
            nearestPlanetDist = min(nearestPlanetDist < 0 ? .greatestFiniteMagnitude : nearestPlanetDist, d)
        }
        let playerPos = world.player.position
        Log.input.debug("selectAt scenePoint=(\(p.x, privacy: .public),\(p.y, privacy: .public)) playerPos=(\(playerPos.x, privacy: .public),\(playerPos.y, privacy: .public)) nearestShipDist=\(nearestShipDist, privacy: .public) nearestPlanetDist=\(nearestPlanetDist, privacy: .public)")
        if let ship = world.npcs.filter({ ($0.position - p).length <= $0.radius + 10 })
            .min(by: { ($0.position - p).length < ($1.position - p).length }) {
            selectShip(ship.entityID)
            return true
        }
        if let planet = planetVisuals.filter({ pv in
            let dx = Double(pv.position.x) - p.x, dy = Double(pv.position.y) - p.y
            return (dx * dx + dy * dy).squareRoot() <= Double(pv.radius) + 15
        }).min(by: { a, b in
            let da = Double(a.position.x) - p.x, db = Double(a.position.y) - p.y
            let ea = Double(b.position.x) - p.x, eb = Double(b.position.y) - p.y
            return (da * da + db * db) < (ea * ea + eb * eb)
        }) {
            selectPlanet(planet.id)
            // Clicking a hypergate powers it up if you're cleared to use it (a
            // wormhole needs nothing). Selection still happens either way.
            if planet.isGate { handleGateClick(planet.id) }
            return true
        }
        clearTarget()
        return false
    }

    // MARK: Hypergate / wormhole gameplay

    private enum GateGlowKind { case hypergate, wormhole }

    /// Whether the player is cleared to use hypergate `spobID` right now — a
    /// clearance check against the gate's owning government (see
    /// `SpobRes.playerMayUseGate`). Wormholes always pass.
    func playerMayUseGate(_ spobID: Int) -> Bool {
        guard let spob = galaxy?.game.spob(spobID) else { return false }
        let dip = world?.diplomacy
        let govt = spob.government
        let standing = dip?.playerRecord[govt] ?? 0
        let hostile = dip?.isHostileToPlayer(govt) ?? false
        let allied = dip?.areAllied(govt, world?.player.government ?? independentGovt) ?? false
        return spob.playerMayUseGate(standing: standing, hostile: hostile, allied: allied)
    }

    /// Handle a click on a gate. A wormhole just notes it's usable; a hypergate
    /// switches on (glow + charge sound) if the player is cleared, or refuses
    /// with a message and does nothing if not.
    private func handleGateClick(_ spobID: Int) {
        guard let spob = galaxy?.game.spob(spobID) else { return }
        if spob.isWormhole {
            hud?.post("Wormhole — fly into it to be swept across the galaxy.")
            return
        }
        guard spob.isHypergate else { return }
        if playerMayUseGate(spobID) {
            if openGateIDs.insert(spobID).inserted {
                if let node = planetNodeByID[spobID] {
                    setGateGlow(node: node, radius: planetVisuals.first { $0.id == spobID }?.radius ?? 40,
                                kind: .hypergate)
                }
                audio?.play(.hyperspaceCharge)
                hud?.post("\(spob.name) hypergate online — land on it to travel.")
            } else {
                hud?.post("\(spob.name) hypergate is online.")
            }
        } else {
            audio?.play(.uiError)
            let owner = galaxy?.game.govt(spob.government)?.name ?? "controlling"
            hud?.post("You are not cleared to use the \(owner) hypergate.")
        }
    }

    /// Mark hypergate `spobID` on (used when landing auto-activates a gate the
    /// player is cleared for but never clicked). No-op for a non-gate.
    func activateGate(_ spobID: Int) {
        guard let spob = galaxy?.game.spob(spobID), spob.isHypergate, openGateIDs.insert(spobID).inserted else { return }
        if let node = planetNodeByID[spobID] {
            setGateGlow(node: node, radius: planetVisuals.first { $0.id == spobID }?.radius ?? 40, kind: .hypergate)
        }
    }

    /// Add (or refresh) the pulsing aura that marks a live gate: cyan for a
    /// hypergate, violet for a wormhole — the same palette the galaxy map uses.
    private func setGateGlow(node: SKNode, radius: CGFloat, kind: GateGlowKind) {
        let glowName = "gateGlow"
        node.childNode(withName: glowName)?.removeFromParent()
        let color: SKColor = kind == .wormhole
            ? SKColor(red: 0.78, green: 0.45, blue: 1.0, alpha: 1)
            : SKColor(red: 0.30, green: 0.85, blue: 0.98, alpha: 1)
        let glow = SKShapeNode(circleOfRadius: max(20, radius) * 1.2)
        glow.name = glowName
        glow.lineWidth = 3
        glow.glowWidth = 7
        glow.strokeColor = color
        glow.fillColor = color.withAlphaComponent(0.12)
        glow.zPosition = -1
        glow.blendMode = .add
        glow.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.5, duration: 0.7), .fadeAlpha(to: 1.0, duration: 0.7)])))
        node.addChild(glow)
    }

    private func clearGateGlow(_ spobID: Int) {
        planetNodeByID[spobID]?.childNode(withName: "gateGlow")?.removeFromParent()
    }

    private func updateTargetHUD(_ target: Ship?) {
        guard let hud else { return }
        guard let target else {
            hud.targetName = ""; hud.targetShield = 0; hud.targetArmor = 0
            hud.targetHostile = false; hud.targetGovtLabel = ""
            hud.targetShipTypeID = nil
            return
        }
        hud.targetName = target.name
        hud.targetShipTypeID = target.shipTypeID >= 128 ? target.shipTypeID : nil
        hud.targetShield = target.maxShield > 0 ? target.shield / target.maxShield : 0
        hud.targetArmor = target.maxArmor > 0 ? target.armor / target.maxArmor : 1
        hud.targetHostile = isEffectivelyHostileToPlayer(target)
        hud.targetGovtLabel = galaxy?.game.govt(target.government)?.targetCode ?? ""
    }

    /// The click-selected planet/station nav destination, if any (independent
    /// of the ship target above — the two coexist, as in the real game).
    private func updateNavTargetHUD() {
        guard let hud else { return }
        guard let id = selectedPlanetID, let pv = planetVisuals.first(where: { $0.id == id }) else {
            hud.navTargetName = ""; hud.navTargetLandable = false
            return
        }
        hud.navTargetName = pv.name
        hud.navTargetLandable = world.systemContext.bodies.first { $0.id == id }.map(isPlayerLandTarget) ?? false
    }

    // MARK: Screen shake

    /// Remaining shake time and its peak magnitude (points). Refreshed by each
    /// nearby explosion; decays to nothing over `shakeDuration`.
    private var shakeTime: CGFloat = 0
    private var shakeMag: CGFloat = 0
    private let shakeDuration: CGFloat = 0.4

    /// Register a camera-shake impulse from an explosion, scaled by how close it
    /// went off and how big it was. Gated by the "Screen shake" setting and
    /// suppressed entirely by "Reduce flashing & motion".
    private func addShake(at world: CGPoint, radius: CGFloat) {
        guard let player = playerShip else { return }
        let d = hypot(world.x - CGFloat(player.position.x), world.y - CGFloat(player.position.y))
        let falloff = max(0, 1 - d / 900)           // felt within ~900px
        guard falloff > 0 else { return }
        // Haptics are independent of the visual-shake preference.
        if falloff > 0.35 { Haptics.play(.light) }
        guard settings.screenShake, !settings.reduceFlashing else { return }
        shakeMag = min(20, max(shakeMag, (6 + radius * 0.35) * falloff))
        shakeTime = shakeDuration
    }

    /// The camera position with the current shake offset applied, decaying the
    /// shake each frame. Returns `base` unchanged when nothing is shaking.
    private func shakenCameraPosition(_ base: CGPoint, dt: Double) -> CGPoint {
        guard shakeTime > 0 else { return base }
        shakeTime -= CGFloat(dt)
        guard shakeTime > 0 else { shakeMag = 0; return base }
        let m = shakeMag * (shakeTime / shakeDuration)      // ease out
        return CGPoint(x: base.x + .random(in: -m...m), y: base.y + .random(in: -m...m))
    }

    /// Seconds a shield flare takes to fade from a full hit back to invisible.
    private static let shieldFlareDecay: CGFloat = 0.45
    /// Peak opacity of the shield bubble at full flare (translucent, not opaque).
    private static let shieldFlareMaxAlpha: CGFloat = 0.85

    /// Advance a decaying shield-hit flare (0…1). It decays every frame and
    /// spikes whenever the ship's shield dropped since the last frame — i.e. the
    /// shields just absorbed a hit. Regeneration (shield rising) never flares,
    /// and once shields hit 0 armour damage produces no further drop, so the
    /// bubble stops — matching EV Nova's "shields only" flash. `shieldWas < 0`
    /// (the first frame after a (re)build) is treated as "no prior sample".
    private static func advanceShieldFlare(_ current: CGFloat, shieldNow: Double,
                                           shieldWas: Double, maxShield: Double,
                                           dt: TimeInterval) -> CGFloat {
        var flare = max(0, current - CGFloat(dt) / shieldFlareDecay)
        if shieldWas >= 0, maxShield > 0 {
            let dropFrac = (shieldWas - shieldNow) / maxShield
            if dropFrac > 0.0001 {
                // Even a glancing hit reads (floor 0.4); a big bite maxes out.
                flare = max(flare, min(1, 0.4 + CGFloat(dropFrac) * 6))
            }
        }
        return flare
    }

    /// Apply a flare value to a shield-bubble node: hide it when spent, else
    /// scale its opacity by the flare.
    private func applyShieldFlare(_ flare: CGFloat, to node: SKSpriteNode) {
        if flare <= 0.02 { node.isHidden = true; return }
        node.isHidden = false
        node.alpha = flare * Self.shieldFlareMaxAlpha
    }

    private func updateThruster(active: Bool, angle: Double, boosted: Bool = false) {
        // The "Engine & weapon glow" option, off, suppresses the exhaust entirely.
        guard settings.engineGlow else {
            engineGlowSprite?.isHidden = true
            thruster.isHidden = true
            return
        }
        // Real per-hull engine-glow art (when the data has one) replaces the
        // synthetic flame entirely rather than layering both.
        if let glow = engineGlowSprite {
            glow.isHidden = !active
            if active {
                // "Reduce flashing & motion" holds the exhaust at a steady level
                // instead of the low-pass-filtered flicker.
                let targetAlpha: CGFloat = settings.reduceFlashing ? (boosted ? 0.95 : 0.75)
                    : (boosted ? .random(in: 0.85...1.0) : .random(in: 0.6...0.85))
                thrusterAlpha = thrusterAlpha * 0.85 + targetAlpha * 0.15
                glow.alpha = thrusterAlpha
            }
            thruster.isHidden = true
            return
        }
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

    /// Mirror the world's live projectiles into a pooled set of sprites. Each shot
    /// draws its real weapon graphic (`wëap` spïn art) oriented to its heading —
    /// a torpedo points where it flies, a spinning mine animates — falling back to
    /// a soft additive dot for weapons that ship no graphic. Nodes are reused
    /// across frames and re-textured in place (cheap); same-weapon volleys batch.
    private func syncProjectiles() {
        let shots = world.projectiles
        while projectileNodes.count < shots.count {
            let dot = SKSpriteNode(texture: projectileTexture)
            projectileLayer.addChild(dot)
            projectileNodes.append(dot)
        }
        for (i, node) in projectileNodes.enumerated() {
            guard i < shots.count else { node.isHidden = true; continue }
            let s = shots[i]
            node.position = CGPoint(x: s.position.x, y: s.position.y)
            node.isHidden = false

            let frames = s.graphicSpinID.map { weaponGraphicTextures($0) } ?? []
            if !frames.isEmpty {
                // Real shot art. A many-frame sheet that doesn't spin is a
                // rotation sheet (orient by heading); otherwise it's a looping
                // animation drawn pointing along travel.
                let asRotation = frames.count >= 16 && !s.spinShots
                if asRotation {
                    let n = frames.count
                    var a = s.facing.truncatingRemainder(dividingBy: 2 * .pi)
                    if a < 0 { a += 2 * .pi }
                    node.texture = frames[Int((a / (2 * .pi) * Double(n)).rounded()) % n]
                    node.zRotation = 0
                } else {
                    let idx = s.spinShots ? Int(effectClock * 15) % frames.count : 0
                    node.texture = frames[idx]
                    node.zRotation = -CGFloat(s.facing)
                }
                node.size = node.texture?.size() ?? CGSize(width: 12, height: 12)
                node.colorBlendFactor = 0
                node.blendMode = .alpha
            } else {
                // Generic glowing bolt.
                node.texture = projectileTexture
                node.size = CGSize(width: 9, height: 9)
                node.color = SKColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)
                node.colorBlendFactor = 1
                node.blendMode = .add
                node.zRotation = 0
            }
        }
    }

    /// Decoded, cached shot-graphic frames for a weapon's spïn id.
    private func weaponGraphicTextures(_ spinID: Int) -> [SKTexture] {
        if let cached = weaponGraphicCache[spinID] { return cached }
        var textures: [SKTexture] = []
        if let sheet = galaxy?.game.weaponSprite(spinID: spinID) {
            textures = SpriteTextures.rotationFrames(from: sheet, rotationCount: sheet.frameCount)
        }
        weaponGraphicCache[spinID] = textures
        return textures
    }

    /// Mirror `world.activeBeams` into a pool of stretched beam sprites. The
    /// world welds continuous beams to their shooters each step, so simply
    /// following its geometry keeps a beam locked to the moving ship and its
    /// endpoint clipped to whatever it's hitting. Pooled + batched, so many
    /// simultaneous beams cost almost nothing.
    private func syncBeams() {
        let beams = world.activeBeams
        while beamNodes.count < beams.count {
            let node = SKSpriteNode(texture: beamTexture)
            node.anchorPoint = CGPoint(x: 0, y: 0.5)   // pivot at the muzzle end
            node.colorBlendFactor = 1
            node.blendMode = .add
            node.zPosition = 12
            effectsLayer.addChild(node)
            beamNodes.append(node)
        }
        for (i, node) in beamNodes.enumerated() {
            guard i < beams.count else { node.isHidden = true; continue }
            let b = beams[i]
            let from = CGPoint(x: b.from.x, y: b.from.y)
            let dx = b.to.x - b.from.x, dy = b.to.y - b.from.y
            let length = max(1, CGFloat((dx * dx + dy * dy).squareRoot()))
            let width = CGFloat(b.width > 0 ? b.width : 3)
            node.position = from
            node.zRotation = atan2(CGFloat(dy), CGFloat(dx))
            node.size = CGSize(width: length, height: max(2, width))
            if let c = b.color {
                node.color = SKColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
            } else {
                node.color = b.hit ? SKColor(red: 1, green: 0.6, blue: 0.3, alpha: 1)
                                   : SKColor(white: 0.85, alpha: 1)
            }
            // A continuous beam holds full brightness while its trigger is down;
            // a pulse beam fades out over its short life instead of blinking off.
            node.alpha = b.continuous ? 0.95 : max(0.1, CGFloat(b.life / 0.08))
            node.isHidden = false
        }
    }

    /// A soft round dot used for every projectile (radial white→transparent).
    private static func makeDotTexture(diameter: Int = 16) -> SKTexture {
        let d = max(4, diameter)
        return imageTexture(width: d, height: d) { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [SKColor.white.cgColor,
                          SKColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: cs, colors: colors,
                                        locations: [0, 1]) else { return }
            let c = CGPoint(x: Double(d) / 2, y: Double(d) / 2)
            ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: Double(d) / 2,
                                   options: [])
        }
    }

    /// A 1×N vertical-falloff strip: opaque core fading to transparent edges.
    /// Stretched along its length (x) and thickness (y) per beam.
    private static func makeBeamTexture(thickness: Int = 32) -> SKTexture {
        let h = max(4, thickness)
        return imageTexture(width: 4, height: h) { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [SKColor(white: 1, alpha: 0).cgColor,
                          SKColor.white.cgColor,
                          SKColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: cs, colors: colors,
                                        locations: [0, 0.5, 1]) else { return }
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: Double(h)), options: [])
        }
    }

    /// Draw into an RGBA bitmap and wrap the result in an `SKTexture`.
    private static func imageTexture(width: Int, height: Int, _ draw: (CGContext) -> Void) -> SKTexture {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture()
        }
        draw(ctx)
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }

    // MARK: NPC ships

    /// Reconcile the scene's NPC nodes with the world's live NPC roster: spawn
    /// nodes for arrivals, update transforms/plume/damage for the living, and
    /// remove nodes for ships that died or jumped out.
    /// Diff `world.asteroids` against the live node pool: build a node for any
    /// new rock (initial scatter or a fragmentation child), update its rotation
    /// frame from `spriteFrame`, and drop nodes for rocks that died this tick.
    /// Asteroids are stationary (see `Asteroid`'s doc comment), so unlike
    /// `syncNPCs` this never repositions an existing node.
    private func syncAsteroids() {
        var seen = Set<Int>()
        for rock in world.asteroids where rock.isAlive {
            seen.insert(rock.id)
            let node = asteroidNodes[rock.id] ?? makeAsteroidNode(for: rock)
            if let sprite = node.sprite, !node.textures.isEmpty {
                sprite.texture = node.textures[min(rock.spriteFrame, node.textures.count - 1)]
            }
        }
        for (id, node) in asteroidNodes where !seen.contains(id) {
            node.container.removeFromParent()
            asteroidNodes[id] = nil
        }
    }

    private func makeAsteroidNode(for rock: Asteroid) -> AsteroidNode {
        let n = AsteroidNode()
        n.container.position = CGPoint(x: rock.position.x, y: rock.position.y)
        n.container.zPosition = 6
        let textures = asteroidTextures(for: rock.roidTypeID)
        n.textures = textures
        if let first = textures.first {
            let sprite = SKSpriteNode(texture: first)
            sprite.texture?.filteringMode = spriteFilter
            n.container.addChild(sprite)
            n.sprite = sprite
        }
        addChild(n.container)
        asteroidNodes[rock.id] = n
        return n
    }

    private func syncNPCs() {
        var seen = Set<Int>()
        // A cloak scanner's 0x0002 bit ("reveal cloaked ships on the screen")
        // keeps cloaked hulls fully visible to the player despite the fade
        // below; without it, cloaking fades a ship toward invisible as
        // `cloakLevel` rises (harmless — always 0 on an uncloaked ship).
        let screenRevealsCloaked = world.player.cloakScannerFlags & 0x0002 != 0
        for npc in world.npcs {
            seen.insert(npc.entityID)
            let node = npcNodes[npc.entityID] ?? makeNPCNode(for: npc)
            node.container.position = CGPoint(x: npc.position.x, y: npc.position.y)
            node.container.alpha = screenRevealsCloaked ? 1.0 : CGFloat(1 - npc.effectiveCloakLevel)
            node.animClock += frameDT
            node.blinkClock += frameDT
            let heading = node.hullAnim.heading(forAngle: npc.angle)
            let turn = turnSign(fromAngle: node.lastAngle, toAngle: npc.angle, dt: frameDT)
            node.lastAngle = npc.angle
            let set = node.hullAnim.baseSet(turnSign: turn, animClock: node.animClock, disabled: npc.disabled)
            if let sprite = node.sprite, !node.textures.isEmpty {
                sprite.texture = node.textures[node.hullAnim.frameIndex(set: set, heading: heading, count: node.textures.count)]
            } else if let tri = node.placeholder {
                tri.zRotation = -CGFloat(npc.angle)
            }
            if let glow = node.engineGlow, !node.engineGlowTextures.isEmpty {
                glow.texture = node.engineGlowTextures[node.hullAnim.frameIndex(set: set, heading: heading, count: node.engineGlowTextures.count)]
            }
            if let lights = node.light, !node.lightTextures.isEmpty {
                if npc.disabled && node.hullAnim.hidesLightsWhenDisabled {
                    lights.isHidden = true
                } else {
                    lights.texture = node.lightTextures[node.hullAnim.frameIndex(set: set, heading: heading, count: node.lightTextures.count)]
                    let intensity = node.hullAnim.lightIntensity(clock: node.blinkClock)
                    lights.isHidden = intensity <= 0.02
                    lights.alpha = intensity
                }
            }
            if let wg = node.weaponGlow, !node.weaponGlowTextures.isEmpty {
                node.weaponGlowFlare *= node.hullAnim.weaponGlowDecay(dt: frameDT)
                wg.texture = node.weaponGlowTextures[node.hullAnim.frameIndex(set: set, heading: heading, count: node.weaponGlowTextures.count)]
                wg.isHidden = node.weaponGlowFlare <= 0.02
                wg.alpha = node.weaponGlowFlare
            }
            if let shield = node.shield {
                if npc.disabled {
                    shield.isHidden = true
                    node.shieldFlare = 0
                } else {
                    node.shieldFlare = Self.advanceShieldFlare(node.shieldFlare, shieldNow: npc.shield,
                                                               shieldWas: node.lastShield,
                                                               maxShield: npc.maxShield, dt: frameDT)
                    applyShieldFlare(node.shieldFlare, to: shield)
                }
            }
            node.lastShield = npc.shield
            if npc.disabled {
                // A drifting hulk: dimmed, engines dead, no health readout.
                setDisabledLook(node, on: true)
                node.thruster?.isHidden = true
                node.engineGlow?.isHidden = true
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

        // Real engine-glow art, added first so it renders behind the hull.
        let glowTextures = npcEngineGlowTextures(for: npc.shipTypeID)
        n.engineGlowTextures = glowTextures
        if let first = glowTextures.first {
            let glow = SKSpriteNode(texture: first)
            glow.texture?.filteringMode = spriteFilter
            glow.blendMode = .add
            glow.isHidden = true
            n.container.addChild(glow)
            n.engineGlow = glow
        }

        let textures = npcTextures(for: npc.shipTypeID)
        n.textures = textures
        if let first = textures.first {
            let sprite = SKSpriteNode(texture: first)
            sprite.texture?.filteringMode = spriteFilter
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

        // Base-image animation config (banking / animation / frames-per-rotation)
        // for this hull — drives the same multi-set frame selection as the player.
        if let shan = galaxy?.game.shan(npc.shipTypeID) { n.hullAnim = HullAnim(shan) }

        // Running-lights + weapon-glow overlays (real per-hull art), additive.
        let lightTex = npcLightTextures(for: npc.shipTypeID)
        n.lightTextures = lightTex
        if let first = lightTex.first {
            let lights = SKSpriteNode(texture: first)
            lights.texture?.filteringMode = spriteFilter
            lights.blendMode = .add
            lights.zPosition = 0.5
            lights.isHidden = true
            n.container.addChild(lights)
            n.light = lights
        }
        let wgTex = npcWeaponGlowTextures(for: npc.shipTypeID)
        n.weaponGlowTextures = wgTex
        if let first = wgTex.first {
            let wg = SKSpriteNode(texture: first)
            wg.texture?.filteringMode = spriteFilter
            wg.blendMode = .add
            wg.zPosition = 0.5
            wg.isHidden = true
            n.container.addChild(wg)
            n.weaponGlow = wg
        }

        // Shield bubble overlay (only when a "Shields" plug-in supplied the art),
        // drawn on top of the hull and flared when this NPC's shields take a hit.
        let shieldTex = npcShieldTextures(for: npc.shipTypeID)
        n.shieldTextures = shieldTex
        if let first = shieldTex.first {
            let shield = SKSpriteNode(texture: first)
            shield.texture?.filteringMode = spriteFilter
            shield.zPosition = 1
            shield.isHidden = true
            n.container.addChild(shield)
            n.shield = shield
        }

        // A slim armor/shield bar that only appears once the ship is hurt. Solid
        // `SKSpriteNode`s (shared white texture → they batch) instead of the two
        // per-ship `SKShapeNode`s they replaced.
        let barWidth: CGFloat = max(20, n.radius * 1.6)
        let barBG = SKSpriteNode(color: SKColor(white: 0, alpha: 0.5), size: CGSize(width: barWidth, height: 3))
        let fill = SKSpriteNode(color: SKColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1), size: CGSize(width: barWidth, height: 3))
        // Deplete from the right: anchor the fill at its left edge.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.position = CGPoint(x: -barWidth / 2, y: 0)
        let barHolder = SKNode()
        // Above (default), below, or hidden entirely, per Settings ▸ Graphics.
        // The original never floated these over ships, so `off` is the faithful
        // look. `updateNPCHealth` respects `off` too, so it can't un-hide them.
        barHolder.position = CGPoint(x: 0, y: barOffsetY(radius: n.radius))
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

    // MARK: Hyperspace jump (player)

    /// Build the two camera-space overlays a jump uses: a full-viewport white
    /// flash and a fan of radial star-streak lines. Both start hidden and are
    /// reused every jump (no per-jump allocation). Parented to the camera so they
    /// cover the viewport no matter where the ship is in the system.
    private func buildJumpOverlays() {
        let flash = SKSpriteNode(color: .white, size: CGSize(width: 8000, height: 8000))
        flash.zPosition = 500
        flash.alpha = 0
        flash.isHidden = true
        cameraNode.addChild(flash)
        jumpFlash = flash

        let streaks = SKNode()
        streaks.zPosition = 490
        streaks.alpha = 0
        streaks.isHidden = true
        // A field of thin bright lines running along +y (the container is rotated
        // to the outbound heading at jump time), spread across the viewport.
        for _ in 0..<28 {
            let len = CGFloat.random(in: 300...900)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -len / 2))
            path.addLine(to: CGPoint(x: 0, y: len / 2))
            let line = SKShapeNode(path: path)
            line.strokeColor = SKColor(red: 0.8, green: 0.9, blue: 1.0, alpha: 0.9)
            line.lineWidth = CGFloat.random(in: 1...2.5)
            line.blendMode = .add
            line.position = CGPoint(x: .random(in: -1400...1400), y: .random(in: -1400...1400))
            streaks.addChild(line)
        }
        cameraNode.addChild(streaks)
        jumpStreaks = streaks
    }

    /// The system-murk fog veil: same oversized camera-parented sprite trick
    /// as the jump flash above, so it always covers the viewport regardless of
    /// zoom. Starts fully transparent; `updateMurkFog` drives its opacity.
    private func buildMurkFog() {
        let fog = SKSpriteNode(color: .black, size: CGSize(width: 8000, height: 8000))
        fog.zPosition = 480       // above the starfield/planets/ships, below jump overlays
        fog.alpha = 0
        fog.isHidden = true
        cameraNode.addChild(fog)
        murkFog = fog
    }

    /// Fog opacity tracks `World.effectiveMurk(for:)` (0 = clear, 100 = the
    /// Bible's own "question your glasses prescription"); a negative value
    /// hides the starfield entirely instead of thickening the fog.
    private func updateMurkFog() {
        let murk = world.effectiveMurk(for: world.player)
        for layer in starLayers { layer.container.isHidden = murk < 0 }
        guard let murkFog else { return }
        let alpha = CGFloat(max(0, min(100, murk))) / 100 * 0.85
        murkFog.alpha = alpha
        murkFog.isHidden = alpha <= 0.001
    }

    /// Begin the player's hyperspace jump to `destSystemID`. The scene owns the
    /// whole sequence: it turns the ship to `outboundHeading`, accelerates away
    /// with streaking stars, white-flashes, swaps the world to the destination
    /// in place (no scene teardown — so keyboard focus and the presented scene
    /// survive), and pops out already moving. `commit` runs once at the flash
    /// peak to update the app model (fuel/route/pilot/save). `instant` skips the
    /// slow align (an instant-jump outfit). No-op if a jump is already running.
    func beginJump(to destSystemID: Int, outboundHeading: Double, instant: Bool,
                   speed: Double = 1, commit: @escaping () -> Void) {
        guard jumpPhase == .none, world != nil else { return }
        cancelAutoLand()                       // a jump overrides any landing autopilot
        jumpDestSystemID = destSystemID
        jumpArriveGateID = nil                 // ordinary hyperjump: arrive at the edge
        jumpOutboundHeading = outboundHeading
        jumpInstant = instant
        jumpSpeed = max(1, speed)
        jumpCommit = commit
        jumpCommitted = false
        jumpClock = 0
        jumpPhase = instant ? .accelerate : .align
        // Orient the streak fan along the direction of travel.
        jumpStreaks?.zRotation = -CGFloat(outboundHeading)
        // Spin-up sound as the maneuver starts.
        audio?.play(.hyperspaceCharge)
        Log.scene.debug("beginJump -> system \(destSystemID) heading \(outboundHeading, format: .fixed(precision: 2)) instant=\(instant)")
    }

    /// Travel through a gate to `systemID`, emerging from gate `destGateID` on the
    /// far side. No align/tear-away maneuver — the gate does the work, so it's a
    /// quick white flash and you're there ("bam"). `commit` runs at the flash peak
    /// (model: set system, advance the day, save — gates spend no fuel). No-op if
    /// a jump is already running.
    func beginGateJump(toSystem systemID: Int, arriveAtGate destGateID: Int, commit: @escaping () -> Void) {
        guard jumpPhase == .none, world != nil else { return }
        cancelAutoLand()
        jumpDestSystemID = systemID
        jumpArriveGateID = destGateID
        jumpOutboundHeading = world.player.angle
        jumpInstant = true
        jumpSpeed = 1
        jumpCommit = commit
        jumpCommitted = false
        jumpClock = 0
        world.player.velocity = Vec2()      // you're sitting on the gate — no run-up
        jumpPhase = .flash                   // straight to the white-out; no maneuver
        audio?.play(.hyperspaceCharge)
        Log.scene.debug("beginGateJump -> system \(systemID), emerge at gate \(destGateID)")
    }

    /// Advance the jump one frame and return the `ControlIntent` that flies it.
    /// Called from `update` in place of manual input while `jumpPhase != .none`.
    private func stepJump(_ dt: Double) -> ControlIntent {
        jumpClock += dt
        let p = world.player
        var intent = ControlIntent()

        switch jumpPhase {
        case .none:
            break

        case .align:
            // Turn to the outbound heading and bleed off speed. This is the
            // deliberate "swing around to point at the destination" maneuver.
            intent.desiredHeading = jumpOutboundHeading
            let aimErr = abs(angleDelta(from: p.angle, to: jumpOutboundHeading))
            // Brake by facing our velocity's reverse once roughly aligned, so we
            // launch from near a standstill.
            if p.velocity.length > p.stats.maxSpeed * 0.15, aimErr < 0.6 {
                intent.desiredHeading = (p.velocity * -1).angle
                if abs(angleDelta(from: p.angle, to: intent.desiredHeading!)) < .pi / 3 { intent.thrust = true }
            }
            let aligned = aimErr < 0.1 && p.velocity.length < p.stats.maxSpeed * 0.2
            if aligned || jumpClock > 3.0 {         // 3s safety cap so a slow turner can't stall
                enterJumpPhase(.accelerate)
            }

        case .accelerate:
            // Point at the exit and pour on speed; the stars streak. We lift the
            // player's own speed cap (the same over-speed mechanism NPC jump-ins
            // use) so the ship visibly tears away rather than crawling to cruise.
            intent.desiredHeading = jumpOutboundHeading
            if abs(angleDelta(from: p.angle, to: jumpOutboundHeading)) < .pi / 2 { intent.thrust = true }
            p.entryOverspeed = max(p.entryOverspeed, p.stats.maxSpeed * 4)
            p.entryOverspeedDecayPerSec = 0        // hold the boost through the launch
            let streak = min(1 + jumpClock * 12, 9)
            showJumpStreaks(intensity: CGFloat(min(1, jumpClock / 0.35)), stretch: CGFloat(streak))
            // Hyperspace-speed outfits (ModType 22) shorten the launch.
            if jumpClock > (jumpInstant ? 0.18 : 0.45) / jumpSpeed {
                enterJumpPhase(.flash)
            }

        case .flash:
            intent.desiredHeading = jumpOutboundHeading
            // Ramp the white flash up fast; at its peak commit + swap the system.
            let t = min(1, jumpClock / 0.14)
            jumpFlash?.isHidden = false
            // "Reduce flashing & motion" caps the white-out so the jump doesn't
            // fully blank the screen.
            jumpFlash?.alpha = CGFloat(t) * (settings.reduceFlashing ? 0.45 : 1.0)
            showJumpStreaks(intensity: 1, stretch: 9)
            if !jumpCommitted, t >= 1 {
                jumpCommitted = true
                jumpCommit?()                          // app model: spend fuel, advance route, follow pilot, save
                reloadSystem(to: jumpDestSystemID, outboundHeading: jumpOutboundHeading,
                             arriveAtGate: jumpArriveGateID)
                enterJumpPhase(.arrive)
            }

        case .arrive:
            // New system is loaded and the ship is coasting in from the edge.
            // Fade the flash + streaks out to reveal it, then hand back control.
            let t = min(1, jumpClock / 0.35)
            jumpFlash?.alpha = CGFloat(1 - t) * (settings.reduceFlashing ? 0.45 : 1.0)
            jumpStreaks?.alpha = CGFloat((1 - t) * 0.6)
            if jumpClock > 0.35 {
                jumpFlash?.isHidden = true
                jumpFlash?.alpha = 0
                jumpStreaks?.isHidden = true
                jumpStreaks?.alpha = 0
                jumpPhase = .none
                jumpCommit = nil
            }
        }
        return intent
    }

    private func enterJumpPhase(_ phase: JumpPhase) {
        jumpPhase = phase
        jumpClock = 0
    }

    /// Show/scale the streak overlay: `intensity` (0…1) drives its opacity,
    /// `stretch` elongates the lines along the travel direction.
    private func showJumpStreaks(intensity: CGFloat, stretch: CGFloat) {
        guard let streaks = jumpStreaks else { return }
        streaks.isHidden = false
        streaks.alpha = intensity * 0.7
        streaks.yScale = stretch
    }

    /// Swap the simulated world to `systemID` *in place* — no scene/host
    /// teardown, so the presented `SKScene` and keyboard focus are untouched
    /// (rebuilding the host was the source of the "HUD says I've arrived but I
    /// still see the old system and can't move" bug). Rebuilds the world +
    /// stellar geometry, repositions the player at the hyperspace edge pointed
    /// inward and coasting fast (like an NPC jump-in), and clears every transient
    /// node from the old system.
    private func reloadSystem(to systemID: Int, outboundHeading: Double, arriveAtGate gateID: Int? = nil) {
        guard let galaxy else {
            Log.scene.error("reloadSystem(\(systemID)): no galaxy — cannot load the destination system")
            return
        }
        let game = galaxy.game
        let player = world.player
        // Fresh, populated world for the destination, reusing the player ship
        // (its fuel/damage/cargo carry over) and the same galaxy catalog.
        var tuning = CombatTuning.default; tuning.playerDamageScale = settings.difficulty.playerDamageScale
        let (w, gx) = GameSession.makeWorld(game: game, systemID: systemID, player: player, galaxy: galaxy, combatTuning: tuning,
                                            seed: currentWorldSeed(systemID: systemID))

        let ctx = w.systemContext
        var arrivalGate: StellarBody?
        if let gateID, let gate = ctx.bodies.first(where: { $0.id == gateID }) {
            // Gate arrival: emerge *out of* the destination gate along its emerge
            // heading (or facing away from the system centre), drifting clear —
            // not the fast tear-in of an ordinary hyperspace jump.
            arrivalGate = gate
            let ang = gate.gateEmergeAngle ?? (gate.position - ctx.center).angle
            let outward = Vec2(sin(ang), cos(ang))
            player.position = gate.position + outward * (gate.radius + player.radius + 25)
            player.angle = ang
            player.velocity = outward * min(player.stats.maxSpeed * 0.5, 160)
            player.entryOverspeed = 0
            player.entryOverspeedDecayPerSec = 0
        } else {
            // Enter from the edge on the side we *came from* — the origin system's
            // direction, which is opposite the outbound bearing we jumped along — then
            // fly inward, continuing that same direction of travel. (Placing us on the
            // outbound side instead made us pop in on the far edge, facing back the
            // way we came.) Pointed inward, tearing in and decelerating like an NPC.
            let travelDir = Vec2(sin(outboundHeading), cos(outboundHeading))   // A→B, the way we're heading
            player.position = ctx.center - travelDir * ctx.spawnRadius          // arrive on B's A-facing edge
            player.angle = (ctx.center - player.position).angle                 // face inward == the travel direction
            let entrySpeed = min(player.stats.maxSpeed * 2.4, 3200)
            player.velocity = Vec2(sin(player.angle), cos(player.angle)) * entrySpeed
            player.entryOverspeed = max(0, entrySpeed - player.stats.maxSpeed)
            player.entryOverspeedDecayPerSec = player.entryOverspeed / 1.3
        }
        player.currentTargetID = nil
        player.wantsToDepart = false

        self.world = w
        self.galaxy = gx
        self.systemID = systemID

        // Swap the stellar geometry + labels for the new system and drop every
        // transient node (NPCs/projectiles/beams/effects/labels/selection).
        self.planetVisuals = makePlanetVisuals(systemID: systemID, game: game)
        clearSystemNodes()
        // Mark the arrival gate open *before* building nodes so it glows as we
        // pop out of it (buildPlanets reads `openGateIDs`); the flourish closes
        // it again shortly after (unless it's a wormhole, which stays live).
        if let arrivalGate { openGateIDs.insert(arrivalGate.id) }
        buildPlanets()
        if let arrivalGate { playGateArrivalFlourish(arrivalGate.id) }

        // Recentre camera + ship node on the arrival point immediately (don't
        // wait a frame — the flash is covering this) and refresh the HUD name.
        let scenePos = CGPoint(x: player.position.x, y: player.position.y)
        shipNode.position = scenePos
        cameraNode.position = scenePos
        systemName = game.system(systemID)?.name ?? ""
        hud?.systemName = systemName
        audio?.play(.hyperspaceArrive)
        jumpArriveGateID = nil
        Log.scene.debug("reloadSystem: now in \(self.systemName) [\(systemID)], \(w.npcs.count) NPCs")
    }

    /// The destination gate opens with a bright ring as the player pops out, then
    /// (for a hypergate) closes again a moment later. A wormhole stays shimmering.
    private func playGateArrivalFlourish(_ gateID: Int) {
        guard let node = planetNodeByID[gateID] else { return }
        let radius = planetVisuals.first { $0.id == gateID }?.radius ?? 40
        let ring = SKShapeNode(circleOfRadius: max(20, radius) * 1.4)
        ring.strokeColor = SKColor(red: 0.65, green: 0.95, blue: 1.0, alpha: 1)
        ring.lineWidth = 4
        ring.glowWidth = 12
        ring.blendMode = .add
        ring.zPosition = 6
        ring.setScale(0.5)
        node.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 1.4, duration: 0.45), .fadeOut(withDuration: 0.55)]),
                            .removeFromParent()]))
        let isWormhole = planetVisuals.first { $0.id == gateID }?.isWormhole ?? false
        if !isWormhole {
            // Hypergate: closes behind you after the emerge.
            node.run(.sequence([.wait(forDuration: 1.5), .run { [weak self] in
                self?.openGateIDs.remove(gateID)
                self?.clearGateGlow(gateID)
            }]))
        }
    }

    /// Take off from stellar object `spobID`, reloading the *current* system in
    /// place — the takeoff twin of `reloadSystem`. Unlike a jump (same hull, same
    /// player object), a takeoff may follow a shipyard/outfitter visit, so it takes
    /// a freshly-built `player` (from the pilot loadout) and its `textures`,
    /// swapping the ship node's sprite too. Positions the ship just clear of the
    /// departed body, nosed outward and drifting gently out, and plays the launch
    /// (airlock) cue + grow-out-of-planet effect — NOT the hyperspace arrival cue.
    /// **No scene/host teardown** → the `SpriteView` keeps its identity (no
    /// re-present flash) and keyboard focus/input stay wired to this same scene.
    func reloadForDeparture(spobID: Int, player: Ship, textures: [SKTexture], engineTextures: [SKTexture],
                            shieldTextures: [SKTexture] = [],
                            lightTextures: [SKTexture] = [], weaponGlowTextures: [SKTexture] = [],
                            hullAnim: HullAnim = HullAnim()) {
        guard let galaxy else {
            Log.scene.error("reloadForDeparture(\(spobID)): no galaxy — cannot reload the system")
            return
        }
        let game = galaxy.game
        // Fresh, populated world for the current system, built around the newly
        // constructed player ship (its fuel/damage/cargo already seeded from the pilot).
        var tuning = CombatTuning.default; tuning.playerDamageScale = settings.difficulty.playerDamageScale
        let (w, gx) = GameSession.makeWorld(game: game, systemID: systemID, player: player, galaxy: galaxy, combatTuning: tuning,
                                            seed: currentWorldSeed(systemID: systemID))

        // Lift off from the departed body: sit just clear of its surface, nose
        // pointed away from the system centre, at rest — EV Nova doesn't give
        // you outbound momentum on takeoff, you fly away under your own thrust.
        let ctx = w.systemContext
        if let body = ctx.bodies.first(where: { $0.id == spobID }) {
            var outward = body.position - ctx.center
            if outward.length < 1 { outward = Vec2(0, -1) }
            let dir = outward.normalized
            player.position = body.position + dir * (body.radius + 60)
            player.angle = dir.angle
            player.velocity = Vec2()
        } else {
            // Departed body isn't a navigable stellar (shouldn't happen from the
            // landing screen) — fall back to the generic mid-system start point.
            player.position = ctx.center + Vec2(0, -700)
        }
        player.currentTargetID = nil
        player.wantsToDepart = false

        self.world = w
        self.galaxy = gx

        // Rebuild the player ship node from the (possibly new) hull sprite, then
        // swap the stellar geometry + drop every transient node from the old view.
        self.rotationTextures = textures
        self.engineGlowTextures = engineTextures
        self.shieldTextures = shieldTextures
        self.lightTextures = lightTextures
        self.weaponGlowTextures = weaponGlowTextures
        self.hullAnim = hullAnim
        self.lastPlayerShield = -1
        self.shieldFlare = 0
        self.weaponGlowFlare = 0
        self.animClock = 0
        self.blinkClock = 0
        self.lastPlayerAngle = .nan
        shipNode?.removeFromParent()
        buildShip()
        self.planetVisuals = makePlanetVisuals(systemID: systemID, game: game)
        clearSystemNodes()
        buildPlanets()

        // Snap camera + ship node onto the launch point. No takeoff sound —
        // leaving a planet is silent in the original (the old snd 390 "Airlock"
        // cue here was the odd "escape hatch" noise on launch).
        let scenePos = CGPoint(x: player.position.x, y: player.position.y)
        shipNode.position = scenePos
        cameraNode.position = scenePos
        applyEntrance(.launch, to: shipNode, at: scenePos, heading: player.angle)
        Log.scene.debug("reloadForDeparture: launched from spob \(spobID) in \(self.systemName) [\(self.systemID)], \(w.npcs.count) NPCs")
    }

    /// Build the render-side stellar visuals for a system from game data — the
    /// same construction `GameHost` does on a fresh build, so an in-place system
    /// reload gets identical planets without a host rebuild.
    private func makePlanetVisuals(systemID: Int, game: NovaGame) -> [PlanetVisual] {
        game.stellarObjects(in: systemID).map { entry in
            let tex = entry.sprite.flatMap { $0.frameCGImage(0) }.map { SKTexture(cgImage: $0) }
            let radius = CGFloat(entry.sprite?.frameWidth ?? 48) / 2
            return PlanetVisual(id: entry.spob.id, name: entry.spob.name,
                                position: CGPoint(x: entry.spob.x, y: entry.spob.y),
                                texture: tex, radius: radius,
                                government: entry.spob.government,
                                isUninhabited: entry.spob.isUninhabited,
                                isHypergate: entry.spob.isHypergate,
                                isWormhole: entry.spob.isWormhole)
        }
    }

    /// Remove every node tied to the *old* system before loading a new one:
    /// planets, NPC ships, projectiles, asteroids, beam loops, transient effects,
    /// AI-debug labels, and the current selection/target. The player ship node,
    /// starfield, camera, and jump overlays persist across the swap.
    private func clearSystemNodes() {
        for n in planetNodes { n.removeFromParent() }
        planetNodes.removeAll()
        planetNodeByID.removeAll()
        // Open-gate state is per-system: the old system's gate ids mean nothing
        // in the new one. The arrival gate (if any) is re-opened in `reloadSystem`.
        openGateIDs.removeAll()
        for (_, n) in npcNodes { n.container.removeFromParent() }
        npcNodes.removeAll()
        for n in projectileNodes { n.removeFromParent() }
        projectileNodes.removeAll()
        for (_, n) in asteroidNodes { n.container.removeFromParent() }
        asteroidNodes.removeAll()
        for (key, _) in activeBeamLoops { audio?.stopLoop(key: key) }
        activeBeamLoops.removeAll()
        // Beam + flash sprites live on effectsLayer, cleared just below; drop our
        // handles so the pools rebuild for the new system.
        effectsLayer.removeAllChildren()
        beamNodes.removeAll()
        activeFlashes.removeAll()
        flashPool.removeAll()
        for (_, n) in aiLabelNodes { n.removeFromParent() }
        aiLabelNodes.removeAll()
        pendingEntrance.removeAll()
        selectedPlanetID = nil
        shipBracket.isHidden = true
        planetBracket.isHidden = true
    }

    /// Drop the decoded-texture caches that are deliberately *kept across systems*
    /// (NPC hulls, engine glows, shields, asteroids, weapon shots) so the next
    /// system builds fast. Ordinary jumps keep these warm on purpose — this is for
    /// memory-pressure response only, driven from `GameHost`. Each rebuilds
    /// lazily from the sprite pool / disk cache on next use, so the only cost is a
    /// one-time re-decode after the flush.
    func evictTextureCaches() {
        npcTextureCache.removeAll()
        npcEngineGlowCache.removeAll()
        npcShieldCache.removeAll()
        asteroidTextureCache.removeAll()
        weaponGraphicCache.removeAll()
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
        n.engineGlow?.isHidden = true
        n.healthBar?.isHidden = true
        // Reparenting requires no existing parent; npcLayer and effectsLayer share
        // the scene's coordinate space so the world position carries over.
        n.container.removeFromParent()
        return n.container
    }

    private func updateNPCThruster(_ n: NPCNode, npc: Ship) {
        // We don't see the NPC's intent, so infer "thrusting" from moving forward
        // near its own heading at a decent clip.
        let heading = (sin(npc.angle), cos(npc.angle))
        let forward = npc.velocity.x * heading.0 + npc.velocity.y * heading.1
        let active = npc.velocity.length > npc.stats.maxSpeed * 0.25 && forward > 0

        // Real per-hull engine-glow art replaces the synthetic flame entirely.
        if let glow = n.engineGlow {
            glow.isHidden = !active
            if active {
                let target: CGFloat = .random(in: 0.55...0.8)
                n.thrusterAlpha = n.thrusterAlpha * 0.85 + target * 0.15
                glow.alpha = n.thrusterAlpha
            }
            n.thruster?.isHidden = true
            return
        }
        guard let thruster = n.thruster else { return }
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
        // Hidden when the player turned bars off, otherwise shown only when hurt.
        holder.isHidden = settings.shipBarPosition == .off || frac >= 0.999
        fill.xScale = CGFloat(max(0.001, frac))
        // Green when healthy, through amber, to red when critical.
        fill.color = SKColor(red: CGFloat(1 - frac) * 0.9 + 0.1,
                             green: CGFloat(frac) * 0.9,
                             blue: 0.25, alpha: 1)
    }

    /// Y offset for a ship's hull/shield bar, per the player's chosen position.
    /// `off` is positioned like `above` but kept hidden (bars never un-hide when off).
    private func barOffsetY(radius: CGFloat) -> CGFloat {
        switch settings.shipBarPosition {
        case .above, .off: return radius + 8
        case .below:       return -(radius + 8)
        }
    }

    /// Re-apply the display settings that affect already-built nodes — planet name
    /// labels and hull/shield bar position/visibility — so toggling them from
    /// Settings updates the live scene without waiting for a system rebuild.
    func applyDisplaySettings(_ newSettings: GameSettings) {
        let filterChanged = newSettings.smoothSprites != settings.smoothSprites
        settings = newSettings
        controllerInput?.deadzone = Float(settings.stickDeadzone)   // live "Stick dead zone"
        Haptics.enabled = settings.hapticsEnabled
        applyColorblindFilter()
        #if os(macOS)
        if !settings.mouseAiming { input?.mouse.desiredHeading = nil }   // clear stale mouse-aim
        #endif
        #if os(iOS)
        updateTiltActive()
        #endif
        for node in planetNodes {
            node.childNode(withName: "planetLabel")?.isHidden = !settings.showPlanetLabels
        }
        for (_, n) in npcNodes {
            guard let holder = n.healthBar else { continue }
            holder.position = CGPoint(x: 0, y: barOffsetY(radius: n.radius))
            if settings.shipBarPosition == .off {
                holder.isHidden = true
            } else {
                n.lastArmor = -1   // force updateNPCHealth to re-evaluate visibility
            }
        }
        // Smooth-scaling toggled: re-flip every live sprite's texture filtering so
        // it applies without waiting for a system rebuild. (engineGlow / screenShake
        // / reduceFlashing are read live each frame, so they need no node pass.)
        if filterChanged { applySpriteFiltering(to: self) }
    }

    /// Apply the colorblind assist to the whole scene. `SKScene` is an
    /// `SKEffectNode`, so a `CIColorMatrix` on `filter` transforms the entire
    /// rendered frame. Each mode nudges the axis the deficiency confuses onto a
    /// channel the viewer still sees (red↔green difference into blue for
    /// prot/deuteranopia; blue↔red difference into green for tritanopia), so the
    /// game's colour-coded ships/blips/bars stay distinguishable. Off = no filter
    /// (and no offscreen render cost).
    #if os(iOS)
    /// Start/stop device-motion updates so tilt steering only runs while the
    /// "Tilt to Turn" scheme is selected.
    private func updateTiltActive() {
        if settings.controlScheme == .tilt { tiltInput?.start() }
        else { tiltInput?.stop() }
    }
    #endif

    private func applyColorblindFilter() {
        guard settings.colorblindMode != .none else {
            shouldEnableEffects = false
            filter = nil
            return
        }
        let f = CIFilter(name: "CIColorMatrix")
        let k: CGFloat = 0.5
        switch settings.colorblindMode {
        case .protanopia, .deuteranopia:
            f?.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
            f?.setValue(CIVector(x: k, y: -k, z: 1, w: 0), forKey: "inputBVector")
        case .tritanopia:
            f?.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x: -k, y: 1, z: k, w: 0), forKey: "inputGVector")
            f?.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        case .none:
            break
        }
        f?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter = f
        shouldEnableEffects = true
    }

    /// Recursively set every sprite's texture filtering to the current mode.
    private func applySpriteFiltering(to node: SKNode) {
        (node as? SKSpriteNode)?.texture?.filteringMode = spriteFilter
        for child in node.children { applySpriteFiltering(to: child) }
    }

    // MARK: Hyperspace no-jump zone

    /// EV Nova's "no-jump zone": you can't enter hyperspace within this radius of
    /// the system centre (Bible: the standard radius is 1000px, adjustable by the
    /// "hyperspace dist mod" outfit #23). Fixed at the stock 1000 for now.
    var hyperspaceNoJumpRadius: Double = 1000

    /// True when the player is clear of the no-jump zone and may jump. Too close,
    /// it posts the original's "fly further out" nudge and returns false so the
    /// caller refuses the jump.
    func canEnterHyperspace() -> Bool {
        guard let w = world else { return true }
        // The no-jump zone exists to stop you jumping while parked over a
        // system's populated core (its planets/stations cluster at the centre).
        // An empty system — or one with only uninhabited rocks — has nothing to
        // fly clear of, so the restriction shouldn't apply there; you can jump
        // from anywhere. `canLand` is true only for landable, inhabited bodies.
        guard w.systemContext.bodies.contains(where: { $0.canLand }) else { return true }
        let dist = (w.player.position - w.systemContext.center).length
        if dist < hyperspaceNoJumpRadius {
            hud?.post("You are too close to the system's center to enter hyperspace.")
            return false
        }
        return true
    }

    /// The rotation textures for a `röid` type, decoded once and cached (a
    /// system typically reuses only a handful of the 16 real asteroid types).
    private func asteroidTextures(for roidTypeID: Int) -> [SKTexture] {
        if let cached = asteroidTextureCache[roidTypeID] { return cached }
        var textures: [SKTexture] = []
        if let sheet = galaxy?.game.asteroidSprite(roidTypeID) {
            textures = SpriteTextures.rotationFrames(from: sheet)
        }
        asteroidTextureCache[roidTypeID] = textures
        return textures
    }

    /// The rotation textures for a hull id, decoded from the player's data once
    /// and cached (many NPCs share a hull).
    private func npcTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcTextureCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        // Full multi-set sheet (banking/animation sets, all headings), not just
        // the first rotation set — the render selects the live set/heading.
        if shipTypeID >= 128, let sheet = galaxy?.game.shipSprite(shipTypeID) {
            textures = SpriteTextures.allFrames(from: sheet)
        }
        npcTextureCache[shipTypeID] = textures
        return textures
    }

    /// That hull's own authored engine-glow overlay, if it has one — same
    /// per-hull-art principle as `npcTextures`, cached the same way.
    private func npcEngineGlowTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcEngineGlowCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        if shipTypeID >= 128, let sheet = galaxy?.game.engineGlowSprite(shipTypeID) {
            textures = SpriteTextures.allFrames(from: sheet)
        }
        npcEngineGlowCache[shipTypeID] = textures
        return textures
    }

    /// That hull's running-lights overlay, if any — full multi-set sheet, cached.
    private func npcLightTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcLightCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        if shipTypeID >= 128, let sheet = galaxy?.game.lightSprite(shipTypeID) {
            textures = SpriteTextures.allFrames(from: sheet)
        }
        npcLightCache[shipTypeID] = textures
        return textures
    }

    /// That hull's weapon-glow overlay, if any — full multi-set sheet, cached.
    private func npcWeaponGlowTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcWeaponGlowCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        if shipTypeID >= 128, let sheet = galaxy?.game.weaponGlowSprite(shipTypeID) {
            textures = SpriteTextures.allFrames(from: sheet)
        }
        npcWeaponGlowCache[shipTypeID] = textures
        return textures
    }

    /// That hull's shield-bubble overlay, if a "Shields" plug-in supplied one —
    /// same per-hull-art principle as `npcTextures`, cached the same way. Empty
    /// for stock data (base hulls leave the shän shield layer unset).
    private func npcShieldTextures(for shipTypeID: Int) -> [SKTexture] {
        if let cached = npcShieldCache[shipTypeID] { return cached }
        var textures: [SKTexture] = []
        if shipTypeID >= 128, let sheet = galaxy?.game.shieldSprite(shipTypeID) {
            textures = SpriteTextures.rotationFrames(from: sheet)
        }
        npcShieldCache[shipTypeID] = textures
        return textures
    }

    /// This ship's relationship to the player: hostile / neutral / friendly-or-
    /// owned / disabled. Drives both the minimap dot color and the placeholder
    /// hull tint, so the two stay consistent.
    /// Whether an NPC should read as an *enemy* to the player right now. This is
    /// broader than formal government disposition (`isHostileToPlayer`): a ship
    /// that is actively fighting the player, or has been provoked into hostility,
    /// counts as an enemy even when the player's legal standing with its
    /// government is still neutral — so anything shooting at you reads red rather
    /// than staying a confusing neutral blip.
    private func isEffectivelyHostileToPlayer(_ npc: Ship) -> Bool {
        if isEntityAttackingPlayer(npc.entityID) { return true }
        if npc.brain?.provokedByPlayer == true { return true }
        return world.diplomacy?.isHostileToPlayer(npc.government) == true
    }

    private func relationship(for npc: Ship) -> RadarRelationship {
        if npc.disabled { return .disabled }
        // Your own escorts always read as friendly (green), whatever their base
        // government or the current diplomacy — a ship flying in your wing is
        // yours. Checked before hostility so a mercenary of an otherwise-hostile
        // government still shows green while it's escorting you.
        if npc.brain?.leaderID == World.playerEntityID { return .friendlyOrOwned }
        if isEffectivelyHostileToPlayer(npc) { return .hostile }
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

    // MARK: Selection brackets

    /// Four disconnected L-shaped corner marks around a `size`-wide square —
    /// the classic viewfinder/targeting-bracket look.
    private func bracketPath(size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let half = size / 2
        let arm = max(4, size * 0.22)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-half, half, 1, -1), (half, half, -1, -1),
            (-half, -half, 1, 1), (half, -half, -1, 1),
        ]
        for (x, y, dx, dy) in corners {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + arm * dx, y: y))
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + arm * dy))
        }
        return path
    }

    /// A gentle "locked on" pulse, restarted only when a bracket first
    /// attaches to a new target (not every frame).
    private func restartPulse(_ node: SKShapeNode) {
        node.removeAllActions()
        node.setScale(1.0)
        let pulse = SKAction.sequence([.scale(to: 1.08, duration: 0.55), .scale(to: 1.0, duration: 0.55)])
        pulse.timingMode = .easeInEaseOut
        node.run(.repeatForever(pulse))
    }

    /// Track the current ship target + planet nav-selection every frame:
    /// position, color (relationship for ships; landable blue / not-landable
    /// red for planets, matching the manual), and a lock-on pulse that only
    /// restarts when the locked id actually changes.
    private func updateSelectionBrackets() {
        if let tid = world.player.currentTargetID, let ship = world.ship(id: tid) {
            let radius = npcNodes[tid]?.radius ?? CGFloat(ship.radius)
            shipBracket.position = CGPoint(x: ship.position.x, y: ship.position.y)
            shipBracket.isHidden = false
            shipBracket.strokeColor = factionColor(for: ship)
            if lockedShipBracketID != tid {
                lockedShipBracketID = tid
                shipBracket.path = bracketPath(size: radius * 2 + 14)
                restartPulse(shipBracket)
            }
        } else if lockedShipBracketID != nil {
            lockedShipBracketID = nil
            shipBracket.isHidden = true
            shipBracket.removeAllActions()
        }

        if let pid = selectedPlanetID, let pv = planetVisuals.first(where: { $0.id == pid }) {
            let landable = world.systemContext.bodies.first { $0.id == pid }?.canLand ?? false
            planetBracket.position = pv.position
            planetBracket.isHidden = false
            planetBracket.strokeColor = landable ? SKColor(red: 0.35, green: 0.6, blue: 1.0, alpha: 1)
                                                  : SKColor(red: 0.95, green: 0.3, blue: 0.25, alpha: 1)
            if lockedPlanetBracketID != pid {
                lockedPlanetBracketID = pid
                planetBracket.path = bracketPath(size: pv.radius * 2 + 18)
                restartPulse(planetBracket)
            }
        } else if lockedPlanetBracketID != nil {
            lockedPlanetBracketID = nil
            planetBracket.isHidden = true
            planetBracket.removeAllActions()
        }
    }

    // MARK: Combat effects

    /// Reposition every active beam loop against the shooter's current
    /// position each frame (positional volume/pan), and clean up any whose
    /// shooter no longer resolves — a defensive fallback for the normal case
    /// of the world sending an explicit `.beamLoopStop`.
    private func updateBeamLoopPositions(listener: CGPoint) {
        guard !activeBeamLoops.isEmpty else { return }
        for (key, loop) in activeBeamLoops {
            guard let shooter = world.ship(id: loop.shooterID) else {
                activeBeamLoops.removeValue(forKey: key)
                audio?.stopLoop(key: key)
                continue
            }
            audio?.startOrUpdateLoop(key: key, soundID: loop.soundID,
                                     at: CGPoint(x: shooter.position.x, y: shooter.position.y),
                                     listener: listener)
        }
    }

    /// An expanding, fading flash for an explosion.
    private func spawnExplosion(at point: CGPoint, radius: CGFloat) {
        spawnFlash(at: point, startRadius: max(10, radius * 0.6), endRadius: max(10, radius * 0.6) * 2.2,
                   color: SKColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1), duration: 0.35)
    }

    /// The player's death spectacle: a run of staggered explosion bursts scattered
    /// across the (now frozen — the engine stops the dead player in place) wreck,
    /// each with a bang and a shake, growing to a final big blast that hides the
    /// hull — the classic "slowly explode a bunch, then it's gone" before the host
    /// returns to the main menu. Runs on the scene's action clock so it plays out
    /// during the pre-menu delay; latched so it only fires once.
    func beginPlayerDeathSequence() {
        guard !playerDeathSequenceStarted else { return }
        playerDeathSequenceStarted = true
        audio?.stopAllLoops()

        let bursts = 9
        let step = 0.2
        for i in 0..<bursts {
            run(.sequence([
                .wait(forDuration: Double(i) * step),
                .run { [weak self] in
                    guard let self, let p = self.playerShip?.position else { return }
                    let at = CGPoint(x: CGFloat(p.x) + .random(in: -22...22),
                                     y: CGFloat(p.y) + .random(in: -22...22))
                    self.spawnExplosion(at: at, radius: 32 + CGFloat(i) * 4)
                    self.audio?.play(303, at: at, listener: at)
                    self.addShake(at: at, radius: 60)
                }
            ]))
        }
        // Final blast, then the wreck is gone.
        run(.sequence([
            .wait(forDuration: Double(bursts) * step),
            .run { [weak self] in
                guard let self else { return }
                if let p = self.playerShip?.position {
                    let at = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                    self.spawnExplosion(at: at, radius: 96)
                    self.audio?.play(303, at: at, listener: at)
                    self.addShake(at: at, radius: 110)
                }
                self.shipNode?.isHidden = true
            }
        ]))
    }

    /// Spawn a pooled, additive expanding flash animated in `updateFlashes` — no
    /// per-event `SKShapeNode` allocation or `SKAction` scheduling (both were
    /// real churn during a fight full of explosions and point-defense hits).
    private func spawnFlash(at point: CGPoint, startRadius: CGFloat, endRadius: CGFloat,
                            color: SKColor, duration: Double) {
        let node = flashPool.popLast() ?? {
            let n = SKSpriteNode(texture: projectileTexture)
            n.blendMode = .add
            n.zPosition = 13
            n.colorBlendFactor = 1
            effectsLayer.addChild(n)
            return n
        }()
        node.color = color
        node.position = point
        node.isHidden = false
        node.alpha = 1
        activeFlashes.append(Flash(node: node, age: 0, duration: duration,
                                   startDiameter: startRadius * 2, endDiameter: endRadius * 2))
    }

    /// Advance pooled flashes: grow + fade, then return finished nodes to the pool.
    private func updateFlashes(_ dt: Double) {
        guard !activeFlashes.isEmpty else { return }
        var i = 0
        while i < activeFlashes.count {
            activeFlashes[i].age += dt
            let f = activeFlashes[i]
            let t = min(1, f.age / f.duration)
            if t >= 1 {
                f.node.isHidden = true
                flashPool.append(f.node)
                activeFlashes.remove(at: i)
                continue
            }
            let d = f.startDiameter + (f.endDiameter - f.startDiameter) * CGFloat(t)
            f.node.size = CGSize(width: d, height: d)
            f.node.alpha = CGFloat(1 - t)
            i += 1
        }
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
        hud.ionization = p.ionizeMax > 0 ? min(1, p.ionCharge / p.ionizeMax) : 0
        hud.ionized = p.isIonized
        updateWarnings(shieldFraction: hud.shield, armorFraction: hud.armor)
        updateTargetHUD(p.currentTargetID.flatMap { world.ship(id: $0) })
        updateNavTargetHUD()
        hud.cargoUsed = p.cargoUsed
        hud.cargoCapacity = p.cargoCapacity
        // The weapon readout tracks the selected *secondary* (what the secondary
        // trigger / weapon-switch control fires), matching EV Nova's status bar;
        // falls back to the first weapon so a guns-only ship still shows one.
        if let mount = p.effectiveSecondaryMount ?? p.weapons.first {
            hud.weaponName = mount.spec.name.novaDisplayName
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
        // Both stellars and ships drop off the scope once they pass the radar
        // range — contacts scroll out of view rather than piling on the rim
        // (planets used to clamp to the edge and stick there).
        hud.planetBlips = planetVisuals.compactMap { pv in
            let dx = (Double(pv.position.x) - shipPos.x) / Double(radarRange)
            let dy = -(Double(pv.position.y) - shipPos.y) / Double(radarRange)
            guard dx * dx + dy * dy <= 1 else { return nil }
            return RadarContact(x: dx, y: dy, relationship: relationship(forPlanet: pv))
        }
        // A cloaked ship drops off the player's radar entirely unless its own
        // device flags it "visible on radar" regardless (oütf ModType 17
        // 0x0002) or the player carries a cloak scanner that reveals cloaked
        // ships on radar (ModType 30 0x0001).
        let radarRevealsCloaked = p.cloakScannerFlags & 0x0001 != 0
        // System sensor static (sÿst.Interference) shrinks the ship radar's
        // effective reach exactly as it shrinks AI perception — contacts that
        // would show at the fixed range drop off sooner as static thickens.
        // Stellars aren't gated by this: they're visible landmarks, not active
        // sensor contacts.
        let shipRadarRange = max(1, world.effectiveSensorRange(Double(radarRange), for: p))
        hud.blips = world.npcs.compactMap { npc in
            if npc.isEffectivelyCloaked, !npc.cloakVisibleOnRadar, !radarRevealsCloaked { return nil }
            let dx = (npc.position.x - shipPos.x) / shipRadarRange
            let dy = -(npc.position.y - shipPos.y) / shipRadarRange
            guard dx * dx + dy * dy <= 1 else { return nil }
            // IFF gates allegiance coloring (EV Nova oütf ModType 14): with an IFF
            // outfit, blips tint red/green/grey by relationship; without one, every
            // ship contact is drawn in the single neutral radar color, so friend and
            // foe are indistinguishable — you have to lock a target to identify it.
            let rel = playerHasIFF ? relationship(for: npc) : .neutral
            return RadarContact(x: dx, y: dy, relationship: rel)
        }
    }

    // MARK: - Debug suite: performance instrumentation

    /// Accumulate this frame's timing and, roughly twice a second, flush a
    /// windowed sample (fps, average and worst frame ms, live entity/node
    /// counts) up to the `DebugController`. Deliberately throttled: pushing
    /// `@Published` metrics at the full frame rate would have SwiftUI re-lay-out
    /// the debug overlay 60×/sec, itself a measurable cost that would pollute
    /// the very numbers we're trying to read.
    private func samplePerformance(rawFrame: TimeInterval, dt: TimeInterval) {
        if rawFrame > 0 {
            perfRawAccum += rawFrame
            perfWorstFrame = max(perfWorstFrame, rawFrame)
            perfFrames += 1
        }
        perfReportClock += dt
        guard perfReportClock >= 0.5, perfFrames > 0 else { return }

        let avg = perfRawAccum / Double(perfFrames)
        let fps = avg > 0 ? 1.0 / avg : 0
        let nodes = totalNodeCount()
        debug?.report(fps: fps, frameMsAvg: avg * 1000, frameMsMax: perfWorstFrame * 1000,
                      ships: world.npcs.count, projectiles: world.projectiles.count,
                      asteroids: world.asteroids.count, nodes: nodes)

        perfReportClock = 0
        perfRawAccum = 0
        perfWorstFrame = 0
        perfFrames = 0
    }

    /// Total live SpriteKit node count in the scene graph (recursive) — the
    /// render-side population that grows with ships, projectiles, and effects.
    /// Walked only on the throttled report tick, so the O(n) traversal is a
    /// twice-a-second cost, not a per-frame one.
    private func totalNodeCount() -> Int {
        func count(_ node: SKNode) -> Int {
            node.children.reduce(1) { $0 + count($1) }
        }
        return count(self)
    }

    // MARK: - Debug suite: performance stress test

    /// Flood the current system with `shipCount` mutually-hostile combatants
    /// and let them fight — the port's built-in worst case for measuring and
    /// fixing frame-rate problems. Clears any existing traffic and suspends the
    /// ambient spawner first so the population is exactly what we asked for, then
    /// scatters two enemy teams into one overlapping cloud around the system
    /// centre so combat erupts immediately (everyone starts inside AI scan
    /// range of an enemy).
    func startPerformanceTest(shipCount: Int) {
        guard let galaxy, world != nil else {
            Log.scene.error("startPerformanceTest: no galaxy/world (game data not loaded) — nothing to spawn")
            return
        }
        // Exactly the requested population: stop ambient arrivals and wipe the
        // field, then build the fleet ourselves.
        world.spawner = nil
        world.removeAllNPCs()

        let (govtA, govtB) = pickBattleGovernments()
        let hulls = pickCombatHulls(galaxy: galaxy)
        guard !hulls.isEmpty else {
            Log.scene.error("startPerformanceTest: no ship hulls resolvable in the data — cannot spawn a fleet")
            return
        }

        let center = world.systemContext.center
        // A cloud wide enough to hold the fleet without everyone stacking on one
        // point, but tight enough that both teams are within scan range on
        // frame one. Scales gently with the requested count.
        let cloudRadius = max(700.0, 90.0 * Double(shipCount).squareRoot())
        for i in 0..<max(0, shipCount) {
            let team = i % 2 == 0 ? govtA : govtB
            let hull = hulls[i % hulls.count]
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let dist = world.rng.double(in: 0...cloudRadius)
            let pos = center + Vec2(sin(bearing), cos(bearing)) * dist
            let ang = world.rng.double(in: 0...(2 * .pi))
            guard let ship = galaxy.makeLoadedShip(hull, government: team, at: pos, angle: ang,
                                                   skillRoll: world.rng.double(in: -1...1)) else { continue }
            ship.brain = AIBrain(aiType: .warship, govt: team)
            world.addNPC(ship, arrival: .populate)
        }
        Log.scene.debug("startPerformanceTest: spawned \(shipCount) combatants (govts \(govtA) vs \(govtB), \(hulls.count) hull types)")
    }

    /// Tear down the stress-test fleet and restore the system's normal ambient
    /// traffic (rebuild the spawner and let it re-populate).
    func stopPerformanceTest() {
        guard let galaxy, world != nil else { return }
        world.removeAllNPCs()
        if let sys = galaxy.game.system(systemID) {
            let spawner = Spawner(galaxy: galaxy, table: SpawnTable(system: sys))
            world.spawner = spawner
            spawner.populate(world)
        }
        Log.scene.debug("stopPerformanceTest: fleet cleared, ambient spawner restored")
    }

    /// Two mutually-hostile governments to pit against each other. Prefers a
    /// real enemy pair from the loaded diplomacy table (so the AI genuinely
    /// wants to fight); falls back to any two distinct governments, and finally
    /// to independents (which won't auto-engage, but still exercises the
    /// render/physics path under load).
    private func pickBattleGovernments() -> (Int, Int) {
        guard let dip = world.diplomacy else { return (independentGovt, independentGovt) }
        let ids = Array(dip.govts.keys)
        for a in ids {
            for b in ids where b != a && dip.areEnemies(a, b) {
                return (a, b)
            }
        }
        if ids.count >= 2 { return (ids[0], ids[1]) }
        return (ids.first ?? independentGovt, independentGovt)
    }

    /// A varied set of *armed* hulls to spawn (up to a cap, so the test exercises
    /// several sprite sheets without unbounded texture memory). Falls back to
    /// every hull if none report weapon mounts.
    private func pickCombatHulls(galaxy: Galaxy) -> [Int] {
        let cap = 16
        let allIDs = galaxy.game.ships().map { $0.id }
        let armed = allIDs.filter { (galaxy.shipSpec($0)?.mounts.isEmpty == false) }
        let chosen = armed.isEmpty ? allIDs : armed
        return Array(chosen.prefix(cap))
    }

    // MARK: - Debug suite: live game-state actions

    /// Spawn `count` armed ships right on top of the player, each provoked and
    /// locked onto the player so they attack immediately — the debug suite's
    /// "spawn enemies" button. Unlike the stress test this keeps the ambient
    /// spawner running and adds to the existing population rather than wiping
    /// it. Returns how many actually spawned.
    @discardableResult
    func debugSpawnHostiles(count: Int) -> Int {
        guard let galaxy, world != nil else {
            Log.scene.error("debugSpawnHostiles: no galaxy/world (game data not loaded)")
            return 0
        }
        let hulls = pickCombatHulls(galaxy: galaxy)
        guard !hulls.isEmpty else { return 0 }
        let player = world.player
        var spawned = 0
        for i in 0..<max(0, count) {
            let hull = hulls[i % hulls.count]
            // Ring the player at close-but-not-touching range so they arrive in
            // combat instantly without overlapping the hull.
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let dist = world.rng.double(in: 400...900)
            let pos = player.position + Vec2(sin(bearing), cos(bearing)) * dist
            // Face the player.
            let ang = (player.position - pos).angle
            guard let ship = galaxy.makeLoadedShip(hull, at: pos, angle: ang,
                                                   skillRoll: world.rng.double(in: -1...1)) else { continue }
            let brain = AIBrain(aiType: .interceptor, govt: ship.government)
            brain.provokedByPlayer = true          // hostile to the player regardless of diplomacy
            brain.targetID = player.entityID
            ship.brain = brain
            world.addNPC(ship, arrival: .hyperspace)
            spawned += 1
        }
        Log.scene.debug("debugSpawnHostiles: spawned \(spawned) attackers on the player")
        return spawned
    }

    /// Directly set the player's live standing with a government so the change
    /// takes effect in this session immediately (ships turn hostile/neutral on
    /// the spot). The persisted `legalRecord` is updated separately by the
    /// caller so the change also survives a save.
    func debugSetLiveRelation(govt: Int, record: Int) {
        world.diplomacy?.setPlayerRecord(govt, to: record)
    }

    // MARK: - Debug suite: live cheats

    /// Hold the debug suite's continuous cheats against the world each frame.
    /// God mode marks the player ship invulnerable (the world's damage handler
    /// then swallows every hit); infinite fuel pins the tank full so afterburner
    /// and jumps never run it down. Both clear cleanly when their switch is off.
    private func applyDebugCheats(to player: Ship) {
        guard let debug else { return }
        // Only write when the value actually needs to change — cheap, and avoids
        // fighting the ship's own state when the cheat is off.
        if player.invulnerable != debug.godMode { player.invulnerable = debug.godMode }
        if debug.godMode {
            // Keep the health bars pinned up too, so god mode reads as god mode
            // even against pre-existing damage or ion drain.
            player.shield = player.maxShield
            player.armor = player.maxArmor
            player.ionCharge = 0
        }
        if debug.infiniteFuel, player.maxFuel > 0 {
            player.fuel = player.maxFuel
        }
    }

    // MARK: - Debug suite: fleet & escorts

    /// Spawn `count` friendly ships of the given hull already recruited into the
    /// player's escort wing (flying formation, defending the player). Returns how
    /// many actually spawned. Hull `nil` picks varied combat hulls like the
    /// stress test does.
    @discardableResult
    func debugSpawnEscorts(count: Int, hull: Int? = nil) -> Int {
        guard let galaxy, world != nil else {
            Log.scene.error("debugSpawnEscorts: no galaxy/world (game data not loaded)")
            return 0
        }
        let hulls = hull.map { [$0] } ?? pickCombatHulls(galaxy: galaxy)
        guard !hulls.isEmpty else { return 0 }
        let player = world.player
        var spawned = 0
        for i in 0..<max(0, count) {
            let h = hulls[i % hulls.count]
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let dist = world.rng.double(in: 300...600)
            let pos = player.position + Vec2(sin(bearing), cos(bearing)) * dist
            guard let ship = galaxy.makeLoadedShip(h, government: player.government,
                                                   at: pos, angle: player.angle,
                                                   skillRoll: world.rng.double(in: 0...1)) else { continue }
            world.addNPC(ship, arrival: .hyperspace)
            world.recruitEscort(ship)      // wire the AI into the player's wing
            spawned += 1
        }
        Log.scene.debug("debugSpawnEscorts: recruited \(spawned) escorts (hull \(hull.map(String.init) ?? "varied"))")
        return spawned
    }

    /// Spawn a single ship of `hull` near the player with a chosen disposition:
    /// `.hostile` (provoked, locked on), `.escort` (recruited into the wing), or
    /// `.neutral` (ambient traffic of its own government). Returns whether it
    /// spawned.
    enum DebugDisposition { case hostile, escort, neutral }
    @discardableResult
    func debugSpawnShip(hull: Int, govt: Int? = nil, as disposition: DebugDisposition) -> Bool {
        guard let galaxy, world != nil else { return false }
        let player = world.player
        let bearing = world.rng.double(in: 0...(2 * .pi))
        let dist = world.rng.double(in: 400...800)
        let pos = player.position + Vec2(sin(bearing), cos(bearing)) * dist
        let ang = (player.position - pos).angle
        let team = disposition == .escort ? player.government : govt
        guard let ship = galaxy.makeLoadedShip(hull, government: team, at: pos, angle: ang,
                                               skillRoll: world.rng.double(in: -1...1)) else { return false }
        switch disposition {
        case .hostile:
            let brain = AIBrain(aiType: .interceptor, govt: ship.government)
            brain.provokedByPlayer = true
            brain.targetID = player.entityID
            ship.brain = brain
            world.addNPC(ship, arrival: .hyperspace)
        case .escort:
            world.addNPC(ship, arrival: .hyperspace)
            world.recruitEscort(ship)
        case .neutral:
            ship.brain = AIBrain(aiType: .braveTrader, govt: ship.government)
            world.addNPC(ship, arrival: .hyperspace)
        }
        return true
    }

    /// Knock every hostile NPC down to a drifting, boardable hulk (shields gone,
    /// armor to a sliver so the world's damage handler disables rather than
    /// destroys it). Returns how many were affected.
    @discardableResult
    func debugDisableAllHostiles() -> Int {
        guard world != nil else { return 0 }
        var n = 0
        for s in world.npcs where s.isAlive && !s.disabled && isHostileToPlayer(s) {
            s.shield = 0
            s.armor = max(1, s.maxArmor * 0.05)
            s.disabled = true
            n += 1
        }
        Log.scene.debug("debugDisableAllHostiles: disabled \(n) ships")
        return n
    }

    /// Destroy every hostile NPC outright (a battlefield wipe). Returns the count
    /// removed. Uses the normal death path so wrecks/explosions still play.
    @discardableResult
    func debugDestroyAllHostiles() -> Int {
        guard world != nil else { return 0 }
        var n = 0
        for s in world.npcs where s.isAlive && isHostileToPlayer(s) {
            s.shield = 0
            s.armor = 0                 // next despawn sweep clears it as a kill
            n += 1
        }
        Log.scene.debug("debugDestroyAllHostiles: killed \(n) ships")
        return n
    }

    /// Remove every NPC from the system immediately (traffic, hostiles, escorts).
    /// Returns how many were cleared. Leaves the ambient spawner running so the
    /// system slowly re-populates.
    @discardableResult
    func debugClearAllNPCs() -> Int {
        guard world != nil else { return 0 }
        let n = world.npcs.count
        world.removeAllNPCs()
        return n
    }

    /// Whether an NPC currently counts as hostile to the player — provoked, or an
    /// enemy of the player by the live diplomacy table.
    private func isHostileToPlayer(_ s: Ship) -> Bool {
        if s.brain?.provokedByPlayer == true { return true }
        return world.diplomacy?.areEnemies(s.government, world.player.government) ?? false
    }

    /// Live counts for the debug suite's fleet read-out.
    var liveHostileCount: Int {
        guard world != nil else { return 0 }
        return world.npcs.filter { $0.isAlive && isHostileToPlayer($0) }.count
    }
    var liveEscortCount: Int { world?.playerEscorts.count ?? 0 }

    /// The live world's per-government legal record right now — read at
    /// natural save points (landing, jump-out) to persist into
    /// `PlayerState.legalRecord`, since a fresh `Diplomacy` (and thus a fresh
    /// in-memory record) is built on every jump. See `GameHost.init`'s seeding
    /// call for the inbound half of this bridge.
    var liveLegalRecord: [Int: Int] { world.diplomacy?.playerRecord ?? [:] }

    /// Combat rating earned since the last call, draining the live tally back
    /// to 0 — fold the result into `PlayerState.combatRating`. Safe to call
    /// from multiple sync points; each call only returns what's accrued since
    /// the previous one.
    func consumeCombatRatingDelta() -> Int {
        world.diplomacy?.consumeCombatRatingDelta() ?? 0
    }

    // MARK: - Debug suite: AI overlay

    /// Draw every NPC's live AI "thoughts" over the flight scene when the debug
    /// suite has it on: a state label above each ship, a red line to its combat
    /// target, a cyan line to its navigation goal (the point it's steering
    /// toward — its current path), and a green line from an escort to its
    /// fleet leader. Pure visualization; reads brain state, never mutates it.
    ///
    /// Lines are three combined `CGPath`s (one node each, rebuilt per frame) so
    /// the whole overlay is a handful of nodes regardless of ship count; only
    /// the per-ship labels are pooled by entity id.
    private func updateAIDebug() {
        guard debug?.aiDebugEnabled == true else {
            if aiDebugBuilt { clearAIDebug() }
            return
        }
        ensureAIDebugNodes()

        let targetPath = CGMutablePath()
        let destPath = CGMutablePath()
        let leaderPath = CGMutablePath()
        var seen = Set<Int>()

        for npc in world.npcs where npc.isAlive {
            guard let brain = npc.brain else { continue }
            seen.insert(npc.entityID)
            let from = CGPoint(x: npc.position.x, y: npc.position.y)

            if let tid = brain.targetID ?? npc.currentTargetID, let t = world.ship(id: tid) {
                targetPath.move(to: from)
                targetPath.addLine(to: CGPoint(x: t.position.x, y: t.position.y))
            }
            if let dest = brain.destination {
                destPath.move(to: from)
                destPath.addLine(to: CGPoint(x: dest.x, y: dest.y))
            }
            if let lid = brain.leaderID, let leader = world.ship(id: lid) {
                leaderPath.move(to: from)
                leaderPath.addLine(to: CGPoint(x: leader.position.x, y: leader.position.y))
            }

            let label = aiLabelNodes[npc.entityID] ?? makeAILabel(for: npc.entityID)
            label.position = CGPoint(x: from.x, y: from.y + CGFloat(npc.radius) + 18)
            label.text = aiLabelText(npc, brain)
            label.fontColor = aiStateColor(brain.state)
        }

        aiTargetLines?.path = targetPath
        aiDestLines?.path = destPath
        aiLeaderLines?.path = leaderPath

        for (id, node) in aiLabelNodes where !seen.contains(id) {
            node.removeFromParent()
            aiLabelNodes[id] = nil
        }
    }

    /// Create the three shared line nodes once (idempotent). Labels are made
    /// lazily per ship in `makeAILabel`.
    private func ensureAIDebugNodes() {
        guard !aiDebugBuilt else { return }
        func lineNode(_ color: SKColor) -> SKShapeNode {
            let n = SKShapeNode()
            n.strokeColor = color
            n.lineWidth = 1
            n.alpha = 0.7
            aiDebugLayer.addChild(n)
            return n
        }
        aiTargetLines = lineNode(SKColor(red: 0.95, green: 0.3, blue: 0.25, alpha: 1))  // combat target
        aiDestLines   = lineNode(SKColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1))  // nav goal / path
        aiLeaderLines = lineNode(SKColor(red: 0.4, green: 0.9, blue: 0.45, alpha: 1))   // formation link
        aiDebugBuilt = true
    }

    /// Tear the overlay back down when it's switched off, so it costs nothing
    /// while disabled.
    private func clearAIDebug() {
        aiDebugLayer.removeAllChildren()
        aiTargetLines = nil
        aiDestLines = nil
        aiLeaderLines = nil
        aiLabelNodes.removeAll()
        aiDebugBuilt = false
    }

    private func makeAILabel(for id: Int) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.fontSize = 8
        label.verticalAlignmentMode = .bottom
        label.horizontalAlignmentMode = .center
        aiDebugLayer.addChild(label)
        aiLabelNodes[id] = label
        return label
    }

    /// The compact readout above each ship: its state (abbreviated), the entity
    /// it's targeting if any, and an escort's formation slot.
    private func aiLabelText(_ npc: Ship, _ brain: AIBrain) -> String {
        var text = aiStateAbbrev(brain.state)
        if let tid = brain.targetID { text += "→\(tid)" }
        if brain.leaderID != nil { text += " E\(brain.formationSlot)" }
        return text
    }

    private func aiStateAbbrev(_ state: AIState) -> String {
        switch state {
        case .spawning:   return "SPAWN"
        case .traveling:  return "TRVL"
        case .landing:    return "LAND"
        case .patrolling: return "PATRL"
        case .orbiting:   return "ORBIT"
        case .attacking:  return "ATK"
        case .fleeing:    return "FLEE"
        case .departing:  return "DEPRT"
        case .escorting:  return "ESCRT"
        case .assisting:  return "ASSIST"
        case .scanning:   return "SCAN"
        }
    }

    /// State → label colour: red for combat, amber for flight/evade, cyan for
    /// travel, green for escort/assist, grey for idle patrol.
    private func aiStateColor(_ state: AIState) -> SKColor {
        switch state {
        case .attacking:
            return SKColor(red: 0.95, green: 0.35, blue: 0.3, alpha: 1)
        case .fleeing, .departing:
            return SKColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 1)
        case .traveling, .landing:
            return SKColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1)
        case .escorting, .assisting, .scanning:
            return SKColor(red: 0.45, green: 0.9, blue: 0.5, alpha: 1)
        case .patrolling, .orbiting, .spawning:
            return SKColor(white: 0.85, alpha: 1)
        }
    }
}
