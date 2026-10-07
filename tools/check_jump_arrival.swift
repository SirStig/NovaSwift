import Foundation
import SwiftUI
import os
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// The runner replaces the two markers with verbatim app methods. This is an
// in-process fixture: no app bootstrap, window, preferences or pilot archive.
// Rendering/audio/persistence shims leave the transition and real Worlds intact.
private enum Log {
    static let scene = Logger(subsystem: "dev.gamestudio.jump-fixture", category: "scene")
    static let story = Logger(subsystem: "dev.gamestudio.jump-fixture", category: "story")
    static let input = Logger(subsystem: "dev.gamestudio.jump-fixture", category: "input")
}
private final class Node {
    var position = CGPoint.zero
    var alpha: CGFloat = 0
    var isHidden = true
    var zRotation: CGFloat = 0
    var yScale: CGFloat = 1
}
private struct Settings {
    struct Difficulty { var playerDamageScale = 1.0 }
    struct Aliveness { var populationScale = 1.0; var passThroughChance = 0.5 }
    var difficulty = Difficulty()
    var systemAliveness = Aliveness()
    var reduceFlashing = true
}
@MainActor private final class Audio {
    enum Cue { case hyperspaceArrive }
    func startHyperspaceCharge() {}
    func stopHyperspaceCharge() {}
    func play(_ cue: Cue) {}
}
@MainActor private final class HUD {
    var systemName = ""
    var navCourseSystemName = ""
    var navCourseJumps = 0
    func post(_ text: String) {}
}
@MainActor private final class GameScene {
    var world: World!
    var galaxy: Galaxy?
    var systemID = 0
    var systemName = ""
    var playerShip: Ship? { world?.player }
    var settings = Settings()
    var audio: Audio? = Audio()
    var hud: HUD? = HUD()
    var shipNode = Node()
    var cameraNode = Node()
    var jumpFlash: Node? = Node()
    var jumpStreaks: Node? = Node()
    var planetVisuals: [Int] = []
    var openGateIDs: Set<Int> = []
    var destroyedStellarIDs: Set<Int> = []
    var escortRecordByEntity: [Int: Int] = [:]
    var hyperspaceNoJumpRadius = 1000.0
    var worldSeedDayProvider: (() -> Int)?
    var seedReads: [(system: Int, day: Int, fuel: Double)] = []
    var reloadNotifications = 0
    var onSystemReloaded: ((Int) -> Void)? {
        get { reloadHandler }
        set {
            reloadHandler = newValue.map { callback in
                { [weak self] id in self?.reloadNotifications += 1; callback(id) }
            }
        }
    }
    private var reloadHandler: ((Int) -> Void)?
    var onAutoLandArrived: ((Int) -> Void)?
    var onMissionShipGoalReached: ((Int, MissionShipGoal, Bool) -> Void)?
    var onMissionShipLost: ((Int, MissionShipGoal) -> Void)?
    var onPlayerDisabled: (() -> Void)?
    var onPlayerBoarded: (() -> Void)?
    var onStellarDefendersLaunched: ((Int, Int, Int) -> Void)?
    var onStellarDominated: ((Int) -> Void)?
    var onStellarDestroyed: ((Int) -> Void)?
    var onEscortLost: ((Int) -> Void)?
    private enum JumpPhase { case none, align, accelerate, flash, arrive }
    private var jumpPhase: JumpPhase = .none
    private var jumpClock = 0.0
    private var jumpOutboundHeading = 0.0
    private var jumpInstant = false
    private var jumpSpeed = 1.0
    private var jumpDestSystemID = 0
    private var jumpCommit: (() -> Void)?
    private var jumpCommitted = false
    private var jumpArriveGateID: Int?
    var isJumping: Bool { jumpPhase != .none }
    func cancelAutoLand() {}
    func canEnterHyperspace() -> Bool { true }
    func makePlanetVisuals(systemID: Int, game: NovaGame) -> [Int] { [] }
    func clearSystemNodes() { escortRecordByEntity.removeAll() }
    func buildPlanets() {}
    func playGateArrivalFlourish(_ id: Int) {}
    func despawnEscort(recordID: Int) {}
    func advanceAnimation() { _ = stepJump(0.2) }

