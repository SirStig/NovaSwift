import SwiftUI
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// Builds and owns the game scene, input, controller, and HUD for a play session.
@MainActor
final class GameHost {
    let scene = GameScene(size: CGSize(width: 1024, height: 768))
    let input = InputController()
    let hud = GameHUDModel()
    let controller: GameControllerInput
    /// The authentic status-bar style (ïntf + backdrop PICT), when the data has
    /// one. Not `let`: it reskins to the player's current hull government (see
    /// `refreshHUDStyle`) whenever the ship changes (e.g. buying a new hull then
    /// taking off, which reuses this host rather than rebuilding it).
    private(set) var hudStyle: AuthenticHUDStyle?
    /// The loaded game + galaxy + spaceport graphics, exposed so the container can
    /// present the landing screen (which needs `spöb` data and interface PICTs).
    let game: NovaGame?
    let galaxy: Galaxy?
    let graphics: SpaceportGraphics?

    /// Cache of ship-type id → target-display source sprite (dedicated shipyard
    /// art if present, else the in-flight sprite). Keyed with an optional value
    /// so a miss is cached too — the HUD asks on every target change.
    private var targetSpriteCache: [Int: CGImage?] = [:]

    /// The source sprite for a target ship's red silhouette (`ShipSilhouetteView`
    /// applies the red tint + scanlines). Uses the **in-flight sprite**, which
    /// carries a transparency mask, so only the ship's shape tints — the
    /// dedicated shipyard art (`shipPicture`) has a baked opaque background that
    /// would tint into a solid red rectangle. Nil when the data has no sprite.
    func targetSilhouette(shipType id: Int) -> CGImage? {
        if let cached = targetSpriteCache[id] { return cached }
        let img = game?.ship(id).flatMap { graphics?.shipFallbackPicture($0) }
        targetSpriteCache[id] = img
        return img
    }

    init(model: AppModel, systemID: Int? = nil, arrivedViaJump: Bool = false) {
        controller = GameControllerInput(input: input)
        hudStyle = GameHost.makeHUDStyle(model.data.game, shipType: model.pilot.state.shipType)
        hud.credits = model.pilot.state.credits
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
            // A fresh Galaxy means a fresh Diplomacy (`makeDiplomacy()` caches
            // per-Galaxy, and every jump rebuilds `GameHost` from scratch) — seed
            // it from the persisted pilot so standing survives across jumps.
            // Combat rating isn't seeded here; it's a per-session delta folded
            // into `PlayerState.combatRating` at sync points instead (see
            // `GameContainerView.syncCombatStanding()`).
            galaxy.makeDiplomacy().seed(legalRecord: pilot.legalRecord)
            // Player ship + sprite textures from the current pilot loadout (see
            // `buildPlayerShip`) — the exact same construction the in-place
            // takeoff reload (`GameScene.reloadForDeparture`) uses, so a newly
            // bought hull/outfit takes effect identically on both paths.
            let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
            ship = session.ship
            textures = session.textures
            engineTextures = session.engineTextures
            hud.shipName = session.shipName
            // Load the requested system (or the pilot's current one — every call
            // site passes an explicit systemID today, but this stays as a safe
            // default if that ever changes).
            let target = systemID ?? pilot.currentSystem
            let targetSystem = game.system(target) ?? game.startingSystem()
            if let system = targetSystem {
                systemName = system.name
                aiSystemID = system.id
                // Story-destroyed stellars (mission `Y` op / spöb OnDestroy,
                // persisted in `destroyedStellars`) show their **wreck** graphic
                // (`spöb.DestroyedGraphic`) and can't be landed on; a stellar with
                // no wreck art simply vanishes until regenerated (`U`). The
                // inverse "land only when destroyed" (Flags 0x0080) is hidden
                // until destroyed, then appears as a normal, landable base.
                let destroyed = model.pilot.state.destroyedStellars ?? []
                planets = game.stellarObjects(in: system.id).compactMap { entry in
                    let spob = entry.spob
                    let isDestroyed = destroyed.contains(spob.id)
                    if spob.landableOnlyWhenDestroyed && !isDestroyed { return nil }   // hidden until revealed
                    var sprite = entry.sprite
                    var wreck = false
                    if isDestroyed && !spob.landableOnlyWhenDestroyed {
                        guard let ws = game.spobDestroyedSprite(spob.id) else { return nil } // no wreck art → vanish
                        sprite = ws
                        wreck = true
                    }
                    let tex = sprite.flatMap { $0.frameCGImage(0) }.map { SKTexture(cgImage: $0) }
                    let radius = CGFloat(sprite?.frameWidth ?? 48) / 2
                    return PlanetVisual(id: spob.id, name: spob.name,
                                        position: CGPoint(x: spob.x, y: spob.y),
                                        texture: tex, radius: radius,
                                        government: spob.government,
                                        isUninhabited: spob.isUninhabited || wreck)
                }
                // Start the player a little "south" of the system's actual centre
                // (the centroid of its stellar bodies, not necessarily world origin)
                // so planets are in view. (Takeoff positions the ship at the
                // departed body instead — that's handled in the in-place
                // `GameScene.reloadForDeparture`, not this fresh-build path.)
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

        // Contraband scanning: when a government ship finishes scanning the
        // player, its government checks the player's holds/equipment against its
        // `ScanMask` and fines (`ScanFine`) / logs smuggling (`SmugPenalty`).
        // The consequence needs live pilot state, so it's wired from here.
        if let scanGame = aiGame {
            let pilotStore = model.pilot
            scene.onPlayerScanned = { [weak pilotStore, weak hud] scannerGovt in
                guard let pilotStore else { return }
                // Smuggling missions (mïsn Flags 0x0020 "fail if scanned") are
                // blown when this govt's scan finds their illegal cargo aboard —
                // independent of the general-contraband fine below.
                let scanFailIDs = pilotStore.state.activeMissions.map(\.missionID).filter { id in
                    guard let m = scanGame.mission(id), m.failIfScanned else { return false }
                    let cargoType = pilotStore.state.activeMission(id)?.resolvedCargoType ?? m.cargoType
                    let carrying = (pilotStore.state.cargo[cargoType] ?? 0) > 0
                    return carrying && scanGame.isMissionCargoContraband(id, to: scannerGovt)
                }
                if !scanFailIDs.isEmpty {
                    let engine = StoryEngine(game: scanGame, player: pilotStore.state)
                    for id in scanFailIDs { engine.failMission(id) }
                    pilotStore.state = engine.player
                    hud?.post("Your illicit cargo was detected — mission failed.")
                    pilotStore.save()
                }
                guard let result = ContrabandScan.enforce(on: &pilotStore.state,
                                                           game: scanGame, govtID: scannerGovt),
                      result.foundContraband else { return }
                let name = scanGame.govt(scannerGovt)?.name ?? "Patrol"
                if result.warningOnly {
                    hud?.post("\(name): contraband detected — you are let off with a warning.")
                } else if result.fine > 0 {
                    hud?.post("\(name) fined you \(result.fine)cr for carrying contraband.")
                }
                if result.smugglingPenalty > 0 {
                    hud?.post("\(name) logs your smuggling; your standing worsens.")
                }
                pilotStore.save()
            }

            // pêrs (named characters): seed grudges, gate appearances on their
            // ActiveOn NCB + not-yet-defeated, and persist grudge/defeat outcomes.
            scene.persGrudges = model.pilot.state.persGrudges ?? []
            scene.persSpawnEligible = { [weak pilotStore] id in
                guard let store = pilotStore else { return true }
                if store.state.isPersDefeated(id) { return false }
                guard let pers = scanGame.pers(id), !pers.activeOn.isEmpty else { return true }
                return StoryEngine(game: scanGame, player: store.state).evaluate(test: pers.activeOn)
            }
            scene.onPersGrudge = { [weak pilotStore] pid in
                pilotStore?.state.recordPersGrudge(pid); pilotStore?.save()
            }
            scene.onPersDefeated = { [weak pilotStore] pid in
                pilotStore?.state.recordPersDefeated(pid); pilotStore?.save()
            }
            // The player's own ship was destroyed. With an escape pod: rescued
            // at the nearest inhabited port, ship/cargo/outfits lost — saved,
            // then back to the main menu. Without one: a real game-over — the
            // explosion (already emitted alongside this event) gets a moment
            // to play out before returning to the main menu; nothing is saved,
            // so the pilot resumes from their last landing/takeoff autosave.
            scene.onPlayerDestroyed = { [weak pilotStore, weak scene] hadEscapePod in
                guard let pilotStore else { return }
                if hadEscapePod, let deathPosition = scene?.playerShip?.position,
                   let rescue = Self.rescueLandingSpot(diedIn: aiSystemID, near: deathPosition, game: scanGame) {
                    Self.applyEscapePodRescue(to: &pilotStore.state, systemID: rescue.systemID, game: scanGame)
                    pilotStore.save()
                    model.returnToMainMenu()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        model.returnToMainMenu()
                    }
                }
            }
            // The world was already built by `configure` above — push the pilot's
            // existing grudges/eligibility onto it now.
            scene.syncPersStateToWorld()
        }
    }

    /// The player's live ship + its sprite textures, built from the current pilot
    /// loadout (hull + installed outfits → shields/armor/fuel/afterburner/cargo +
    /// resolved weapons). Shared by the initial `GameHost` build and the in-place
    /// takeoff reload (`GameScene.reloadForDeparture`) so a newly bought hull or
    /// outfit takes effect identically on both paths. Fuel/armor/shield are seeded
    /// from the pilot's saved levels (nil = full — new pilot / just repaired), so
    /// they persist across a takeoff; the pilot's cargo is carried into the hold.
    struct PlayerSession {
        let ship: Ship
        let textures: [SKTexture]
        let engineTextures: [SKTexture]
        let shipName: String
    }
    static func buildPlayerShip(model: AppModel, galaxy: Galaxy, game: NovaGame) -> PlayerSession {
        let pilot = model.pilot.state
        let shipID = pilot.shipType
        let res = game.ship(shipID)
        let ship = galaxy.makeLoadedShip(shipID, extraOutfits: pilot.outfits)
            ?? Ship(name: res?.displayName ?? "Ship",
                    stats: ShipStats(speed: res?.speed ?? 300, acceleration: res?.acceleration ?? 400,
                                     turnRate: res?.turnRate ?? 30, rotationFrames: 36))
        ship.cargo = pilot.cargo
        if let lo = galaxy.loadout(shipID: shipID, extraOutfits: pilot.outfits) {
            ship.fuel = pilot.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
        }
        ship.armor = pilot.armor.map { min($0, ship.maxArmor) } ?? ship.maxArmor
        ship.shield = pilot.shield.map { min($0, ship.maxShield) } ?? ship.maxShield
        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        if let sheet = game.shipSprite(shipID) { textures = SpriteTextures.rotationFrames(from: sheet) }
        if let glow = game.engineGlowSprite(shipID) { engineTextures = SpriteTextures.rotationFrames(from: glow) }
        let name = pilot.shipName.isEmpty ? (res?.displayName ?? "") : pilot.shipName
        return PlayerSession(ship: ship, textures: textures, engineTextures: engineTextures, shipName: name)
    }

