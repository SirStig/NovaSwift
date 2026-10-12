#if os(macOS)
import SwiftUI
import Combine
import SpriteKit
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

/// A lightweight list entry for the debug panel's searchable pickers.
struct EditorPick: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    var subtitle: String = ""
    /// Pre-lowercased haystack, computed once at build time so per-keystroke
    /// filtering is a plain `contains`.
    let searchText: String

    init(id: Int, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.searchText = "\(id) \(title) \(subtitle)".lowercased()
    }
}

/// The sandbox behind `EditorTestRunView`: owns the throwaway pilot (control
/// bits, outfits, credits, date, missions — in memory only, never saved), the
/// current `GameHost`, the navigation model, the debug/console controllers, and
/// every debug action the panel offers. Actions that change the player's hull
/// or loadout rebuild the host in place (same system, same pose); everything
/// else drives the live scene directly.
///
/// The pilot is a `PilotStore(editorSandbox:)`: in-memory only, `save()`/`reset()` are
/// no-ops, so the real spaceport screens can be driven against it (see
/// `EditorTestSession+Story.swift`). Nothing here calls a roster API or `AppModel.autosave`.
@MainActor
final class EditorTestSession: ObservableObject {

    enum Phase: Equatable { case loading, running, failed(String) }
    enum Stance: String, CaseIterable, Identifiable {
        case hostile = "Hostile", neutral = "Neutral", friendly = "Friendly"
        var id: String { rawValue }
    }
    enum Placement: String, CaseIterable, Identifiable {
        case nearPlayer = "Near player", atCursor = "At cursor"
        var id: String { rawValue }
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var host: GameHost?
    @Published private(set) var build: EditorBuild?
    @Published private(set) var systemID: Int = 0
    @Published var shipID: Int = 0
    /// The spöb the player is docked at (the real spaceport is shown), if any.
    @Published var landedSpobID: Int?
    /// The Mission Info window (active missions + objectives).
    @Published var showMissionInfo = false { didSet { applyPause() } }
    /// The open hail dialog, if any.
    @Published var hail: HailDialogState? { didSet { applyPause() } }
    /// The boarded hulk's manifest while the plunder dialog is up.
    @Published var boardManifest: World.BoardingManifest? { didSet { applyPause() } }
    /// Bumped after each loot action so the plunder dialog re-reads the manifest.
    @Published var boardRefresh = 0
    @Published var paused = false { didSet { applyPause() } }
    @Published var timeScale: Double = 1
    @Published private(set) var aiFrozen = false
    /// Bumped whenever sandbox pilot state changes, so the panel refreshes.
    @Published private(set) var stateRevision = 0
    @Published private(set) var buildInfo = ""

    // Searchable catalogs (built once per collection).
    private(set) var shipPicks: [EditorPick] = []
    private(set) var outfitPicks: [EditorPick] = []
    private(set) var fleetPicks: [EditorPick] = []
    private(set) var systemPicks: [EditorPick] = []
    private(set) var missionPicks: [EditorPick] = []
    private(set) var govtPicks: [EditorPick] = []

    // MARK: Collaborators

    let debug = DebugController()
    let console = ConsoleController()
    let nav = NavigationModel(game: nil, startSystemID: 128)
    /// Throwaway pilot: an in-memory `PilotStore` that never reads or writes the live save
    /// (`save()` and `reset()` are no-ops on a sandbox store).
    let pilot = PilotStore(editorSandbox: PlayerState())
    /// The story seam for everything this session runs through `StoryEngine` (mission
    /// scripts, crön ticks, texts, offers). Bound to the live scene in `wireStoryServices()`.
    let missionServices = AppGameServices()

    /// The pointer position inside the play viewport (SwiftUI top-left origin)
    /// and that viewport's size — for "spawn at cursor".
    var cursorViewPoint: CGPoint?
    var playViewSize: CGSize = .zero

