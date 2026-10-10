import SwiftUI
import Combine
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory
import NovaSwiftNet

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

    /// The OS memory-pressure watcher (both platforms). Held so it stays alive and
    /// can be cancelled in `deinit`.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Release every re-derivable sprite/texture cache in response to system
    /// memory pressure: the decoded-sheet pool in `NovaGame`, the scene's
    /// cross-system texture caches, and the target-silhouette cache. Everything
    /// dropped re-decodes (cheaply, from the disk cache) on next use — the cost is
    /// a brief rebuild, the payoff is not getting jettisoned by the OS.
    func evictSpriteCaches(reason: String) {
        let released = game?.flushSpriteSheets() ?? 0
        scene.evictTextureCaches()
        targetSpriteCache.removeAll()
        Log.scene.notice("memory pressure (\(reason, privacy: .public)): flushed \(released, privacy: .public) sprite sheet(s) + scene texture caches")
    }

    /// Start watching for OS memory pressure and flush re-derivable caches when it
    /// arrives. `DispatchSource` (rather than the iOS-only memory-warning
    /// notification) so one seam covers iOS and macOS.
    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let critical = self.memoryPressureSource?.data.contains(.critical) ?? false
                self.evictSpriteCaches(reason: critical ? "critical" : "warning")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit { memoryPressureSource?.cancel() }

    init(model: AppModel, systemID: Int? = nil, arrivedViaJump: Bool = false) {
        controller = GameControllerInput(input: input)
        controller.bindings = model.padBindings
        hudStyle = GameHost.makeHUDStyle(model.data.game, shipType: model.pilot.state.shipType)
        hud.credits = model.pilot.state.credits
        scene.scaleMode = .resizeFill

        let pilot = model.pilot.state
        let ship: Ship
        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        var shieldTextures: [SKTexture] = []
        var lightTextures: [SKTexture] = []
        var weaponGlowTextures: [SKTexture] = []
        var altTextures: [SKTexture] = []
        var hullAnim = HullAnim()
        var planets: [PlanetVisual] = []
        var systemName = ""
        var buoyMessage: String?
        var aiGame: NovaGame?
        var aiGalaxy: Galaxy?
        var aiSystemID = 0

        if let game = model.data.game {
            // Build the player's ship from the *pilot*: its current hull + every
            // installed outfit → real shields/armor/fuel/afterburner/cargo and a
            // resolved weapon set. The pilot's cargo is carried into the hold.
            let galaxy = Galaxy(game: game, flightTuning: FlightTuning(enhancements: model.settings.enhancements))
            aiGame = game
            aiGalaxy = galaxy
            let target = systemID ?? pilot.currentSystem
            // A fresh Galaxy means a fresh Diplomacy (`makeDiplomacy()` caches
            // per-Galaxy, and every jump rebuilds `GameHost` from scratch) — seed
            // it with the pilot's per-system reputation (EC-02) so standing
            // survives across jumps. `currentSystemID`/`game` are what the
            // hostility ladder reads and where a crime's flood starts.
            let dip = galaxy.makeDiplomacy()
            dip.currentSystemID = target
            dip.game = game
            dip.seed(reputation: pilot.systemReputation ?? [:])
            // Ranks with "govt won't attack" (Flags 0x0100) shield the player
            // from that government's ships for as long as the rank is held.
            dip.rankProtectedGovts = Set(pilot.activeRanks
                .compactMap { game.rank($0) }
                .filter { $0.govtWontAttack && $0.govt >= 128 }
                .map { $0.govt })
            // Every active rank's flags: the ship comm window reads 0x0400 / 0x0800
            // from ranks allied with the hailed ship (AI-42).
            dip.activeRankFlags = pilot.activeRanks.sorted()
                .compactMap { game.rank($0) }
                .filter { $0.govt >= 128 }
                .map { (govt: $0.govt, flags: $0.flags) }
            // Player ship + sprite textures from the current pilot loadout (see
            // `buildPlayerShip`) — the exact same construction the in-place
            // takeoff reload (`GameScene.reloadForDeparture`) uses, so a newly
            // bought hull/outfit takes effect identically on both paths.
            let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
            ship = session.ship
            textures = session.textures
            engineTextures = session.engineTextures
            shieldTextures = session.shieldTextures
            lightTextures = session.lightTextures
            weaponGlowTextures = session.weaponGlowTextures
            altTextures = session.altTextures
            hullAnim = session.hullAnim
            hud.shipName = session.shipName
            // Load the requested system (or the pilot's current one — every call
            // site passes an explicit systemID today, but this stays as a safe
            // default if that ever changes). `target` was already resolved above
            // to seed `dip`; this can still fall back to `startingSystem()` if
            // `target` doesn't resolve to real data, so correct `dip`'s origin
            // to match in that rare case.
            let targetSystem = game.system(target) ?? game.startingSystem()
            if let system = targetSystem {
                systemName = system.name
                aiSystemID = system.id
                dip.currentSystemID = system.id
                // Message buoy (sÿst.Message → STR# 1000, 1-based): shown on
                // arriving in a system that has one.
                if arrivedViaJump, let text = game.systemMessageText(system.message) {
                    buoyMessage = text
                }
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
                    // `spöb.X/Y` is authored +y-down (same convention as `sÿst.X/Y`);
                    // flip to this engine/SpriteKit's +y-up world.
                    return PlanetVisual(id: spob.id, name: spob.name,
                                        position: CGPoint(x: spob.x, y: -spob.y),
                                        texture: tex, radius: radius,
                                        government: spob.government,
                                        isUninhabited: spob.isUninhabited || wreck)
                }
                // Placement. Loading a pilot that was saved while docked lifts off
                // from that pad — EV Nova only saves on landing, so "where I saved"
                // is a planet, and the player expects to resume *there*, not dumped
                // at the system centre. Mirror the takeoff math in
                // `GameScene.reloadForDeparture`: sit just clear of the body's
                // surface, nosed outward, at rest. Otherwise, use the raw in-flight
                // position/heading captured by `GameContainerView.saveGame` (every
                // autosave, not just on landing) — that's what lets a save taken
                // mid-flight resume exactly where it was instead of at the system
                // centre. Only a legacy save with neither field falls back to the
                // generic "a little south of centre so planets are in view."
                let sysCtx = galaxy.systemContext(for: system.id)
                if let sid = pilot.landedSpob,
                   let body = sysCtx.bodies.first(where: { $0.id == sid }) {
                    // The original's launch: at the stellar's centre, at rest,
                    // on a random whole-degree heading (FL-20).
                    ship.position = body.position
                    ship.angle = Double(Int.random(in: 0..<360)) * .pi / 180
                    ship.velocity = Vec2()
                } else if let x = pilot.shipPositionX, let y = pilot.shipPositionY {
                    ship.position = Vec2(x, y)
                    ship.angle = pilot.shipHeading ?? 0
                    ship.velocity = Vec2()
                } else {
                    ship.position = sysCtx.center + Vec2(0, -700)
                }
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
        // Vary the spawn RNG seed by the in-game day so re-entering a system doesn't
        // reproduce the identical ships. Set BEFORE configure (which builds the
        // initial world) and read live on later in-scene rebuilds (jump/takeoff),
        // which run after the calendar advances.
        let seedPilot = model.pilot
        scene.worldSeedDayProvider = { [weak seedPilot] in seedPilot?.state.date.julianDay ?? 0 }
        scene.strictPlay = model.pilot.state.isStrictPlay
        scene.playerCombatRatingProvider = { [weak seedPilot] in seedPilot?.state.combatRating ?? 0 }
        // AI-13 / AI-15: reinforcement retrigger days and stellar garrisons
        // persist in the save; the scene seeds every world it builds from them
        // and hands back what each visit changed.
        scene.defenseStateProvider = { [weak seedPilot] in
            (seedPilot?.state.reinforcementRetriggerDays ?? [:], seedPilot?.state.stellarGarrisons ?? [:])
        }
        scene.broadcastContextProvider = { [weak seedPilot] in
            guard let state = seedPilot?.state, let game = aiGame else { return ("", 0) }
            var mask: UInt16 = 0
            for am in state.activeMissions where am.isCarryingCargo {
                mask |= UInt16(truncatingIfNeeded: game.mission(am.missionID)?.scanMask ?? 0)
            }
            return (state.pilotName, mask)
        }
        scene.onReinforcementsCalled = { [weak seedPilot] systemID, days in
            guard let seedPilot else { return }
            var delays = seedPilot.state.reinforcementRetriggerDays ?? [:]
            delays[systemID] = max(delays[systemID] ?? 0, days)
            seedPilot.state.reinforcementRetriggerDays = delays
        }
        scene.onGarrisonSnapshot = { [weak seedPilot] changes in
            guard let seedPilot else { return }
            var garrisons = seedPilot.state.stellarGarrisons ?? [:]
            for (spobID, count) in changes { garrisons[spobID] = count }
            seedPilot.state.stellarGarrisons = garrisons.isEmpty ? nil : garrisons
        }
        scene.configure(player: ship, textures: textures, engineTextures: engineTextures,
                        shieldTextures: shieldTextures,
                        lightTextures: lightTextures, weaponGlowTextures: weaponGlowTextures,
                        altTextures: altTextures,
                        hullAnim: hullAnim,
                        settings: model.settings,
                        input: input, controller: controller, hud: hud, audio: model.audio,
                        planets: planets, systemName: systemName,
                        game: aiGame, systemID: aiSystemID, galaxy: aiGalaxy,
                        arrivedViaJump: arrivedViaJump)

        // Surface the system's message-buoy text (if any) once the scene is up.
        if let buoyMessage { hud.post(buoyMessage) }

        // Contraband scanning: when a government ship finishes scanning the
        // player, its government checks the player's holds/equipment against its
        // `ScanMask` and fines (`ScanFine`) / logs smuggling (`SmugPenalty`).
        // The consequence needs live pilot state, so it's wired from here.
        if let scanGame = aiGame {
            let pilotStore = model.pilot
            scene.onPlayerScanned = { [weak pilotStore, weak hud, weak scene] scannerGovt in
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
                guard let result = ContrabandScan.enforce(on: &pilotStore.state, game: scanGame,
                                                           govtID: scannerGovt, recordCrime: false),
                      result.foundContraband else { return }
                // The smuggling flood goes to the live per-system record (EC-02).
                if result.smugglingPenalty > 0 { scene?.recordSmuggling(against: scannerGovt) }
                let name = scanGame.govt(scannerGovt)?.displayName ?? "Patrol"
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

            // IFF (oütf ModType 14, "colorized radar"): EV Nova only tints radar
            // blips by allegiance when the player's ship carries an IFF outfit;
            // without one, contacts are a single neutral color. Resolve the player's
            // full loadout (hull preinstalled + owned outfits) and check for it.
            scene.playerHasIFF = aiGalaxy
                .flatMap { PilotEconomy.loadout(model.pilot.state, galaxy: $0) }?
                .outfits.keys.contains { scanGame.outfit($0)?.has(.iff) == true } ?? false

            // pêrs (named characters): seed grudges, gate appearances on their
            // ActiveOn NCB + not-yet-defeated, and persist grudge/defeat outcomes.
            scene.persGrudges = model.pilot.state.persGrudges ?? []
            scene.destroyedStellarIDs = model.pilot.state.destroyedStellars ?? []
            // A damaged destroyable stellar is still damaged on return (OS-13).
            scene.stellarStrengthLeft = { [weak pilotStore] in pilotStore?.state.stellarStrengthLeft ?? [:] }
            scene.persSpawnEligible = { [weak pilotStore] id in
                guard let store = pilotStore else { return true }
                if store.state.isPersDefeated(id) { return false }
                guard let pers = scanGame.pers(id), !pers.activeOn.isEmpty else { return true }
                return StoryEngine(game: scanGame, player: store.state).evaluate(test: pers.activeOn)
            }
            // shïp.AppearOn: a hull with a non-blank AppearOn test only appears in
            // düde spawns while its control-bit expression passes against live bits.
            scene.shipSpawnEligible = { [weak pilotStore] id in
                guard let store = pilotStore else { return true }
                guard let ship = scanGame.ship(id), !ship.appearOn.isEmpty else { return true }
                return StoryEngine(game: scanGame, player: store.state).evaluate(test: ship.appearOn)
            }
            // Mining: the player's scoop collected a destroyed asteroid's yield —
            // add it to cargo (clamped to free hold) and report what was stowed.
            scene.onAsteroidMined = { [weak pilotStore] cargoType, quantity in
                guard let store = pilotStore, let commodity = Commodity.standard(cargoID: cargoType) else { return nil }
                let stowed = store.collectCargo(id: cargoType, tons: quantity, galaxy: Galaxy(game: scanGame))
                guard stowed > 0 else { return nil }
                return (stowed, scanGame.commodityName(commodity))
            }
            // Tribbles breed and perishables rot in flight (EC-24).
            scene.onJunkCargoEvent = { [weak pilotStore] in
                _ = pilotStore?.runJunkCargoEvent(galaxy: Galaxy(game: scanGame))
            }
            if let holdGalaxy = aiGalaxy {
                scene.playerHoldHasRoom = { [weak pilotStore] in
                    guard let store = pilotStore else { return false }
                    return PilotEconomy.cargoFree(store.state, galaxy: holdGalaxy) > 0
                }
            }
            scene.onPersGrudge = { [weak pilotStore] pid in
                pilotStore?.state.recordPersGrudge(pid); pilotStore?.save()
            }
            scene.onPersDefeated = { [weak pilotStore] pid in
                pilotStore?.state.recordPersDefeated(pid); pilotStore?.save()
            }
            // The pilot is lost: the death sequence ran out with no eject
            // (OS-02; ejecting and the pod's respawn are handled in the
            // container). A real game-over — the explosion gets a moment to
            // play out before returning to the main menu. Nothing is saved, so
            // the pilot resumes from its last launch; under Strict Play the
            // pilot is deleted outright (FL-03).
            scene.onPlayerDestroyed = { [weak pilotStore] in
                guard let pilotStore else { return }
                if pilotStore.state.strictPlayDeathDeletesPilot { model.deleteStrictPlayPilot() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    model.returnToMainMenu()
                }
            }
            // Co-op (Layer 2): let the live multiplayer session drive per-system
            // sim sync around each step. No-ops unless ≥2 players share the system.
            scene.syncPreStep = { world in model.session.syncPreStep(world: world) }
            scene.syncPostStep = { world in model.session.syncPostStep(world: world) }
            // Co-op: the lobby's shared game-speed (host-set, broadcast via
            // `SessionRules`) overrides each device's own local setting so the
            // whole lobby's sims share one clock instead of drifting apart.
            scene.gameSpeedMultiplierOverride = {
                model.session.isActive ? model.session.rules.gameSpeedMultiplier : nil
            }
            // The world was already built by `configure` above — push the pilot's
            // existing grudges/eligibility onto it now.
            scene.syncPersStateToWorld()
        }
        startMemoryPressureMonitoring()
    }

    // MARK: Flight-training sandbox

    /// Build a throwaway host for the flight-training tutorial: the scenario's
    /// starting hull, fully outfitted, dropped into the starting system with the
    /// player made invulnerable and **none** of the pilot-save callbacks wired.
    /// Nothing here reads or writes the live pilot — the tutorial is a sandbox
    /// that must never touch a real save. Returns nil when no data is loaded.
    static func makeTrainingHost(model: AppModel) -> GameHost? {
        guard let game = model.data.game else { return nil }
        let galaxy = Galaxy(game: game, flightTuning: FlightTuning(enhancements: model.settings.enhancements))

        // Fly the hull the scenario starts you in, so the training flight matches
        // the ship the pilot will actually take off in. Fall back to the first
        // ship type in the data if the scenario's is unusable.
        let scenario = game.startingChar()
        let shipID = scenario.flatMap { $0.shipID >= 128 ? $0.shipID : nil }
            ?? game.ships().first?.id ?? 128
        guard let ship = galaxy.makeLoadedShip(shipID) else { return nil }
        ship.armor = ship.maxArmor
        ship.shield = ship.maxShield

        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        if let sheet = game.shipSprite(shipID) { textures = SpriteTextures.rotationFrames(from: sheet) }
        if let glow = game.engineGlowSprite(shipID) { engineTextures = SpriteTextures.rotationFrames(from: glow) }
        let shipName = game.ship(shipID)?.displayName ?? "Trainer"

        // The starting system is always inhabited (a planet to practice landing
        // on) and calm — ideal for training. No destroyed-stellar handling here:
        // the sandbox never persists, so there's nothing to have destroyed.
        var planets: [PlanetVisual] = []
        var systemName = ""
        var systemID = 0
        if let system = game.startingSystem() {
            systemName = system.name
            systemID = system.id
            planets = game.stellarObjects(in: system.id).compactMap { entry in
                let spob = entry.spob
                let tex = entry.sprite.flatMap { $0.frameCGImage(0) }.map { SKTexture(cgImage: $0) }
                let radius = CGFloat(entry.sprite?.frameWidth ?? 48) / 2
                return PlanetVisual(id: spob.id, name: spob.name,
                                    position: CGPoint(x: spob.x, y: -spob.y),
                                    texture: tex, radius: radius,
                                    government: spob.government,
                                    isUninhabited: spob.isUninhabited)
            }
            let sysCenter = galaxy.systemContext(for: system.id).center
            ship.position = sysCenter + Vec2(0, -700)
        }

        return GameHost(training: model, ship: ship, textures: textures,
                        engineTextures: engineTextures, shipName: shipName,
                        systemID: systemID, planets: planets, systemName: systemName,
                        game: game, galaxy: galaxy)
    }

    /// Designated initializer for the training sandbox (see `makeTrainingHost`).
    /// Sets up the scene from a pre-built ship/system and wires nothing that could
    /// mutate the live pilot — deliberately far leaner than the play-session init.
    init(training model: AppModel, ship: Ship, textures: [SKTexture],
         engineTextures: [SKTexture], shipName: String, systemID: Int,
         planets: [PlanetVisual], systemName: String, game: NovaGame?, galaxy: Galaxy?) {
        controller = GameControllerInput(input: input)
        controller.bindings = model.padBindings
        self.game = game
        self.galaxy = galaxy
        self.graphics = game.map { SpaceportGraphics(game: $0) }
        hudStyle = GameHost.makeHUDStyle(game, shipType: ship.shipTypeID)
        hud.credits = 0
        hud.shipName = shipName
        hud.systemName = systemName
        scene.scaleMode = .resizeFill
        scene.configure(player: ship, textures: textures, engineTextures: engineTextures,
                        settings: model.settings,
                        input: input, controller: controller, hud: hud, audio: model.audio,
                        planets: planets, systemName: systemName,
                        game: game, systemID: systemID, galaxy: galaxy,
                        arrivedViaJump: false, playerDamageScaleOverride: 0)
        startMemoryPressureMonitoring()
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
        let shieldTextures: [SKTexture]
        let lightTextures: [SKTexture]
        let weaponGlowTextures: [SKTexture]
        let altTextures: [SKTexture]
        let hullAnim: HullAnim
        let shipName: String
    }
    static func buildPlayerShip(model: AppModel, galaxy: Galaxy, game: NovaGame) -> PlayerSession {
        let pilot = model.pilot.state
        let shipID = pilot.shipType
        let res = game.ship(shipID)
        // Both flags off: `pilot.outfits` already lists everything the hull came
        // with — `DefaultItems` and stock `WeapType` armament alike (granted at
        // pilot creation / purchase / capture / mission swap) — so folding either
        // in again here would fly every preinstalled turret, and every stock gun,
        // twice. See `PilotEconomy.loadout`.
        let ship = galaxy.makeLoadedShip(shipID, extraOutfits: pilot.outfits,
                                         includeDefaultItems: false,
                                         includeHullWeapons: false)
            ?? Ship(name: res?.displayName ?? "Ship",
                    stats: ShipStats(speed: res?.speed ?? 300, acceleration: res?.acceleration ?? 400,
                                     turnRate: res?.turnRate ?? 30, rotationFrames: 36))
        ship.cargo = pilot.cargo
        if let lo = PilotEconomy.loadout(pilot, galaxy: galaxy) {
            ship.fuel = pilot.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
            // The hull's own fuel regen needs shïp Flags 0x0008 for the player (FL-07).
            ship.fuelRegenPerSec = lo.playerFuelRegenPerSec
        }
        ship.armor = pilot.armor.map { min($0, ship.maxArmor) } ?? ship.maxArmor
        ship.shield = pilot.shield.map { min($0, ship.maxShield) } ?? ship.maxShield
        // Bays carry the fighters the pilot owns, not a free full load (UI-02).
        Munitions.loadCarriedFighters(into: ship, state: pilot, game: game)
        var textures: [SKTexture] = []
        var engineTextures: [SKTexture] = []
        var shieldTextures: [SKTexture] = []
        var lightTextures: [SKTexture] = []
        var weaponGlowTextures: [SKTexture] = []
        var altTextures: [SKTexture] = []
        // Full multi-set sheets (banking/animation sets + all headings) so the
        // scene can select the live set/heading — not just the first 36 frames.
        if let sheet = game.shipSprite(shipID) { textures = SpriteTextures.allFrames(from: sheet) }
        if let glow = game.engineGlowSprite(shipID) { engineTextures = SpriteTextures.allFrames(from: glow) }
        if let lights = game.lightSprite(shipID) { lightTextures = SpriteTextures.allFrames(from: lights) }
        if let wg = game.weaponGlowSprite(shipID) { weaponGlowTextures = SpriteTextures.allFrames(from: wg) }
        if let alt = game.altSprite(shipID) { altTextures = SpriteTextures.allFrames(from: alt) }
        // The shän shield-bubble layer (single-frame overlay), only present when a
        // "Shields" graphics plug-in populated it — nil/empty for stock hulls.
        if let bubble = game.shieldSprite(shipID) { shieldTextures = SpriteTextures.rotationFrames(from: bubble) }
        let hullAnim = game.shan(shipID).map(HullAnim.init) ?? HullAnim()
        let name = pilot.shipName.isEmpty ? (res?.displayName ?? "") : pilot.shipName
        return PlayerSession(ship: ship, textures: textures, engineTextures: engineTextures,
                             shieldTextures: shieldTextures, lightTextures: lightTextures,
                             weaponGlowTextures: weaponGlowTextures, altTextures: altTextures,
                             hullAnim: hullAnim, shipName: name)
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
            guard let shipType, let ship = game.ship(shipType) else { return 128 }
            // Bible: the status bar matches the ship's inherent *attributes* govt
            // or its inherent combat govt. `InherentGovt` is encoded (e.g. 1130 =
            // attributes govt 130), so decode both rather than using the raw
            // value — otherwise an encoded hull (like the Polaris Raven #310)
            // fails to resolve and wrongly falls back to the Default interface.
            let govtID = ship.inherentAttributesGovt >= 128 ? ship.inherentAttributesGovt
                                                            : ship.inherentCombatGovt
            guard govtID >= 128, let iid = game.govt(govtID)?.interface, iid >= 128 else { return 128 }
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
        guard let sheet = PICT.decodeLogged(pictData, id: intf.backgroundPictID) else {
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

    /// Whether pausing opens the port's sidebar menu. Follows the setting on desktop;
    /// always on for mobile, which has no keyboard and reaches the sidebar only via
    /// the ☰ button. When false (Classic desktop), pause exits to the authentic menu.
    private var sidebarEnabled: Bool {
        #if os(iOS)
        return true
        #else
        return model.settings.sidebarPauseMenu
        #endif
    }

    /// Live debug/performance state for this play session, handed to each
    /// `GameScene` the container (re)builds. Persists across host rebuilds.
    @StateObject private var debug = DebugController()
    /// The in-game command console: a typed CLI companion to the debug suite
    /// (log tail + commands), gated by the same debug-mode setting.
    @StateObject private var console = ConsoleController()
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
    /// True from the moment `grabSceneFocus` is asked to reclaim focus until
    /// it either confirms `isSceneFocused` stuck or gives up. `onKeyPress`
    /// only fires while `isSceneFocused` is actually true, so a held arrow
    /// key repeats straight into AppKit's unhandled-key beep for however long
    /// this reclaim is in flight; `ArrowKeyFocusFallback` uses this flag to
    /// step in only for that specific window, never when some other view
    /// (a text field, an overlay's own arrow-key handling) legitimately holds
    /// focus on purpose.
    @State private var reclaimingSceneFocus = false
    /// The open hail/communication dialog, if any (nil = closed).
    @State private var hailDialogState: HailDialogState?
    @State private var showStoryGuide = false
    @State private var storyGuideFocusKey: String?
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
    /// A mission `Q` message staged by the departure it triggers: shown for
    /// 0x1f4 raw calls in place of the launch line (UI-11, MS-18).
    @State private var stagedLaunchQuote: String?
    @State private var showEscortsPanel = false
    /// The Ship Info card over flight — the targeted ship, or your own hull when
    /// nothing is targeted (opened by the `.shipInfo` key).
    @State private var showShipInfoPanel = false
    /// Bumped when an escort order is issued so the command window re-renders
    /// with the new highlighted order (engine state changes don't publish).
    @State private var escortRefresh = 0
    /// A story `M` (false) or `N` (true) that fired while docked: the launch
    /// tail applies it (MS-18).
    @State private var dockedStoryMove: Bool?
    /// The disabled ship currently being boarded (nil = plunder dialog closed).
    @State private var boardManifest: World.BoardingManifest?
    /// The open plunder window's self-destruct risk (EC-18).
    @State private var plunderPanic: World.PlunderPanic?
    /// Bumped after taking loot so the plunder dialog re-reads the manifest.
    @State private var boardRefresh = 0
    /// A hulk that just rolled a successful capture, awaiting the player's
    /// "use as escort" vs. "take command of it" choice (nil = no pending choice).
    @State private var pendingCaptureChoice: (entityID: Int, shipType: Int, name: String)?
    /// Credit cost of "Request Assistance" by how the hailed crew feels about
    /// the player (`GameScene.AssistanceTier`) — allies help for free; a
    /// crew that dislikes the player (negative but not-yet-hostile legal
    /// record) charges a premium and only sometimes agrees at all. No
    /// distance/danger scaling beyond this tier — a deliberate scope cut.
    private let assistanceCostNeutral = 300
    private let assistanceCostWary = 900
    /// Heartbeat for rotating in-flight backups. EV Nova only *saves* on landing,
    /// and we keep that as the canonical save — but between landings a long haul
    /// (exploring, dogfighting, trading run) could lose a lot of progress to a
    /// crash. This fires a backup-taking autosave every few minutes while actually
    /// flying, so there's always a recent restore point without disturbing the
    /// land-is-the-save model. Backups rotate (newest 8 + first), so this can't
    /// grow unbounded.
    private let backupHeartbeat = Timer.publish(every: 180, on: .main, in: .common).autoconnect()
    /// Heartbeat for the in-flight mission-ship sighting check (escort and
    /// observe goals). A few seconds is plenty granular.
    private let missionSightingHeartbeat = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    /// The bomb outfits' fuse in 30 Hz ticks (OS-08); nil when none is aboard.
    @State private var bombFuse: Int?
    /// Stellars whose bribe was accepted since the last jump (EC-25): landing
    /// is granted there until the player leaves the system.
    @State private var bribedStellars: Set<Int> = []
    /// The per-jump planetary-bribe latch: `Rand(100)` rolled at the first
    /// stellar hail after a jump, −1 until then; a refused or failed bribe
    /// spends it (EC-25).
    @State private var bribeLatch = -1
    /// The planetary bribe's open payment window, if any.
    @State private var planetPayment: PaymentWindow?
    /// The original AI's comm session with the hailed ship (AI-42), and the
    /// shared payment window (DLOG 1008) when it names a price.
    @State private var shipComm: OriginalComms.Session?
    @State private var shipPayment: ShipPayment?
    /// A mission escort let go from the comm window (STR# 3001): it leaves
    /// when the window closes.
    @State private var pendingEscortRelease: Int?
    /// Chance a "wary" (dislikes-you-but-not-hostile) crew agrees at all.
    private let assistanceWaryAcceptChance = 0.5

    /// Other players' locations for the galaxy-map presence markers, keyed by
    /// system id (excludes the local player; empty when no session is active).
    private var galaxyPlayerMarkers: [Int: [GalaxyMapView.PlayerMapMarker]] {
        guard model.session.isActive else { return [:] }
        var result: [Int: [GalaxyMapView.PlayerMapMarker]] = [:]
        for presence in model.session.presence.values
        where presence.playerID != model.session.localPlayerID {
            result[presence.currentSystemID, default: []]
                .append(.init(id: presence.playerID, name: presence.name))
        }
        return result
    }

    /// The scene + HUD + overlays stack, split out from `body`. Kept separate so
    /// this content and the long lifecycle-modifier chain in `body` aren't one
    /// giant expression: SwiftUI's type-checker times out compiling them together
    /// (it tipped over once the in-flight backup heartbeat modifier was added).
    /// Two smaller expressions type-check quickly; the runtime view is identical.
    @ViewBuilder private var gameStack: some View {
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

                // Show the ☰ button whenever the sidebar is available: always on
                // mobile (no keyboard), and on desktop when the sidebar pause menu is
                // enabled (Enhanced / Nova Swift / Custom). Desktop can also open it
                // via the Esc/menu keybinding. When the sidebar is off (Classic
                // desktop), pause exits to the main menu, so there's nothing to open.
                if sidebarEnabled {
                    topLeftMenuButton
                }

                if nav.showingMap && gateMapOrigin == nil {
                    GalaxyMapView(nav: nav, pilot: model.pilot, onJump: { _ = attemptJump() },
                                  onClose: { nav.showingMap = false },
                                  fullscreen: model.settings.fullscreenGalaxyMap,
                                  playerMarkers: galaxyPlayerMarkers)
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

                // Multiplayer session chat — only rendered while a session is
                // live (started from the in-game menu). Passive cluster; empty
                // regions don't block fly-to-tap. It sits bottom-leading, but
                // moves to the top-left while the touch controls are up, since
                // their turn cluster claims that corner. Hidden while the galaxy
                // map (or gate destination map) owns the screen — its bottom-left
                // corner holds the map's own buttons, which the chat button would
                // otherwise cover.
                if !nav.showingMap && gateMapOrigin == nil {
                    #if os(iOS)
                    MultiplayerChatCluster(session: model.session,
                                           touchControlsVisible: flightControlsVisible)
                    #else
                    MultiplayerChatCluster(session: model.session)
                    #endif
                }

                // Trade / item hand-off — a live trade window, or an incoming
                // invite prompt. Modal overlays, only while in a session.
                if model.session.trade != nil {
                    TradeView().transition(.opacity)
                } else if let invite = model.session.incomingTradeInvite {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        TradeInvitePromptView(invite: invite)
                    }
                    .transition(.opacity)
                }

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
                            rightInset: touchRightInset(host, in: geo.size),
                            onDiscrete: handleDiscrete,
                            onOpenPanel: openMobilePanel)
                    }
                }
                #endif

                // The contextual action strip sits above the controls; on iOS
                // it's the row of situational pills (Land, Board, Hail, Jump,
                // Escorts), on macOS just the classic "Press L" land hint.
                // Inset by the HUD sidebar width so it centres on the actual play
                // viewport, not the full window (see `Self.sidebarWidth`).
                // Only while flight actually owns the screen — same gate as the
                // touch controls, plus the gate destination map — so it never
                // floats over the galaxy map or another fullscreen dialog.
                if flightControlsVisible && gateMapOrigin == nil {
                    GeometryReader { geo in
                        ContextualActionsView(hud: host.hud, onAction: handleDiscrete,
                                              rightInset: touchRightInset(host, in: geo.size))
                    }
                }

                if let state = hailDialogState {
                    HailDialogView(
                        state: state, portrait: hailPortrait(state), graphics: host.graphics,
                        showAssistButton: hailShowsAssistButton(state),
                        assistEnabled: hailAssistEnabled(state),
                        onGreetings: {
                            if case .planet = state.kind {
                                planetGreetings()
                            } else if let session = shipComm,
                                      case let .ship(entityID, _) = state.kind, session.entityID == entityID {
                                originalCommGreetings(session)
                            } else {
                                hailDialogState?.responseText = state.hostile
                                    ? "They don't seem interested in talking."
                                    : "Just a routine hail, nothing more."
                            }
                        },
                        onRequestAssistance: {
                            if case let .ship(entityID, _) = state.kind { requestAssistance(entityID: entityID) }
                        },
                        onRequestLanding: { requestPlanetLanding() },
                        onDemandTribute: { demandPlanetTribute() },
                        onClose: {
                            if let id = pendingEscortRelease { host.scene.originalReleaseEscort(entityID: id) }
                            pendingEscortRelease = nil
                            hailDialogState = nil
                        })
                }

                // The bribe's payment window (DLOG 1008) over the comm window.
                if let payment = planetPayment, let game = host.game {
                    NegotiationView(graphics: host.graphics,
                                    message: PaymentWindow.prompt(price: payment.price, game: game),
                                    primaryLabel: host.graphics?.buttonLabel(SpaceportLabel.acceptPrice, fallback: "Accept Price") ?? "Accept Price",
                                    secondaryLabel: host.graphics?.buttonLabel(SpaceportLabel.lowerPrice, fallback: "Lower Price") ?? "Lower Price",
                                    onPrimary: { pressPlanetPayment(.pay) },
                                    onSecondary: { pressPlanetPayment(.haggle) },
                                    onDismiss: {})
                }

                // The ship comm's payment window (DLOG 1008, AI-42).
                if let payment = shipPayment, let game = host.game {
                    NegotiationView(graphics: host.graphics,
                                    message: PaymentWindow.prompt(price: payment.window.price, game: game),
                                    primaryLabel: host.graphics?.buttonLabel(SpaceportLabel.acceptPrice, fallback: "Accept Price") ?? "Accept Price",
                                    secondaryLabel: host.graphics?.buttonLabel(SpaceportLabel.lowerPrice, fallback: "Lower Price") ?? "Lower Price",
                                    onPrimary: { pressShipPayment(.pay) },
                                    onSecondary: { pressShipPayment(.haggle) },
                                    onDismiss: {})
                }

                // A pêrs's in-flight LinkMission offer (hailed or boarded) —
                // stacks over the hail dialog exactly as the bar stacks its
                // offer over the spaceport hub.
                if let offer = flightMissionServices.pendingOffer, let graphics = host.graphics {
                    Color.black.opacity(0.5).ignoresSafeArea().transition(.opacity)
                    MissionSingleDialog(graphics: graphics, offer: offer, offered: [offer.mission],
                                        onPage: { _ in },
                                        onAccept: { acceptFlightMissionOffer(offer) },
                                        onDecline: { declineFlightMissionOffer(offer) },
                                        storylineTag: storylineTag(for: offer.mission.id, game: host.game),
                                        onOpenStoryline: storylineTag(for: offer.mission.id, game: host.game).map { t in { openStoryline(t.key) } })
                        .transition(.opacity)
                }

                if let game = host.game {
                    Color.clear
                        .storylineGuideSheet(isPresented: $showStoryGuide, game: game,
                                             player: { model.pilot.state }, storylineKey: storyGuideFocusKey)
                }

                // Mobile action-menu panels (opened from the on-screen controls).
                mobilePanels

                if showMenu {
                    GameMenuView(hud: host.hud,
                                 onResume: { showMenu = false },
                                 onOpenMap: { nav.showingMap = true },
                                 onSave: { saveGame(reason: $0) },
                                 showDebug: model.settings.debugModeEnabled,
                                 onOpenDebug: {
                                     showMenu = false
                                     console.tab = .tools
                                     console.isPresented = true
                                 })
                }

                // Dev console: an on-screen entry point + live metrics chip while
                // debug mode is on, and the full developer panel when opened. The
                // simulation keeps running underneath so the readout stays live.
                if model.settings.debugModeEnabled {
                    debugControls
                    if console.isPresented {
                        DevConsoleView(console: console, debug: debug, onClose: {
                            // Escape / the hidden cancel button reach this from
                            // inside a SwiftUI update pass — see `setPresented`.
                            console.setPresented(false)
                        }, onSelectEntity: { ref in
                            switch ref {
                            case let .ship(id, _): console.submit("select ship \(id)")
                            case let .spob(id, _): console.submit("select spob \(id)")
                            }
                        })
                        .zIndex(35)
                    }
                    // Right-click (macOS) / long-press (iOS/tvOS) context menu
                    // on a ship/planet in the live scene — see
                    // `GameScene.rightMouseDown`/`firePendingLongPress`.
                    if let request = debug.contextMenuRequest {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture { debug.contextMenuRequest = nil }
                            .zIndex(38)
                        DevContextMenu(ref: request.ref, console: console) {
                            debug.contextMenuRequest = nil
                        }
                        .position(request.screenPoint)
                        .zIndex(39)
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
                                      pilot: model.pilot, onDepart: depart,
                                      onLiveSync: { syncHUDFromPilotState() },
                                      showHints: model.settings.tutorialHints)
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
    }

    /// First half of the lifecycle-modifier chain (animations + the early
    /// `.onChange` handlers), split from `body` so the full chain isn't one
    /// expression the SwiftUI type-checker can't solve in reasonable time. The
    /// remaining handlers hang off this in `body`; the composed view is identical.
    private var gameStackWithEarlyLifecycle: some View {
        gameStack
        .animation(.easeInOut(duration: 0.2), value: nav.showingMap)
        .animation(.easeInOut(duration: 0.2), value: gateMapOrigin)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMenu)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: console.isPresented)
        .animation(.easeInOut(duration: 0.2), value: landedSpobID)
        .onChange(of: isSceneFocused) { _, focused in
            Log.input.debug("isSceneFocused -> \(focused, privacy: .public)")
        }
        .onChange(of: showMenu) { _, open in
            setMenuPaused(open, reason: "showMenu=\(open)")
            // Deferred a tick: setting `@FocusState` in the same transaction that
            // dismisses the overlay stealing focus can silently lose the race on
            // macOS — the scene view has to actually reclaim key status first.
            if !open { grabSceneFocus(reason: "menu closed") }
        }
        .onChange(of: nav.showingMap) { _, open in
            // The Galaxy Map is a full-screen planning overlay — freeze the sim and
            // its audio behind it (like every other in-flight menu), then hand focus
            // back to flight on close.
            setMenuPaused(open, reason: "showingMap=\(open)")
            if !open { grabSceneFocus(reason: "map closed") }
        }
        .onChange(of: gateMapOrigin) { _, id in
            setMenuPaused(id != nil, reason: "gateMap=\(id != nil)")
            if id == nil { grabSceneFocus(reason: "gate map closed") }
        }
        .onChange(of: nav.plan) { _, _ in
            syncNavCourseToHUD(host)
        }
        .onChange(of: hailDialogState != nil) { _, open in
            setMenuPaused(open, reason: "hailDialogState=\(open)")
            if !open { grabSceneFocus(reason: "hail dialog closed") }
        }
        .onChange(of: showEscortsPanel) { _, open in
            // The Escorts window is an escort's hail — pause the sim and its audio
            // behind it and return focus to flight when it closes, exactly like the
            // comm dialog.
            setMenuPaused(open, reason: "showEscortsPanel=\(open)")
            if !open { grabSceneFocus(reason: "escorts window closed") }
        }
        .onChange(of: showShipInfoPanel) { _, open in
            // Ship Info is a read-only card; pause the sim behind it (like the other
            // mobile panels) and hand keyboard focus back to flight on close.
            setMenuPaused(open, reason: "showShipInfoPanel=\(open)")
            if !open { grabSceneFocus(reason: "ship info closed") }
        }
        .onChange(of: flightMissionServices.pendingOffer != nil) { _, open in
            setMenuPaused(open, reason: "flightMissionOffer=\(open)")
            if !open { grabSceneFocus(reason: "flight mission offer closed") }
        }
        // The remaining in-flight overlays. Each of these takes the controls away
        // (they're all in `flightControlsVisible`) but used to leave the sim
        // running underneath — so reading a plunder manifest, the mission list,
        // the pilot card or a mission's completion text meant being shot at by
        // ships you could neither see nor answer. One gate covers the lot.
        .onChange(of: sceneFreezingOverlayOpen) { _, open in
            setMenuPaused(open, reason: "flightOverlay=\(open)")
            if !open { grabSceneFocus(reason: "flight overlay closed") }
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding/quitting: landed, save like the original's quit
            // while landed; in flight, only under `frequentAutosave` — the
            // original rolls a quit in flight back to the last launch.
            if phase != .active {
                syncCombatStanding()
                saveGame(reason: landedSpobID != nil ? .backgroundLanded : .background)
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
    }

    /// Second slice of the lifecycle-modifier chain (the in-flight backup,
    /// landing, and initial-host `.task`), split from `body` for the same
    /// type-checker reason as `gameStackWithEarlyLifecycle`. `body` applies the
    /// last few `.onChange` handlers on top of this.
    private var gameStackWithMidLifecycle: some View {
        gameStackWithEarlyLifecycle
        .onReceive(backupHeartbeat) { _ in
            // Rotating in-flight backup. Only while actively flying a live session:
            // skip if there's no host yet, if we're docked (landing already saves +
            // backs up), or while a menu/map/dialog holds the sim paused — no point
            // snapshotting a frozen, already-checkpointed state.
            guard host != nil, landedSpobID == nil, !showMenu, !nav.showingMap,
                  hailDialogState == nil, flightMissionServices.pendingOffer == nil else { return }
            syncCombatStanding()
            saveGame(reason: .periodic)
        }
        .onReceive(missionSightingHeartbeat) { _ in
            guard let host, landedSpobID == nil, !showMenu, !nav.showingMap,
                  host.scene.playerShip?.isAlive == true else { return }
            checkMissionShipSightings(host)
        }
        .onChange(of: landedSpobID) { _, id in
            setScenePaused(id != nil, reason: "landedSpobID=\(id.map(String.init) ?? "nil")")
            // Mirror the docked state into the persisted pilot so the on-land save
            // records *where* we landed — that's what lets a reload lift off from
            // this pad instead of the system centre. Cleared on departure below.
            model.pilot.state.landedSpob = id
            if let id {
                // Landing costs no day; the visit's days run on departure (FL-05).
                model.pilot.visitDays = SpaceportVisitDays()
                handleStoryLanding(spobID: id)                  // finish deliveries / pick up cargo
                DispatchQueue.main.async {
                    // Inhabited ports restore hull + shields to full for free
                    // (shields regen while docked; hull is patched up). Fuel is
                    // NOT topped off here — refuelling is the paid "Recharge"
                    // service, per the Bible (free only via govt/rank flags).
                    repairOnLanding(spobID: id)
                    syncCombatStanding()
                    // What was fired or lost in flight stays spent (UI-02).
                    recordMunitions()
                    saveGame(reason: .land)               // `frequentAutosave` only; the original saves on leaving
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
                // `GameHost` has now consumed `landedSpob` to place the ship on its
                // pad; we're airborne, so clear the docked marker. This keeps it
                // from re-placing us at that planet if we later jump back into this
                // system without having landed again in the meantime.
                model.pilot.state.landedSpob = nil
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
        // A successful capture offers a choice, same as the real game: fly
        // the captured hull yourself, or send it into the wing as an escort.
        .confirmationDialog("Ship captured!",
                            isPresented: Binding(get: { pendingCaptureChoice != nil },
                                                 set: { if !$0 { pendingCaptureChoice = nil } }),
                            presenting: pendingCaptureChoice) { cap in
            Button("Take Command") { takeCommandOfCapturedShip(cap) }
            // Only offered under the escort-wing cap — a full wing can still
            // take command of the captured hull, just not add it as an escort.
            if model.pilot.canAddEscort() {
                Button("Use as Escort") { recruitCapturedShipAsEscort(cap) }
            }
        } message: { cap in
            Text("\(cap.name.isEmpty ? "The ship" : cap.name) is yours. Fly it yourself, or add it to your escort wing?")
        }
    }

    var body: some View {
        gameStackWithMidLifecycle
        // Leaving the game unsuppresses the UI cursor so it works on the menus.
        .onDisappear { CursorTargets.shared.suppressed = false }
        // Keep cursor suppression tracking who owns the screen. `wirePadController`
        // asserts `suppressed == flightControlsVisible`, but it only re-runs on a
        // scene/bindings change — so opening an overlay (console, menu, map) left
        // the cursor suppressed from whenever the pad was last wired, and a
        // controller/tvOS player couldn't click anything in it.
        .onChange(of: flightControlsVisible) { _, flying in
            CursorTargets.shared.suppressed = flying
        }
        // Commands read `debug`/`model` live at call time (they close over
        // `self`), so registering once per session is enough — a jump
        // rebuild doesn't need to re-wire them the way pad bindings do.
        .onAppear { registerConsoleCommands() }
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
            bribedStellars = []
            bribeLatch = -1
            planetPayment = nil
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
                storyArrival(in: newID)                       // follow the pilot to the new system
                // Announce the jump to any multiplayer peers (no-op if no session).
                model.session.updatePresence(systemID: newID, name: model.pilot.state.pilotName,
                                             shipTypeID: model.pilot.state.shipType)
                syncCombatStanding()   // the about-to-be-discarded Diplomacy is the source of truth
                model.pilot.save()
                saveGame(reason: .jump)                 // `frequentAutosave` only (UI-01)
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

    /// Pause both the simulation *and* the sustained game audio behind an in-flight
    /// overlay menu (Escorts, Hail, Galaxy/Gate Map, the in-game menu / Story map,
    /// mission offers). Landing at a spaceport deliberately doesn't route through
    /// here — the port keeps its own ambience playing over the frozen sim.
    private func setMenuPaused(_ paused: Bool, reason: String) {
        setScenePaused(paused, reason: reason)
        model.audio.setPaused(paused)
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
        reclaimingSceneFocus = true
        DispatchQueue.main.async {
            isSceneFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if isSceneFocused {
                    reclaimingSceneFocus = false
                    Log.input.debug("grabSceneFocus(\(reason, privacy: .public)) confirmed, attempt \(attempt)")
                } else if attempt < 5 {
                    Log.input.debug("grabSceneFocus(\(reason, privacy: .public)) attempt \(attempt) didn't stick — retrying")
                    grabSceneFocus(reason: reason, attempt: attempt + 1)
                } else {
                    reclaimingSceneFocus = false
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
                }.buttonStyle(.novaPlain)
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

    /// Why the player may not land on `spob` right now, or nil when landing is
    /// allowed (`LandedServices.landingClearance`, EC-04/EC-05): the landing
    /// fee, the system reputation against `MinStatus`, domination, an accepted
    /// bribe, the government's `Require` bits, an active mission's destination
    /// and AlwaysLand ranks, in the original's order. The message is the
    /// original's STR# 2002 line.
    private func landingRefusalReason(spob: SpobRes) -> String? {
        guard let game = host?.game else { return nil }
        // `spöb.Flags` 0x0080 ("Can only land when destroyed"): a hidden base or
        // buried installation whose cover has to be blown off first. Checked
        // before every other gate — no rank, domination or permit gets you in
        // while the surface is intact. (Checked here rather than dropped from the
        // approach list so the player gets a reason, not a dead planet.)
        if spob.landableOnlyWhenDestroyed, !model.pilot.state.isStellarDestroyed(spob.id) {
            return "There is nowhere to land here."
        }
        let clearance = LandedServices.landingClearance(
            spob: spob, system: nav.currentSystemID, state: model.pilot.state, game: game,
            diplomacy: host?.galaxy?.makeDiplomacy(), contributedBits: game.contributedBits(pilot: model.pilot.state),
            bribed: bribedStellars.contains(spob.id))
        return LandedServices.refusalMessage(clearance, spob: spob, game: game)
    }

    /// The original's two-press landing (0x00457580; UI-08). The first press
    /// on the selected stellar requests clearance — a denied stellar says so
    /// (#81–83) and drops the selection, an uninhabited one answers "No
    /// response." (#53) and is cleared at once, any other gets a request line
    /// unless the ship is already within 250 px — and the clearance line
    /// follows on reaching 250 px (`postLandingClearance`). The second press
    /// lands, or says why not: cloaked (#73), too fast (#69–72), too far
    /// (#65–68).
    private func pressLand(_ scene: GameScene) {
        guard let game = host?.game, let id = scene.selectedPlanetID, let spob = game.spob(id) else { return }
        let text = OriginalText(game: game)
        let body = OriginalText.Body(spob)
        if model.pilot.state.destroyedStellars?.contains(id) == true, !spob.landableOnlyWhenDestroyed {
            model.audio.play(.uiSelect)
            host?.hud.post(text.unableToLand(body: body, stellar: spob.displayName), rawCalls: OriginalText.Duration.landing)
            return
        }
        if scene.landingProblem(id) == .cloaked {
            model.audio.play(.uiSelect)
            host?.hud.post(text.misc(73), rawCalls: OriginalText.Duration.landing)
            return
        }
        guard scene.landingRequestID == id else {
            // First press: the request.
            if spob.isUninhabited && !spob.isGate {
                host?.hud.post(text.misc(53), rawCalls: OriginalText.Duration.landing)
                scene.requestLandingClearance(id, clearedNow: true)
                if let land = scene.attemptLand() { requestLanding(land) }
                return
            }
            // Clearance reads the per-system reputation, so fold in this
            // session's crimes first (EC-02).
            syncCombatStanding()
            let refusal = spob.isGate ? nil : landingRefusalReason(spob: spob)
            let denied = spob.isGate ? !(spob.isWormhole || scene.playerMayUseGate(id)) : refusal != nil
            if denied {
                model.audio.play(.uiSelect)
                // An unpayable fee says so (#61–64); otherwise #81–83.
                host?.hud.post(refusal ?? text.landingDenied(body: body), rawCalls: OriginalText.Duration.landing)
                scene.clearTravelSelection()
                return
            }
            if scene.isWithinClearanceRange(id) {
                scene.requestLandingClearance(id)        // the clearance line follows next frame
                return
            }
            model.audio.play(.uiSelect)
            host?.hud.post(text.landingRequest(body: body, stellar: spob.displayName,
                                               pilot: model.pilot.state.pilotName) { Int.random(in: 0..<$0) },
                           rawCalls: OriginalText.Duration.landing)
            scene.requestLandingClearance(id)
            return
        }
        // Second press: land, or say why not.
        if let land = scene.attemptLand() {
            requestLanding(land)
            return
        }
        model.audio.play(.uiSelect)
        switch scene.landingProblem(id) {
        case .tooFast?:
            host?.hud.post(text.tooFast(body: body), rawCalls: OriginalText.Duration.approach)
        case .cloaked?:
            host?.hud.post(text.misc(73), rawCalls: OriginalText.Duration.landing)
        default:
            host?.hud.post(text.tooFar(body: body), rawCalls: OriginalText.Duration.approach)
        }
    }

    /// The clearance line on reaching 250 px of the requested stellar
    /// (0x00459950): "Cleared to land" and its variants, then "Commence final
    /// approach." or "Welcome to <stellar>.", and the landing fee when one is
    /// due.
    private func postLandingClearance(_ id: Int) {
        guard let game = host?.game, let spob = game.spob(id), !spob.isUninhabited || spob.isGate else { return }
        let fee = model.pilot.state.hasDominated(id) ? 0 : spob.landingFee
        model.audio.play(.uiSelect)
        host?.hud.post(OriginalText(game: game).landingClearance(
            body: OriginalText.Body(spob), stellar: spob.displayName,
            pilot: model.pilot.state.pilotName, fee: fee) { Int.random(in: 0..<$0) },
                       rawCalls: OriginalText.Duration.landing)
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
        // Travel-permit / legal-standing landing clearance (see landingRefusalReason).
        if let spob = host?.game?.spob(id), let reason = landingRefusalReason(spob: spob) {
            host?.hud.post(reason)
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

    /// A wormhole spits you out at a visible linked wormhole, or a random other
    /// link-less one if it has no links (OS-06). No destination choice.
    private func beginWormholeTransport(from wormhole: SpobRes) {
        guard let game = host?.game else { return }
        let story = StoryEngine(game: game, player: model.pilot.state)
        let exits = game.wormholeExitCandidates(from: wormhole, currentSystem: nav.currentSystemID,
                                                isVisible: { story.isSystemVisible($0) })
        guard let dest = exits.randomElement() else {
            host?.hud.post("Unable to use this wormhole."); return
        }
        performGateJump(toSystem: dest.systemID, arriveAtGate: dest.gateSpobID)
    }

    /// Drive a gate transport through the live scene: it flashes and swaps to
    /// `destSystem` in place, emerging from `destGate`. The flash-peak commit sets
    /// the system — gates spend **no** fuel and **no** days (OS-06: none of the
    /// original's daily-tick callers is on the gate path), and no hyperspace link
    /// is required.
    private func performGateJump(toSystem destSystem: Int, arriveAtGate destGate: Int) {
        guard let host, !host.scene.isJumping else { return }
        gateMapOrigin = nil
        host.scene.beginGateJump(toSystem: destSystem, arriveAtGate: destGate) {
            hostSystemID = destSystem                     // set first: suppress the host-rebuild onChange
            nav.arriveViaGate(at: destSystem)
            storyArrival(in: destSystem)
            runMissionFlightPass()
            model.pilot.save()
            saveGame(reason: .jump)
            // The scene reloads the destination world after this commit. Its
            // onSystemReloaded hook then attaches mission ships and escorts.
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
            // The escort fleet pass and one payroll period run as the
            // spaceport closes (0x004229d0, EC-22 / EC-20), before the visit's
            // days (FL-05); then the original's launch-tail save (UI-01), still
            // docked at this stellar: that's the restore point.
            if let departedSpob { runEscortFleetPass(spobID: departedSpob) }
            payEscorts(periods: 1)
            advanceGameDays(model.pilot.visitDays.departureDays)
            model.pilot.visitDays = SpaceportVisitDays()
            model.pilot.save()
            saveGame(reason: .launch)
            // In flight again: the mission pass runs (a deadline that ran out
            // while docked fails now) and a `Q` staged while landed shows.
            var launchMessage: String?
            if let game = model.data.game {
                let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
                launchMessage = engine.playerLaunched()
                model.pilot.state = engine.player
            }
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
            if let keepPosition = dockedStoryMove, let game = model.data.game {
                // A story move while docked (MS-18): launch into the new
                // system — `M` on its first nav stellar, `N` at the docked
                // stellar's old coordinates (the launch snap is skipped).
                dockedStoryMove = nil
                let systemID = model.pilot.state.currentSystem
                let oldStellar = departedSpob.flatMap { game.spob($0) }.map { Vec2(Double($0.x), Double(-$0.y)) }
                landedSpobID = nil
                relocateFlightHost(to: systemID, reason: "depart (story move)")
                let at = keepPosition ? oldStellar : firstNavStellarPosition(systemID, game: game)
                if let at {
                    host?.scene.playerShip?.position = at
                    host?.scene.playerShip?.velocity = Vec2()
                }
                if let departedSpob { postLaunchLine(from: departedSpob) }
            } else if let host, let galaxy = host.galaxy, let game = host.game, let spob = departedSpob {
                let session = GameHost.buildPlayerShip(model: model, galaxy: galaxy, game: game)
                host.hud.shipName = session.shipName
                // A hull bought at this spaceport changes the HUD skin (and the
                // credit balance changed too); reskin before the scene reloads.
                host.refreshHUDStyle(model: model)
                host.scene.reloadForDeparture(spobID: spob, player: session.ship,
                                              textures: session.textures,
                                              engineTextures: session.engineTextures,
                                              shieldTextures: session.shieldTextures,
                                              lightTextures: session.lightTextures,
                                              weaponGlowTextures: session.weaponGlowTextures,
                                              altTextures: session.altTextures,
                                              hullAnim: session.hullAnim)
                landedSpobID = nil            // now fade the port out over the ready scene
                setScenePaused(false, reason: "depart (in place)")
                syncNav(host)
                postLaunchLine(from: spob)
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
            if let launchMessage, !launchMessage.isEmpty { host?.hud.post(launchMessage) }
        }
    }

    /// The status line on arriving in a system (0x0044f3d0; UI-11): the buoy
    /// (sÿst Message, STR# 1000, shown 0x1e0 raw calls) when the system has
    /// one, else "Arriving in the X system on <date>." (#43–48), or the gate
    /// and wormhole variants, with "No stellar objects present." (#49) when
    /// it has none.
    private func postArrivalLine(systemID: Int, gateID: Int?) {
        guard let game = model.data.game, let system = game.system(systemID) else { return }
        if let buoy = game.systemMessageText(system.message) {
            host?.hud.post(buoy, rawCalls: OriginalText.Duration.buoy)
            return
        }
        let gate = gateID.flatMap { game.spob($0) }
        let kind: OriginalText.GateKind? = gate.map { $0.isWormhole ? .wormhole : .hypergate }
        let hasStellars = system.spobs.contains { game.spob($0).map { !$0.isGate } ?? false }
        let line = OriginalText(game: game).arrival(system: system.displayName, player: model.pilot.state,
                                                    hasStellars: hasStellars, via: kind,
                                                    abandonedFighters: host?.scene.lastJumpAbandonedFighters ?? 0) {
            Int.random(in: 0..<$0)
        }
        host?.hud.post(line)
    }

    /// The status line on leaving a spaceport (0x00456134; UI-11): a staged
    /// mission `Q` message for 0x1f4 raw calls, else "Launching from X on
    /// <date>." (#55–60).
    private func postLaunchLine(from spobID: Int) {
        guard let game = model.data.game else { return }
        if let quote = stagedLaunchQuote {
            stagedLaunchQuote = nil
            if !quote.isEmpty { host?.hud.post(quote, rawCalls: OriginalText.Duration.missionQuote) }
            return
        }
        let name = game.spob(spobID)?.displayName ?? ""
        host?.hud.post(OriginalText(game: game).launch(stellar: name, player: model.pilot.state) { Int.random(in: 0..<$0) })
    }

    /// Reattach `nav`'s live-fuel/multi-jump sources to the current session's
    /// ship — needed every time `host` is (re)built, since neither survives a
    /// system rebuild on its own.
    private func syncNav(_ host: GameHost?) {
        // In-place jumps commit nav/fuel/date first, then replace the world.
        // Spawn into that finished destination world so its ships survive the
        // replacement. A discarded host must not reattach an obsolete scene.
        host?.scene.onSystemReloaded = { [weak host] systemID in
            guard let host, self.host === host, nav.currentSystemID == systemID else { return }
            syncNav(host)
            postArrivalLine(systemID: systemID, gateID: host.scene.lastArrivalGateID)
        }
        // Re-bind the auto-landing arrival callback for whatever scene is current
        // (this runs at every host build/rebuild) so the autopilot can commit the
        // landing through the same confirm-aware path as the manual Land key.
        host?.scene.onAutoLandArrived = { id in requestLanding(id) }
        // Selecting a stellar takes the travel channel from an armed jump (UI-06).
        host?.scene.onTravelStellarSelected = { nav.disarmJump() }
        host?.scene.onLandingCleared = { id in postLandingClearance(id) }
        host?.scene.persGrudgeProvider = { id in model.pilot.state.persHoldsGrudge(id) }
        // Feed a mission special-ship's completed goal back into the story engine
        // (decrement the objective, complete the mission if it was the last one).
        host?.scene.onMissionShipGoalReached = { missionID, goal, _ in
            handleMissionShipGoalReached(missionID: missionID, goal: goal)
        }
        host?.scene.onMissionAuxShipsArrived = { missionID, count in
            guard let m = model.data.game?.mission(missionID), !m.infiniteAuxShips,
                  let i = model.pilot.state.activeMissions.firstIndex(where: { $0.missionID == missionID }) else { return }
            let left = model.pilot.state.activeMissions[i].auxShipsRemaining ?? m.auxShipCount
            model.pilot.state.activeMissions[i].auxShipsRemaining = max(0, left - count)
        }
        host?.scene.onMissionShipLost = { missionID, goal in
            handleMissionShipLost(missionID: missionID, goal: goal)
        }
        host?.scene.onPlayerDisabled = {
            failActiveMissions(where: { $0.failIfPlayerDisabled },
                               reason: "Your ship was disabled — mission failed.")
        }
        // OS-02. A hull going down fails the same Flags2-0x0004 missions as a
        // disable; ejecting hands the pilot the new craft; the pod's landing
        // respawns them.
        host?.scene.onPlayerDying = {
            failActiveMissions(where: { $0.failIfPlayerDisabled },
                               reason: "Your ship was destroyed — mission failed.")
        }
        host?.scene.onPlayerEjected = { previous, newClass, intoPod in
            guard let game = model.data.game else { return }
            EscapePodRespawn.eject(&model.pilot.state, from: previous, into: newClass, game: game)
            // A pod can't lead: the escorts are released.
            if intoPod { model.pilot.state.escorts = nil }
            model.pilot.save()
        }
        host?.scene.onEscapePodRespawn = { respawnFromEscapePod() }
        host?.scene.onPlayerBoarded = {
            // mïsn.Flags 0x8000 — "mission fails if you're boarded by pirates".
            failActiveMissions(where: { $0.flags1 & 0x8000 != 0 },
                               reason: "You were boarded — mission failed.")
        }
        host?.scene.onPlayerBoardedBy = { boarderID, ratio in
            // AI-29: the boarders take cargo and credits
            // (`Boarding_BoardShipAndTransferCargo` 0x00412550).
            guard let scene = host?.scene else { return }
            let loss = scene.resolvePlayerBoarding(byShipID: boarderID, ratio: ratio,
                                                   playerCargo: model.pilot.state.cargo,
                                                   playerCredits: model.pilot.state.credits)
            for (commodity, tons) in loss.cargo {
                let left = (model.pilot.state.cargo[commodity] ?? 0) - tons
                model.pilot.state.cargo[commodity] = left > 0 ? left : nil
            }
            model.pilot.state.credits = max(0, model.pilot.state.credits - loss.credits)
            scene.debugSyncCredits(model.pilot.state.credits)
            if let line = playerBoardedLine(tons: loss.cargo.values.reduce(0, +), credits: loss.credits) {
                host?.hud.post(line)
            }
        }
        // Demand-Tribute domination feedback. Each defense wave announces itself
        // (fires on the first wave and on every relaunch as the field is cleared);
        // a surrender persists through the story engine + daily tribute.
        host?.scene.onStellarDefendersLaunched = { spobID, count, _ in
            let name = model.data.game?.spob(spobID)?.name ?? "The stellar"
            host?.hud.post("\(name) scrambles \(count) defender\(count == 1 ? "" : "s").")
        }
        // Bomb fuses count simulation ticks (OS-08).
        host?.scene.onPlayerTick = {
            if let host, landedSpobID == nil { checkHazardOutfits(host) }
        }
        host?.scene.onStellarDominated = { spobID in
            handleStellarDominated(spobID: spobID)
        }
        host?.scene.onStellarDestroyed = { spobID in
            handleStellarShotDown(spobID: spobID)
        }
        // Live-world effect hooks for the flight-side story services (mission
        // OnSuccess / cron OnStart side effects that reach outside pilot state).
        flightMissionServices.onLeaveStellar = { message in
            if landedSpobID != nil {
                // Q op: bounced back into space; its text replaces the launch line.
                stagedLaunchQuote = message
                depart()
            } else if let message, !message.isEmpty {
                host?.hud.post(message, rawCalls: OriginalText.Duration.missionQuote)
            }
        }
        // A `Q` fired in flight, and the "mission failed" notices: the
        // original's overlay line over the flight view.
        flightMissionServices.onOverlayMessage = { message in
            host?.hud.post(message)
        }
        flightMissionServices.onSpawnMissionShips = { _, _ in spawnActiveMissionShips() }
        flightMissionServices.onChangePlayerShip = { shipID, _ in
            // The hull swap is already in `PlayerState`. In flight, rebuild the
            // world in place so the new hull/sprite/stats take effect immediately
            // (a mission `C/E/H` op that fires mid-space); landed, the takeoff
            // rebuild picks it up. Mission ships respawn via `syncNav` and their
            // objective counts persist in state, so a mid-mission swap is safe.
            guard landedSpobID == nil else { return }
            // The swap keeps the hull's damage; a disabled hull is then
            // repaired one armor point at a time until it no longer reads
            // disabled (0x00449932, MS-18).
            let damage = host?.scene.playerShip.map { (armor: $0.armor, shield: $0.shield) }
            rebuildFlightHost(reason: "story ship swap")
            if let damage, let ship = host?.scene.playerShip {
                ship.armor = min(damage.armor, ship.maxArmor)
                ship.shield = min(damage.shield, ship.maxShield)
                while ship.disabled, ship.armor < ship.maxArmor { ship.armor += 1 }
            }
        }
        flightMissionServices.onMovePlayer = { systemID, keepPosition in
            movePlayerToSystem(systemID, keepPosition: keepPosition)
        }
        flightMissionServices.onSetStellarDestroyed = { spobID, destroyed in
            // Persisted in PlayerState by the engine; the body itself drops out
            // of the world on the next system (re)build. Surface it now.
            let name = model.data.game?.spob(spobID)?.name ?? "A stellar object"
            // Keep the renderer's mirror current so `Flags2` 0x0080 ("animate
            // only when destroyed") flips without waiting for a system rebuild.
            if destroyed { host?.scene.destroyedStellarIDs.insert(spobID) }
            else { host?.scene.destroyedStellarIDs.remove(spobID) }
            host?.hud.post(destroyed ? "\(name) has been destroyed." : "\(name) has been restored.")
        }
        // A failed / aborted / resolved mission releases its ships (MS-07);
        // docked, the original removes them instead.
        flightMissionServices.onReleaseMissionShips = { missionID in
            host?.scene.releaseMissionShips(missionID: missionID, despawn: landedSpobID != nil)
        }
        // An unpaid escort defects (EC-20): its ship leaves the system; the
        // payroll's own dialog (STR# 2002 #302/#303) tells the player.
        flightMissionServices.onEscortDeparted = { escortID, _ in
            host?.scene.despawnEscort(recordID: escortID)
        }
        // An escort that dies in combat is gone for good: drop it from the pilot
        // roster so it won't respawn next system (and a hired one stops billing).
        host?.scene.onEscortLost = { recordID in
            // A destroyed non-mission freighter takes its share of the
            // fleet's cargo down with it (0x004192d0 → 0x00469810, EC-21).
            if let rec = model.pilot.state.escort(id: recordID), rec.missionID == nil, let game = model.data.game,
               let hull = game.ship(rec.shipType), hull.inherentAI < 3 {
                transferCargoToEscort(holds: hull.cargoSpace, game: game)
            }
            if let lost = model.pilot.state.removeEscort(id: recordID) {
                host?.hud.post("\(lost.name) was destroyed.")
            }
            model.pilot.save()
        }
        // AI-38: a disabled escort drops out of the wing; a freighter first
        // takes its share of the fleet's cargo (0x004192d0 → 0x00469810) and
        // carries it until it is repaired back or lost.
        host?.scene.onEscortDisabled = { recordID, entityID, freighter in
            guard freighter, let rec = model.pilot.state.escort(id: recordID), rec.missionID == nil,
                  let game = model.data.game, let hull = game.ship(rec.shipType) else { return }
            let moved = transferCargoToEscort(holds: hull.cargoSpace, game: game)
            host?.scene.setEscortCargo(entityID: entityID, cargo: moved)
            model.pilot.save()
        }
        host?.scene.onEscortAbandoned = { recordID, destroyed in
            if let lost = model.pilot.state.removeEscort(id: recordID), destroyed {
                host?.hud.post("\(lost.name) was destroyed.")
            }
            model.pilot.save()
        }
        // Boarding repaired a former freighter escort: its cargo comes back
        // aboard, with no hold check (0x0045a3d0).
        host?.scene.onEscortRepairedCargo = { cargo in
            for (type, tons) in cargo { model.pilot.state.cargo[type, default: 0] += tons }
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
        nav.autoRoutePlotting = model.settings.enhancements.autoRoutePlotting
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
        if let destID = nav.destinationID, let name = nav.system(destID)?.displayName {
            hud.navCourseSystemName = name
            hud.navCourseJumps = nav.route.count
        } else {
            hud.navCourseSystemName = ""
            hud.navCourseJumps = 0
        }
        // The original nav panel names the armed next hop, or "Unexplored
        // System" (#346) until it has been visited (UI-10).
        hud.navJumpArmed = nav.jumpArmed
        if let hop = nav.route.first, let system = nav.system(hop) {
            let visited = model.pilot.state.exploredSystems.contains(hop) || model.pilot.chartedSystems.contains(hop)
            hud.navNextHopName = visited ? system.displayName
                : (model.data.game?.stringList(2002)?.string(at: 346) ?? "")
        } else {
            hud.navNextHopName = ""
        }
    }

    /// Run `days` of the original's daily tick (`0x00466cb0`: date, crön,
    /// deadlines, tribute…). Its callers are the complete list of day costs:
    /// a jump's travel days, a spaceport departure, a pod respawn, a mission's
    /// DatePostInc (FL-05).
    private func advanceGameDays(_ days: Int) {
        guard days > 0, let game = model.data.game else { return }
        for _ in 0..<days {
            // Route through the flight mission services so a crön that fires
            // today (its OnStart/OnEnd) can surface its text / notifications /
            // spawns through the same seam a mission does.
            let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
            engine.advanceOneDay()
            model.pilot.state = engine.player
        }
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
        case .disable, .escort: engine.missionShipDisabled(missionID: missionID)
        case .board, .rescue:   engine.missionShipBoarded(missionID: missionID)
        default:                engine.missionShipDestroyed(missionID: missionID)
        }
        model.pilot.state = engine.player
        // Mission boarding can add cargo in flight; keep the live hold and its
        // HUD/capacity calculations in sync before checkpointing the pilot.
        host?.scene.playerShip?.cargo = engine.player.cargo
        saveGame(reason: .event)
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
            let goalEligible = m.hasShipObjective && (passiveGoal || am.shipObjectivesRemaining > 0)
            let goalSystemMatches = missionSystemMatches(code: m.shipSystem, active: am, currentSystem: currentSys, game: game)
            if goalEligible, goalSystemMatches {
                // `mïsn.ShipName`/`ShipSubtitle` name the mission's special ships
                // on the target display, instead of their bare hull type.
                if m.shipStart == 1 {
                    // AI-14: a ShipStart-1 batch waits out its rearm delay, then
                    // jumps in from the previous system's side.
                    scene.scheduleMissionArrival(missionID: m.id, dudeID: m.shipDude,
                                                 count: max(1, m.shipCount), goal: m.shipGoal,
                                                 behavior: m.shipBehaviorMode, auxiliary: false,
                                                 name: missionShipName(m, game: game),
                                                 subtitle: missionShipSubtitle(m, game: game))
                } else {
                    scene.spawnMissionShips(missionID: m.id, dudeID: m.shipDude,
                                            count: max(1, m.shipCount), goal: m.shipGoal,
                                            behavior: m.shipBehaviorMode, government: nil,
                                            arrival: arrivalMode(forShipStart: m.shipStart),
                                            navStellarIndex: (-16 ... -1).contains(m.shipStart) ? -1 - m.shipStart : nil,
                                            startsCloaked: m.shipStart == 2,
                                            name: missionShipName(m, game: game),
                                            subtitle: missionShipSubtitle(m, game: game))
                }
            } else if m.hasShipObjective {
                Log.story.debug("spawnActiveMissionShips: mission \(m.id) goal ships not spawned (eligible=\(goalEligible), systemMatches=\(goalSystemMatches), shipSystem=\(m.shipSystem), currentSys=\(currentSys), remaining=\(am.shipObjectivesRemaining))")
            }

            // Auxiliary (flavor) ships — no goal, standard AI.
            // AI-14: they jump in after a `Rand(70) + 70`-tick timer from a random
            // side; without Flags 0x0010 each one spends the mission's budget.
            let auxLeft = m.infiniteAuxShips ? m.auxShipCount : (am.auxShipsRemaining ?? m.auxShipCount)
            if auxLeft > 0, m.auxShipDude >= 128,
               missionSystemMatches(code: m.auxShipSystem, active: am, currentSystem: currentSys, game: game) {
                scene.scheduleMissionArrival(missionID: m.id, dudeID: m.auxShipDude, count: auxLeft,
                                             goal: .none, behavior: .standard, auxiliary: true)
            }
        }
    }

    /// A mission ship left the fight: destroyed (counted against a disable,
    /// escort or unboarded board/rescue goal, which then fails) or — for a
    /// chase-off goal — jumped out (MS-11).
    private func handleMissionShipLost(missionID: Int, goal: MissionShipGoal) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        if goal == .chaseOff {
            engine.missionShipLeft(missionID: missionID)
        } else {
            engine.missionShipDestroyed(missionID: missionID)
        }
        model.pilot.state = engine.player
        saveGame(reason: .event)
    }

    /// Follow the pilot into `systemID` through the story engine: the system
    /// becomes explored, nebula events fire (for `hops` crossed on the way
    /// too), and the mission-offer rolls are drawn afresh (UI-04, OS-14).
    private func storyArrival(in systemID: Int, via hops: [Int] = []) {
        guard let game = model.data.game else {
            model.pilot.state.currentSystem = systemID
            model.pilot.state.exploredSystems.insert(systemID)
            return
        }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.playerJumped(toSystem: systemID, via: hops)
        model.pilot.state = engine.player
    }

    /// The original's per-tick mission pass, run where it can change anything
    /// in flight: after a jump's days, on launch, after a gate.
    private func runMissionFlightPass() {
        guard let game = model.data.game, !model.pilot.state.activeMissions.isEmpty else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.missionFlightPass()
        model.pilot.state = engine.player
    }

    /// Escort and observe goals need their ships seen: an escort counts as
    /// under way once its ships are present, an observe goal once one is on
    /// screen and uncloaked.
    private func checkMissionShipSightings(_ host: GameHost) {
        guard let game = model.data.game else { return }
        let due = model.pilot.state.activeMissions.compactMap { am -> Int? in
            guard !(am.shipsSighted ?? false), let m = game.mission(am.missionID) else { return nil }
            switch m.shipGoal {
            case .escort:  return host.scene.hasMissionShips(m.id) ? m.id : nil
            case .observe: return host.scene.missionShipInView(m.id) ? m.id : nil
            default:       return nil
            }
        }
        guard !due.isEmpty else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        for id in due { engine.missionShipsSighted(missionID: id) }
        model.pilot.state = engine.player
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
        saveGame(reason: .event)
    }

    /// `mïsn.ShipName` (a `STR#` id), resolved to the name this mission's special
    /// ships fly under. Empty when the mission names none, which leaves each
    /// ship showing its hull type as before.
    private func missionShipName(_ m: MissionRes, game: NovaGame) -> String {
        guard m.shipNameStrID > 0,
              let list = game.stringList(m.shipNameStrID),
              let first = list.strings.first(where: { !$0.isEmpty }) else { return "" }
        return first
    }

    /// `mïsn.ShipSubtitle` (a `STR#` id), resolved to the line shown beneath the
    /// ship's name on the target display (e.g. "Federation Navy"). Empty when
    /// the mission sets none, which is the common case.
    private func missionShipSubtitle(_ m: MissionRes, game: NovaGame) -> String {
        guard m.shipSubtitleStrID > 0,
              let list = game.stringList(m.shipSubtitleStrID),
              let first = list.strings.first(where: { !$0.isEmpty }) else { return "" }
        return first
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
            return game.systemNeighbors(initial).contains(currentSystem)
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
    /// The escape pod has come down (OS-02, `PlayerTick_TimedActionTransition`
    /// 0x0044d490): every active mission is aborted; the pilot is reset to
    /// class 0 keeping only the outfits that stay with them; the pod set down
    /// beside a shipyard in a neighbouring system the pilot knows (else the
    /// first system); `rand(30) + 15` days pass; the ship gets a fresh
    /// registration, every standing returns to its InitialRec, and the pilot
    /// is in flight there with dësc 13999 on screen. Only Strict Play saves.
    private func respawnFromEscapePod() {
        guard let game = model.data.game else { return }
        let deathSystem = nav.currentSystemID
        var engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        for id in model.pilot.state.activeMissions.map(\.missionID) { engine.abortMission(id) }
        model.pilot.state = engine.player
        EscapePodRespawn.resetToClassZero(&model.pilot.state, game: game)
        engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        let target = EscapePodRespawn.respawnStellar(from: deathSystem, state: model.pilot.state, game: game,
                                                     isVisible: { engine.isSystemVisible($0) })
        let systemID = target?.system ?? game.systems().first?.id ?? deathSystem
        model.pilot.state.currentSystem = systemID
        model.pilot.state.exploredSystems.insert(systemID)
        model.pilot.state.landedSpob = nil
        model.pilot.state.shipPositionX = 50
        model.pilot.state.shipPositionY = -50
        model.pilot.state.shipHeading = 0
        var rng = NovaRandom(seed: UInt64(model.pilot.state.date.julianDay) &* 2_654_435_761 &+ UInt64(systemID))
        advanceGameDays(EscapePodRespawn.driftDays(roll30: rng.range(30)))
        EscapePodRespawn.finishRespawn(&model.pilot.state, game: game, galaxy: Galaxy(game: game),
                                       registrationDigits: (0..<4).map { _ in rng.range(9) + 1 })
        model.pilot.save()
        saveGame(reason: .podRespawn)
        nav.configure(game: game, startSystemID: systemID)
        hostSystemID = systemID
        host = GameHost(model: model, systemID: systemID)
        debug.attach(host?.scene)
        setScenePaused(false, reason: "escape pod respawn")
        syncNav(host)
        grabSceneFocus(reason: "escape pod respawn")
        flightMissionServices.storyText = (title: "", text: game.descText(13999))
    }

    private func movePlayerToSystem(_ systemID: Int, keepPosition: Bool) {
        model.pilot.state.currentSystem = systemID
        model.pilot.state.exploredSystems.insert(systemID)
        guard let game = model.data.game, game.system(systemID) != nil else { return }
        // Docked, the original only stashes the move for the launch tail
        // (MS-18): `M` launches at the new system's first nav stellar, `N`
        // skips the launch snap and keeps the old stellar's coordinates.
        guard landedSpobID == nil else { dockedStoryMove = keepPosition; return }
        // In flight `N` keeps the player's exact x/y; `M` places it on the new
        // system's first nav stellar at rest. The rebuild also drops the
        // target and brings the escorts along. Capture before the rebuild.
        let keptPosition = keepPosition ? host?.scene.playerShip?.position : nil
        relocateFlightHost(to: systemID, reason: "story relocate")
        if let keptPosition {
            host?.scene.playerShip?.position = keptPosition
        } else if let navPosition = firstNavStellarPosition(systemID, game: game) {
            host?.scene.playerShip?.position = navPosition
            host?.scene.playerShip?.velocity = Vec2()
        }
    }

    /// A fresh flight host for `systemID` (a story move or a docked move's
    /// launch).
    private func relocateFlightHost(to systemID: Int, reason: String) {
        guard let game = model.data.game else { return }
        nav.configure(game: game, startSystemID: systemID)
        hostSystemID = systemID
        host = GameHost(model: model, systemID: systemID)
        debug.attach(host?.scene)
        setScenePaused(false, reason: reason)
        syncNav(host)
        grabSceneFocus(reason: reason)
    }

    /// The world position of `systemID`'s first nav stellar (spöb y is
    /// +y-down; the world is +y-up), where an `M` move places the player.
    private func firstNavStellarPosition(_ systemID: Int, game: NovaGame) -> Vec2? {
        guard let spob = game.system(systemID)?.spobs.lazy.compactMap({ game.spob($0) }).first else { return nil }
        return Vec2(Double(spob.x), Double(-spob.y))
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

    /// The boarded-player line (0x00412550): "<n> ton(s)" STR# 2002 #391 #373
    /// [#392] "<c> credit(s)" #374, nil when nothing was taken.
    private func playerBoardedLine(tons: Int, credits: Int) -> String? {
        guard tons > 0 || credits > 0 else { return nil }
        let list = host?.game?.stringList(2002)
        func s(_ i: Int) -> String { list?.string(at: i) ?? "" }
        var parts: [String] = []
        if tons > 0 {
            parts += ["\(tons)", tons == 1 ? "ton" : "tons", s(391), s(373)]
            if credits > 0 { parts.append(s(392)) }
        }
        if credits > 0 { parts += ["\(credits)", credits < 2 ? "credit" : "credits"] }
        parts.append(s(374))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The landing fee (EC-05): the full `spöb` fee, waived at a dominated
    /// stellar. Clearance already refused a landing the player couldn't pay for.
    private func chargeLandingFee(spobID: Int) {
        guard let game = host?.game, let spob = game.spob(spobID) else { return }
        let fee = LandedServices.landingFee(spob: spob, state: model.pilot.state)
        guard fee > 0 else { return }
        model.pilot.state.credits = max(0, model.pilot.state.credits - fee)
        Log.spaceport.debug("Landing fee \(fee) cr charged at spob \(spobID, privacy: .public)")
    }

    /// Docking: the fee, then the free refit. The original refills shields and
    /// armor at no cost on every launch (`Stellar_Launch`, EC-06); doing it on
    /// touchdown leaves the pilot full for the takeoff rebuild either way.
    private func repairOnLanding(spobID: Int) {
        guard let ship = host?.scene.playerShip else { return }
        chargeLandingFee(spobID: spobID)
        ship.shield = ship.maxShield
        ship.armor = ship.maxArmor
        model.pilot.state.armor = ship.armor
        model.pilot.state.shield = ship.shield
    }

    /// The escort fleet pass on leaving a spaceport (EC-22): marked sales and
    /// upgrades are processed at a shipyard stellar, and one dialog reports
    /// them (STR# 2002 #298–#301). Upgraded hulls appear when the launch
    /// rebuilds the system.
    private func runEscortFleetPass(spobID: Int) {
        guard let game = host?.game, let spob = game.spob(spobID) else { return }
        let pass = model.pilot.runEscortFleetPass(at: spob, game: game, disabled: disabledEscortRecordIDs())
        guard pass.transactions > 0 else { return }
        for id in pass.soldIDs { host?.scene.despawnEscort(recordID: id) }
        flightMissionServices.showStoryText(PilotEconomy.escortFleetPassText(pass, game: game), title: "")
        escortRefresh += 1
    }

    /// Escort payroll (EC-20): `periods` periods — one per spaceport visit,
    /// the travel days per jump.
    private func payEscorts(periods: Int) {
        guard periods > 0, let game = model.data.game, !model.pilot.state.hiredEscorts.isEmpty else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.processEscortPayroll(periods: periods, skipping: disabledEscortRecordIDs())
        model.pilot.state = engine.player
    }

    /// Roster ids of escorts whose live ship is disabled: the payroll and the
    /// sale pass skip them (`Ship_IsShipDisabled`).
    private func disabledEscortRecordIDs() -> Set<Int> {
        host?.scene.disabledEscortRecordIDs() ?? []
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
    /// Durably save the pilot for `reason`, if it's a save point (the
    /// original's cadence unless `frequentAutosave`; see `PilotSaveReason`).
    /// Spent munitions are folded into the pilot first (UI-02). Under
    /// `frequentAutosave` the live ship's position/heading is recorded so an
    /// in-flight save resumes in place; otherwise none is kept and the pilot
    /// reloads at the stellar it launched from.
    private func saveGame(reason: AppModel.SaveReason) {
        if model.settings.enhancements.frequentAutosave, let ship = host?.scene.playerShip {
            model.pilot.state.shipPositionX = ship.position.x
            model.pilot.state.shipPositionY = ship.position.y
            model.pilot.state.shipHeading = ship.angle
        } else {
            // The original saves no position: a pilot reloads at the stellar it
            // last launched from, on a random heading (UI-01).
            model.pilot.state.shipPositionX = nil
            model.pilot.state.shipPositionY = nil
            model.pilot.state.shipHeading = nil
        }
        recordMunitions()
        host?.scene.persistOutgoingDefenseState()   // AI-15 garrisons touched this visit
        model.autosave(reason: reason)
    }

    /// Fold the rounds and fighters the live ship has left back into the pilot's
    /// owned ammunition (UI-02).
    private func recordMunitions() {
        guard let ship = host?.scene.playerShip, ship.isAlive, let game = host?.game else { return }
        Munitions.record(ship, into: &model.pilot.state, game: game)
    }

    private func syncCombatStanding() {
        guard let scene = host?.scene else { return }
        // Crimes committed in flight flooded the live per-system reputation
        // (EC-02); fold the change into the pilot.
        model.pilot.state.applyReputationDelta(scene.consumeReputationDelta())
        // The same crimes revoke crime-sensitive allied ranks (EC-10).
        if let game = model.data.game {
            for crime in scene.consumeCrimeEvents() {
                model.pilot.state.revokeRanks(forCrime: crime.kind, against: crime.victim, game: game)
            }
        }
        // Live stellar damage carries over to the next visit (OS-13).
        let armor = scene.liveStellarStrength
        if !armor.isEmpty {
            var left = model.pilot.state.stellarStrengthLeft ?? [:]
            for (id, value) in armor where !model.pilot.state.isStellarDestroyed(id) && value >= 0 {
                left[id] = value
            }
            model.pilot.state.stellarStrengthLeft = left
        }
        let delta = scene.consumeCombatRatingDelta()
        if delta != 0 {
            model.pilot.state.combatRating = CombatRatingRule.fold(model.pilot.state.combatRating, adding: delta)
            scene.syncPlayerCombatRating(model.pilot.state.combatRating)
        }
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
        // (Bible: 1000px, adjustable by "hyperspace dist mod" outfits). The scene
        // posts a "fly further out" message; close the map (if it was the trigger)
        // so that message is visible, and return `true` (handled) so a `J` press
        // doesn't then re-open the map over it — the player has a course, they're
        // just too close to use it yet.
        if let galaxy = host.galaxy {
            host.scene.hyperspaceNoJumpRadius = model.pilot.hyperspaceNoJumpRadius(galaxy: galaxy)
        }
        guard host.scene.canEnterHyperspace() else { nav.showingMap = false; return true }
        let destID = nav.route[hops - 1]
        // The ship turns toward the armed first hop, even on a multi-jump (A9).
        let outbound = outboundHeading(from: nav.currentSystemID, to: nav.route[0])
        let fastJump = host.galaxy.map { model.pilot.hasInstantJump(galaxy: $0) } ?? false
        let speed = host.galaxy.map { model.pilot.jumpSpeedFactor(galaxy: $0) } ?? 1
        nav.showingMap = false
        host.scene.beginJump(to: destID, outboundHeading: outbound, instant: fastJump, speed: speed) {
            // The jump fires: commit the arrival in the model. `commitArrival`
            // spends one jump's fuel however many hops a multi-jump crossed
            // (FL-06) and pins the destination even if the route drifted during
            // the sequence, so nav and the loaded system can't disagree.
            hostSystemID = destID                              // set first: keeps onChange from also rebuilding the host
            // Travel days, computed once even for a multi-jump: the most any
            // ship making the jump costs — this hull and its ModType-22 outfits,
            // or an attached escort's hull (FL-05).
            let days = max(host.galaxy.map { PilotEconomy.travelDays(model.pilot.state, galaxy: $0) } ?? 1,
                           host.scene.attachedShipsTravelDays())
            let passedThrough = Array(nav.route.prefix(max(0, hops - 1)))
            _ = nav.commitArrival(at: destID, hops: hops)
            model.pilot.state.fuel = host.scene.playerShip?.fuel
            // Only the final system is explored; the hops in between still
            // fire their nebula events (OS-14).
            storyArrival(in: destID, via: passedThrough)
            advanceGameDays(days)
            payEscorts(periods: days)                          // one period per travel day (EC-20)
            runMissionFlightPass()                             // a deadline that ran out fails now
            model.pilot.save()
            saveGame(reason: .jump)                            // `frequentAutosave` only (UI-01)
            // Attach mission ships and escorts after reloadSystem has replaced
            // the world, through the scene's onSystemReloaded hook.
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

    /// The right-edge clearance touch-only UI (the on-screen controls, the
    /// land prompt) must keep so it never paints over the HUD. In authentic
    /// mode that's the reserved sidebar; in Modern/Nova Swift mode there's no
    /// reserved sidebar (the scene fills the width), but `GameHUDView` still
    /// floats its own info stack in the top-right corner, so touch UI insets
    /// by that instead — without this both claim the same corner.
    private func touchRightInset(_ host: GameHost, in size: CGSize) -> CGFloat {
        if let style = activeHUDStyle(host) {
            return Self.sidebarWidth(in: size, style: style)
        }
        return GameHUDView.reservedRightWidth(largerHUD: model.settings.largerHUD)
    }

    /// The authentic status-bar style to actually render, or nil to fall back to
    /// the port's own modern `GameHUDView`. Nil whenever the player is in the
    /// Nova Swift / "Modern interface" mode — even when the data ships an `ïntf`
    /// — so the modern HUD overlays the play area instead of the authentic
    /// sidebar reserving screen width. `GameHost` always builds `hudStyle`; the
    /// view decides per-frame whether to use it, so toggling the setting live
    /// swaps HUDs without rebuilding the host.
    private func activeHUDStyle(_ host: GameHost) -> AuthenticHUDStyle? {
        model.settings.modernHUD ? nil : host.hudStyle
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
        // Game controller: hand it the same discrete-action sink and "flight
        // owns input" gate the keyboard paths below use, plus the live button
        // map. Re-wired when the host is rebuilt (depart swaps the scene) and
        // when the player rebinds buttons in Settings → Controls.
        .onAppear { wirePadController(host) }
        .onChange(of: ObjectIdentifier(host.scene)) { wirePadController(host) }
        .onChange(of: model.padBindings) { wirePadController(host) }
        #if os(macOS)
        // On macOS the flight scene owns the keyboard through one AppKit event
        // monitor rather than SwiftUI focus. It drives every binding — including
        // bare modifiers (Control/Option/Command/Shift), which `.onKeyPress`
        // never reports — and *consumes* the key while flying, so nothing falls
        // through to the system alert beep or to SwiftUI focus navigation
        // ("switching screens"). Gated on `flightControlsVisible`, so overlays
        // and text fields keep normal keyboard behaviour. See FlightKeyboardMonitor.
        //
        // The cross-platform `KeyboardControls` (`.onKeyPress`) is deliberately
        // NOT applied on macOS: `.onKeyPress` on this `.focusable()` view still
        // fires even though the monitor returns `nil`, so running both would
        // double-handle every key. Continuous bindings (`= pressed`) are
        // idempotent and survive that, but discrete actions *toggle* — two fires
        // per press cancel out, so ESC/M would open the menu/map and instantly
        // close it. The monitor already covers every binding onKeyPress did.
        .background(FlightKeyboardMonitor(input: host.input, bindings: model.bindings,
                                          isActive: { flightControlsVisible },
                                          onDiscrete: handleDiscrete))
        #else
        .modifier(KeyboardControls(input: host.input, bindings: model.bindings,
                                   onDiscrete: handleDiscrete))
        #endif
    }

    /// The on-screen flight controls show only during actual flight — hidden
    /// while landed or whenever a modal (map, menu, hail, a mobile panel, the
    /// plunder dialog, the debug suite) owns the screen, so they neither draw
    /// over nor steal touches from it.
    /// Points the pad at the container's discrete-action handler and gates it
    /// on the same "flight owns the screen" rule as the keyboard. Idempotent —
    /// safe to call from onAppear and every re-wire trigger.
    private func wirePadController(_ host: GameHost) {
        host.controller.bindings = model.padBindings
        host.controller.onDiscrete = handleDiscrete
        host.controller.isActive = { flightControlsVisible }
        // While flight owns the sticks (and Ⓐ fires weapons), the UI cursor
        // must stay hidden and inert; it takes over the moment a modal/landing
        // screen opens. Tracks the same gate as the controller's flight input.
        CursorTargets.shared.suppressed = flightControlsVisible
    }

    /// The in-flight overlays that should freeze the sim behind them but aren't
    /// already covered by their own `onChange` above. Boarding is the one the
    /// player notices most: the plunder dialog is a decision, not a glance, and
    /// the fight it interrupts kept going while it was open.
    private var sceneFreezingOverlayOpen: Bool {
        landedSpobID == nil
            && (boardManifest != nil || showMissionsPanel || showPilotInfoPanel
                || showStoryGuide || flightMissionServices.storyText != nil)
    }

    private var flightControlsVisible: Bool {
        landedSpobID == nil && !nav.showingMap && !showMenu && hailDialogState == nil
            && !showMissionsPanel && !showPilotInfoPanel && !showEscortsPanel
            && !showShipInfoPanel && boardManifest == nil && !console.isPresented
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
                           shipFigures: playerInfoFigures(),
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
                        onGroupCommand: { category, command in
                            scene.commandEscortGroup(category: category, command: command)
                            escortRefresh += 1
                        },
                        strings: model.data.game?.stringList(2002),
                        onRelease: { releaseEscort($0) },
                        pilot: model.pilot.state,
                        onUpgrade: { upgradeEscort($0) },
                        onCancelUpgrade: { cancelEscortUpgrade($0) },
                        onSell: { sellEscort($0) },
                        onCancelSale: { cancelEscortSale($0) },
                        onClose: { showEscortsPanel = false })
                .shrinkToFitViewport()
                .transition(.opacity)
        }
        if showShipInfoPanel, let graphics = model.uiGraphics, let game = model.data.game {
            Color.black.opacity(0.5).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showShipInfoPanel = false }
            // Describe the targeted ship if one is locked, otherwise the player's
            // own hull — the same "target, falling back to self" the HUD uses.
            let shipID = host?.hud.targetShipTypeID ?? model.pilot.state.shipType
            ShipInfoView(graphics: graphics, ship: game.ship(shipID),
                         onDone: { showShipInfoPanel = false })
                .transition(.opacity)
        }
        if let m = boardManifest, let scene = host?.scene {
            let _ = boardRefresh   // re-read after taking loot
            PlunderView(
                graphics: host?.graphics,
                targetName: m.name,
                cargoLines: m.cargo.map { PlunderLine(label: commodityLabel($0.commodity),
                                                      amount: "\($0.tons)") },
                creditsAboard: m.credits,
                ammoAboard: scene.ammoAboard(m.shipID),
                energyAboard: Int(scene.fuelAboard(m.shipID).rounded()),
                captureChance: m.captureChance,
                onTakeCargo: { plunderPress(scene, m.shipID) { plunderTakeCargo(scene, shipID: m.shipID) } },
                onTakeCredits: { plunderPress(scene, m.shipID) { plunderTakeCredits(scene, shipID: m.shipID) } },
                onTakeAmmo: { plunderPress(scene, m.shipID) { plunderTakeAmmo(scene, shipID: m.shipID) } },
                onTakeEnergy: { plunderPress(scene, m.shipID) { plunderTakeFuel(scene, shipID: m.shipID) } },
                onCaptureShip: { plunderPress(scene, m.shipID) { plunderCapture(scene, shipID: m.shipID) } },
                onDismiss: {
                    // Leaving clears the panic; the hulk stays adrift,
                    // disabled (EC-18).
                    scene.finishBoardingWithoutCapture(m.shipID)
                    plunderPanic = nil
                    boardManifest = nil
                })
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

    /// Bomb outfits (OS-08): a fuse seeded at `rand(100)` counts 30 Hz ticks
    /// to 300 (6.7–10 s after the bomb comes aboard, 0x0044b3d4). A lethal bomb
    /// (ModType 47) then destroys the ship outright — game over, no escape pod;
    /// a nonlethal one (ModType 50) throws all its units overboard, plays spöb
    /// impact effect `ModVal − 128` and deals armor-only damage
    /// `armor + rand(armor × 0.5 + 1)` of the hull's base armor.
    private func checkHazardOutfits(_ host: GameHost) {
        guard let game = host.game else { return }
        let bombs = model.pilot.state.outfits.filter { $0.value > 0 }.keys.sorted().compactMap { oid -> (OutfRes, Int, Bool)? in
            guard let o = game.outfit(oid) else { return nil }
            for (type, value) in o.modifiers {
                if type == .bomb { return (o, value, true) }
                if type == .nonlethalBomb { return (o, value, false) }
            }
            return nil
        }
        guard let (outfit, value, lethal) = bombs.first else { bombFuse = nil; return }
        guard let fuse = bombFuse else { bombFuse = Int.random(in: 0..<100); return }
        guard fuse >= 300 else { bombFuse = fuse + 1; return }
        bombFuse = nil
        guard let ship = host.scene.playerShip, ship.isAlive else { return }
        if lethal {
            let line = value >= 0 ? game.descText(value)
                : (game.stringList(2002)?.string(at: 38) ?? "A bomb has exploded onboard your ship!")
            host.hud.post(line)
            ship.hasEscapePod = false
            ship.hasAutoEject = false
            _ = ship.applyDamage(shield: 1_000_000, armor: 1_000_000, piercing: true)
            Log.scene.notice("Bomb outfit \(outfit.id, privacy: .public) detonated")
        } else {
            model.pilot.state.outfits[outfit.id] = nil
            let base = Double(game.ship(model.pilot.state.shipType)?.armor ?? 0)
            let damage = base + Double(Int.random(in: 0..<max(1, Int(base * 0.5 + 1))))
            _ = ship.applyDamage(shield: 0, armor: damage, piercing: true)
            host.scene.triggerPlayerOutfitExplosion(radius: 24, boomID: value >= 128 ? value - 128 : nil)
            Log.scene.notice("Nonlethal bomb outfit \(outfit.id, privacy: .public) went off")
        }
    }

    /// Immediately reflect a spaceport transaction (new ship, refuel, repair)
    /// in the on-screen HUD instead of waiting for the takeoff rebuild to pick
    /// it up. `hud.*` are manually-synced caches of `PlayerState`, not live-
    /// bound (see `GameScene.debugSyncCredits`) — recomputes fresh from the
    /// current pilot state and that ship's real loadout, the same source
    /// `depart()`'s own rebuild (`GameHost.buildPlayerShip`) uses, so this is
    /// safe to call after any purchase regardless of what changed.
    private func syncHUDFromPilotState() {
        guard let host, let galaxy = host.galaxy, let game = host.game else { return }
        let state = model.pilot.state
        host.hud.credits = state.credits
        let res = game.ship(state.shipType)
        host.hud.shipName = state.shipName.isEmpty ? (res?.displayName ?? "") : state.shipName
        guard let lo = PilotEconomy.loadout(state, galaxy: galaxy) else { return }
        let fuel = state.fuel.map { min($0, lo.maxFuel) } ?? lo.maxFuel
        let shield = state.shield.map { min($0, lo.maxShield) } ?? lo.maxShield
        let armor = state.armor.map { min($0, lo.maxArmor) } ?? lo.maxArmor
        host.scene.syncLiveHUDStats(fuel: fuel, maxFuel: lo.maxFuel,
                                    shield: shield, maxShield: lo.maxShield,
                                    armor: armor, maxArmor: lo.maxArmor)
        // Cargo/mass-affecting outfits (Cargo Expansion, etc.) and speed/accel/
        // turn outfits only ever change `lo`, never a cached copy — but the HUD's
        // own cargo/speed readouts are separate manually-synced caches too, and
        // were missing from this sync entirely, so buying one of these left the
        // sidebar showing stale numbers until the next takeoff rebuilt the ship.
        host.hud.cargoCapacity = lo.cargoCapacity
        host.hud.cargoUsed = state.usedCargoSpace
        host.hud.maxSpeed = lo.speed
    }

    /// A plunder button press: after a loot action the hulk may blow itself up
    /// first (`rand(100) ≤ panic`, STR# 2002 #113), ending the boarding.
    private func plunderPress(_ scene: GameScene, _ shipID: Int, _ action: () -> Void) {
        if var panic = plunderPanic {
            let blows = panic.rollsSelfDestruct(rand: { Int.random(in: 0..<$0) })
            plunderPanic = panic
            if blows {
                hulkSelfDestructs(scene, shipID)
                return
            }
        }
        action()
    }

    private func hulkSelfDestructs(_ scene: GameScene, _ shipID: Int) {
        scene.selfDestructHulk(shipID)
        host?.hud.post(host?.game?.stringList(2002)?.string(at: 113) ?? "The ship self-destructs!")
        plunderPanic = nil
        boardManifest = nil
    }

    private func plunderTakeCredits(_ scene: GameScene, shipID: Int) {
        let credits = scene.plunderCredits(shipID)
        guard credits > 0 else { return }
        plunderPanic?.looted(.credits)
        model.pilot.state.credits += credits
        model.pilot.save()
        host?.hud.credits = model.pilot.state.credits
        host?.hud.post("Took \(credits) credits.")
        refreshBoard(scene, shipID: shipID)
    }

    /// The Cargo button (0x00482940, EC-18): the hulk's rolled cargo, cut to
    /// the fleet's free space; "You salvaged N tons of X from this ship."
    /// (STR# 2002 #115/#391/#108), or #114 when nothing fits.
    private func plunderTakeCargo(_ scene: GameScene, shipID: Int) {
        guard let game = host?.game, let galaxy = host?.galaxy else { return }
        let room = PilotEconomy.cargoFree(model.pilot.state, galaxy: galaxy)
        let offered = scene.boardingManifest(shipID)?.cargo.first
        let taken = scene.plunderCargo(shipID, room: room)
        guard offered != nil else { return }
        plunderPanic?.looted(.cargo)
        let text = OriginalText(game: game)
        guard let (commodity, tons) = taken.first else {
            host?.hud.post(text.misc(114))
            refreshBoard(scene, shipID: shipID)
            return
        }
        model.pilot.state.cargo[commodity, default: 0] += tons
        model.pilot.save()
        let name = Commodity(rawValue: commodity).map { game.commodityName($0) } ?? ""
        host?.hud.post("\(text.misc(115)) \(OriginalText.grouped(tons)) \(text.misc(tons == 1 ? 1 : 2)) \(text.misc(391)) \(name) \(text.misc(108))")
        refreshBoard(scene, shipID: shipID)
    }

    /// "Energy" plunder button — siphon the hulk's jump fuel. The engine adds it
    /// to the live player ship (clamped to capacity); persist the new value to the
    /// pilot so it survives the flight, and let `updateHUD` repaint the gauge.
    private func plunderTakeFuel(_ scene: GameScene, shipID: Int) {
        let took = scene.plunderFuel(shipID)
        guard took >= 1 else { return }
        plunderPanic?.looted(.fuel)
        model.pilot.state.fuel = scene.playerShip?.fuel
        model.pilot.save()
        let jumps = Int((took / 100).rounded())
        host?.hud.post(jumps > 0 ? "Siphoned \(Int(took)) fuel (~\(jumps) jump\(jumps == 1 ? "" : "s"))."
                                 : "Siphoned \(Int(took)) fuel.")
        refreshBoard(scene, shipID: shipID)
    }

    /// "Ammo" plunder button — top up the player's matching weapons from the
    /// hulk's magazines. Ammunition lives on the in-flight weapon mounts (no
    /// separate save field), so this needs no pilot write.
    private func plunderTakeAmmo(_ scene: GameScene, shipID: Int) {
        let rounds = scene.plunderAmmo(shipID)
        guard rounds > 0 else { return }
        plunderPanic?.looted(.ammo)
        host?.hud.post("Transferred \(rounds) round\(rounds == 1 ? "" : "s") of ammunition.")
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
            // "Replace the ship with the mission's special ship" (0x0040), for a
            // one-ship mission (AI-39).
            if pers.replacedByMissionShip, let game = host?.game, offer.mission.shipCount == 1,
               offer.mission.shipDude >= 128 {
                host?.scene.replacePersWithMissionShip(personID: pid, mission: offer.mission,
                                                       name: missionShipName(offer.mission, game: game),
                                                       subtitle: missionShipSubtitle(offer.mission, game: game))
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

    /// From the table prewarmed once per data set at load time
    /// (`GameDataController.prewarm()`) — no per-call rescan. `game` param
    /// kept only so callers don't need to unwrap `host.game` twice.
    private func storylineTag(for missionID: Int, game: NovaGame?) -> MissionStorylineTag? {
        guard model.settings.showMissionStorylineTags, game != nil else { return nil }
        return model.data.storylineTags[missionID]
    }

    private func openStoryline(_ key: String) {
        storyGuideFocusKey = key
        showStoryGuide = true
    }

    /// Roll a capture attempt. On success, closes the plunder dialog and hands
    /// off to `pendingCaptureChoice` so the player picks "use as escort" or
    /// "take command of it" — EV Nova offers both outcomes for a successful
    /// capture, not just recruit-as-escort.
    private func plunderCapture(_ scene: GameScene, shipID: Int) {
        let capturedPers = scene.personID(forEntity: shipID)
        guard let cap = scene.attemptCapture(shipID) else {
            host?.hud.post(host?.game?.stringList(2002)?.string(at: 125) ?? "Capture attempt failed.")
            refreshBoard(scene, shipID: shipID)
            return
        }
        // One capture in ten ends with the crew scuttling the ship.
        if Int.random(in: 0..<10) == 0 {
            hulkSelfDestructs(scene, shipID)
            return
        }
        plunderPanic = nil
        boardManifest = nil
        // UI-17: a captured përs is consumed (0x00423fa0) — it never spawns again.
        if let pid = capturedPers {
            model.pilot.state.recordPersDefeated(pid)
        }
        pendingCaptureChoice = cap
    }

    /// "Use as escort" outcome: register the captured hull in the persistent
    /// roster (free — no daily fee) so it follows the player between systems
    /// and can later be sold/upgraded at a shipyard.
    private func recruitCapturedShipAsEscort(_ cap: (entityID: Int, shipType: Int, name: String)) {
        guard let scene = host?.scene else { return }
        scene.recruitCapturedEscort(cap.entityID)
        let name = cap.name.isEmpty ? (model.data.game?.ship(cap.shipType)?.name ?? "Escort") : cap.name
        let record = model.pilot.state.registerEscort(shipType: cap.shipType, name: name, origin: .captured)
        scene.tagEscort(entityID: cap.entityID, recordID: record.id)
        applyOnCapture(shipType: cap.shipType)
        model.pilot.save()
        host?.hud.post("Ship captured — it joins your escorts.")
        pendingCaptureChoice = nil
    }

    /// "Take command" outcome: the captured hull becomes the player's new
    /// flagship, and the ship they were flying joins the wing as a free
    /// escort instead (same billing as a normal capture — `EscortOrigin
    /// .captured` — just applied to the ship being stepped out of). Mirrors
    /// the mission `C/E/H` ship-swap path: the hull change lands in
    /// `PlayerState` first, then `rebuildFlightHost` picks it up.
    private func takeCommandOfCapturedShip(_ cap: (entityID: Int, shipType: Int, name: String)) {
        guard let game = model.data.game else { return }
        // The old hull joins the wing when there is room (STR# 2002 #304/#305).
        let kept = PilotEconomy.takeCommandOfCapturedHull(&model.pilot.state, hull: cap.shipType, game: game)
        host?.hud.post(game.stringList(2002)?.string(at: kept ? 304 : 305)
                       ?? (kept ? "You retained your old ship as an escort." : "You were unable to retain your old ship as an escort."))
        model.pilot.save()
        pendingCaptureChoice = nil
        rebuildFlightHost(reason: "captured-ship command swap")
    }

    /// Bible `shïp.OnCapture`: control-bit set expression run when the player
    /// captures a hull of this type (usually blank; some story hulls flip a
    /// bit on capture). Applies regardless of which capture outcome is chosen
    /// — capturing that hull type is what matters, not what's done with it.
    private func applyOnCapture(shipType: Int) {
        guard let game = model.data.game, let onCapture = game.ship(shipType)?.onCapture,
              !onCapture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state)
        engine.apply(set: onCapture,
                     source: "shïp \(shipType) \"\(game.ship(shipType)?.name ?? "")\" OnCapture")
        model.pilot.state = engine.player
    }

    /// Release the escort with persistent `recordID` — the escort window's
    /// Release (0x004853a0, EC-22). It first takes its share of the fleet's
    /// cargo (EC-21, whatever its hull), leaves the roster (a hired one stops
    /// billing) and stays in the system as an ordinary NPC with its class's
    /// default AI. Works whether or not it's currently spawned.
    private func releaseEscort(_ recordID: Int) {
        if let rec = model.pilot.state.escort(id: recordID), let game = model.data.game {
            transferCargoToEscort(holds: game.ship(rec.shipType)?.cargoSpace ?? 0, game: game)
        }
        _ = model.pilot.state.removeEscort(id: recordID)
        model.pilot.save()
        host?.scene.releaseEscort(recordID: recordID)
        escortRefresh += 1
    }

    /// The fleet's cargo share an escort leaving the wing carries off (EC-21).
    @discardableResult
    private func transferCargoToEscort(holds: Int, game: NovaGame) -> [Int: Int] {
        let missionCargo = StoryEngine(game: game, player: model.pilot.state).carriedMissionCargo()
        return PilotEconomy.transferCargoToEscort(&model.pilot.state, recipientHolds: holds,
                                                 missionCargo: missionCargo, galaxy: Galaxy(game: game))
    }

    /// Toggle escort `recordID`'s upgrade mark on (EC-22): applied by the fleet
    /// pass on leaving a shipyard stellar; the window shows STR# 2002 #292.
    private func upgradeEscort(_ recordID: Int) {
        guard let game = model.data.game else { return }
        if model.pilot.requestEscortUpgrade(recordID: recordID, game: game) != nil { escortRefresh += 1 }
    }

    /// Clear escort `recordID`'s upgrade mark.
    private func cancelEscortUpgrade(_ recordID: Int) {
        model.pilot.cancelEscortUpgrade(recordID: recordID)
        escortRefresh += 1
    }

    /// Toggle escort `recordID`'s sale mark on (EC-22): sold by the fleet pass
    /// on leaving a shipyard stellar; the window shows STR# 2002 #295.
    private func sellEscort(_ recordID: Int) {
        if model.pilot.requestEscortSale(recordID: recordID) { escortRefresh += 1 }
    }

    /// Clear escort `recordID`'s sale mark.
    private func cancelEscortSale(_ recordID: Int) {
        model.pilot.cancelEscortSale(recordID: recordID)
        escortRefresh += 1
    }

    /// Open one of the mobile action-menu panels over flight.
    private func openMobilePanel(_ panel: MobilePanel) {
        switch panel {
        case .missions:  showMissionsPanel = true
        case .pilotInfo:
            // Combat rating/legal record only flow from the live `Diplomacy`/
            // scene into the persisted pilot at landing/jump/backgrounding or
            // the 3-minute heartbeat (`syncCombatStanding`) — opening Pilot Info
            // mid-flight right after a kill could otherwise show stale numbers
            // for up to those 3 minutes.
            syncCombatStanding()
            showPilotInfoPanel = true
        }
    }

    /// Dump the hold — the mobile Pilot-info panel's "Jettison Cargo".
    /// The live ship's figures for Player Info's stat grid (UI-13), in the
    /// original's per-tick units.
    private func playerInfoFigures() -> PlayerInfoPages.ShipFigures? {
        guard let scene = host?.scene, let p = scene.playerShip, let speed = scene.playerEffectiveMaxSpeed else { return nil }
        let ticks = OriginalClock.ticksPerSecond
        return PlayerInfoPages.ShipFigures(
            turnDegPerTick: p.stats.playerTurnDegPerTick,
            thrustPerTick2: p.stats.acceleration / (ticks * ticks),
            maxSpeedPerTick: speed / ticks,
            shield: p.shield, maxShield: p.maxShield,
            armor: p.armor, maxArmor: p.maxArmor,
            destroyed: !p.isAlive, fuel: p.fuel)
    }

    /// Player Info's Jettison Cargo (0x0041f330 with jettison-all, UI-13):
    /// the hold and every abortable mission's cargo go overboard as floating
    /// pods from the ship and its freighter escorts, and the line reads
    /// "Cargo jettisoned." (STR# 2002 #289) — or the mission failure that
    /// replaced it. Docked, nothing is drawn or shown.
    private func jettisonHold() {
        guard let game = model.data.game else { return }
        let docked = landedSpobID != nil
        let fleet = host?.galaxy.map { PilotEconomy.cargoCapacity(model.pilot.state, galaxy: $0) } ?? 0
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        let thrown = engine.jettisonCargo(docked: docked)
        model.pilot.state = engine.player
        model.pilot.save()
        host?.scene.playerShip?.cargo = model.pilot.state.cargo
        guard !docked, thrown.total > 0 else { return }
        host?.scene.spawnJettisonPods(total: thrown.total, ordinaryTotal: thrown.ordinaryTotal, fleetCapacity: fleet)
        if !thrown.missionFailedShown { host?.hud.post(game.stringList(2002)?.string(at: 289) ?? "") }
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
            // Nothing selected yet (the player never clicked a planet) — target
            // the closest landable body so Land always has something to act on.
            scene.selectNearestLandableIfNoneSelected()
            if model.settings.autoLanding {
                // Auto-landing: fly to the targeted/nearest landable body and set
                // down on arrival. Pressing Land again cancels an in-progress
                // approach. Falls back to an immediate land if we're already
                // parked on a pad with nothing to fly to.
                if scene.isAutoLanding { scene.cancelAutoLand() }
                else if scene.beginAutoLandOnSelected() { /* autopilot engaged */ }
                else if let id = scene.attemptLand() { requestLanding(id) }
            } else if model.settings.enhancements.forgivingLanding {
                // The `forgivingLanding` enhancement: one press, nearest body.
                if let id = scene.attemptLand() { requestLanding(id) }
            } else {
                pressLand(scene)
            }
        case .openMenu, .pauseGame:
            if landedSpobID != nil { return }
            if gateMapOrigin != nil { gateMapOrigin = nil; return }
            if nav.showingMap { nav.showingMap = false }
            else if sidebarEnabled { showMenu.toggle() }
            else {
                // Classic (sidebar off): mimic the original — save and drop straight
                // to the authentic main menu, with no port-original overlay.
                saveGame(reason: .manual)
                model.returnToMainMenu()
            }
        case .galaxyMap:
            nav.autoRoutePlotting = model.settings.enhancements.autoRoutePlotting
            nav.showingMap.toggle()
        case .hyperjump:
            // With a jump armed, J engages the hyperdrive along the route. With
            // none the original says so (STR# 2002 #29), and without the fuel
            // for a jump "Insufficient energy" (#10); the `autoRoutePlotting`
            // enhancement opens the map instead.
            if !attemptJump() {
                if model.settings.enhancements.autoRoutePlotting {
                    nav.showingMap = true
                } else if let game = model.data.game {
                    let text = OriginalText(game: game)
                    host?.hud.post(text.misc(nav.nextJumpHopCount > 0 ? 10 : 29))
                }
            }
        case .targetNearest:
            host?.scene.selectNearestTarget()
        case .nearestHostile:
            host?.scene.selectNearestHostile()
        case .targetNext:
            host?.scene.cycleTarget()
        case .targetPrevious:
            host?.scene.cycleTarget(reverse: true)
        case .targetEscortNext:
            host?.scene.cycleTarget(squad: true)
        case .clearTarget:
            if model.settings.enhancements.modernKeyBindings {
                host?.scene.clearTarget()
            } else {
                // The original's N clears the travel selection: a selected
                // stellar and an armed jump (Alt-N clears the ship target).
                host?.scene.clearTravelSelection()
                nav.disarmJump()
            }
        case .clearShipTarget:
            host?.scene.clearShipTarget()
        case .selectNav1, .selectNav2, .selectNav3, .selectNav4:
            let index = [GameAction.selectNav1, .selectNav2, .selectNav3, .selectNav4].firstIndex(of: action) ?? 0
            host?.scene.selectNavStellar(index: index)
        case .hyperspaceArm:
            // H: the travel channel goes back to hyperspace, re-arming the
            // plotted route's next hop.
            host?.scene.clearTravelSelection()
            nav.rearmRoute()
        case .dismissMessage:
            host?.hud.dismissMessage()
        case .playerInfo:
            model.audio.play(.uiSelect)
            syncCombatStanding()
            showPilotInfoPanel.toggle()
        case .missionInfo:
            model.audio.play(.uiSelect)
            showMissionsPanel.toggle()
        case .clearSecondary:
            host?.scene.playerShip?.clearSecondary()
        case .hailTarget:
            hail()
        case .hailStellar:
            hail(stellar: true)
        case .selectSecondaryNext:
            host?.scene.cycleSecondaryWeapon(forward: true)
        case .selectSecondaryPrev:
            host?.scene.cycleSecondaryWeapon(forward: false)
        case .toggleCloak:
            host?.scene.togglePlayerCloak()
        case .recallFighters:
            host?.scene.recallPlayerFighters()
        case .eject:
            host?.scene.requestEject()
        case .commandEscortAggressive:
            host?.scene.commandEscorts(.aggressive)
        case .commandEscortDefensive:
            host?.scene.commandEscorts(.defensive)
        case .commandEscortEvasive:
            host?.scene.commandEscorts(.evasive)
        case .commandEscortHold:
            host?.scene.commandEscorts(.hold)
        case .openEscorts:
            model.audio.play(.uiSelect)
            showEscortsPanel = true
        case .shipInfo:
            model.audio.play(.uiSelect)
            showShipInfoPanel = true
        case .board:
            // Board the targeted hulk if it's disabled and in reach.
            if let m = host?.scene.attemptBoard() {
                boardManifest = m
                plunderPanic = World.PlunderPanic(rand: { Int.random(in: 0..<$0) })
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
    private func hail(stellar: Bool = false) {
        guard let scene = host?.scene, let result = scene.attemptHail(stellar: stellar) else {
            let debug = host?.scene.debugTargetState
            Log.input.debug("hail() — attemptHail() returned nil; currentTargetID=\(debug?.id?.description ?? "nil", privacy: .public) resolves=\(debug?.resolves ?? false, privacy: .public) selectedPlanetID=\(host?.scene.selectedPlanetID?.description ?? "nil", privacy: .public)")
            return
        }
        switch result {
        case let .ship(entityID, name, shipTypeID, govt, hostile):
            // Hailing one of your own escorts opens its command window (EV Nova's
            // Escorts dialog, DITL #1022) rather than the generic comm dialog.
            let isEscort = scene.isPlayerEscort(entityID)
            Log.input.debug("hail() -> ship entityID=\(entityID, privacy: .public) name=\(name, privacy: .public) isPlayerEscort=\(isEscort, privacy: .public)")
            if isEscort {
                model.audio.play(.uiSelect)
                showEscortsPanel = true
                return
            }
            let personID = host?.scene.personID(forEntity: entityID)
            // The original's hail rules (AI-44, 0x00454910): a beep while
            // cloaked or jumping; "No response." for disabled ships, the
            // Enforcer and Flags-0x0400 governments (përs included);
            // "entering hyperspace" for a ship spinning up.
            let originalCheck = scene.originalHailCheck(entityID: entityID)
            switch originalCheck {
            case .beep?:
                model.audio.play(.uiSelect)
                return
            case let .message(index)?:
                model.audio.play(.uiSelect)
                host?.hud.post(host?.game?.stringList(2002)?.string(at: index) ?? "")
                return
            case .escortWindow?:
                model.audio.play(.uiSelect)
                showEscortsPanel = true
                return
            case .open?, nil:
                break
            }
            // `gövt.cantBeHailed` (Flags1 0x0400): ships of this government give no
            // response to a generic hail. A named pêrs aboard is still reachable —
            // they carry their own comm quotes — so only gate the anonymous case.
            // No `govt` at all (Independent, `GalaxyMapView`'s own fallback for
            // the same case) always gives a response — nothing to gate on.
            if originalCheck == nil, personID == nil, govt?.cantBeHailed == true {
                model.audio.play(.uiSelect)
                host?.hud.post(host?.game?.stringList(2002)?.string(at: 53) ?? "")   // "No response."
                return
            }
            if let govt { model.audio.playHailVoice(govt: govt, hostile: hostile) }
            // The comm identifies a generic ship by its government's `CommName`
            // (Bible: "the short string to show for ships of this government when
            // they are hailed"), not its internal ship name. `nonTalkative`
            // (Flags2 0x0001) govts answer but have nothing to say. No resolvable
            // govt (Independent) falls back to that label, same as elsewhere.
            let commName = govt?.commName ?? "Independent"
            var displayName = commName
            var response: String
            if hostile {
                response = "They aren't interested in talking."
            } else if govt?.nonTalkative == true {
                response = "This is \(commName). They have nothing further to say."
            } else {
                response = "This is \(commName). Go ahead."
            }
            var customPictID: Int?
            var persCommQuote: String?
            // Named person (pêrs): replace the generic response with their comm
            // quote and note any mission they offer.
            if let pid = personID,
               let game = host?.game, let pers = game.pers(pid) {
                let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
                let disabled = host?.scene.isEntityDisabled(entityID) ?? false
                let attacking = host?.scene.isEntityAttackingPlayer(entityID) ?? false
                let enc = PersEncounter.hail(pers, player: model.pilot.state, game: game,
                                             engine: engine, disabled: disabled, attacking: attacking)
                displayName = enc.name
                customPictID = enc.hailPictID
                persCommQuote = enc.commQuote
                if originalCheck == nil, let quote = enc.commQuote ?? enc.hailQuote { response = quote }
                presentPersMissionOffer(pid, missionID: enc.offerMissionID, engine: engine, game: game)
                if pers.quoteOnce {
                    model.pilot.state.markPersQuoteShown(pid); model.pilot.save()
                }
            }
            var shipState = HailDialogState(
                kind: .ship(entityID: entityID, shipTypeID: shipTypeID),
                name: displayName, govtLabel: govt?.targetCode ?? "", hostile: hostile,
                responseText: response, customPictID: customPictID)
            // The original AI's comm window (AI-42/43): one session of rolls
            // per hail; the opening line and the Greetings text come from it,
            // and the middle button begs for mercy while the ship presses on.
            shipComm = scene.openOriginalComm(entityID: entityID, playerCredits: model.pilot.state.credits,
                                              context: shipCommGreetingContext(persCommQuote: persCommQuote))
            shipPayment = nil
            pendingEscortRelease = nil
            if let session = shipComm {
                var line = shipCommLine(session.openingPrompt, session)
                if session.appendsPilotName { line += model.pilot.state.pilotName + "." }
                shipState.responseText = line
                if scene.originalKeepsPressingPlayer(entityID: entityID) {
                    // STR# 150 #25.
                    shipState.assistTitle = host?.game?.stringList(150)?.string(at: 25) ?? "Beg For Mercy"
                }
            }
            hailDialogState = shipState
        case let .planet(spobID, name, _, landable):
            // The stellar comm window (UI-09, 0x00480030): an uninhabited
            // stellar or a gate gets no window, just "No response."
            guard let game = host?.game, let spob = game.spob(spobID) else { return }
            // The window reads the per-system reputation (EC-02): fold in this
            // session's crimes first.
            syncCombatStanding()
            var latch = bribeLatch
            guard let comm = StellarComm.open(spob: spob, system: nav.currentSystemID, state: model.pilot.state,
                                              game: game, diplomacy: host?.galaxy?.makeDiplomacy(),
                                              bribeLatch: &latch, rand: { Int.random(in: 0..<max(1, $0)) }) else {
                model.audio.play(.uiSelect)
                host?.hud.post(game.stringList(2002)?.string(at: 53) ?? "No response.")
                return
            }
            bribeLatch = latch
            host?.scene.noteStellarCommOpened()
            var state = HailDialogState(
                kind: .planet(spobID: spobID), name: name,
                govtLabel: StellarComm.classFragment(spob: spob, game: game), hostile: false,
                landable: landable && landingRefusalReason(spob: spob) == nil,
                responseText: comm.openingText(spob: spob, state: model.pilot.state, game: game))
            state.comm = comm
            refreshPlanetHail(&state, spob: spob, game: game)
            hailDialogState = state
        }
    }

    /// The parts of the stellar comm window that follow the pilot's state:
    /// the status line and the two action buttons' titles.
    private func refreshPlanetHail(_ state: inout HailDialogState, spob: SpobRes, game: NovaGame) {
        guard let comm = state.comm else { return }
        let status = comm.status(spob: spob, system: nav.currentSystemID, state: model.pilot.state, game: game)
        state.statusText = status?.text
        state.statusHostile = status?.hostile ?? false
        let labels = host?.graphics
        func label(_ index: Int, _ fallback: String) -> String { labels?.buttonLabel(index, fallback: fallback) ?? fallback }
        if comm.denied {
            state.topButtonTitle = label(SpaceportLabel.offerBribe, "Offer Bribe")
        } else if model.settings.enhancements.forgivingLanding, landingRefusalReason(spob: spob) != nil {
            state.topButtonTitle = label(SpaceportLabel.requestLanding, "Request Landing")
        } else {
            state.topButtonTitle = label(SpaceportLabel.greetings, "Greetings")
        }
        if model.pilot.state.hasDominated(spob.id) {
            state.tributeTitle = label(SpaceportLabel.release, "Release")
            state.tributeEnabled = !spob.startsDominated
        } else {
            state.tributeTitle = label(SpaceportLabel.demandTribute, "Demand Tribute")
            state.tributeEnabled = true
        }
        state.landable = landingRefusalReason(spob: spob) == nil
    }

    /// The stellar comm's Greetings / Offer Bribe button (EC-25).
    private func planetGreetings() {
        guard var state = hailDialogState, case let .planet(spobID) = state.kind, let comm = state.comm,
              let game = host?.game, let spob = game.spob(spobID) else { return }
        switch comm.greetings(spob: spob, state: model.pilot.state, game: game) {
        case let .reply(text):
            state.responseText = text
            hailDialogState = state
        case let .offerBribe(prompt, price):
            state.responseText = prompt
            hailDialogState = state
            planetPayment = PaymentWindow(price: price, rand: { Int.random(in: 0..<max(1, $0)) })
        }
    }

    /// A press in the bribe's payment window (DLOG 1008).
    private func pressPlanetPayment(_ press: PaymentWindow.Press) {
        guard var window = planetPayment else { return }
        switch window.press(press) {
        case .open:
            planetPayment = window
        case .paid:
            planetPayment = nil
            settlePlanetBribe(paid: true, price: window.price)
        case .refused:
            planetPayment = nil
            settlePlanetBribe(paid: false, price: window.price)
        }
    }

    private func settlePlanetBribe(paid: Bool, price: Int) {
        guard var state = hailDialogState, case let .planet(spobID) = state.kind, var comm = state.comm,
              let game = host?.game, let spob = game.spob(spobID) else { return }
        var latch = bribeLatch
        let outcome = comm.settleBribe(paid: paid, price: price, spob: spob, state: &model.pilot.state,
                                       game: game, bribeLatch: &latch)
        bribeLatch = latch
        state.comm = comm
        switch outcome {
        case let .cannotAfford(text), let .refused(text):
            state.responseText = text
            hailDialogState = state
        case let .paid(_, hudLine):
            // Paid: landing is granted until the player leaves the system, and
            // the comm window closes.
            bribedStellars.insert(spobID)
            host?.hud.post(hudLine)
            hailDialogState = nil
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
        if let session = shipComm, session.entityID == entityID {
            originalCommAssistance(session)
            return
        }
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

    /// STR# 3000 entry `prompt × 5 + variant + 1` for the ship comm window.
    private func shipCommLine(_ prompt: Int, _ session: OriginalComms.Session) -> String {
        let entry = OriginalComms.promptEntry(prompt, variant: session.variant)
        return host?.game?.stringList(entry.list)?.string(at: entry.index) ?? ""
    }

    /// The greeting context the engine can't see: active disasters with more
    /// than a day left, the përs CommQuote and the pilot's name (AI-43).
    private func shipCommGreetingContext(persCommQuote: String?) -> OriginalComms.GreetingContext {
        let state = model.pilot.state
        var disasters: [OriginalComms.Disaster] = []
        if let game = host?.game {
            for (oopsID, expiry) in (state.activeDisasters ?? [:]).sorted(by: { $0.key < $1.key })
            where state.date.days(until: expiry) > 1 {
                guard let o = game.oops(oopsID) else { continue }
                let stellar = o.stellar == -1 ? (state.disasterStellars?[oopsID] ?? -1) : o.stellar
                guard stellar >= 128 else { continue }
                disasters.append(.init(stellarID: stellar, commodity: o.commodity, priceDelta: o.priceDelta))
            }
        }
        return OriginalComms.GreetingContext(disasters: disasters, persCommQuote: persCommQuote,
                                             pilotName: state.pilotName)
    }

    /// The Greetings button under the original AI (AI-43).
    private func originalCommGreetings(_ session: OriginalComms.Session) {
        guard var state = hailDialogState, let answer = host?.scene.originalPressGreetings(session) else { return }
        switch answer {
        case .greeting: state.responseText = session.greeting
        case let .reply(prompt): state.responseText = shipCommLine(prompt, session)
        default: break
        }
        hailDialogState = state
    }

    /// The middle button under the original AI (AI-42, 0x0047e470): Beg For
    /// Mercy while the ship presses its attack, else Request Assistance.
    private func originalCommAssistance(_ session: OriginalComms.Session) {
        guard var state = hailDialogState, let scene = host?.scene,
              let answer = scene.originalPressAssistance(session) else { return }
        switch answer {
        case let .reply(prompt):
            state.responseText = shipCommLine(prompt, session)
            hailDialogState = state
        case .greeting, .nothing:
            break
        case let .releaseEscort(prompt):
            state.responseText = shipCommLine(prompt, session)
            state.assistRequested = true
            pendingEscortRelease = session.entityID
            hailDialogState = state
        case let .done(prompt, effect):
            var s = session
            _ = scene.originalSettle(&s, effect: effect, paid: true)
            shipComm = s
            state.responseText = shipCommLine(prompt, session)
            state.assistRequested = true
            hailDialogState = state
        case let .offer(prompt, price, free, effect):
            state.responseText = shipCommLine(prompt, session)
            hailDialogState = state
            if free {
                settleShipPayment(effect: effect, paid: true, price: 0)
            } else {
                shipPayment = ShipPayment(window: PaymentWindow(price: price, rand: { Int.random(in: 0..<max(1, $0)) }),
                                          effect: effect)
            }
        }
    }

    /// A press in the ship comm's payment window (DLOG 1008).
    private func pressShipPayment(_ press: PaymentWindow.Press) {
        guard var payment = shipPayment else { return }
        switch payment.window.press(press) {
        case .open:
            shipPayment = payment
        case .paid:
            shipPayment = nil
            settleShipPayment(effect: payment.effect, paid: true, price: payment.window.price)
        case .refused:
            shipPayment = nil
            settleShipPayment(effect: payment.effect, paid: false, price: payment.window.price)
        }
    }

    private func settleShipPayment(effect: OriginalComms.Effect, paid: Bool, price: Int) {
        guard var session = shipComm, var state = hailDialogState, let scene = host?.scene else { return }
        if paid, model.pilot.state.credits < price {
            state.responseText = shipCommLine(OriginalComms.Prompt.cannotAfford, session)
            hailDialogState = state
            return
        }
        let prompt = scene.originalSettle(&session, effect: effect, paid: paid)
        shipComm = session
        if paid, price > 0 {
            model.pilot.state.credits -= price
            scene.debugSyncCredits(model.pilot.state.credits)
        }
        if paid, effect != .bribe { state.assistRequested = true }
        if let prompt { state.responseText = shipCommLine(prompt, session) }
        hailDialogState = state
    }

    /// The `forgivingLanding` enhancement's Request Landing button: report
    /// whether landing is cleared. Updates the open dialog in place.
    private func requestPlanetLanding() {
        guard var state = hailDialogState, case let .planet(spobID) = state.kind else { return }
        let refusal = host?.game?.spob(spobID).flatMap { landingRefusalReason(spob: $0) }
        if let refusal {
            state.landable = false
            state.responseText = refusal
        } else {
            state.landable = true
            state.responseText = "Landing clearance granted. You are cleared to land."
        }
        hailDialogState = state
    }

    /// The stellar comm's Demand Tribute / Release button (EC-16). Every demand
    /// is a crime against the stellar's government (the engine applies it);
    /// below a combat rating of 12,800 the demand is laughed off; a stellar with
    /// nothing left to fight submits to the window's first demand; otherwise it
    /// launches its defenders. On a dominated world the button releases it.
    private func demandPlanetTribute() {
        guard var state = hailDialogState, case let .planet(spobID) = state.kind, var comm = state.comm,
              let game = host?.game, let spob = game.spob(spobID) else { return }
        if model.pilot.state.hasDominated(spobID) {
            guard !spob.startsDominated else { return }
            host?.scene.releaseStellar(spobID: spobID)
            let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
            engine.releaseStellar(spobID)
            model.pilot.state = engine.player
            syncCombatStanding()
            state.responseText = StellarComm.releaseReply(spob: spob, game: game)
            refreshPlanetHail(&state, spob: spob, game: game)
            hailDialogState = state
            return
        }
        guard let outcome = host?.scene.demandTribute(
                spobID: spobID,
                combatRating: model.pilot.state.combatRating,
                alreadyDominated: model.pilot.state.dominatedStellars ?? [],
                firstPressInWindow: !comm.tributePressed) else { return }
        comm.tributePressed = true
        state.comm = comm
        syncCombatStanding()
        let reply = comm.tributeReply(outcome, spob: spob, game: game)
        if !reply.isEmpty { state.responseText = reply }
        refreshPlanetHail(&state, spob: spob, game: game)
        hailDialogState = state
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
        saveGame(reason: .event)
        let name = game.spob(spobID)?.name ?? "The stellar"
        host?.hud.post("\(name) submits to your rule — it will pay tribute daily.")
        if var state = hailDialogState, case let .planet(id) = state.kind, id == spobID,
           let spob = game.spob(spobID) {
            state.hostile = false
            refreshPlanetHail(&state, spob: spob, game: game)
            hailDialogState = state
        }
    }

    /// A destroyable stellar (`spöb.Strength` > 0) was shot down in the live
    /// world (`onStellarDestroyed`). Persist it through the story engine — which
    /// fires the stellar's `OnDestroy` control bits and stamps the day so its
    /// `spöb.DeadTime` regeneration timer runs on the galaxy clock — then drop it
    /// out of the live scene the same way a story `Y` op would.
    private func handleStellarShotDown(spobID: Int) {
        guard let game = model.data.game else { return }
        let engine = StoryEngine(game: game, player: model.pilot.state, services: flightMissionServices)
        engine.stellarShotDown(spobID)
        model.pilot.state = engine.player
        saveGame(reason: .event)
        let name = game.spob(spobID)?.name ?? "The stellar"
        host?.hud.post("\(name) has been destroyed.")
    }

    private func hailShowsAssistButton(_ state: HailDialogState) -> Bool {
        if case .ship = state.kind { return true }
        return false
    }

    private func hailAssistEnabled(_ state: HailDialogState) -> Bool {
        guard case let .ship(entityID, _) = state.kind, !state.assistRequested else { return false }
        // The original window offers the button unless the government's
        // flags_secondary 0x0001 takes it away; otherwise its answer says no.
        if let session = shipComm, session.entityID == entityID { return !session.noAssistance }
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

    /// The developer entry point shown while debug mode is on: one console
    /// button and a live fps/ship chip, tucked under the menu button (clear of
    /// the right-edge status bar). The button opens on the command line, the
    /// chip on the tools pane — the same panel either way, landing where you
    /// were already looking. Also carries the hidden ⌘\` shortcut that toggles
    /// the console from a hardware keyboard — same pattern as `RootView`'s
    /// ⇧⌘D catcher, and command-modified for the same reason:
    /// `FlightKeyboardMonitor` passes ⌘-chords through untouched even while
    /// flight owns every other key.
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        console.tab = .console
                        console.isPresented = true
                    } label: {
                        Image(systemName: "terminal.fill")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(devConsoleGreen.opacity(0.5)))
                            .foregroundStyle(devConsoleGreen)
                    }
                    .buttonStyle(.novaPlain)
                    DebugMetricsChip(debug: debug) {
                        console.tab = .tools
                        console.isPresented = true
                    }
                }
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 14)
        .padding(.top, 68)   // below the hamburger menu button
        .opacity(showMenu || console.isPresented ? 0 : 1)
        .allowsHitTesting(!showMenu && !console.isPresented)
        .zIndex(15)
        #if !os(tvOS)
        .overlay {
            Button { console.setPresented(!console.isPresented) } label: { Color.clear }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .keyboardShortcut("`", modifiers: [.command])
        }
        #endif
    }

    /// Registers every game-specific console command onto `console` — the CLI
    /// counterpart to `DebugSuiteView`'s buttons/toggles, plus a few things
    /// only a typed command makes practical (arbitrary credit amounts, a
    /// specific hull by id/name, jumping straight to a relation value).
    /// Called once from `onAppear`; each closure reads `debug`/`model` live,
    /// so it keeps working across host rebuilds (jumps, landings) without
    /// re-registering.
    private func registerConsoleCommands() {
        func onOff(_ args: [String], current: Bool) throws -> Bool {
            guard let raw = args.first else { return !current }
            switch raw.lowercased() {
            case "on", "true", "1": return true
            case "off", "false", "0": return false
            default: throw ConsoleController.CommandError(message: "Expected on/off, got '\(raw)'")
            }
        }

        console.register(.init(name: "god", summary: "Toggle god mode (no damage).", usage: "god [on|off]") { args in
            debug.godMode = try onOff(args, current: debug.godMode)
            return "God mode: \(debug.godMode ? "on" : "off")"
        })

        console.register(.init(name: "fuel", summary: "Toggle infinite fuel.", usage: "fuel [on|off]") { args in
            debug.infiniteFuel = try onOff(args, current: debug.infiniteFuel)
            return "Infinite fuel: \(debug.infiniteFuel ? "on" : "off")"
        })

        console.register(.init(name: "ai", summary: "Toggle the AI state/paths overlay.", usage: "ai [on|off]") { args in
            debug.aiDebugEnabled = try onOff(args, current: debug.aiDebugEnabled)
            return "AI overlay: \(debug.aiDebugEnabled ? "on" : "off")"
        })

        console.register(.init(name: "uidebug", summary: "Toggle the UI measurement grid.", usage: "uidebug [on|off]") { args in
            model.settings.uiDebugOverlay = try onOff(args, current: model.settings.uiDebugOverlay)
            model.commitSettings()
            return "UI debug grid: \(model.settings.uiDebugOverlay ? "on" : "off")"
        })

        console.register(.init(name: "heal", summary: "Full shield + armor on the live ship.", usage: "heal") { _ in
            guard let ship = debug.scene?.playerShip else { throw ConsoleController.CommandError(message: "No live ship.") }
            ship.shield = ship.maxShield
            ship.armor = ship.maxArmor
            return "Healed."
        })

        console.register(.init(name: "refuel", summary: "Fill the live ship's fuel tank.", usage: "refuel") { _ in
            guard let ship = debug.scene?.playerShip else { throw ConsoleController.CommandError(message: "No live ship.") }
            ship.fuel = ship.maxFuel
            model.pilot.state.fuel = ship.maxFuel
            model.pilot.save()
            return "Refueled."
        })

        console.register(.init(name: "credits", summary: "Add or set the pilot's credits.", usage: "credits <add|set> <amount>") { args in
            guard args.count == 2, let amount = Int(args[1]) else {
                throw ConsoleController.CommandError(message: "Usage: credits <add|set> <amount>")
            }
            switch args[0].lowercased() {
            case "add": model.pilot.state.credits = max(0, model.pilot.state.credits + amount)
            case "set": model.pilot.state.credits = max(0, amount)
            default: throw ConsoleController.CommandError(message: "Expected add/set, got '\(args[0])'")
            }
            model.pilot.save()
            debug.scene?.debugSyncCredits(model.pilot.state.credits)
            return "Credits: \(model.pilot.state.credits)"
        })

        console.register(.init(name: "fps", summary: "Print the current performance snapshot.", usage: "fps") { _ in
            String(format: "%.0f fps · frame %.1fms (worst %.1fms) · %d ships, %d shots, %d roids, %d nodes",
                   debug.fps, debug.frameMsAvg, debug.frameMsMax,
                   debug.shipCount, debug.projectileCount, debug.asteroidCount, debug.nodeCount)
        })

        console.register(.init(name: "perf", summary: "Start/stop the performance stress test.", usage: "perf <start [count]|stop>") { args in
            guard let sub = args.first else { throw ConsoleController.CommandError(message: "Usage: perf <start [count]|stop>") }
            switch sub.lowercased() {
            case "start":
                if let count = args.dropFirst().first.flatMap(Int.init) { debug.perfTestShipCount = count }
                debug.startPerformanceTest()
                return "Stress test started with \(debug.perfTestShipCount) ships."
            case "stop":
                debug.stopPerformanceTest()
                return "Stress test stopped."
            default:
                throw ConsoleController.CommandError(message: "Expected start/stop, got '\(sub)'")
            }
        })

        console.register(.init(name: "clearnpcs", summary: "Remove every NPC from the live system.", usage: "clearnpcs") { _ in
            let n = debug.scene?.debugClearAllNPCs() ?? 0
            return "Cleared \(n) ship\(n == 1 ? "" : "s")."
        })

        console.register(.init(name: "killhostiles", summary: "Destroy every hostile in the live system.", usage: "killhostiles") { _ in
            let n = debug.scene?.debugDestroyAllHostiles() ?? 0
            return "Destroyed \(n) ship\(n == 1 ? "" : "s")."
        })

        console.register(.init(name: "spawn", summary: "Spawn a ship by id, hostile/escort/neutral.", usage: "spawn <hostile|escort|neutral> <shipID> [count]") { args in
            guard args.count >= 2, let hull = Int(args[1]) else {
                throw ConsoleController.CommandError(message: "Usage: spawn <hostile|escort|neutral> <shipID> [count]")
            }
            let disposition: GameScene.DebugDisposition
            switch args[0].lowercased() {
            case "hostile": disposition = .hostile
            case "escort": disposition = .escort
            case "neutral": disposition = .neutral
            default: throw ConsoleController.CommandError(message: "Expected hostile/escort/neutral, got '\(args[0])'")
            }
            let count = args.dropFirst(2).first.flatMap(Int.init) ?? 1
            var spawned = 0
            for _ in 0..<max(1, count) where debug.scene?.debugSpawnShip(hull: hull, as: disposition) == true {
                spawned += 1
            }
            return spawned > 0 ? "Spawned \(spawned) × #\(hull) (\(args[0]))." : "Couldn't spawn #\(hull) — no live scene?"
        })

        console.register(.init(name: "ship", summary: "Set the pilot's current hull by id or name.", usage: "ship <id|name…>") { args in
            guard !args.isEmpty else { throw ConsoleController.CommandError(message: "Usage: ship <id|name…>") }
            guard let game = model.data.game else { throw ConsoleController.CommandError(message: "No game data loaded.") }
            let resolved: ShipRes?
            if args.count == 1, let id = Int(args[0]) {
                resolved = game.ship(id)
            } else {
                let query = args.joined(separator: " ")
                let matches = game.ships().filter { $0.displayName.localizedCaseInsensitiveContains(query) }
                if matches.count > 1 {
                    let names = matches.prefix(8).map { "#\($0.id) \($0.displayName)" }.joined(separator: ", ")
                    throw ConsoleController.CommandError(message: "Ambiguous — matches: \(names)")
                }
                resolved = matches.first
            }
            guard let ship = resolved else { throw ConsoleController.CommandError(message: "No ship matching '\(args.joined(separator: " "))'.") }
            model.pilot.state.shipType = ship.id
            model.pilot.state.shipName = ship.displayName
            model.pilot.save()
            return "Current ship set to #\(ship.id) \(ship.displayName) — applies on next takeoff/jump/landing."
        })

        console.register(.init(name: "outfit", summary: "Grant or remove an outfit.", usage: "outfit <add|remove> <outfitID> [count]") { args in
            guard args.count >= 2, let id = Int(args[1]) else {
                throw ConsoleController.CommandError(message: "Usage: outfit <add|remove> <outfitID> [count]")
            }
            let count = max(1, args.dropFirst(2).first.flatMap(Int.init) ?? 1)
            guard let outfit = model.data.game?.outfit(id) else {
                throw ConsoleController.CommandError(message: "No outfit #\(id).")
            }
            switch args[0].lowercased() {
            case "add": model.pilot.state.grantOutfit(id, count: count)
            case "remove": model.pilot.state.removeOutfit(id, count: count)
            default: throw ConsoleController.CommandError(message: "Expected add/remove, got '\(args[0])'")
            }
            model.pilot.save()
            let owned = model.pilot.state.outfits[id] ?? 0
            return "\(outfit.outfitterDisplayName): now ×\(owned) — applies on next ship rebuild."
        })

        console.register(.init(name: "relation", summary: "Set the legal record in the current system.", usage: "relation <value>") { args in
            guard args.count == 1, let value = Int(args[0]) else {
                throw ConsoleController.CommandError(message: "Usage: relation <value>")
            }
            let system = model.pilot.state.currentSystem
            let clamped = SystemReputation.clamp(value)
            model.pilot.state.systemReputation = (model.pilot.state.systemReputation ?? [:])
                .merging([system: clamped]) { _, new in new }
            model.pilot.save()
            debug.scene?.debugSetLiveReputation(clamped)
            return "Reputation in system #\(system) set to \(clamped)."
        })

        console.register(.init(name: "bit", summary: "Set/clear/toggle a control bit, or explain one.",
                               usage: "bit <set|clear|toggle|info> <n>") { args in
            guard args.count == 2, let n = Int(args[1]) else {
                throw ConsoleController.CommandError(message: "Usage: bit <set|clear|toggle|info> <n>")
            }
            switch args[0].lowercased() {
            case "set": model.pilot.state.setBit(n)
            case "clear": model.pilot.state.clearBit(n)
            case "toggle": model.pilot.state.toggleBit(n)
            case "info":
                // Same cross-reference the Bits browser shows, as text. Reads
                // whatever the browser already built; empty until then.
                let refs = console.ncbIndex.references(for: n)
                let state = model.pilot.state.setBits.contains(n) ? "SET" : "clear"
                guard !refs.isEmpty else {
                    return "Bit \(n) [\(state)] — no references in this data set."
                }
                let lines = refs.map { ref -> String in
                    var role: String
                    switch ref.role {
                    case .set: role = "sets"
                    case .clear: role = "clears"
                    case .toggle: role = "toggles"
                    case let .test(negated): role = negated ? "tests (needs clear)" : "tests (needs set)"
                    }
                    return "  \(role) — \(ref.kind) #\(ref.resourceID) \(ref.resourceName) · \(ref.field)"
                }
                return (["Bit \(n) [\(state)] — \(refs.count) reference(s):"] + lines)
                    .joined(separator: "\n")
            default:
                throw ConsoleController.CommandError(message: "Expected set/clear/toggle/info, got '\(args[0])'")
            }
            model.pilot.save()
            return "Bit \(n): \(model.pilot.state.setBits.contains(n) ? "set" : "clear")"
        })

        console.register(.init(name: "date", summary: "Advance the galaxy date.", usage: "date +<days>") { args in
            guard let arg = args.first, arg.hasPrefix("+"), let days = Int(arg.dropFirst()) else {
                throw ConsoleController.CommandError(message: "Usage: date +<days>")
            }
            model.pilot.state.date = model.pilot.state.date.adding(days: days)
            model.pilot.save()
            return "Date: \(model.pilot.state.date.description)"
        })

        console.register(.init(name: "select", summary: "Select a live ship or stellar by id.",
                               usage: "select <ship|spob> <id>") { args in
            guard args.count == 2, let id = Int(args[1]) else {
                throw ConsoleController.CommandError(message: "Usage: select <ship|spob> <id>")
            }
            guard let scene = debug.scene else { throw ConsoleController.CommandError(message: "No live scene.") }
            switch args[0].lowercased() {
            case "ship":
                guard let ship = scene.npc(id: id) else { throw ConsoleController.CommandError(message: "No live ship #\(id).") }
                scene.debugSelect(.ship(id: id, name: ship.name))
                return "Selected ship #\(id) \(ship.name)."
            case "spob":
                let name = model.data.game?.spob(id)?.name ?? ""
                scene.debugSelect(.spob(id: id, name: name))
                return "Selected stellar #\(id)\(name.isEmpty ? "" : " \(name)")."
            default:
                throw ConsoleController.CommandError(message: "Expected ship/spob, got '\(args[0])'")
            }
        })

        /// Every entity-action command below (`destroy`/`disable`/`capture`/`conquer`)
        /// takes a bare ship entityID, or the literal `selected` to act on
        /// whatever's currently targeted (`debug.selection`) — which is what a
        /// right-click/long-press or the Selected card in Tools already set.
        func resolveShipID(_ args: [String]) throws -> Int {
            if let raw = args.first, raw.lowercased() != "selected", let id = Int(raw) { return id }
            if case let .ship(id, _)? = debug.selection { return id }
            throw ConsoleController.CommandError(message: "No ship selected — pass an id or select one first.")
        }
        func resolveSpobID(_ args: [String]) throws -> Int {
            if let raw = args.first, raw.lowercased() != "selected", let id = Int(raw) { return id }
            if case let .spob(id, _)? = debug.selection { return id }
            throw ConsoleController.CommandError(message: "No stellar selected — pass an id or select one first.")
        }

        console.register(.init(name: "destroy", summary: "Dev-tools kill a ship.", usage: "destroy <id|selected>") { args in
            let id = try resolveShipID(args)
            guard debug.scene?.debugDestroyShip(entityID: id) == true else {
                throw ConsoleController.CommandError(message: "No live ship #\(id).")
            }
            return "Destroyed ship #\(id)."
        })

        console.register(.init(name: "disable", summary: "Dev-tools disable a ship.", usage: "disable <id|selected>") { args in
            let id = try resolveShipID(args)
            guard debug.scene?.debugDisableShip(entityID: id) == true else {
                throw ConsoleController.CommandError(message: "No live ship #\(id).")
            }
            return "Disabled ship #\(id)."
        })

        console.register(.init(name: "capture", summary: "Dev-tools cheat-capture a ship as an escort.",
                               usage: "capture <id|selected>") { args in
            let id = try resolveShipID(args)
            guard let cap = debug.scene?.debugCaptureShip(entityID: id) else {
                throw ConsoleController.CommandError(message: "No live ship #\(id).")
            }
            recruitCapturedShipAsEscort(cap)
            return "Captured \(cap.name.isEmpty ? "ship #\(id)" : cap.name) as an escort."
        })

        console.register(.init(name: "conquer", summary: "Dev-tools instantly dominate a stellar (skips the defense fight).",
                               usage: "conquer <id|selected>") { args in
            let id = try resolveSpobID(args)
            guard let scene = debug.scene else { throw ConsoleController.CommandError(message: "No live scene.") }
            let name = model.data.game?.spob(id)?.name ?? "#\(id)"
            guard scene.debugConquerStellar(spobID: id) else {
                return "\(name) is already dominated, or isn't a stellar in this system."
            }
            return "\(name) dominated."
        })

        console.register(.init(name: "cycle", summary: "Cycle the ship/planet selection.",
                               usage: "cycle <ships|planets> [next|prev]") { args in
            guard let kind = args.first else { throw ConsoleController.CommandError(message: "Usage: cycle <ships|planets> [next|prev]") }
            let reverse = args.dropFirst().first?.lowercased() == "prev"
            guard let scene = debug.scene else { throw ConsoleController.CommandError(message: "No live scene.") }
            switch kind.lowercased() {
            case "ships": scene.cycleTarget(reverse: reverse)
            case "planets": scene.cyclePlanet(reverse: reverse)
            default: throw ConsoleController.CommandError(message: "Expected ships/planets, got '\(kind)'")
            }
            guard let ref = debug.selection else { return "Nothing in range to select." }
            return "Selected \(ref.name.isEmpty ? "#\(ref.id)" : ref.name)."
        })
    }

    // The single in-game entry point: one unobtrusive button in the top-left
    // (clear of the right-edge status bar) that opens the consolidated menu.
    private var topLeftMenuButton: some View {
        VStack {
            HStack {
                Button { showMenu = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .padding(11)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                        Text("Menu")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.85), radius: 1.5, y: 0.5)
                    }
                }
                .buttonStyle(.novaPlain)
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
struct GameLoadingView: View {
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

/// The bottom-left status line: the calendar date on each jump/land, hail
/// replies, mission notices and any other transient game message — one line
/// that fades out on its own timer (`GameHUDModel.post`), replaced by whatever
/// posts next rather than stacking underneath it. No panel or border — just
/// the line, like the original.
struct MessageLogView: View {
    @ObservedObject var hud: GameHUDModel

    /// Mirrors `ContextualActionsView.bottomPadding` — sits flush with the true
    /// bottom edge (just clearing the safe area on iOS, which already clears
    /// the home indicator).
    private var bottomPadding: CGFloat {
        #if os(iOS)
        6
        #else
        8
        #endif
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                if let m = hud.message {
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
/// The ship comm's open payment window and whether it prices a bribe or
/// paid assistance (AI-42).
struct ShipPayment {
    var window: PaymentWindow
    let effect: OriginalComms.Effect
}

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
    /// Planet hails: the original's comm-window state (UI-09) — the
    /// Greetings/Offer Bribe and Demand Tribute/Release buttons read it.
    var comm: StellarComm? = nil
    /// Planet hails: "Status: Dominated" / "Hostile" / "Forbidden".
    var statusText: String? = nil
    var statusHostile = false
    /// Planet hails: the top button's title (Greetings, Offer Bribe, or the
    /// `forgivingLanding` enhancement's Request Landing).
    var topButtonTitle = "Greetings"
    /// Planet hails: the middle button (Demand Tribute, or Release on a
    /// dominated world; dimmed on an always-dominated one).
    var tributeTitle = "Demand Tribute"
    var tributeEnabled = true
    /// Ship hails: the middle button — "Request Assistance", or "Beg For
    /// Mercy" while the ship presses its attack (AI-42).
    var assistTitle = "Request Assistance"
}

/// Routes hardware-keyboard presses into flight intents using the user's
/// keybindings. Continuous actions (turn/thrust/fire) are held; discrete actions
/// (target/jump/map/…) will dispatch once their systems exist.
struct KeyboardControls: ViewModifier {
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
            case .selfDestruct: input.keyboard.selfDestruct = pressed
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