    // EXTRACTED_SCENE_METHODS
}
@MainActor private final class GameHost {
    let scene: GameScene
    let game: NovaGame?
    var galaxy: Galaxy? { scene.galaxy }
    var hud: HUD { scene.hud! }
    init(scene: GameScene, game: NovaGame) { self.scene = scene; self.game = game }
}
@MainActor private final class Pilot {
    var state: PlayerState
    var saveCount = 0
    init(_ state: PlayerState) { self.state = state }
    func save() { saveCount += 1 }
    func maxJumpHops(galaxy: Galaxy) -> Int { PilotEconomy.maxJumpHops(state, galaxy: galaxy) }
    func hyperspaceNoJumpRadius(galaxy: Galaxy) -> Double { PilotEconomy.hyperspaceNoJumpRadius(state, galaxy: galaxy) }
    func hasInstantJump(galaxy: Galaxy) -> Bool { true }
    func jumpSpeedFactor(galaxy: Galaxy) -> Double { 1 }
}
@MainActor private final class DataModel { var game: NovaGame?; init(_ game: NovaGame) { self.game = game } }
@MainActor private final class Model {
    let pilot: Pilot
    let data: DataModel
    init(pilot: PlayerState, game: NovaGame) { self.pilot = Pilot(pilot); data = DataModel(game) }
}
@MainActor private final class Services {
    var onLeaveStellar: ((String?) -> Void)?
    var onSpawnMissionShips: ((Int, MissionRes) -> Void)?
    var onChangePlayerShip: ((Int, ChangeShipMode) -> Void)?
    var onMovePlayer: ((Int, Bool) -> Void)?
    var onSetStellarDestroyed: ((Int, Bool) -> Void)?
    var onEscortFeeCharged: ((Int) -> Void)?
    var onEscortDeparted: ((Int, String) -> Void)?
}
private final class StateBox<Value> { var value: Value; init(_ value: Value) { self.value = value } }
@propertyWrapper private struct FixtureState<Value> {
    private let box: StateBox<Value>
    init(wrappedValue: Value) { box = StateBox(wrappedValue) }
    var wrappedValue: Value { get { box.value } nonmutating set { box.value = newValue } }
}
@MainActor private struct GameContainerView {
    let model: Model
    let nav: NavigationModel
    @FixtureState var host: GameHost?
    @FixtureState var hostSystemID = 0
    @FixtureState var gateMapOrigin: Int? = nil
    @FixtureState var landedSpobID: Int? = nil
    let flightMissionServices = Services()
    enum SaveReason { case jump }
    func requestLanding(_ id: Int) {}
    func handleMissionShipGoalReached(missionID: Int, goal: MissionShipGoal) {}
    func handleMissionShipLost(missionID: Int) {}
    func failActiveMissions(where predicate: (MissionRes) -> Bool, reason: String) {}
    func handleStellarDominated(spobID: Int) {}
    func handleStellarShotDown(spobID: Int) {}
    func depart() {}
    func rebuildFlightHost(reason: String) {}
    func movePlayerToSystem(_ id: Int, keepPosition: Bool) {}
    func advanceGameDay() { model.pilot.state.date = model.pilot.state.date.adding(days: 1) }
    func saveGame(reason: SaveReason) {}
    func fixtureSync() { syncNav(host) }
    func fixtureHyperspace() -> Bool { attemptJump() }
    func fixtureGate(system: Int, gate: Int) { performGateJump(toSystem: system, arriveAtGate: gate) }

    // EXTRACTED_CONTAINER_METHODS
}