    weak var app: AppModel?
    let collection: ResourceCollection
    private let base: ResourceCollection?
    private let startSystem: Int?
    private let startShip: Int?
    var startSystemID: Int? { startSystem }
    var startShipID: Int? { startShip }
    var departedSpobID: Int?
    private var frozenBrains: [Int: AIBrain] = [:]
    private var frozenSpawner: Spawner?
    private var pilotWatch: AnyCancellable?
    var rebuildTask: Task<Void, Never>?
    private var started = false
    // Story / spaceport / comms state (logic in EditorTestSession+Story.swift).
    var plunderPanic: World.PlunderPanic?
    var persOfferEngine: StoryEngine?
    var persOfferPersonID: Int?
    var stagedLaunchQuote: String?
    /// A story `M`/`N` move that fired while docked (keepPosition) — applied on take-off.
    var dockedMove: Bool?
    var departing = false
    /// Loot granted while boarding changed the loadout: refit the ship when the dialog closes.
    var loadoutDirtyDuringBoarding = false
    /// The comm window's per-jump bribe latch (−1 until rolled).
    var bribeLatch = -1

    init(collection: ResourceCollection, base: ResourceCollection?, startSystem: Int?, startShip: Int?) {
        self.collection = collection
        self.base = base
        self.startSystem = startSystem
        self.startShip = startShip
    }

    var game: NovaGame? { build?.game }
    /// Speed multiplier the scene should use, or nil to leave the player's setting alone.
    var speedOverride: Double? { timeScale == 1 ? nil : timeScale }

    // MARK: Lifecycle