    /// The nearest inhabited `spöb` to `position` within `systemID`, paired
    /// with that system's id, or nil if the system has none.
    static func nearestInhabitedSpob(in systemID: Int, near position: Vec2,
                                     game: NovaGame) -> (spob: SpobRes, systemID: Int)? {
        let candidates = game.stellarObjects(in: systemID).map(\.spob).filter { !$0.isUninhabited }
        guard let nearest = candidates.min(by: {
            (Vec2(Double($0.x), Double($0.y)) - position).length < (Vec2(Double($1.x), Double($1.y)) - position).length
        }) else { return nil }
        return (nearest, systemID)
    }

    /// Where an escape pod drops the pilot: the nearest inhabited spöb in the
    /// system they died in, or — for the rare uninhabited-only system — the
    /// pilot's own starting system, which is always inhabited.
    static func rescueLandingSpot(diedIn systemID: Int, near position: Vec2,
                                  game: NovaGame) -> (spob: SpobRes, systemID: Int)? {
        if let here = nearestInhabitedSpob(in: systemID, near: position, game: game) { return here }
        guard let start = game.startingSystem() else { return nil }
        return nearestInhabitedSpob(in: start.id, near: Vec2(), game: game)
    }

    /// Apply an escape-pod rescue to a persisted pilot: the ship, its cargo,
    /// and every installed outfit are lost (per the Bible's escape pod being
    /// a last resort, not a lifeboat that tows your hull home); the pilot is
    /// dropped at `spob` with a stock replacement hull and full fuel/armor/
    /// shield. Credits, legal record, missions, and combat rating carry over.
    static func applyEscapePodRescue(to state: inout PlayerState, systemID: Int, game: NovaGame) {
        let stockShipID: Int?
        if let scenarioShip = game.startingChar()?.shipID, scenarioShip >= 128 {
            stockShipID = scenarioShip
        } else {
            stockShipID = game.ships().first?.id
        }
        if let stockShipID {
            state.shipType = stockShipID
            state.shipName = game.ship(stockShipID)?.name ?? ""
        }
        state.outfits = [:]
        state.cargo = [:]
        state.armor = nil; state.shield = nil; state.fuel = nil
        state.currentSystem = systemID
        state.exploredSystems.insert(systemID)
    }

    /// Recompute the status-bar skin for the player's current hull — call after
    /// the ship changes without a full host rebuild (buy a new hull, then take
    /// off, which reuses this host). Also refreshes the credit balance shown in
    /// the bottom readout. The container reads `hudStyle` on its next render, so
    /// the new skin appears as soon as the departure re-renders the view.
    func refreshHUDStyle(model: AppModel) {
        hudStyle = GameHost.makeHUDStyle(model.data.game, shipType: model.pilot.state.shipType)
        hud.credits = model.pilot.state.credits
    }

