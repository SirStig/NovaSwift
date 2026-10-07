import Foundation
import NovaSwiftKit
import NovaSwiftEngine
import NovaSwiftStory

// A headless stock-data check. This creates a synthetic pilot in memory;
// no installed app, pilot archive, preferences or game window is opened.
@main
struct CheckTakeSample {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: check-take-sample NOVA_DATA_DIRECTORY")
        }
        let files = GameLibrary.discoverResourceFiles(in: URL(fileURLWithPath: CommandLine.arguments[1]))
        let game = NovaGame(try GameLibrary.merge(baseFiles: files))
        guard let mission = game.mission(155), let system = game.system(521) else {
            fatalError("Stock Take Sample mission/system resources are missing")
        }
        var pilot = PlayerState(pilotName: "Mission fixture", credits: 1_000, currentSystem: 259)
        pilot.setBit(279)
        let story = StoryEngine(game: game, player: pilot)
        story.initialSpob = 286
        guard story.accept(mission.id) else { fatalError("Could not accept mission fixture") }
        story.playerJumped(toSystem: system.id)

        let galaxy = Galaxy(game: game)
        guard let playerShip = galaxy.makeLoadedShip(128, at: Vec2()) else {
            fatalError("Stock player hull missing")
        }
        let world = World(player: playerShip)
        world.galaxy = galaxy
        world.systemContext = galaxy.systemContext(for: system.id)
        let ids = world.spawnMissionShips(missionID: mission.id, dudeID: mission.shipDude,
                                         count: mission.shipCount, goal: mission.shipGoal,
                                         behavior: mission.shipBehaviorMode, arrival: .populate)
        guard ids.count == 1, let wraith = world.ship(id: ids[0]) else {
            fatalError("Mission Wraith did not spawn")
        }
        _ = world.drainEvents()
        // Boarding has a scene-side range gate; place the synthetic player in
        // reach so this checks the world/story path independently of flying.
        world.player.position = wraith.position
        let locked = world.selectNearestTarget(hostileOnly: false)?.entityID == wraith.entityID
        _ = world.drainEvents()

        func boardAndDeliverEvents(to engine: StoryEngine) -> Int {
            guard world.board(shipID: wraith.entityID) != nil else { return 0 }
            var goals = 0
            // The app now performs this drain immediately, before its plunder
            // sheet pauses the scene or the next step clears pending events.
            for event in world.drainEvents() {
                if case let .missionShipGoalReached(mid, _, goal, byPlayer) = event, byPlayer {
                    goals += 1
                    switch goal {
                    case .board, .rescue: engine.missionShipBoarded(missionID: mid)
                    case .disable: engine.missionShipDisabled(missionID: mid)
                    default: engine.missionShipDestroyed(missionID: mid)
                    }
                }
            }
            world.player.cargo = engine.player.cargo
            return goals
        }
        let firstGoals = boardAndDeliverEvents(to: story)
        let remaining = story.player.activeMission(mission.id)?.shipObjectivesRemaining ?? -1
        let pickedUp = story.player.activeMission(mission.id)?.cargoPickedUp == true
        let sampleTons = story.player.cargo[31] ?? 0
        let liveCargoTons = world.player.cargo[31] ?? 0
        let repeatGoals = boardAndDeliverEvents(to: story)
        let repeatSampleTons = story.player.cargo[31] ?? 0

        // Check a save-format round trip in memory, then complete the return
        // leg using the actual mission resource and normal landing entry point.
        let encoded = try JSONEncoder().encode(story.player)
        let restored = try JSONDecoder().decode(PlayerState.self, from: encoded)
        let resumed = StoryEngine(game: game, player: restored)
        resumed.playerJumped(toSystem: 259)
        resumed.playerLanded(onSpob: 286)
        let completed = resumed.player.completedMissions.contains(mission.id)
        let reward = resumed.player.credits - pilot.credits
        let delivered = (resumed.player.cargo[31] ?? 0) == 0
        let checks: [String: Bool] = [
            "stockMissionFields": mission.shipSystem == 521 && mission.shipDude == 186
                && mission.shipGoal == .board && mission.cargoPickup == .onSpecialShip,
            "disabledWraithSpawned": wraith.shipTypeID == 185 && wraith.disabled && wraith.isAlive,
            "generalNearestLocksDerelict": locked,
            "boardingReportsExactlyOneGoal": firstGoals == 1,
            "boardingObjectiveMet": remaining == 0,
            "samplePickedUp": pickedUp && sampleTons == 1,
            "liveHoldContainsSample": liveCargoTons == 1,
            "repeatBoardingDoesNotRepeatGoalOrCargo": repeatGoals == 0 && repeatSampleTons == 1,
            "saveRoundTripPreservesSample": restored.cargo[31] == 1
                && restored.activeMission(mission.id)?.cargoPickedUp == true,
            "returnCompletesAndPays": completed && reward == 40_000 && delivered
                && resumed.player.setBits.contains(280),
        ]
        let report: [String: Any] = [
            "missionID": mission.id, "systemID": system.id,
            "missionDudeID": mission.shipDude, "shipTypeID": wraith.shipTypeID,
            "initialDerelictArmor": wraith.armor,
            "firstBoardGoalEvents": firstGoals, "repeatBoardGoalEvents": repeatGoals,
            "remainingAfterBoard": remaining, "sampleTonsAfterBoard": sampleTons,
            "rewardCredits": reward, "completed": completed,
            "checks": checks, "allChecksPass": checks.values.allSatisfy { $0 },
            "mode": "headless stock-data runtime; synthetic in-memory pilot",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