    func start(app: AppModel) async {
        guard !started else { return }
        started = true
        self.app = app
        EditorHD.shared.acquire(self)
        let result = await EditorGameFactory.build(
            collection: collection, base: base,
            flightTuning: FlightTuning(enhancements: app.settings.enhancements),
            systemID: startSystem, shipID: startShip, catalogs: true,
            hd: EditorHD.inputs(app: app, base: base))
        switch result {
        case .failure(let e):
            phase = .failed(e.localizedDescription)
        case .success(let b):
            build = b
            guard let dflt = b.defaultStart else {
                phase = .failed("The collection has no usable start system / ship."); return
            }
            let sys = startSystem.flatMap { b.game.system($0)?.id } ?? dflt.systemID
            let ship = startShip.flatMap { b.game.ship($0)?.id } ?? dflt.shipID
            // Catalogs came out of the off-main build; the initial pilot state and
            // its hidden-system set are computed off-main too (decodes every sÿst).
            let cats = b.catalogs ?? EditorCatalogs.make(game: b.game)
            shipPicks = cats.ships; outfitPicks = cats.outfits; fleetPicks = cats.fleets
            systemPicks = cats.systems; missionPicks = cats.missions; govtPicks = cats.govts
            let game = b.game
            let allSystems = cats.systems.map(\.id)
            let prep = await Task.detached(priority: .userInitiated) {
                Self.initialState(game: game, systemID: sys, shipID: ship, systemIDs: allSystems)
            }.value
            pilot.state = prep.state
            nav.hiddenSystems = prep.hidden
            registerCommands()
            wireStoryServices()
            // Spaceport purchases / accepted missions mutate the pilot directly: keep the panel fresh.
            pilotWatch = pilot.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.touch() }
            }
            nav.configure(game: b.game, startSystemID: sys)
            systemID = sys
            shipID = ship
            buildInfo = String(format: "build %.0f ms (sync %.0f, warm %.0f) · %d edited sprite(s)",
                               b.totalMillis, b.spriteSyncMillis, b.warmMillis, b.changedSprites)
            await installHost(systemID: sys, shipID: ship, pose: nil)
            phase = host == nil ? .failed("Couldn't build the start system #\(sys).") : .running
        }
    }

    /// Release everything (End Test). Safe to call twice.
    func shutdown() {
        rebuildTask?.cancel()
        host?.scene.isPaused = true
        host?.scene.onSystemReloaded = nil
        host?.scene.onPlayerDestroyed = nil
        host?.scene.gameSpeedMultiplierOverride = nil
        host?.scene.onMissionShipGoalReached = nil
        host?.scene.onAutoLandArrived = nil
        host?.scene.persSpawnEligible = nil
        host?.scene.shipSpawnEligible = nil
        host?.scene.debug = nil
        unwireStoryCallbacks(host?.scene)
        debug.attach(nil)
        host = nil
        hail = nil; boardManifest = nil
        missionServices.onLeaveStellar = nil; missionServices.onOverlayMessage = nil
        missionServices.onSpawnMissionShips = nil; missionServices.onChangePlayerShip = nil
        missionServices.onMovePlayer = nil; missionServices.onSetStellarDestroyed = nil
        missionServices.onReleaseMissionShips = nil; missionServices.onEscortDeparted = nil
        missionServices.onCloseSpaceportScreen = nil
        pilotWatch = nil
        EditorHD.shared.release(self, app: app)
    }

    // MARK: Sandbox pilot

    private struct InitialState: @unchecked Sendable {
        let state: PlayerState
        let hidden: Set<Int>
    }

    /// Pure: the throwaway pilot's starting state + which systems it can't see yet.
    nonisolated private static func initialState(game: NovaGame, systemID: Int, shipID: Int, systemIDs: [Int]) -> InitialState {
        var s = PlayerState()
        s.pilotName = "Test Pilot"
        s.shipType = shipID
        s.shipName = game.ship(shipID)?.displayName ?? ""
        s.currentSystem = systemID
        s.credits = 1_000_000
        s.outfits = [:]
        for (oid, c) in EditorGameFactoryOutfits.stock(game: game, shipID: shipID) { s.grantOutfit(oid, count: c) }
        s.hullFittingsGranted = true
        s.exploredSystems = Set(systemIDs)
        return InitialState(state: s, hidden: game.hiddenSystemIDs(for: s))
    }

    private func resetSandboxPilot(game: NovaGame, systemID: Int, shipID: Int) {
        var s = PlayerState()
        s.pilotName = "Test Pilot"
        s.shipType = shipID
        s.shipName = game.ship(shipID)?.displayName ?? ""
        s.currentSystem = systemID
        s.credits = 1_000_000
        s.outfits = [:]
        for (oid, c) in EditorGameFactoryOutfits.stock(game: game, shipID: shipID) { s.grantOutfit(oid, count: c) }
        s.hullFittingsGranted = true
        s.exploredSystems = Set(game.systems().map(\.id))
        pilot.state = s
        refreshNavVisibility()
    }

    func refreshNavVisibility() {
        guard let game else { return }
        nav.hiddenSystems = game.hiddenSystemIDs(for: pilot.state)
    }

    func touch() { stateRevision &+= 1 }

    // MARK: Host construction

    struct Pose { var position: Vec2; var angle: Double; var velocity: Vec2 }

    func currentPose() -> Pose? {
        guard let p = host?.scene.playerShip else { return nil }
        return Pose(position: p.position, angle: p.angle, velocity: p.velocity)
    }

    /// (Re)build the host. `pose == nil` starts at the default spot.
    func installHost(systemID: Int, shipID: Int, pose: Pose?) async {
        guard let app, let build else { return }
        await Task.detached(priority: .userInitiated) {
            EditorGameFactory.warm(game: build.game, systemID: systemID, shipID: shipID)
        }.value
        var opts = EditorHostOptions(systemID: systemID, shipID: shipID)
        opts.outfits = pilot.state.outfits
        opts.shipName = pilot.state.shipName
        if let pose { opts.position = pose.position; opts.angle = pose.angle; opts.velocity = pose.velocity }
        guard let newHost = GameHost.makeEditorHost(model: app, build: build, options: opts) else { return }
        let god = debug.godMode, fuel = debug.infiniteFuel, ai = debug.aiDebugEnabled
        host?.scene.isPaused = true
        host = newHost
        self.systemID = newHost.scene.editorSystemID
        self.shipID = shipID
        aiFrozen = false; frozenBrains = [:]; frozenSpawner = nil
        wire(newHost)
        debug.godMode = god; debug.infiniteFuel = fuel; debug.aiDebugEnabled = ai
        newHost.hud.credits = pilot.state.credits
        // The sandbox pilot's hold and fuel carry into the fresh ship; the new world gets the
        // active missions' ships and the escort wing again.
        if let ship = newHost.scene.playerShip {
            ship.cargo = pilot.state.cargo
            if let f = pilot.state.fuel { ship.fuel = min(f, ship.maxFuel) }
        }
        hail = nil; boardManifest = nil
        systemEntered()
        touch()
    }

    /// Hand-off to the scene: callbacks capture `self` weakly so the scene can
    /// never keep the session (or the session the scene) alive after End Test.
    func wire(_ host: GameHost) {
        let scene = host.scene
        debug.attach(scene)
        scene.onSystemReloaded = { [weak self] id in self?.systemReloaded(id) }
        scene.gameSpeedMultiplierOverride = { [weak self] in self?.speedOverride }
        scene.onPlayerDestroyed = { [weak self] in self?.playerDestroyed() }
        scene.onAutoLandArrived = { [weak self] id in self?.land(id) }
        scene.onMissionShipGoalReached = { [weak self] mid, goal, _ in self?.missionGoal(mid, goal) }
        scene.persSpawnEligible = { [weak self] id in
            guard let self, let game = self.game else { return true }
            guard let pers = game.pers(id), !pers.activeOn.isEmpty else { return true }
            return StoryEngine(game: game, player: self.pilot.state).evaluate(test: pers.activeOn)
        }
        scene.shipSpawnEligible = { [weak self] id in
            guard let self, let game = self.game else { return true }
            guard let ship = game.ship(id), !ship.appearOn.isEmpty else { return true }
            return StoryEngine(game: game, player: self.pilot.state).evaluate(test: ship.appearOn)
        }
        scene.isPaused = paused
        nav.attachShip(scene.playerShip)
        wireStoryCallbacks(host)
    }

    func applyPause() {
        host?.scene.isPaused = paused || landedSpobID != nil || nav.showingMap
            || showMissionInfo || hail != nil || boardManifest != nil
    }

    /// Re-sync after anything that pauses (map, landing).
    func refreshPause() { applyPause() }

    func systemReloaded(_ id: Int) {
        systemID = id
        pilot.state.currentSystem = id
        pilot.state.exploredSystems.insert(id)
        aiFrozen = false; frozenBrains = [:]; frozenSpawner = nil
        nav.attachShip(host?.scene.playerShip)
        if let name = game?.system(id)?.displayName {
            host?.hud.post("Entering the \(name) system.")
        }
        bribeLatch = -1
        systemEntered()      // mission ships (ShipSyst), escorts, nav visibility
        touch()
    }

    private func playerDestroyed() {
        host?.hud.post("Ship destroyed — respawning…")
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard let self, !Task.isCancelled else { return }
            await self.installHost(systemID: self.systemID, shipID: self.shipID, pose: nil)
        }
    }

    /// Debounced rebuild after hull/loadout edits (same system, same pose).
    func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            await self.installHost(systemID: self.systemID, shipID: self.shipID, pose: self.currentPose())
        }
    }

    // MARK: Flight actions (called by the view)

    func landKeyPressed() {
        guard landedSpobID == nil, let scene = host?.scene else { return }
        // The sandbox skips the request/clearance exchange: a press inside the
        // arm range counts as already cleared (same as the tutorial).
        if let sel = scene.selectNearestLandableIfNoneSelected(), scene.isWithinClearanceRange(sel) {
            scene.requestLandingClearance(sel, clearedNow: true)
        }
        if let id = scene.attemptLand() { land(id) }
        else { host?.hud.post("Get closer and slow down to land.") }
    }

    // `land(_:)`, `takeOff()` and `attemptJump()` live in EditorTestSession+Story.swift.

    // MARK: Debug actions — cheats & world

    func setGod(_ on: Bool) { debug.godMode = on; touch() }
    func setInfiniteFuel(_ on: Bool) { debug.infiniteFuel = on; touch() }

    func heal() {
        guard let s = host?.scene.playerShip else { return }
        s.shield = s.maxShield; s.armor = s.maxArmor; s.ionCharge = 0
        pilot.state.shield = nil; pilot.state.armor = nil
    }

    func refuel() {
        guard let s = host?.scene.playerShip else { return }
        s.fuel = s.maxFuel
        pilot.state.fuel = s.maxFuel
    }

    func setCredits(_ amount: Int, add: Bool) {
        pilot.state.credits = max(0, add ? pilot.state.credits + amount : amount)
        host?.scene.debugSyncCredits(pilot.state.credits)
        host?.hud.credits = pilot.state.credits
        touch()
    }

    /// Advance the calendar `n` days through the story engine's daily tick, so crön events
    /// start/end, deadlines and tribute run exactly as on a jump or a spaceport visit.
    func addDays(_ n: Int) {
        advanceGameDays(n)
    }

    func setPaused(_ p: Bool) { paused = p }
    func setTimeScale(_ s: Double) { timeScale = s; touch() }

    func clearNPCs() -> Int { host?.scene.debugClearAllNPCs() ?? 0 }
    func killHostiles() -> Int { host?.scene.debugDestroyAllHostiles() ?? 0 }
    func disableHostiles() -> Int { host?.scene.debugDisableAllHostiles() ?? 0 }

    func setAIFrozen(_ on: Bool) {
        guard let world = host?.scene.editorWorld, on != aiFrozen else { return }
        if on {
            frozenBrains = [:]
            for s in world.npcs where s.brain != nil {
                frozenBrains[s.entityID] = s.brain
                s.brain = nil
                s.velocity = Vec2()
            }
            frozenSpawner = world.spawner
            world.spawner = nil
        } else {
            for s in world.npcs { if let b = frozenBrains[s.entityID] { s.brain = b } }
            if world.spawner == nil { world.spawner = frozenSpawner }
            frozenBrains = [:]; frozenSpawner = nil
        }
        aiFrozen = on
        touch()
    }

    /// Selected ship/stellar actions. `nil` id = whatever `debug.selection` is.
    func destroySelected() -> Bool {
        guard case let .ship(id, _)? = debug.selection else { return false }
        return host?.scene.debugDestroyShip(entityID: id) ?? false
    }
    func disableSelected() -> Bool {
        guard case let .ship(id, _)? = debug.selection else { return false }
        return host?.scene.debugDisableShip(entityID: id) ?? false
    }
    /// Cheat-capture: the ship becomes one of the player's escorts.
    func captureSelected() -> Bool {
        guard case let .ship(id, _)? = debug.selection, let scene = host?.scene,
              let ship = scene.npc(id: id), scene.debugCaptureShip(entityID: id) != nil,
              let world = scene.editorWorld else { return false }
        ship.disabled = false
        ship.shield = ship.maxShield; ship.armor = ship.maxArmor
        ship.government = world.player.government
        ship.brain = AIBrain(aiType: .interceptor, govt: ship.government)
        world.recruitEscort(ship)
        return true
    }

    // MARK: Debug actions — spawning

    /// World position for a spawn: around the player, or around the pointer.
    private func spawnCentre(_ placement: Placement, world: World) -> (Vec2, ring: ClosedRange<Double>) {
        let player = world.player.position
        if placement == .atCursor, let p = cursorViewPoint, playViewSize.width > 0, playViewSize.height > 0 {
            let zoom = app?.settings.cameraZoom ?? 1
            let dx = (Double(p.x) - Double(playViewSize.width) / 2) * zoom
            let dy = (Double(playViewSize.height) / 2 - Double(p.y)) * zoom
            return (player + Vec2(dx, dy), 0...60)
        }
        return (player, 400...800)
    }

    @discardableResult
    func spawnShips(hull: Int, count: Int, stance: Stance, govt: Int?, placement: Placement) -> Int {
        guard let scene = host?.scene, let world = scene.editorWorld, let galaxy = scene.editorGalaxy,
              let res = galaxy.game.ship(hull) else { return 0 }
        var spawned = 0
        let (centre, ring) = spawnCentre(placement, world: world)
        for _ in 0..<max(1, count) {
            let bearing = world.rng.double(in: 0...(2 * .pi))
            let dist = world.rng.double(in: ring)
            let pos = centre + Vec2(sin(bearing), cos(bearing)) * dist
            let ang = (world.player.position - pos).angle
            let team: Int? = stance == .friendly ? world.player.government : govt
            guard let ship = galaxy.makeLoadedShip(hull, government: team, at: pos, angle: ang,
                                                   skillScale: galaxy.skillVarianceScale(classOf: hull, rng: &world.rng))
            else { continue }
            switch stance {
            case .hostile:
                let brain = AIBrain(aiType: .interceptor, govt: ship.government)
                brain.provokedByPlayer = true
                brain.targetID = world.player.entityID
                ship.brain = brain
                world.addNPC(ship, arrival: .populate)
            case .neutral:
                let ai = AIType(raw: res.inherentAI)
                ship.brain = AIBrain(aiType: ai == .unknown ? .braveTrader : ai, govt: ship.government)
                world.addNPC(ship, arrival: .populate)
            case .friendly:
                world.addNPC(ship, arrival: .populate)
                world.recruitEscort(ship)
            }
            spawned += 1
        }
        return spawned
    }

    /// Spawn a flët: its lead plus escorts formed up on it (same construction as
    /// the ambient spawner). `stance` re-targets the whole fleet.
    @discardableResult
    func spawnFleet(_ fleetID: Int, stance: Stance, placement: Placement) -> Int {
        guard let scene = host?.scene, let world = scene.editorWorld, let galaxy = scene.editorGalaxy,
              let fleet = galaxy.game.fleet(fleetID) else { return 0 }
        let govt: Int? = stance == .friendly ? world.player.government : (fleet.govt >= 128 ? fleet.govt : nil)
        let (centre, ring) = spawnCentre(placement, world: world)
        let bearing = world.rng.double(in: 0...(2 * .pi))
        let leadPos = centre + Vec2(sin(bearing), cos(bearing)) * world.rng.double(in: ring)
        let ang = (world.player.position - leadPos).angle
        guard let lead = galaxy.makeLoadedShip(fleet.leadShip, government: govt, at: leadPos, angle: ang,
                                               skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng),
                                               includeDefaultItems: false, defaultItemCapabilities: true) else { return 0 }
        func brain(for shipID: Int, fallback: AIType, leader: Int?, slot: Int, g: Int) -> AIBrain {
            let hullAI = galaxy.game.ship(shipID).map { AIType(raw: $0.inherentAI) } ?? fallback
            let b = AIBrain(aiType: hullAI == .unknown ? fallback : hullAI, govt: g)
            b.isFleetMember = true
            b.fleetID = fleetID
            b.leaderID = leader
            b.formationSlot = slot
            if stance == .hostile { b.provokedByPlayer = true; b.targetID = world.player.entityID }
            return b
        }
        lead.brain = brain(for: fleet.leadShip, fallback: .warship, leader: nil, slot: 0, g: lead.government)
        let leadID = world.addNPC(lead, arrival: .populate)
        var n = 1, slot = 0
        if stance == .friendly { world.recruitEscort(lead) }
        for escort in fleet.escorts {
            let count = escort.min == escort.max ? escort.min
                      : world.rng.int(in: escort.min...max(escort.min, escort.max))
            for _ in 0..<max(0, count) {
                let off = Vec2(world.rng.double(in: -150...150), world.rng.double(in: -150...150))
                guard let e = galaxy.makeLoadedShip(escort.shipID, government: govt, at: leadPos + off, angle: ang,
                                                    skillScale: galaxy.skillVarianceScale(classOf: nil, rng: &world.rng),
                                                    includeDefaultItems: false, defaultItemCapabilities: true) else { continue }
                e.brain = brain(for: escort.shipID, fallback: .interceptor, leader: leadID, slot: slot, g: e.government)
                world.addNPC(e, arrival: .populate)
                if stance == .friendly { world.recruitEscort(e) }
                slot += 1; n += 1
            }
        }
        return n
    }

    // MARK: Debug actions — hull & outfits

    func setShip(_ id: Int) {
        guard let game, game.ship(id) != nil else { return }
        pilot.state.shipType = id
        pilot.state.shipName = game.ship(id)?.displayName ?? ""
        pilot.state.outfits = [:]
        for (oid, c) in EditorGameFactoryOutfits.stock(game: game, shipID: id) { pilot.state.grantOutfit(oid, count: c) }
        shipID = id
        touch()
        scheduleRebuild()
    }

    func resetLoadout() {
        guard let game else { return }
        pilot.state.outfits = [:]
        for (oid, c) in EditorGameFactoryOutfits.stock(game: game, shipID: shipID) { pilot.state.grantOutfit(oid, count: c) }
        touch(); scheduleRebuild()
    }

    func giveOutfit(_ id: Int, count: Int) {
        guard game?.outfit(id) != nil else { return }
        pilot.state.grantOutfit(id, count: max(1, count))
        touch(); scheduleRebuild()
    }

    func removeOutfit(_ id: Int, count: Int) {
        pilot.state.removeOutfit(id, count: max(1, count))
        touch(); scheduleRebuild()
    }

    var ownedOutfits: [(id: Int, name: String, count: Int)] {
        pilot.state.outfits.filter { $0.value > 0 }.map { (id: $0.key, name: game?.outfit($0.key)?.outfitterDisplayName ?? "#\($0.key)", count: $0.value) }
            .sorted { $0.id < $1.id }
    }

    // MARK: Debug actions — travel

    func jump(to id: Int) -> Bool {
        guard let game, game.system(id) != nil, let host, landedSpobID == nil else { return false }
        creditSurvivingAuxShips()
        storyArrival(in: id)
        nav.configure(game: game, startSystemID: id)
        host.scene.editorReloadSystem(to: id)       // → onSystemReloaded → systemReloaded
        nav.attachShip(host.scene.playerShip)
        refreshNavVisibility()
        return true
    }

    // MARK: Debug actions — story

    func setBit(_ n: Int, _ op: String) {
        switch op {
        case "set": pilot.state.setBit(n)
        case "clear": pilot.state.clearBit(n)
        default: pilot.state.toggleBit(n)
        }
        refreshNavVisibility()
        touch()
    }

    func evaluate(test: String) -> Bool {
        guard let game else { return false }
        return StoryEngine(game: game, player: pilot.state).evaluate(test: test)
    }

    @discardableResult
    func startMission(_ id: Int) -> Bool {
        guard let game, let m = game.mission(id) else { return false }
        let before = pilot.state.activeMissions.count
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        engine.startMission(id)
        pilot.state = engine.player
        guard pilot.state.activeMissions.count > before else { return false }
        // Special ships spawn straight into the current system (the real game
        // waits for the mission's ShipSyst; a test run wants them now).
        if let am = pilot.state.activeMissions.last, m.shipCount > 0, m.shipDude >= 128,
           let scene = host?.scene {
            let e = StoryEngine(game: game, player: pilot.state)
            scene.spawnMissionShips(missionID: m.id, dudeID: m.shipDude, count: max(1, m.shipCount),
                                    goal: m.shipGoal, behavior: m.shipBehaviorMode, government: nil,
                                    preferredShipID: am.lockedShipType,
                                    name: e.missionShipName(am, m), subtitle: e.missionShipSubtitle(am, m))
        }
        refreshNavVisibility()
        touch()
        return true
    }

    func missionGoal(_ missionID: Int, _ goal: MissionShipGoal) {
        guard let game else { return }
        let engine = StoryEngine(game: game, player: pilot.state, services: missionServices)
        switch goal {
        case .disable, .escort: engine.missionShipDisabled(missionID: missionID)
        case .board, .rescue: engine.missionShipBoarded(missionID: missionID)
        default: engine.missionShipDestroyed(missionID: missionID)
        }
        pilot.state = engine.player
        touch()
    }

    var activeMissionTitles: [String] {
        pilot.state.activeMissions.map { game?.mission($0.missionID)?.displayName ?? "#\($0.missionID)" }
    }

    // MARK: Catalogs

    private func buildCatalogs(_ game: NovaGame) {
        shipPicks = game.ships().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "shïp") }
        outfitPicks = game.outfits().map { EditorPick(id: $0.id, title: $0.outfitterDisplayName, subtitle: "oütf") }
        fleetPicks = game.fleets().map { EditorPick(id: $0.id, title: $0.name.novaDisplayName, subtitle: "flët") }
        systemPicks = game.systems().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "sÿst") }
        missionPicks = game.missions().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "mïsn") }
        govtPicks = game.govts().map { EditorPick(id: $0.id, title: $0.displayName, subtitle: "gövt") }
    }

    func systemName(_ id: Int) -> String { game?.system(id)?.displayName ?? "#\(id)" }
    func shipName(_ id: Int) -> String { game?.ship(id)?.displayName ?? "#\(id)" }
}

/// Stock-fittings helper kept separate so the session doesn't need `GameHost`
/// just to compute a hull's starting inventory.
enum EditorGameFactoryOutfits {
    static func stock(game: NovaGame, shipID: Int) -> [Int: Int] {
        guard let res = game.ship(shipID) else { return [:] }
        return PilotEconomy.hullFittings(res, game: game)
    }
}
#endif