    /// Decode the authentic status bar: the ïntf interface definition + its
    /// backdrop PICT, from the player's own data. Returns nil if unavailable
    /// (the container then falls back to `GameHUDView`, our own non-authentic HUD).
    ///
    /// The HUD reskins with the ship being flown: the player hull's inherent
    /// government picks the interface (Nova Bible `gövt.Interface`), so a
    /// Federation hull wears the Fed status bar, a Polaris hull the Polaris one,
    /// etc. Anything the data leaves under 128 clamps back to the Default (128).
    static func makeHUDStyle(_ game: NovaGame?, shipType: Int? = nil) -> AuthenticHUDStyle? {
        guard let game else {
            Log.hud.debug("makeHUDStyle: no game loaded — falling back to GameHUDView")
            return nil
        }
        let intfID: Int = {
            guard let shipType,
                  let govtID = game.ship(shipType)?.inherentGovt, govtID >= 128,
                  let iid = game.govt(govtID)?.interface, iid >= 128 else { return 128 }
            return iid
        }()
        guard let intf = game.interface(intfID) ?? game.interface() else {
            Log.hud.error("makeHUDStyle: no ïntf(\(intfID)) or ïntf(128) resource — falling back to GameHUDView")
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
    /// The in-game debug suite panel (developer tools), gated by debug mode.
    @State private var showDebugSuite = false
    /// Live debug/performance state for this play session, handed to each
    /// `GameScene` the container (re)builds. Persists across host rebuilds.
    @StateObject private var debug = DebugController()
    /// The spöb the player is currently landed on (nil = flying).
    @State private var landedSpobID: Int?
    /// A pending landing awaiting the player's confirmation (the "Confirm before
    /// landing" setting), nil when none.
    @State private var landConfirmID: Int?
    /// When set, the origin hypergate's spöb id — the galaxy map is showing its
    /// destination network (solid blue lines) for the player to pick a jump.
    @State private var gateMapOrigin: Int?
    /// Whether the first-flight tutorial hints card is showing (the "Tutorial
    /// hints" setting; shown once per install until dismissed).
    @State private var showFlightHints = false
    private static let seenHintsKey = "novaswift.seenFlightHints"
    /// Keyboard focus for the flight scene. `.focusable()` alone never actually
    /// grabs focus — without binding + explicitly setting this, `.onKeyPress` in
    /// `KeyboardControls` silently never fires and the ship can't be flown at
    /// all. Re-asserted whenever a menu/map/spaceport overlay that took focus
    /// away closes back to flight.
    @FocusState private var isSceneFocused: Bool
    /// The open hail/communication dialog, if any (nil = closed).
    @State private var hailDialogState: HailDialogState?
    /// Backs the in-flight LinkMission offer a hailed/boarded `pêrs` makes —
    /// mirrors the bar's `services.pendingOffer` pattern (`SpaceportView`) so
    /// the same accept/decline panel works mid-flight.
    @StateObject private var flightMissionServices = AppGameServices()
    @State private var flightMissionEngine: StoryEngine?
    /// The `pêrs` id behind the current flight mission offer, if any — needed
    /// on accept to honor its deactivate/leave-after-mission flags.
    @State private var flightMissionPersonID: Int?
    /// Mobile action-menu panels the on-screen controls can open over flight.
    @State private var showMissionsPanel = false
    @State private var showPilotInfoPanel = false
    @State private var showEscortsPanel = false
    /// Bumped when an escort order is issued so the command window re-renders
    /// with the new highlighted order (engine state changes don't publish).
    @State private var escortRefresh = 0
    /// The disabled ship currently being boarded (nil = plunder dialog closed).
    @State private var boardManifest: World.BoardingManifest?
    /// Bumped after taking loot so the plunder dialog re-reads the manifest.
    @State private var boardRefresh = 0
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
                if let style = activeHUDStyle(host) {
                    // Constrained to the same capped sidebar width `sceneLayer`
                    // reserves for it (see `Self.sidebarWidth`), and clipped, so
                    // the two never disagree — without this the HUD's own
                    // height-driven `.right` scale would still balloon past the
                    // play viewport's edge on extreme portrait aspect ratios.
                    GeometryReader { geo in
                        AuthenticHUDView(model: host.hud, style: style, showRadar: model.settings.showRadar,
                                         targetSprite: { host.targetSilhouette(shipType: $0) })
                            .frame(width: Self.sidebarWidth(in: geo.size, style: style), height: geo.size.height,
                                   alignment: .trailing)
                            .clipped()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                    .opacity(model.settings.hudOpacity)
                } else {
                    GameHUDView(model: host.hud, showRadar: model.settings.showRadar,       // modern HUD (Nova Swift, or no ïntf in data)
                                largerHUD: model.settings.largerHUD,
                                highContrast: model.settings.highContrastHUD)
                        .opacity(model.settings.hudOpacity)
                }

                topLeftMenuButton

                if nav.showingMap && gateMapOrigin == nil {
                    GalaxyMapView(nav: nav, pilot: model.pilot, onJump: { _ = attemptJump() },
                                  onClose: { nav.showingMap = false },
                                  fullscreen: model.settings.fullscreenGalaxyMap)
                        .transition(.opacity)
                }

                // Gate map: landing on a hypergate opens the galaxy map in
                // destination-picker mode — solid blue lines to every gate this
                // one connects to. Tapping one jumps you through it.
                if let gateID = gateMapOrigin, let game = host.game, let gate = game.spob(gateID) {
                    GalaxyMapView(nav: nav, pilot: model.pilot, onJump: {},
                                  onClose: { gateMapOrigin = nil },
                                  fullscreen: model.settings.fullscreenGalaxyMap,
                                  gateSelection: .init(
                                    originSystem: nav.currentSystemID,
                                    destinations: game.gateDestinations(from: gate),
                                    onSelect: { destGate, destSystem in
                                        performGateJump(toSystem: destSystem, arriveAtGate: destGate)
                                    }))
                        .transition(.opacity)
                }

                MessageLogView(hud: host.hud)

                if showFlightHints && landedSpobID == nil && !showMenu && !nav.showingMap {
                    flightHintsOverlay
                }

                #if os(iOS)
                // Mounted ABOVE the passive HUD/message/menu-button layers so its
                // buttons (and the expandable action grid) are never drawn under
                // — or blocked by — them; hidden whenever a modal owns the screen
                // so it can't intercept those. The play area stays free for
                // tap/drag-to-fly steering and target taps. Right-hand clusters
                // inset by the status-bar HUD width so they never overlap it.
                if flightControlsVisible {
                    GeometryReader { geo in
                        TouchControlsOverlay(
                            input: host.input, hud: host.hud,
                            viewportSize: geo.size,
                            tapToFly: model.settings.controlScheme == .tapToTurn,
                            rightInset: Self.sidebarWidth(in: geo.size, style: activeHUDStyle(host)),
                            onDiscrete: handleDiscrete,
                            onOpenPanel: openMobilePanel)
                    }
                }
                #endif

                // The land prompt sits above the controls; on iOS it's a tappable
                // pill that lands you (replacing the desktop "Press L" hint).
                // Inset by the HUD sidebar width so it centres on the actual play
                // viewport, not the full window (see `Self.sidebarWidth`).
                GeometryReader { geo in
                    LandPromptView(hud: host.hud, onLand: { handleDiscrete(.land) },
                                    rightInset: Self.sidebarWidth(in: geo.size, style: activeHUDStyle(host)))
                }

                if let state = hailDialogState {
                    HailDialogView(
                        state: state, portrait: hailPortrait(state), graphics: host.graphics,
                        showAssistButton: hailShowsAssistButton(state),
                        assistEnabled: hailAssistEnabled(state),
                        onGreetings: {
                            hailDialogState?.responseText = state.hostile
                                ? "They don't seem interested in talking."
                                : "Just a routine hail, nothing more."
                        },
                        onRequestAssistance: {
                            if case let .ship(entityID, _) = state.kind { requestAssistance(entityID: entityID) }
                        },
                        onRequestLanding: { requestPlanetLanding() },
                        onDemandTribute: { demandPlanetTribute() },
                        onClose: { hailDialogState = nil })
                }

                // A pêrs's in-flight LinkMission offer (hailed or boarded) —
                // stacks over the hail dialog exactly as the bar stacks its
                // offer over the spaceport hub.
                if let offer = flightMissionServices.pendingOffer, let graphics = host.graphics {
                    Color.black.opacity(0.5).ignoresSafeArea().transition(.opacity)
                    MissionSingleDialog(graphics: graphics, offer: offer, offered: [offer.mission],
                                        onPage: { _ in },
                                        onAccept: { acceptFlightMissionOffer(offer) },
                                        onDecline: { declineFlightMissionOffer(offer) })
                        .transition(.opacity)
                }

                // Mobile action-menu panels (opened from the on-screen controls).
                mobilePanels

                if showMenu {
                    GameMenuView(hud: host.hud,
                                 onResume: { showMenu = false },
                                 onOpenMap: { nav.showingMap = true },
                                 onOpenEscorts: { showEscortsPanel = true },
                                 showDebug: model.settings.debugModeEnabled,
                                 onOpenDebug: { showMenu = false; showDebugSuite = true })
                }

                // Debug suite: an on-screen entry point + live metrics chip while
                // debug mode is on, and the full developer panel when opened. The
                // simulation keeps running underneath so the readout stays live.
                if model.settings.debugModeEnabled {
                    debugControls
                    if showDebugSuite {
                        DebugSuiteView(debug: debug) { showDebugSuite = false }
                            .zIndex(30)
                            .transition(.opacity)
                    }
                }

                // The landed spaceport, drawn from the player's own EV Nova data.
                // Constrained to the same play-viewport width `sceneLayer` uses
                // (not the full window) so the status-bar HUD on the right stays
                // visible — the real game never hides the ship's own readout
                // behind the landing screen.
                if let id = landedSpobID, let graphics = host.graphics,
                   let galaxy = host.galaxy, let spob = host.game?.spob(id) {
                    GeometryReader { geo in
                        let sidebarWidth = Self.sidebarWidth(in: geo.size, style: activeHUDStyle(host))
                        let playWidth = max(0, geo.size.width - sidebarWidth)
                        SpaceportView(graphics: graphics, galaxy: galaxy, spob: spob,
                                      pilot: model.pilot, onDepart: depart)
                            .frame(width: playWidth, height: geo.size.height)
                            .position(x: playWidth / 2, y: geo.size.height / 2)
                    }
                    .transition(.opacity)
                }

                // Narrative the story engine wants shown — a mission's completion /
                // failure text, a post-accept briefing, or cron news. Placed last
                // in the host branch so it floats above both the flight scene and
                // the spaceport: it can fire on landing (a delivery completes) or
                // in flight (a crön advances the clock). A single OK dismisses it.
                if let story = flightMissionServices.storyText {
                    Color.black.opacity(0.5).ignoresSafeArea().transition(.opacity)
                    NovaDialog(title: story.title.isEmpty ? "Mission" : story.title,
                               width: 480,
                               buttons: [NovaDialogButton(title: "OK", isDefault: true) {
                                   flightMissionServices.storyText = nil
                               }]) {
                        Text(story.text)
                            .novaFont(.body)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            } else {
                GameLoadingView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: nav.showingMap)
        .animation(.easeInOut(duration: 0.2), value: gateMapOrigin)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMenu)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showDebugSuite)
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
        .onChange(of: gateMapOrigin) { _, id in
            if id == nil { grabSceneFocus(reason: "gate map closed") }
        }
        .onChange(of: nav.route) { _, _ in
            syncNavCourseToHUD(host)
        }
        .onChange(of: hailDialogState != nil) { _, open in
            setScenePaused(open, reason: "hailDialogState=\(open)")
            if !open { grabSceneFocus(reason: "hail dialog closed") }
        }
        .onChange(of: flightMissionServices.pendingOffer != nil) { _, open in
            setScenePaused(open, reason: "flightMissionOffer=\(open)")
            if !open { grabSceneFocus(reason: "flight mission offer closed") }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding/quitting is the one moment a manual save/jump/land
            // won't have already caught — e.g. shopping at a spaceport and then
            // leaving the app without departing again. Durable-save whatever the
            // live pilot has right now so it isn't lost.
            if phase != .active {
                syncCombatStanding()
                model.autosave(reason: .timer)
                // "Pause when app loses focus": freeze the sim while backgrounded
                // (unless a modal already owns the pause state).
                if model.settings.pauseOnFocusLoss { setScenePaused(true, reason: "focus lost") }
            } else if model.settings.pauseOnFocusLoss,
                      landedSpobID == nil, !showMenu, !nav.showingMap,
                      hailDialogState == nil, flightMissionServices.pendingOffer == nil {
                // Back to the foreground with nothing else holding the pause —
                // resume flight.
                setScenePaused(false, reason: "focus regained")
            }
        }
        .onChange(of: landedSpobID) { _, id in
            setScenePaused(id != nil, reason: "landedSpobID=\(id.map(String.init) ?? "nil")")
            if let id {
                handleStoryLanding(spobID: id)                  // finish deliveries / pick up cargo BEFORE the day tick
                advanceGameDay()                                // landing→depart is one calendar day
                DispatchQueue.main.async {
                    // Inhabited ports restore hull + shields to full for free
                    // (shields regen while docked; hull is patched up). Fuel is
                    // NOT topped off here — refuelling is the paid "Recharge"
                    // service, per the Bible (free only via govt/rank flags).
                    repairOnLanding(spobID: id)
                    syncCombatStanding()
                    model.autosave(reason: .land)               // EV Nova saves on every landing
                }
                model.audio.startAmbient(soundID: host?.game?.spob(id)?.ambientSoundID)
            } else {
                grabSceneFocus(reason: "departed spaceport")   // departed the spaceport: back to flight
                model.audio.stopAmbient()
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
                debug.attach(host?.scene)                              // point the debug suite at the live scene
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
                applyControlScheme()
                // First-flight tutorial hints (the setting), shown once per install.
                if model.settings.tutorialHints,
                   !UserDefaults.standard.bool(forKey: Self.seenHintsKey) {
                    showFlightHints = true
                }
            }
        }
        .confirmationDialog("Land here?",
                            isPresented: Binding(get: { landConfirmID != nil },
                                                 set: { if !$0 { landConfirmID = nil } }),
                            titleVisibility: .visible) {
            Button("Land") { if let id = landConfirmID { landConfirmID = nil; landedSpobID = id } }
            Button("Cancel", role: .cancel) { landConfirmID = nil }
        }
        .onChange(of: model.settings.controlScheme) { _, _ in applyControlScheme() }
        // Push any settings change into the live scene's own copy so display
        // options (ship bars, planet labels, smooth sprites, engine glow, screen
        // shake, reduce-flashing) take effect without a system rebuild.
        .onChange(of: model.settings) { _, s in host?.scene.applyDisplaySettings(s) }
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
                syncCombatStanding()   // the about-to-be-discarded Diplomacy is the source of truth
                model.pilot.save()
                model.autosave(reason: .jump)                 // durable per-pilot save on hyperjump
                host = GameHost(model: model, systemID: newID, arrivedViaJump: true) // rebuild on jump
                debug.attach(host?.scene)                     // re-point the debug suite (a jump ends any stress test)
                setScenePaused(false, reason: "jump rebuild")
                syncNav(host)
                applyControlScheme()
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
    /// Logs every attempt/outcome (subsystem com.novaswift.app, category Input) so
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

    /// First-flight tutorial hints — a compact, dismissible card of the core
    /// controls, shown once per install when "Tutorial hints" is on. Platform
    /// wording differs (touch vs. keyboard). Dismissing remembers it.
    private var flightHintsOverlay: some View {
        #if os(iOS)
        let tips = ["Drag to fly, or use the on-screen controls",
                    "Tap a ship to target it · tap a planet to set a course",
                    "Tap Land near a planet — or turn on Auto-landing in Settings",
                    "Open the map to plot a hyperspace jump"]
        #else
        let tips = ["Steer with WASD or the arrow keys · Space to fire",
                    "Click a ship to target it · click a planet to set a course",
                    "Press L to land · J for the galaxy map · Tab to cycle targets"]
        #endif
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Getting started", systemImage: "lightbulb")
                    .novaFont(.body, weight: .bold).foregroundStyle(novaAmber)
                Spacer()
                Button {
                    UserDefaults.standard.set(true, forKey: Self.seenHintsKey)
                    withAnimation { showFlightHints = false }
                } label: {
                    Text("Got it").novaFont(.caption, weight: .semibold)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(novaAmber.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(novaAmber.opacity(0.5)))
                }.buttonStyle(.plain)
            }
            ForEach(tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(tip).novaFont(.caption).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 340, alignment: .leading)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(novaAmber.opacity(0.3)))
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }

    /// Commit a landing, honoring the "Confirm before landing" setting: with it
    /// on, stash the spöb and show a confirmation; otherwise land immediately.
    /// Shared by the manual land key, the on-screen Land pill, and the
    /// auto-landing autopilot's arrival.
    private func requestLanding(_ id: Int) {
        // A destroyed stellar is a drifting wreck — you can't dock with it (unless
        // it's a "reveal only when destroyed" base, which becomes a real port once
        // its cover is blown).
        if model.pilot.state.destroyedStellars?.contains(id) == true,
           host?.game?.spob(id)?.landableOnlyWhenDestroyed != true {
            host?.hud.post("Nothing but wreckage remains.")
            return
        }
        // A gate isn't a spaceport — landing on it *uses* it. Route gates to gate
        // travel instead of opening the port (and skip the land confirmation).
        if let game = host?.game, let spob = game.spob(id), spob.isGate {
            handleGateLanding(spob)
            return
        }
        if model.settings.confirmLanding { landConfirmID = id }
        else { landedSpobID = id }
    }

    /// Landing on a gate. A wormhole flings you straight through (no choice); a
    /// hypergate you're cleared for opens its destination map so you can pick a
    /// jump; one you aren't cleared for just refuses.
    private func handleGateLanding(_ spob: SpobRes) {
        guard let scene = host?.scene else { return }
        if spob.isWormhole {
            beginWormholeTransport(from: spob)
        } else if scene.playerMayUseGate(spob.id) {
            guard !(host?.game?.gateDestinations(from: spob) ?? []).isEmpty else {
                host?.hud.post("This hypergate leads nowhere."); return
            }
            scene.activateGate(spob.id)     // light it even if the player never clicked it
            gateMapOrigin = spob.id
        } else {
            host?.hud.post("You are not cleared to use this hypergate.")
        }
    }

    /// A wormhole spits you out at a linked wormhole, or a random one if it has no
    /// links (Bible). Chaotic by design — no destination choice.
    private func beginWormholeTransport(from wormhole: SpobRes) {
        guard let game = host?.game else { return }
        guard let dest = game.wormholeExitCandidates(from: wormhole).randomElement() else {
            host?.hud.post("The wormhole collapses — it leads nowhere."); return
        }
        performGateJump(toSystem: dest.systemID, arriveAtGate: dest.gateSpobID)
    }