@main private struct CheckJumpArrival {
    @MainActor static func main() throws {
        let dataURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let game = NovaGame(try GameLibrary.merge(baseFiles: GameLibrary.discoverResourceFiles(in: dataURL)))
        guard let mission = game.mission(155), mission.shipSystem == 521,
              let sourceSystem = game.system(521)?.links.first(where: { $0 >= 128 }) else {
            fatalError("Stock Take Sample target or adjacent system missing")
        }
        let destinationContext = Galaxy(game: game).systemContext(for: 521)
        guard let destinationGate = destinationContext.bodies.first(where: { $0.isGate }) else {
            fatalError("Stock target system has no real gate/wormhole for gate-arrival fixture")
        }
        var scenarios: [[String: Any]] = []
        for gate in [false, true] {
            var state = PlayerState(pilotName: "Isolated jump fixture", credits: 1000, currentSystem: sourceSystem)
            state.setBit(279)
            let story = StoryEngine(game: game, player: state)
            guard story.accept(155) else { fatalError("Could not accept mission155 fixture") }
            state = story.player
            state.escorts = [EscortRecord(id: 73, shipType: 128, name: "Fixture escort", origin: .captured)]
            let initialDay = state.date.julianDay
            let model = Model(pilot: state, game: game)
            let galaxy = Galaxy(game: game)
            guard let player = galaxy.makeLoadedShip(128, at: Vec2(2000, 0)) else { fatalError("Player hull missing") }
            player.fuel = 300; player.maxFuel = 300
            let scene = GameScene()
            let initial = GameSession.makeWorld(game: game, systemID: sourceSystem, player: player, galaxy: galaxy)
            scene.world = initial.world; scene.galaxy = initial.galaxy; scene.systemID = sourceSystem
            scene.worldSeedDayProvider = { [weak scene, weak model] in
                guard let model else { return 0 }
                let day = model.pilot.state.date.julianDay
                scene?.seedReads.append((scene?.systemID ?? -1, day, player.fuel))
                return day
            }
            let host = GameHost(scene: scene, game: game)
            let nav = NavigationModel(game: game, startSystemID: sourceSystem)
            let container = GameContainerView(model: model, nav: nav, host: host)
            container.fixtureSync()
            guard nav.plotCourse(to: 521), nav.route.count == 1 else { fatalError("Fixture route should be one hop") }
            let oldWorld = scene.world!
            let escortBefore = oldWorld.playerEscorts.filter { $0.escortRecordID == 73 }.count
            if gate { container.fixtureGate(system: 521, gate: destinationGate.id) }
            else if !container.fixtureHyperspace() { fatalError("Fixture jump refused") }
            for _ in 0..<12 { scene.advanceAnimation() }
            let wraiths = scene.world.missionShips(missionID: 155)
            let escorts = scene.world.playerEscorts.filter { $0.escortRecordID == 73 }
            let afterCount = wraiths.count
            let callbackCount = scene.reloadNotifications
            let oldWorldWraiths = oldWorld.missionShips(missionID: 155).count
            let expectedFuel = gate ? 300.0 : 200.0
            let seedRead = scene.seedReads.first
            let navWasCorrectBeforeExtraSync = nav.currentSystemID == scene.systemID
            container.fixtureSync(); container.fixtureSync()
            let checks: [String: Bool] = [
                "destinationWorldReplaced": scene.world !== oldWorld && scene.systemID == 521,
                "modelNavAgreeBeforeExtraSync": navWasCorrectBeforeExtraSync && model.pilot.state.currentSystem == 521,
                "wraithSurvivesArrival": afterCount == 1 && wraiths.first?.disabled == true && wraiths.first?.shipTypeID == 185,
                "escortSurvivesArrival": escortBefore == 1 && escorts.count == 1,
                "postReloadCallbackExactlyOnce": callbackCount == 1,
                "fuelCommitsOnce": player.fuel == expectedFuel,
                "dayCommitsBeforeWorldSeed": seedRead?.day == initialDay + 1 && model.pilot.state.date.julianDay == initialDay + 1,
                "fuelCommitsBeforeWorldSeed": seedRead?.fuel == expectedFuel,
                "gateArrivalUsesRealGate": !gate || abs((player.position - destinationGate.position).length
                    - (destinationGate.radius + player.radius + 25)) < 0.001,
                "extraSyncDoesNotDuplicate": scene.world.missionShips(missionID: 155).count == 1
                    && scene.world.playerEscorts.filter { $0.escortRecordID == 73 }.count == 1,
                "objectiveStillPending": model.pilot.state.activeMission(155)?.shipObjectivesRemaining == 1,
            ]
            scenarios.append([
                "mode": gate ? "gate" : "hyperspace", "sourceSystem": sourceSystem, "targetSystem": 521,
                "arrivalGate": gate ? destinationGate.id : -1,
                "wraithCountAfterArrival": afterCount, "wraithCountInDiscardedWorld": oldWorldWraiths,
                "escortCountAfterArrival": escorts.count, "callbackCount": callbackCount,
                "initialDay": initialDay, "worldSeedDay": seedRead?.day ?? -1,
                "fuelAfterArrival": player.fuel, "fuelAtWorldSeed": seedRead?.fuel ?? -1,
                "checks": checks, "allChecksPass": checks.values.allSatisfy { $0 },
            ])
        }
        let report: [String: Any] = [
            "mode": "Exact extracted app methods; real stock GameSession/World; rendering and save shims only",
            "missionID": 155, "scenarios": scenarios,
            "allChecksPass": scenarios.allSatisfy { $0["allChecksPass"] as? Bool == true },
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