    /// Drive a gate transport through the live scene: it flashes and swaps to
    /// `destSystem` in place, emerging from `destGate`. The flash-peak commit sets
    /// the system, advances a day, and saves — gates spend **no** fuel (that's the
    /// whole point of a gate network), and no hyperspace link is required.
    private func performGateJump(toSystem destSystem: Int, arriveAtGate destGate: Int) {
        guard let host, !host.scene.isJumping else { return }
        gateMapOrigin = nil
        host.scene.beginGateJump(toSystem: destSystem, arriveAtGate: destGate) {
            hostSystemID = destSystem                     // set first: suppress the host-rebuild onChange
            nav.arriveViaGate(at: destSystem)
            model.pilot.state.currentSystem = destSystem
            model.pilot.state.exploredSystems.insert(destSystem)
            advanceGameDay()                              // gate travel still costs a calendar day
            model.pilot.save()
            model.autosave(reason: .jump)
            syncNav(host)
        }
    }

    /// Leave the spaceport: rebuild the ship/system from the (possibly changed)
    /// pilot so new outfits/hull/cargo take effect, with shields/armor restored —
    /// as EV Nova does on takeoff — and resume flight. Fuel carries over as-is
    /// (landing already topped it off; taking off doesn't spend or grant any).
    private func depart() {
        let departedSpob = landedSpobID     // capture; we clear it last, below
        // Deferred a tick so this runs as its own clean update rather than
        // piling model mutations onto whatever transaction triggered the
        // departure (a Leave tap, or a story `Q` op firing from inside a
        // landing's `onChange`).
        DispatchQueue.main.async {
            model.pilot.save()
            model.autosave(reason: .manual)   // catch any shopping done during this landing
            // Takeoff = reload the current system *in place* in the existing
            // scene (rebuilding the ship from the possibly-changed pilot loadout),
            // NOT a fresh `GameHost`. Rebuilding the host swaps the `SpriteView`'s
            // scene, which SwiftUI can only do by tearing the view down and back
            // up (`.id` on the SpriteView) — and that one blank frame during the
            // swap is the "weird screen flash on depart." Reusing the same scene
            // keeps its identity stable (no `.id` teardown → no flash) and leaves
            // keyboard input wired to the same `InputController`. Same pattern the
            // hyperjump uses. Falls back to a full rebuild only if something's
            // missing (no live host/galaxy/game, or an unknown spöb).
            //
            // Crucially, the reload runs *while the spaceport still covers the
            // viewport* (we clear `landedSpobID` only afterwards): the paused
            // scene has been frozen on the pre-landing frame since you docked, so
            // if the port faded out first it would briefly reveal that stale
            // frame (old ship position, old NPCs) before the reload snapped
            // everything into place. Reloading behind the still-opaque port, then
            // dropping it, makes its fade reveal the finished launch state
            // directly — no split-second flash of the old system.
            if let host, let galaxy = host.galaxy, let game = host.game, let spob = departedSpob {
                let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
                host.hud.shipName = session.shipName
                // A hull bought at this spaceport changes the HUD skin (and the
                // credit balance changed too); reskin before the scene reloads.
                host.refreshHUDStyle(model: model)
                host.scene.reloadForDeparture(spobID: spob, player: session.ship,
                                              textures: session.textures,
                                              engineTextures: session.engineTextures)
                landedSpobID = nil            // now fade the port out over the ready scene
                setScenePaused(false, reason: "depart (in place)")
                syncNav(host)
                grabSceneFocus(reason: "depart")
            } else {
                host = GameHost(model: model, systemID: nav.currentSystemID)
                hostSystemID = nav.currentSystemID
                debug.attach(host?.scene)
                landedSpobID = nil
                setScenePaused(false, reason: "depart (rebuild)")
                syncNav(host)
                grabSceneFocus(reason: "depart")
            }
        }
    }

    /// Reattach `nav`'s live-fuel/multi-jump sources to the current session's
    /// ship — needed every time `host` is (re)built, since neither survives a
    /// system rebuild on its own.
    private func syncNav(_ host: GameHost?) {
        // Re-bind the auto-landing arrival callback for whatever scene is current
        // (this runs at every host build/rebuild) so the autopilot can commit the
        // landing through the same confirm-aware path as the manual Land key.
        host?.scene.onAutoLandArrived = { id in requestLanding(id) }
        // Feed a mission special-ship's completed goal back into the story engine
        // (decrement the objective, complete the mission if it was the last one).
        host?.scene.onMissionShipGoalReached = { missionID, goal, _ in
            handleMissionShipGoalReached(missionID: missionID, goal: goal)
        }
        host?.scene.onMissionShipLost = { missionID, _ in
            handleMissionShipLost(missionID: missionID)
        }
        host?.scene.onPlayerDisabled = {
            failActiveMissions(where: { $0.failIfPlayerDisabled },
                               reason: "Your ship was disabled — mission failed.")
        }
        host?.scene.onPlayerBoarded = {
            // mïsn.Flags 0x8000 — "mission fails if you're boarded by pirates".
            failActiveMissions(where: { $0.flags1 & 0x8000 != 0 },
                               reason: "You were boarded — mission failed.")
        }
        // Demand-Tribute domination feedback. Each defense wave announces itself
        // (fires on the first wave and on every relaunch as the field is cleared);
        // a surrender persists through the story engine + daily tribute.
        host?.scene.onStellarDefendersLaunched = { spobID, count, _ in
            let name = model.data.game?.spob(spobID)?.name ?? "The stellar"
            host?.hud.post("\(name) scrambles \(count) defender\(count == 1 ? "" : "s").")
        }
        host?.scene.onStellarDominated = { spobID in
            handleStellarDominated(spobID: spobID)
        }
        // Live-world effect hooks for the flight-side story services (mission
        // OnSuccess / cron OnStart side effects that reach outside pilot state).
        flightMissionServices.onLeaveStellar = { message in
            if landedSpobID != nil { depart() }                 // Q op: bounced back into space
            if let message, !message.isEmpty { host?.hud.post(message) }
        }
        flightMissionServices.onSpawnMissionShips = { _, _ in spawnActiveMissionShips() }
        flightMissionServices.onChangePlayerShip = { shipID, _ in
            // The hull swap is already in `PlayerState`. In flight, rebuild the
            // world in place so the new hull/sprite/stats take effect immediately
            // (a mission `C/E/H` op that fires mid-space); landed, the takeoff
            // rebuild picks it up. Mission ships respawn via `syncNav` and their
            // objective counts persist in state, so a mid-mission swap is safe.
            let name = model.data.game?.ship(shipID)?.name ?? "a new ship"
            host?.hud.post("Your ship is now \(name).")
            if landedSpobID == nil { rebuildFlightHost(reason: "story ship swap") }
        }
        flightMissionServices.onMovePlayer = { systemID, keepPosition in
            movePlayerToSystem(systemID, keepPosition: keepPosition)
        }
        flightMissionServices.onSetStellarDestroyed = { spobID, destroyed in
            // Persisted in PlayerState by the engine; the body itself drops out
            // of the world on the next system (re)build. Surface it now.
            let name = model.data.game?.spob(spobID)?.name ?? "A stellar object"
            host?.hud.post(destroyed ? "\(name) has been destroyed." : "\(name) has been restored.")
        }
        // Daily escort upkeep (charged by StoryEngine.payDailyEscortFees as the
        // calendar advances): surface the total, and when the player can't cover
        // a hired escort's fee it "departs without ceremony" — despawn its ship.
        flightMissionServices.onEscortFeeCharged = { total in
            host?.hud.post("Escort upkeep — \(total)cr.")
        }
        flightMissionServices.onEscortDeparted = { escortID, name in
            host?.scene.despawnEscort(recordID: escortID)
            host?.hud.post("\(name) leaves your service — you can't cover its daily fee.")
        }
        // An escort that dies in combat is gone for good: drop it from the pilot
        // roster so it won't respawn next system (and a hired one stops billing).
        host?.scene.onEscortLost = { recordID in
            if let lost = model.pilot.state.removeEscort(id: recordID) {
                host?.hud.post("\(lost.name) was destroyed.")
            }
            model.pilot.save()
        }
        // Now that this system's world exists, drop in any active mission's
        // special ships whose `ShipSyst` matches here (deduped by the scene).
        spawnActiveMissionShips()
        // Respawn the player's persistent escort wing — EV Nova's escorts follow
        // their flagship between systems. The fresh world has none yet, so this
        // (re)creates a live ship for each saved record and re-tags it.
        host?.scene.respawnEscorts(model.pilot.state.escortWing.map { (recordID: $0.id, shipType: $0.shipType) })
        nav.attachShip(host?.scene.playerShip)
        if let galaxy = host?.galaxy {
            nav.maxJumpHops = model.pilot.maxJumpHops(galaxy: galaxy)
        }
        syncNavCourseToHUD(host)
    }

    /// Pushes the plotted hyperspace course (if any) into the HUD's Nav
    /// readout — needed both whenever `host` is rebuilt (a fresh `hud` starts
    /// with no course) and whenever the course itself changes (plotted,
    /// advanced, or cleared from the map) without a host rebuild.
    private func syncNavCourseToHUD(_ host: GameHost?) {
        guard let hud = host?.hud else { return }
        if let destID = nav.destinationID, let name = nav.system(destID)?.name {
            hud.navCourseSystemName = name
            hud.navCourseJumps = nav.route.count
        } else {
            hud.navCourseSystemName = ""
            hud.navCourseJumps = 0
        }
    }

    /// Advance the galaxy calendar by one day and announce the new date in the
    /// message log. EV Nova ticks a day on every hyperjump and every landing;
    /// `StoryEngine.advanceOneDay` also runs the day's crön/deadline processing,
    /// so time-gated story events and mission time limits progress with it.
    private func advanceGameDay() {
        guard let game = model.data.game else { return }
        // Route through the flight mission services so a crön that fires today
        // (its OnStart/OnEnd) can surface its text / notifications / spawns
        // through the same seam a mission does, instead of silently no-oping.
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.advanceOneDay()
        model.pilot.state = engine.player
        host?.hud.post(Self.logDate(model.pilot.state.date))
    }

    /// Run the story engine's landing hook for a dock at `spobID`, over the one
    /// shared pilot state and the flight mission services. This is what actually
    /// *finishes* cargo / courier / passenger missions — landing at the
    /// destination completes them, pays out, applies OnSuccess control bits and
    /// surfaces the completion text (via `flightMissionServices.storyText`).
    /// Called before `advanceGameDay` so a just-in-time delivery completes before
    /// the calendar tick could trip its deadline.
    private func handleStoryLanding(spobID: Int) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.playerLanded(onSpob: spobID)
        model.pilot.state = engine.player

        // Spaceport news is NOT force-shown on landing — the original never
        // interrupted every dock with a news dialog. It's on-demand instead,
        // behind the bar's "Holovid" button (`HolovidView`), which reads the
        // same `engine.stationNews(forGovt:)` feed when the player chooses to
        // watch it. See docs/reverse-engineering — the beta history calls this
        // the "holovid dialog."
    }

    /// A mission special-ship reached its player-side goal in combat (destroyed /
    /// disabled / boarded). Run the matching engine hook so the objective count
    /// falls; if it was the last ship and the mission has no return leg, the
    /// engine completes and pays out here (its text surfaces via
    /// `flightMissionServices.storyText`). Missions with a return leg finish when
    /// the player next lands there (`handleStoryLanding`).
    private func handleMissionShipGoalReached(missionID: Int, goal: MissionShipGoal) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        switch goal {
        case .disable:        engine.missionShipDisabled(missionID: missionID)
        case .board, .rescue: engine.missionShipBoarded(missionID: missionID)
        default:              engine.missionShipDestroyed(missionID: missionID)
        }
        model.pilot.state = engine.player
        model.autosave(reason: .timer)
    }

    /// Drop any active mission's special **and** auxiliary ships into the live
    /// world when the player is in the matching system. Goal ships
    /// (`ShipCount`/`ShipDude`/`ShipGoal`/`ShipBehav`, arriving per `ShipStart`)
    /// carry the player-side objective; aux ships (`AuxShipCount`/`AuxShipDude`,
    /// in `AuxShipSyst`) are pure atmosphere with no goal. Deduped by the scene
    /// (one `hasMissionShips` guard per mission), so re-entering a system or a
    /// per-frame `syncNav` never stacks duplicate sets. The single-system engine
    /// can't resolve the galaxy map, so the system-match decision lives here.
    private func spawnActiveMissionShips() {
        guard let scene = host?.scene, let game = model.data.game else { return }
        let currentSys = nav.currentSystemID
        for am in model.pilot.state.activeMissions {
            guard let m = game.mission(am.missionID), !scene.hasMissionShips(m.id) else { continue }

            // Goal ships. Escort/observe are passive (they complete by landing, so
            // their objective count is 0) — those always (re)spawn while the
            // mission is active; kill/disable/board objectives don't respawn once
            // met (`shipObjectivesRemaining == 0`).
            let passiveGoal = m.shipGoal == .escort || m.shipGoal == .observe
            if m.hasShipObjective, (passiveGoal || am.shipObjectivesRemaining > 0),
               missionSystemMatches(code: m.shipSystem, active: am, currentSystem: currentSys, game: game) {
                scene.spawnMissionShips(missionID: m.id, dudeID: m.shipDude,
                                        count: max(1, m.shipCount), goal: m.shipGoal,
                                        behavior: m.shipBehaviorMode, government: nil,
                                        arrival: arrivalMode(forShipStart: m.shipStart))
            }

            // Auxiliary (flavor) ships — no goal, standard AI.
            if m.auxShipCount > 0, m.auxShipDude >= 128,
               missionSystemMatches(code: m.auxShipSystem, active: am, currentSystem: currentSys, game: game) {
                scene.spawnMissionShips(missionID: m.id, dudeID: m.auxShipDude,
                                        count: m.auxShipCount, goal: .none,
                                        behavior: .standard, government: nil, arrival: .populate)
            }
        }
    }

    /// An escort/rescue ship the player was protecting was destroyed — fail the
    /// mission (the engine's `missionShipLost` is a no-op if it already completed
    /// or wasn't an escort/rescue goal).
    private func handleMissionShipLost(missionID: Int) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.missionShipLost(missionID: missionID)
        model.pilot.state = engine.player
        model.autosave(reason: .timer)
    }

    /// Fail every active mission whose static `mïsn` matches `predicate` (the
    /// `fail-if-scanned/disabled/boarded` conditions). Snapshots the id list
    /// first since `failMission` mutates `activeMissions`, routes through the
    /// flight services so OnFailure/failure-text surface, and persists once.
    private func failActiveMissions(where predicate: (MissionRes) -> Bool, reason: String) {
        guard let game = model.data.game else { return }
        let ids = model.pilot.state.activeMissions.map(\.missionID)
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        var failedAny = false
        for id in ids {
            guard let m = game.mission(id), predicate(m) else { continue }
            engine.failMission(id)
            failedAny = true
        }
        guard failedAny else { return }
        model.pilot.state = engine.player
        host?.hud.post(reason)
        model.autosave(reason: .timer)
    }

    /// Map a `mïsn.ShipStart` code to a spawn arrival: `1` = jump in from
    /// hyperspace; everything else (nav-defaults −4…−1, random 0, cloaked 2) just
    /// appears in-system. The jump-in *delay* and cloak aren't modelled.
    private func arrivalMode(forShipStart code: Int) -> World.ArrivalMode {
        code == 1 ? .hyperspace : .populate
    }

    /// Whether a `ShipSyst`/`AuxShipSyst` selector `code` resolves to
    /// `currentSystem`. Handles −6 follow-player, −3/−4 the travel/return
    /// stellar's system, −1 the accept ("initial") system, −5 a system adjacent
    /// to the initial, −2 a deterministic random system (stable per mission), and
    /// a specific id.
    private func missionSystemMatches(code: Int, active am: ActiveMission,
                                      currentSystem: Int, game: NovaGame) -> Bool {
        func systemOf(_ spob: Int?) -> Int? {
            spob.flatMap { s in game.systems().first { $0.spobs.contains(s) }?.id }
        }
        switch code {
        case -6:                       return true                              // follow the player
        case -3:                       return systemOf(am.travelSpobID) == currentSystem
        case -4:                       return systemOf(am.returnSpobID) == currentSystem
        case -1:                       return am.acceptSystemID == currentSystem // initial
        case -5:                                                                 // adjacent to initial
            guard let initial = am.acceptSystemID else { return false }
            return game.system(initial)?.links.contains(currentSystem) ?? false
        case -2:                                                                 // random, frozen per mission
            let systems = game.systems().map(\.id).sorted()
            guard !systems.isEmpty else { return false }
            let h = UInt64(bitPattern: Int64(am.missionID)) &* 0x9E3779B97F4A7C15
            return systems[Int(h % UInt64(systems.count))] == currentSystem
        case let sid where sid >= 128: return sid == currentSystem              // specific
        default:                       return false
        }
    }

    /// Story `M`/`N` op: relocate the player to `systemID`. The persistent
    /// `currentSystem` is already updated by the engine; when the player is in
    /// flight we rebuild the world in place for the new system (same fresh-build
    /// path as the initial entry). When landed, the change takes effect on the
    /// next takeoff. `keepPosition` (N vs M) is honoured by the world build's
    /// own spawn placement; we don't preserve exact x/y across the rebuild yet.
    private func movePlayerToSystem(_ systemID: Int, keepPosition: Bool) {
        model.pilot.state.currentSystem = systemID
        model.pilot.state.exploredSystems.insert(systemID)
        guard landedSpobID == nil, let game = model.data.game, game.system(systemID) != nil else { return }
        // N-op keeps the player's exact x/y relative to system centre; M-op drops
        // them at the new system's default entry. Capture before the rebuild.
        let keptPosition = keepPosition ? host?.scene.playerShip?.position : nil
        nav.configure(game: game, startSystemID: systemID)
        hostSystemID = systemID
        host = GameHost(model: model, systemID: systemID)
        debug.attach(host?.scene)
        setScenePaused(false, reason: "story relocate")
        syncNav(host)
        if let keptPosition { host?.scene.playerShip?.position = keptPosition }
        grabSceneFocus(reason: "story relocate")
        host?.hud.post("Relocated to \(game.system(systemID)?.name ?? "a new system").")
    }

    /// Rebuild the flight host in place for the *current* system — used when a
    /// story effect changes the live ship mid-flight and we need the new hull to
    /// appear immediately (the swap is already in `PlayerState`, so the rebuild
    /// picks it up via `GameHost.buildPlayerShip`). No-op while landed (the
    /// takeoff rebuild covers that path).
    private func rebuildFlightHost(reason: String) {
        guard landedSpobID == nil else { return }
        let sys = nav.currentSystemID
        hostSystemID = sys
        host = GameHost(model: model, systemID: sys)
        debug.attach(host?.scene)
        setScenePaused(false, reason: reason)
        syncNav(host)
        grabSceneFocus(reason: reason)
    }

    /// Short calendar date for the message log, e.g. "23 Jun 1177".
    private static func logDate(_ d: GameDate) -> String {
        let m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let mon = (1...12).contains(d.month) ? m[d.month - 1] : "\(d.month)"
        return "\(d.day) \(mon) \(d.year)"
    }

    /// Landing services at an **inhabited port**. Shields recharge for free (they
    /// regen anywhere while docked). Hull repair, though, costs money, billed
    /// automatically on landing like the original — free only at an allied/owned
    /// port (the port's govt runs "Roadside Assistance", gövt 0x0010, or you hold a
    /// rank from it with the free-repair flag 0x0800; the Bible's routes to free
    /// service, the same test the paid Recharge uses). If the player can't afford a
    /// full repair, the hull is patched as far as their credits stretch. Fuel is
    /// never topped off here — that's the paid Recharge service. Uninhabited rocks
    /// give nothing. Writes both the live ship and the persisted pilot so the state
    /// survives the takeoff `GameHost` rebuild.
    private func repairOnLanding(spobID: Int) {
        guard let ship = host?.scene.playerShip else { return }
        if let game = host?.game, let spob = game.spob(spobID), !spob.isUninhabited {
            ship.shield = ship.maxShield                    // shields regen free
            let missing = ship.maxArmor - ship.armor
            if missing > 0.5 {
                if repairIsFree(spob: spob, game: game) {
                    ship.armor = ship.maxArmor
                } else {
                    // ~2cr per hull point (hull is pricier than fuel). Full repair
                    // if affordable, otherwise patch up as far as credits allow.
                    let creditsPerPoint = 2.0
                    let fullCost = Int((missing * creditsPerPoint).rounded())
                    let credits = model.pilot.state.credits
                    if credits >= fullCost {
                        model.pilot.state.credits -= fullCost
                        ship.armor = ship.maxArmor
                        if fullCost > 0 { host?.hud.post("Hull repaired — \(fullCost)cr.") }
                    } else if credits > 0 {
                        ship.armor = min(ship.maxArmor, ship.armor + Double(credits) / creditsPerPoint)
                        model.pilot.state.credits = 0
                        host?.hud.post("Hull partially repaired — \(credits)cr (not enough for a full repair).")
                    } else {
                        host?.hud.post("Not enough credits to repair your hull.")
                    }
                }
            }
        }
        model.pilot.state.armor = ship.armor
        model.pilot.state.shield = ship.shield
    }

    /// Free hull repair / refuel when the port's govt or your rank comps it — the
    /// Bible's "Roadside Assistance" (gövt flags1 0x0010) or an allied rank (rank
    /// flags 0x0800), i.e. an allied/owned world. Mirrors `SpaceportView`'s
    /// `rechargeIsFree` so paid refuel and paid repair agree on who's "allied".
    private func repairIsFree(spob: SpobRes, game: NovaGame) -> Bool {
        let govtID = spob.government
        if govtID >= 128, let g = game.govt(govtID), g.flags1 & 0x0010 != 0 { return true }
        return model.pilot.state.activeRanks.contains {
            game.rank($0)?.govt == govtID && (game.rank($0)?.flags ?? 0) & 0x0800 != 0
        }
    }

    /// Persists whatever combat/legal-standing consequences played out this
    /// session into the pilot: legal record (attacking a government's ships
    /// dents standing with it — see `Diplomacy.recordDisable`/`recordKill`)
    /// and combat rating (Appendix I — sum of destroyed ships' `Strength`).
    /// Call at every point the live `World`/`Diplomacy` might otherwise be
    /// discarded (landing, jump-out) or the app might be backgrounded —
    /// mirrors `repairOnLanding`'s "sync live scene state into the persisted
    /// pilot" pattern for the same reason (a jump rebuilds `GameHost`, and
    /// with it a brand-new, unseeded-until-`GameHost.init` `Diplomacy`).
    private func syncCombatStanding() {
        guard let scene = host?.scene else { return }
        for (govt, value) in scene.liveLegalRecord {
            model.pilot.state.legalRecord[govt] = value
        }
        let delta = scene.consumeCombatRatingDelta()
        if delta != 0 { model.pilot.state.combatRating += delta }
    }

    /// The single path a hyperjump commits through, whether triggered from the
    /// map's JUMP button or the `J` key. Rather than instantly swapping systems
    /// (which read as "the HUD says I've arrived but I still see the old system"),
    /// this hands the whole thing to the live scene: it flies the jump maneuver
    /// (turn → tear away → white flash) and swaps the world *in place* at the
    /// flash peak. The `commit` closure — run by the scene at that peak — is what
    /// actually advances the model (spend fuel, follow the pilot, save), so
    /// `nav.currentSystemID`/the HUD only change at the moment you truly arrive.
    @discardableResult
    private func attemptJump() -> Bool {
        guard let host, !host.scene.isJumping else { return false }
        let hops = nav.nextJumpHopCount
        guard hops > 0, nav.canAfford(hops: hops) else { return false }
        // No-jump zone: you can't enter hyperspace too close to the system centre
        // (Bible: 1000px). The scene posts a "fly further out" message; close the
        // map (if it was the trigger) so that message is visible, and return `true`
        // (handled) so a `J` press doesn't then re-open the map over it — the
        // player has a course, they're just too close to use it yet.
        guard host.scene.canEnterHyperspace() else { nav.showingMap = false; return true }
        let destID = nav.route[hops - 1]
        let outbound = outboundHeading(from: nav.currentSystemID, to: destID)
        let instant = host.galaxy.map { model.pilot.hasInstantJump(galaxy: $0) } ?? false
        let speed = host.galaxy.map { model.pilot.jumpSpeedFactor(galaxy: $0) } ?? 1
        nav.showingMap = false
        host.scene.beginJump(to: destID, outboundHeading: outbound, instant: instant, speed: speed) {
            // Flash peak: commit the arrival in the model. `commitArrival` spends
            // the fuel and pins the destination even if the route drifted during
            // the animation, so nav and the loaded system can't disagree.
            hostSystemID = destID                              // set first: keeps onChange from also rebuilding the host
            _ = nav.commitArrival(at: destID, hops: hops)
            model.pilot.state.fuel = host.scene.playerShip?.fuel
            model.pilot.state.currentSystem = destID
            model.pilot.state.exploredSystems.insert(destID)
            advanceGameDay()                                   // each hyperjump is one calendar day
            model.pilot.save()
            model.autosave(reason: .jump)                      // EV Nova saves on every hyperjump
            syncNav(host)                                      // refresh course/HUD (ship instance persists the swap)
        }
        return true
    }

    /// Compass heading (world radians, 0 = up) from one system toward another on
    /// the galactic map — the direction the ship turns to before jumping. The map
    /// stores +y downward, so it's flipped into the world's +y-up convention
    /// (`Vec2.angle` == `atan2(x, y)`).
    private func outboundHeading(from: Int, to: Int) -> Double {
        guard let g = model.data.game, let a = g.system(from), let b = g.system(to),
              a.x != b.x || a.y != b.y else { return 0 }
        return atan2(Double(b.x - a.x), Double(-(b.y - a.y)))
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

    /// The authentic status-bar style to actually render, or nil to fall back to
    /// the port's own modern `GameHUDView`. Nil whenever the player is in the
    /// Nova Swift / "Modern interface" mode — even when the data ships an `ïntf`
    /// — so the modern HUD overlays the play area instead of the authentic
    /// sidebar reserving screen width. `GameHost` always builds `hudStyle`; the
    /// view decides per-frame whether to use it, so toggling the setting live
    /// swaps HUDs without rebuilding the host.
    private func activeHUDStyle(_ host: GameHost) -> AuthenticHUDStyle? {
        model.settings.modernUI ? nil : host.hudStyle
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
            let sidebarWidth = Self.sidebarWidth(in: geo.size, style: activeHUDStyle(host))
            let playWidth = max(0, geo.size.width - sidebarWidth)
            // Click/tap a ship to target it, a planet to set it as the nav
            // destination, or empty space to clear both selections — handled
            // natively in `GameScene.mouseDown`/`touchesBegan`, not via a
            // SwiftUI gesture (unreliable layered on `SpriteView`'s native view).
            SpriteView(scene: host.scene,
                       preferredFramesPerSecond: model.settings.frameRateCap.fps ?? 120,
                       options: [.ignoresSiblingOrder],
                       debugOptions: model.settings.showFPS ? [.showsFPS, .showsNodeCount] : [])
                .frame(width: playWidth, height: geo.size.height)
                .position(x: playWidth / 2, y: geo.size.height / 2)
                // Tie this view's identity to the scene instance. `SpriteView`
                // presents its `scene:` only when the underlying native view is
                // first created; handing it a *new* scene at the same structural
                // position — which `depart()` does when it rebuilds `host` to
                // pick up a newly-bought hull/outfits — does NOT re-present it.
                // The old scene keeps ticking (and reading the old
                // `InputController`) while the keyboard now writes to the new
                // host's input: keys reach one instance, the visible/ticking
                // scene reads the other. That split is the "movement breaks
                // after departing a planet/station" bug. Keying on the scene's
                // identity forces SwiftUI to rebuild the SpriteView (presenting
                // the new scene) on a host swap, while leaving the in-place
                // hyperjump — which reuses the same `host.scene` — untouched.
                .id(ObjectIdentifier(host.scene))
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
    }

    /// The on-screen flight controls show only during actual flight — hidden
    /// while landed or whenever a modal (map, menu, hail, a mobile panel, the
    /// plunder dialog, the debug suite) owns the screen, so they neither draw
    /// over nor steal touches from it.
    private var flightControlsVisible: Bool {
        landedSpobID == nil && !nav.showingMap && !showMenu && hailDialogState == nil
            && !showMissionsPanel && !showPilotInfoPanel && !showEscortsPanel
            && boardManifest == nil && !showDebugSuite
    }

    /// Push the touch steering mode (Settings ▸ Touch scheme) down to the live
    /// scene. Called on every host build and whenever the setting changes, so a
    /// jump-rebuilt scene keeps the player's choice.
    private func applyControlScheme() {
        host?.scene.tapToFlyEnabled = (model.settings.controlScheme == .tapToTurn)
    }

    /// The mobile action-menu panels (missions / pilot info / escorts), reusing
    /// the same authentic dialogs the in-game menu hosts. Extracted from `body`
    /// to keep that expression inside the type-checker's budget.
    @ViewBuilder private var mobilePanels: some View {
        if showMissionsPanel, let graphics = model.uiGraphics, let game = model.data.game {
            MissionInfoView(graphics: graphics, game: game, pilot: model.pilot,
                            onClose: { showMissionsPanel = false })
                .transition(.opacity)
        }
        if showPilotInfoPanel, let graphics = model.uiGraphics {
            Color.black.opacity(0.5).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showPilotInfoPanel = false }
            PlayerInfoView(graphics: graphics, pilot: model.pilot,
                           onJettison: { jettisonHold() },
                           onDone: { showPilotInfoPanel = false })
                .transition(.opacity)
        }
        if showEscortsPanel, let scene = host?.scene {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showEscortsPanel = false }
            let _ = escortRefresh   // re-read the roster after each order
            EscortsView(graphics: model.uiGraphics,
                        escorts: scene.escortRoster(),
                        records: model.pilot.state.escortWing,
                        game: model.data.game,
                        currentOrder: scene.escortOrder,
                        onCommand: { scene.commandEscorts($0); escortRefresh += 1 },
                        onRelease: { releaseEscort($0) },
                        onUpgrade: { upgradeEscort($0) },
                        onSell: { sellEscort($0) },
                        onClose: { showEscortsPanel = false })
                .shrinkToFitViewport()
                .transition(.opacity)
        }
        if let m = boardManifest, let scene = host?.scene {
            let _ = boardRefresh   // re-read after taking loot
            PlunderView(
                graphics: host?.graphics,
                targetName: m.name,
                cargoLines: m.cargo.map { PlunderLine(label: commodityLabel($0.commodity),
                                                      amount: "\($0.tons)") },
                creditsAboard: m.credits, ammoAboard: 0, energyAboard: 0,
                captureChance: m.captureChance,
                onTakeCargo: { plunderTakeCargo(scene, shipID: m.shipID) },
                onTakeCredits: { plunderTakeCredits(scene, shipID: m.shipID) },
                onTakeAmmo: {}, onTakeEnergy: {},
                onCaptureShip: { plunderCapture(scene, shipID: m.shipID) },
                onDemandTribute: { plunderTakeCredits(scene, shipID: m.shipID) },
                onDismiss: { boardManifest = nil })
                .transition(.opacity)
        }
    }

    /// A commodity's display name for the plunder manifest (best-effort — most
    /// hulks have empty holds, so this is rarely exercised).
    private func commodityLabel(_ id: Int) -> String {
        if let c = Commodity(rawValue: id) { return host?.game?.commodityName(c) ?? "Cargo" }
        return "Cargo"
    }

    private func refreshBoard(_ scene: GameScene, shipID: Int) {
        boardManifest = scene.boardManifest(shipID)
        boardRefresh += 1
    }

    private func plunderTakeCredits(_ scene: GameScene, shipID: Int) {
        let credits = scene.plunderCredits(shipID)
        guard credits > 0 else { return }
        model.pilot.state.credits += credits
        model.pilot.save()
        host?.hud.credits = model.pilot.state.credits
        host?.hud.post("Took \(credits) credits.")
        refreshBoard(scene, shipID: shipID)
    }

    private func plunderTakeCargo(_ scene: GameScene, shipID: Int) {
        let taken = scene.plunderCargo(shipID)
        guard !taken.isEmpty else { return }
        for (commodity, tons) in taken { model.pilot.state.cargo[commodity, default: 0] += tons }
        model.pilot.save()
        let total = taken.reduce(0) { $0 + $1.tons }
        host?.hud.post("Took \(total) tons of cargo.")
        refreshBoard(scene, shipID: shipID)
    }

    /// Grant a boarded përs ship's ItemClass outfit loot to the pilot (given
    /// automatically on boarding, per the Bible's "given out ... when boarded").
    private func grantBoardingLoot(_ m: World.BoardingManifest) {
        guard let scene = host?.scene else { return }
        let loot = scene.plunderOutfits(m.shipID)
        guard !loot.isEmpty else { return }
        for oid in loot { model.pilot.state.grantOutfit(oid) }
        model.pilot.save()
        let names = Set(loot.compactMap { host?.game?.outfit($0)?.name })
        host?.hud.post("Salvaged \(loot.count) item(s)\(names.isEmpty ? "" : ": \(names.sorted().joined(separator: ", "))").")
    }

    /// A boarded `pêrs` offering its LinkMission on boarding rather than
    /// hailing (`Flags` 0x0200) — same in-flight accept/decline panel as a hail.
    private func offerBoardedPersonMission(_ m: World.BoardingManifest) {
        guard let pid = host?.scene.personID(forEntity: m.shipID),
              let game = host?.game, let pers = game.pers(pid) else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        let enc = PersEncounter.hail(pers, player: model.pilot.state, game: game,
                                     engine: engine, boarding: true)
        presentPersMissionOffer(pid, missionID: enc.offerMissionID, engine: engine, game: game)
    }

    /// Surface a `pêrs`'s offered LinkMission as the in-flight accept/decline
    /// panel (mirrors the bar's `services.pendingOffer` flow).
    private func presentPersMissionOffer(_ personID: Int, missionID: Int?, engine: StoryEngine, game: NovaGame) {
        guard let missionID, let mission = game.mission(missionID) else { return }
        flightMissionEngine = engine
        flightMissionPersonID = personID
        engine.present(mission)
    }

    /// Accept the current in-flight `pêrs` LinkMission offer, honoring the
    /// person's deactivate/leave-after-acceptance flags.
    private func acceptFlightMissionOffer(_ offer: MissionOffer) {
        guard let engine = flightMissionEngine else { return }
        _ = engine.accept(offer.mission.id)
        model.pilot.state = engine.player
        if let pid = flightMissionPersonID, let pers = host?.game?.pers(pid) {
            // "Deactivate ship (don't make it show up again) after accepting
            // its LinkMission" (0x0100) — reuses the same not-yet-defeated
            // spawn-eligibility gate as a defeated pêrs, since the visible
            // effect (never spawns again) is identical.
            if pers.deactivateAfterMission {
                model.pilot.state.recordPersDefeated(pid)
            }
            // "Make ship leave after accepting its LinkMission" (0x0800).
            if pers.leaveAfterMission {
                host?.scene.sendPersonDeparting(personID: pid)
            }
        }
        model.pilot.save()
        flightMissionServices.pendingOffer = nil
        flightMissionEngine = nil
        flightMissionPersonID = nil
    }

    /// Decline the current in-flight `pêrs` LinkMission offer.
    private func declineFlightMissionOffer(_ offer: MissionOffer) {
        guard let engine = flightMissionEngine else { return }
        engine.decline(offer.mission.id)
        model.pilot.state = engine.player
        model.pilot.save()
        flightMissionServices.pendingOffer = nil
        flightMissionEngine = nil
        flightMissionPersonID = nil
    }

    private func plunderCapture(_ scene: GameScene, shipID: Int) {
        if let cap = scene.attemptCapture(shipID) {
            // A captured escort is FREE (no daily fee) — register it in the
            // persistent roster so it follows the player between systems and can
            // later be sold/upgraded at a shipyard.
            let name = cap.name.isEmpty ? (model.data.game?.ship(cap.shipType)?.name ?? "Escort") : cap.name
            let record = model.pilot.state.registerEscort(shipType: cap.shipType, name: name, origin: .captured)
            scene.tagEscort(entityID: cap.entityID, recordID: record.id)
            model.pilot.save()
            host?.hud.post("Ship captured — it joins your escorts.")
            boardManifest = nil
        } else {
            host?.hud.post("Capture attempt failed.")
            refreshBoard(scene, shipID: shipID)
        }
    }

    /// Release the escort with persistent `recordID` — the "Release from
    /// Servitude" hail action. Drops it from the pilot roster (a hired one stops
    /// billing) and flies the live ship off. Works whether or not it's currently
    /// spawned (e.g. released while the wing is between systems).
    private func releaseEscort(_ recordID: Int) {
        let released = model.pilot.state.removeEscort(id: recordID)
        model.pilot.save()
        host?.scene.despawnEscort(recordID: recordID)
        escortRefresh += 1
        if let released { host?.hud.post("\(released.name) leaves your command.") }
    }

    /// Upgrade captured escort `recordID` to its hull's `UpgradeTo` (charging
    /// `EscUpgrdCost`). The record's hull swaps now; the live ship takes the new
    /// hull the next time the wing respawns (on takeoff / entering a system).
    private func upgradeEscort(_ recordID: Int) {
        guard let game = model.data.game else { return }
        if let newHull = model.pilot.upgradeEscort(recordID: recordID, game: game) {
            model.pilot.save()
            escortRefresh += 1
            let name = game.ship(newHull)?.name ?? "a better ship"
            host?.hud.post("Escort upgrade purchased — becomes \(name) on takeoff.")
        } else {
            host?.hud.post("Can't upgrade that escort — not upgradeable or too costly.")
        }
    }

    /// Sell captured escort `recordID` for its `EscSellValue` and remove it.
    private func sellEscort(_ recordID: Int) {
        guard let game = model.data.game else { return }
        if let value = model.pilot.sellEscort(recordID: recordID, game: game) {
            model.pilot.save()
            host?.scene.despawnEscort(recordID: recordID)
            escortRefresh += 1
            host?.hud.post("Escort sold — \(value)cr.")
        }
    }

    /// Open one of the mobile action-menu panels over flight.
    private func openMobilePanel(_ panel: MobilePanel) {
        switch panel {
        case .missions:  showMissionsPanel = true
        case .pilotInfo: showPilotInfoPanel = true
        case .escorts:   showEscortsPanel = true
        }
    }

    /// Dump the hold — the mobile Pilot-info panel's "Jettison Cargo".
    private func jettisonHold() {
        model.pilot.state.cargo = [:]
        model.pilot.save()
    }

    private func handleDiscrete(_ action: GameAction) {
        // Ignore sim-affecting flight commands mid-jump — the scene has locked
        // control for the maneuver; landing or re-jumping through it would corrupt
        // the sequence (and pressing J would otherwise pop the map open).
        if host?.scene.isJumping == true {
            switch action { case .land, .hyperjump: return; default: break }
        }
        switch action {
        case .land:
            guard landedSpobID == nil, gateMapOrigin == nil, let scene = host?.scene else { break }
            if model.settings.autoLanding {
                // Auto-landing: fly to the targeted/nearest landable body and set
                // down on arrival. Pressing Land again cancels an in-progress
                // approach. Falls back to an immediate land if we're already
                // parked on a pad with nothing to fly to.
                if scene.isAutoLanding { scene.cancelAutoLand() }
                else if scene.beginAutoLandOnSelected() { /* autopilot engaged */ }
                else if let id = scene.attemptLand() { requestLanding(id) }
            } else if let id = scene.attemptLand() {
                // Classic: only when in range and slow.
                requestLanding(id)
            }
        case .openMenu, .pauseGame:
            if landedSpobID != nil { return }
            if gateMapOrigin != nil { gateMapOrigin = nil; return }
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
        case .selectSecondaryNext:
            host?.scene.cycleSecondaryWeapon(forward: true)
        case .selectSecondaryPrev:
            host?.scene.cycleSecondaryWeapon(forward: false)
        case .toggleCloak:
            host?.scene.togglePlayerCloak()
        case .launchFighters:
            host?.scene.launchPlayerFighters()
        case .recallFighters:
            host?.scene.recallPlayerFighters()
        case .board:
            // Board the targeted hulk if it's disabled and in reach.
            if let m = host?.scene.attemptBoard() {
                boardManifest = m
                grantBoardingLoot(m)   // përs ItemClass loot is handed over on boarding
                offerBoardedPersonMission(m)
            }
        default:
            break
        }
    }

    /// Hail whatever `GameScene.attemptHail()` resolves to — the current
    /// selection, ship or planet — and open the communication dialog.
    /// Silently does nothing with no selection — matches `attemptLand()`'s
    /// "no prompt, no action" pattern.
    private func hail() {
        guard let scene = host?.scene, let result = scene.attemptHail() else { return }
        switch result {
        case let .ship(entityID, name, shipTypeID, govt, hostile):
            model.audio.playHailVoice(govt: govt, hostile: hostile)
            var displayName = name
            var response = hostile ? "They aren't interested in talking." : "This is \(name). Go ahead."
            var customPictID: Int?
            // Named person (pêrs): replace the generic response with their comm
            // quote and note any mission they offer.
            if let pid = host?.scene.personID(forEntity: entityID),
               let game = host?.game, let pers = game.pers(pid) {
                let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
                let disabled = host?.scene.isEntityDisabled(entityID) ?? false
                let attacking = host?.scene.isEntityAttackingPlayer(entityID) ?? false
                let enc = PersEncounter.hail(pers, player: model.pilot.state, game: game,
                                             engine: engine, disabled: disabled, attacking: attacking)
                displayName = enc.name
                customPictID = enc.hailPictID
                if let quote = enc.commQuote ?? enc.hailQuote { response = quote }
                presentPersMissionOffer(pid, missionID: enc.offerMissionID, engine: engine, game: game)
                if pers.quoteOnce {
                    model.pilot.state.markPersQuoteShown(pid); model.pilot.save()
                }
            }
            hailDialogState = HailDialogState(
                kind: .ship(entityID: entityID, shipTypeID: shipTypeID),
                name: displayName, govtLabel: govt.targetCode, hostile: hostile,
                responseText: response, customPictID: customPictID)
        case let .planet(spobID, name, govt, landable):
            // Hostile when the player is deeply wanted by the stellar's govt
            // (a wanted rating turns its defenders on you) — read straight from
            // the pilot's own legal record so it needs no scene internals.
            let record = govt.flatMap { model.pilot.state.legalRecord[$0.id] } ?? 0
            let hostile = record <= -150
            hailDialogState = HailDialogState(
                kind: .planet(spobID: spobID), name: name, govtLabel: govt?.targetCode ?? "", hostile: hostile,
                landable: landable,
                // "Channel open to X" is the manual's own wording for a stellar hail.
                responseText: landable ? "Channel open to \(name)."
                                       : "Channel open to \(name). Landing clearance is not currently granted.")
        }
    }

    /// Price of asking `tier` for assistance, or nil if it won't help at all.
    private func assistanceCost(for tier: GameScene.AssistanceTier) -> Int? {
        switch tier {
        case .ally: return 0
        case .neutral: return assistanceCostNeutral
        case .wary: return assistanceCostWary
        case .unavailable: return nil
        }
    }

    /// Deduct credits and send the hailed ship over to dock with the player
    /// (see `AIBrain.assist`/`World.deliverAssistance`) — free for allies,
    /// paid for a neutral crew, and only sometimes accepted (at a premium,
    /// charged only on acceptance) by a crew that dislikes the player but
    /// isn't outright hostile. Declines in-dialog if the player can't afford
    /// it or the crew turns the request down.
    private func requestAssistance(entityID: Int) {
        guard var state = hailDialogState,
              let tier = host?.scene.assistanceTier(entityID: entityID),
              let cost = assistanceCost(for: tier) else { return }
        guard model.pilot.state.credits >= cost else {
            state.responseText = "You don't have enough credits for that."
            hailDialogState = state
            return
        }
        if tier == .wary, Double.random(in: 0..<1) > assistanceWaryAcceptChance {
            state.responseText = "Not interested. Try hailing someone who actually likes you."
            hailDialogState = state
            return   // declined — no charge
        }
        model.pilot.state.credits -= cost
        host?.scene.requestAssistance(entityID: entityID)
        state.assistRequested = true
        state.responseText = cost == 0 ? "Of course — they're on their way." : "They're on their way."
        hailDialogState = state
    }

    /// Ask a stellar for landing clearance. A non-hostile world grants it (the
    /// dialog switches to "cleared to land"); a hostile one refuses — you'd have
    /// to bribe or dominate it. Updates the open dialog in place.
    private func requestPlanetLanding() {
        guard var state = hailDialogState, case .planet = state.kind else { return }
        if state.hostile {
            state.responseText = "Request denied. You are not welcome here."
        } else {
            state.landable = true
            state.responseText = "Landing clearance granted. You are cleared to land."
        }
        hailDialogState = state
    }

    /// Demand tribute from a stellar — EV Nova's path to forcefully dominating a
    /// planet/station. Runs the real domination engine (`World.demandTribute` via
    /// the scene): a defended world scrambles its `spöb.DefenseDude` fleet in
    /// waves; break them all and demand again and it surrenders. The immediate
    /// `TributeOutcome` drives this dialog reply; wave launches and the surrender
    /// itself flow through `onStellarDefendersLaunched` / `onStellarDominated`
    /// (the latter persists the domination via `handleStellarDominated`).
    private func demandPlanetTribute() {
        guard var state = hailDialogState, case let .planet(spobID) = state.kind else { return }
        guard let outcome = host?.scene.demandTribute(
                spobID: spobID,
                combatRating: model.pilot.state.combatRating,
                alreadyDominated: model.pilot.state.dominatedStellars ?? []) else { return }
        switch outcome {
        case let .defending(launched):
            state.hostile = true
            state.landable = false
            state.responseText = launched > 0
                ? "\"You'll get nothing from us!\" The stellar scrambles its defenders."
                : "\"You'll get nothing from us!\" The stellar's defenders turn on you."
        case .stillDefending:
            state.hostile = true
            state.responseText = "\"Break our fleet first!\" Its defenders are still in the fight."
        case .dominated:
            // The .stellarDominated event also fires and runs handleStellarDominated
            // (which persists it and re-flips this dialog); set the reply now too so
            // the player sees it this frame rather than the next.
            state.hostile = false
            state.landable = true
            state.responseText = "The stellar submits to your demand. It is yours."
        case let .refused(reason):
            state.responseText = tributeRefusalText(reason, name: state.name)
        }
        hailDialogState = state
    }

    /// Flavor text for a rebuffed tribute demand (`TributeRefusal`), shown in the
    /// hail dialog reply.
    private func tributeRefusalText(_ reason: TributeRefusal, name: String) -> String {
        switch reason {
        case .combatRatingTooLow:
            return "\(name) laughs at your demand — you are not feared enough to be taken seriously."
        case .noDefenseFleet:
            return "\(name) has no fleet to defend it — there is no one here to compel."
        case .alreadyDominated:
            return "\(name) already answers to you."
        case .notDominatable:
            return "\(name) cannot be dominated."
        }
    }

    /// A stellar's defenses broke and it surrendered (`onStellarDominated`).
    /// Persist the domination through the story engine — this fires the stellar's
    /// `OnDominate` control bits and enrolls it for daily `Tribute` income
    /// (`StoryEngine.payDailyTribute`, run inside `advanceOneDay`) — then surface
    /// it and flip the hail dialog (if still open on this world) to friendly.
    private func handleStellarDominated(spobID: Int) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.dominateStellar(spobID)
        model.pilot.state = engine.player
        model.autosave(reason: .timer)
        let name = game.spob(spobID)?.name ?? "The stellar"
        host?.hud.post("\(name) submits to your rule — it will pay tribute daily.")
        if var state = hailDialogState, case let .planet(id) = state.kind, id == spobID {
            state.hostile = false
            state.landable = true
            state.responseText = "The stellar submits to your demand. It is yours."
            hailDialogState = state
        }
    }

    private func hailShowsAssistButton(_ state: HailDialogState) -> Bool {
        if case .ship = state.kind { return true }
        return false
    }

    private func hailAssistEnabled(_ state: HailDialogState) -> Bool {
        guard case let .ship(entityID, _) = state.kind, !state.assistRequested else { return false }
        return (host?.scene.assistanceTier(entityID: entityID) ?? .unavailable) != .unavailable
    }

    private func hailPortrait(_ state: HailDialogState) -> CGImage? {
        // A pêrs's custom HailPict (Bible: shown "in the comm dialog instead
        // of the ship's default") wins over the default ship/planet portrait.
        if let pictID = state.customPictID, let custom = host?.graphics?.pict(pictID) {
            return custom
        }
        switch state.kind {
        case let .ship(_, shipTypeID):
            guard let res = host?.game?.ship(shipTypeID) else { return nil }
            return host?.graphics?.shipPicture(res)
        case let .planet(spobID):
            // A stellar comm shows the world/station itself — its **space
            // sprite** (the sphere or station you see in-system), not the
            // ground-level landing landscape. Fall back to the landscape only if
            // the spob defines no sprite.
            if let sprite = host?.game?.spobSprite(spobID)?.frameCGImage(0) { return sprite }
            guard let spob = host?.game?.spob(spobID) else { return nil }
            return host?.graphics?.landscape(for: spob)
        }
    }

    /// The developer entry point shown while debug mode is on: a debug button
    /// and a live fps/ship chip, tucked under the menu button (clear of the
    /// right-edge status bar). Both open the full debug suite.
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showDebugSuite = true } label: {
                        Image(systemName: "ladybug.fill")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color(red: 0.35, green: 0.95, blue: 0.5).opacity(0.5)))
                            .foregroundStyle(Color(red: 0.35, green: 0.95, blue: 0.5))
                    }
                    .buttonStyle(.plain)
                    DebugMetricsChip(debug: debug) { showDebugSuite = true }
                }
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 14)
        .padding(.top, 68)   // below the hamburger menu button
        .opacity(showDebugSuite || showMenu ? 0 : 1)
        .allowsHitTesting(!showDebugSuite && !showMenu)
        .zIndex(15)
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

/// Shown while `GameHost` builds the live scene (ship + planet sprites, HUD
/// art) for the destination system — a synchronous decode that can take a
/// visible moment on mobile hardware. Matches `LoadingView`'s starfield/
/// wordmark treatment so this brief gap reads as an intentional loading
/// screen rather than a stalled black one.
private struct GameLoadingView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            StarfieldBackground()

            VStack(spacing: 18) {
                AppLogo()
                    .frame(width: 88, height: 88)
                    .shadow(color: novaAmber.opacity(0.28), radius: 28)
                    .scaleEffect(pulse ? 1.03 : 1.0)

                Text("NOVA SWIFT")
                    .novaFont(.title, weight: .heavy, size: 34)
                    .tracking(8)
                    .foregroundStyle(.white)

                LinearGradient(colors: [.clear, novaAmber.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 260, height: 1)

                ProgressView()
                    .tint(novaAmber)
                    .scaleEffect(1.2)
                    .padding(.top, 8)

                Text("Entering the system…")
                    .novaFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// The land prompt at the bottom-centre of the screen. On macOS it's the plain
/// EV Nova on-screen text hint ("Press L to land on …"). On iOS the desktop
/// keyboard hint is meaningless, so when you're cleared to set down it becomes a
/// **tappable amber "Land" pill** — the actual control, not a description of one
/// — falling back to a plain "Slow down…" hint when you're too fast.
private struct LandPromptView: View {
    @ObservedObject var hud: GameHUDModel
    var onLand: () -> Void = {}
    /// Width of the HUD sidebar this screen is reserving on the right (see
    /// `GameContainerView.sidebarWidth`), so the prompt centres on the actual
    /// play viewport instead of the full window.
    var rightInset: CGFloat = 0

    /// On iOS the safe area already clears the home indicator, and the touch
    /// controls anchor only a few points beyond it — a bigger gap here read as
    /// the prompt floating well above where the controls sit. On macOS there's
    /// no safe area to lean on, so it keeps its own clearance from the window edge.
    private var bottomPadding: CGFloat {
        #if os(iOS)
        14
        #else
        30
        #endif
    }

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            .padding(.trailing, rightInset)
            .padding(.bottom, bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .novaResponsive()
        .animation(.easeInOut(duration: 0.15), value: hud.landPrompt)
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if hud.landReady, !hud.landName.isEmpty {
            Button(action: onLand) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Land on \(hud.landName)").lineLimit(1)
                }
                .novaFont(.hud, weight: .semibold, size: 12)
                .foregroundStyle(.black)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Capsule().fill(novaAmber))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if !hud.landName.isEmpty {
            hint("Slow down to land on \(hud.landName)").allowsHitTesting(false)
        }
        #else
        if !hud.landPrompt.isEmpty { hint(hud.landPrompt).allowsHitTesting(false) }
        #endif
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            #if os(iOS)
            .novaFont(.hud, weight: .semibold, size: 12)
            #else
            .novaFont(.hud, weight: .semibold)
            #endif
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .transition(.opacity)
    }
}

/// The rolling bottom-left message log: the calendar date on each jump/land,
/// hail replies, mission notices and any other transient game message, as plain
/// stacked text that fades out on its own timer (`GameHUDModel.post`). No panel
/// or border — just the log, like the original.
private struct MessageLogView: View {
    @ObservedObject var hud: GameHUDModel

    /// Mirrors `LandPromptView.bottomPadding` — sits just above the safe area
    /// (which already clears the home indicator) instead of floating a fixed
    /// window-edge distance above it.
    private var bottomPadding: CGFloat {
        #if os(iOS)
        14
        #else
        24
        #endif
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(hud.messages) { m in
                        Text(m.text)
                            #if os(iOS)
                            .novaFont(.hud, weight: .semibold, size: 12)
                            #else
                            .novaFont(.hud, weight: .semibold)
                            #endif
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                            .transition(.opacity)
                    }
                }
                Spacer()
            }
            .padding(.leading, 16).padding(.bottom, bottomPadding)
        }
        .novaResponsive()
        .allowsHitTesting(false)
    }
}

/// State for the open hail/communication dialog (`HailDialogView`).
/// `responseText`/`assistRequested` mutate in place as the player clicks buttons,
/// so the dialog updates without closing.
struct HailDialogState {
    enum Kind {
        case ship(entityID: Int, shipTypeID: Int)
        case planet(spobID: Int)
    }
    let kind: Kind
    let name: String
    let govtLabel: String
    /// Mutable: demanding tribute turns a stellar hostile in place.
    var hostile: Bool
    /// Whether the player currently has landing clearance here (planet hails).
    var landable = true
    var responseText: String
    var assistRequested = false
    /// A `pêrs`'s custom `HailPict`, when this hail is with a named character
    /// that specifies one — overrides the default ship/planet portrait.
    var customPictID: Int? = nil
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
