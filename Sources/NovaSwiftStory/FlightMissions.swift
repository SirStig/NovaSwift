import Foundation
import NovaSwiftKit
import NovaSwiftEngine

// MARK: - Mission ships in flight (frontend-neutral)
//
// The glue between the mission runtime (`StoryEngine`) and a live `World`:
// dropping an active mission's special and auxiliary ships into the system the
// player is in, feeding the world's mission-ship events back as objective
// progress, the escort/observe sightings, and the fail-on-condition sweeps.
// Lifted out of the Apple app's `GameContainerView` so the Godot frontend runs
// the very same decisions; the Apple app calls it too.

/// What a frontend must be able to do with mission ships in its live world. The
/// Apple `GameScene` conforms (its methods already have these shapes); the Godot
/// bridge uses `WorldMissionShipHost`.
public protocol MissionShipHost: AnyObject {
    /// Whether the live world already holds (or has queued) ships tagged with
    /// `missionID` — checked before (re)spawning so a system never stacks sets.
    func hasMissionShips(_ missionID: Int) -> Bool
    /// Whether one of `missionID`'s live ships is in view and uncloaked.
    func missionShipInView(_ missionID: Int) -> Bool
    /// AI-14: queue a batch to jump in after the original's rearm delay.
    func scheduleMissionArrival(missionID: Int, dudeID: Int, count: Int, goal: MissionShipGoal,
                                behavior: MissionShipBehavior, auxiliary: Bool,
                                preferredShipID: Int?, name: String, subtitle: String)
    /// Place a batch into the live system now.
    @discardableResult
    func spawnMissionShips(missionID: Int, dudeID: Int, count: Int,
                           goal: MissionShipGoal, behavior: MissionShipBehavior,
                           government: Int?, arrival: World.ArrivalMode,
                           navStellarIndex: Int?, startsCloaked: Bool,
                           preferredShipID: Int?, name: String, subtitle: String) -> [Int]
}

/// `MissionShipHost` over a bare `World` — the Godot bridge's host.
public final class WorldMissionShipHost: MissionShipHost {
    public let world: World
    /// Half the visible play area around the player, for the observe goal.
    public var viewHalfExtent: Vec2

    public init(world: World, viewHalfExtent: Vec2 = Vec2(640, 400)) {
        self.world = world
        self.viewHalfExtent = viewHalfExtent
    }

    public func hasMissionShips(_ missionID: Int) -> Bool {
        world.npcs.contains { $0.missionID == missionID } || world.hasPendingMissionArrival(missionID: missionID)
    }

    public func missionShipInView(_ missionID: Int) -> Bool {
        let p = world.player.position
        return world.npcs.contains {
            $0.missionID == missionID && $0.isAlive && !$0.isCloaked
                && abs($0.position.x - p.x) <= viewHalfExtent.x
                && abs($0.position.y - p.y) <= viewHalfExtent.y
        }
    }

    public func scheduleMissionArrival(missionID: Int, dudeID: Int, count: Int, goal: MissionShipGoal,
                                       behavior: MissionShipBehavior, auxiliary: Bool,
                                       preferredShipID: Int?, name: String, subtitle: String) {
        let delay = auxiliary ? world.missionAuxDelay() : world.missionRearmDelay(goal: goal, behavior: behavior)
        world.scheduleMissionArrival(missionID: missionID, dudeID: dudeID, count: count, goal: goal,
                                     behavior: behavior, auxiliary: auxiliary, delayCalls: delay,
                                     preferredShipID: preferredShipID, name: name, subtitle: subtitle)
    }

    @discardableResult
    public func spawnMissionShips(missionID: Int, dudeID: Int, count: Int,
                                  goal: MissionShipGoal, behavior: MissionShipBehavior,
                                  government: Int?, arrival: World.ArrivalMode,
                                  navStellarIndex: Int?, startsCloaked: Bool,
                                  preferredShipID: Int?, name: String, subtitle: String) -> [Int] {
        world.spawnMissionShips(missionID: missionID, dudeID: dudeID, count: count, goal: goal,
                                behavior: behavior, government: government, arrival: arrival,
                                navStellarIndex: navStellarIndex, startsCloaked: startsCloaked,
                                preferredShipID: preferredShipID, name: name, subtitle: subtitle)
    }
}

public enum FlightMissions {

    /// A `mïsn.ShipStart` code as a spawn arrival: `1` = jump in from hyperspace;
    /// everything else (nav-defaults −4…−1, random 0, cloaked 2) just appears.
    public static func arrivalMode(forShipStart code: Int) -> World.ArrivalMode {
        code == 1 ? .hyperspace : .populate
    }

    /// Drop any active mission's special **and** auxiliary ships into the live
    /// world when the player is in the matching system. Goal ships
    /// (`ShipCount`/`ShipDude`/`ShipGoal`/`ShipBehav`, arriving per `ShipStart`)
    /// carry the player-side objective; aux ships (`AuxShipCount`/`AuxShipDude`,
    /// in `AuxShipSyst`) are atmosphere. Deduped by the host. Returns true if the
    /// engine changed the player (legacy slots got their ShipSyst resolved), so
    /// the caller adopts `engine.player`.
    @discardableResult
    public static func spawnActiveShips(engine: StoryEngine, host: MissionShipHost, currentSystem: Int) -> Bool {
        let game = engine.game
        var changed = false
        // Slots saved before ShipSyst was resolved at accept get it now.
        if engine.player.activeMissions.contains(where: { $0.shipSystemResolved != true }) {
            engine.resolveLegacyMissionShipSystems()
            changed = true
        }
        for am in engine.player.activeMissions {
            guard let m = game.mission(am.missionID), !host.hasMissionShips(m.id) else { continue }

            // Special ships (0x0041d6e0) spawn whenever the slot's resolved
            // ShipSyst is this system, whatever the ShipGoal — a −1 goal's
            // escorts, pursuers and ambushers included. Escort/observe and
            // goal-less ships always (re)spawn while the mission is active;
            // kill/disable/board objectives don't respawn once met.
            let passiveGoal = m.shipGoal == .escort || m.shipGoal == .observe || m.shipGoal == .none
            let goalEligible = m.shipCount > 0 && m.shipDude >= 128
                && (passiveGoal || am.shipObjectivesRemaining > 0)
            let goalSystemMatches = engine.shipSystemMatches(am, currentSystem: currentSystem)
            let shipName = engine.missionShipName(am, m)
            let shipSubtitle = engine.missionShipSubtitle(am, m)
            if goalEligible, goalSystemMatches {
                // `mïsn.ShipName`/`ShipSubtitle` name the special ships on the
                // target display, instead of their bare hull type.
                if m.shipStart == 1 {
                    // AI-14: a ShipStart-1 batch waits out its rearm delay, then
                    // jumps in from the previous system's side.
                    host.scheduleMissionArrival(missionID: m.id, dudeID: m.shipDude,
                                                count: max(1, m.shipCount), goal: m.shipGoal,
                                                behavior: m.shipBehaviorMode, auxiliary: false,
                                                preferredShipID: am.lockedShipType,
                                                name: shipName, subtitle: shipSubtitle)
                } else {
                    host.spawnMissionShips(missionID: m.id, dudeID: m.shipDude,
                                           count: max(1, m.shipCount), goal: m.shipGoal,
                                           behavior: m.shipBehaviorMode, government: nil,
                                           arrival: arrivalMode(forShipStart: m.shipStart),
                                           navStellarIndex: (-16 ... -1).contains(m.shipStart) ? -1 - m.shipStart : nil,
                                           startsCloaked: m.shipStart == 2,
                                           preferredShipID: am.lockedShipType,
                                           name: shipName, subtitle: shipSubtitle)
                }
            } else if m.shipCount > 0 {
                Log.mission.debug("spawnActiveShips: mission \(m.id) goal ships not spawned (eligible=\(goalEligible), systemMatches=\(goalSystemMatches), shipSystem=\(m.shipSystem), currentSys=\(currentSystem), remaining=\(am.shipObjectivesRemaining))")
            }

            // Auxiliary (flavor) ships — no goal, standard AI.
            // AI-14: they jump in after a `Rand(70) + 70`-tick timer from a random
            // side; without Flags 0x0010 each one spends the mission's budget.
            let auxLeft = m.infiniteAuxShips ? m.auxShipCount : (am.auxShipsRemaining ?? m.auxShipCount)
            if auxLeft > 0, m.auxShipDude >= 128,
               engine.auxSystemMatches(am, m, currentSystem: currentSystem) {
                host.scheduleMissionArrival(missionID: m.id, dudeID: m.auxShipDude, count: auxLeft,
                                            goal: .none, behavior: .standard, auxiliary: true,
                                            preferredShipID: nil, name: "", subtitle: "")
            }
        }
        return changed
    }

    /// The missions whose escort/observe ships are now present/seen (the
    /// original's sighting pass): an escort counts as under way once its ships
    /// exist, an observe goal once one is on screen and uncloaked.
    public static func dueSightings(state: PlayerState, game: NovaGame, host: MissionShipHost) -> [Int] {
        state.activeMissions.compactMap { am -> Int? in
            guard !(am.shipsSighted ?? false), let m = game.mission(am.missionID) else { return nil }
            switch m.shipGoal {
            case .escort:  return host.hasMissionShips(m.id) ? m.id : nil
            case .observe: return host.missionShipInView(m.id) ? m.id : nil
            default:       return nil
            }
        }
    }

    /// A mission special-ship reached its player-side goal in combat. The count
    /// falls; if it was the last ship and there is no return leg, the engine
    /// completes and pays out (its text goes out through the services).
    public static func shipGoalReached(engine: StoryEngine, missionID: Int, goal: MissionShipGoal) {
        switch goal {
        case .disable, .escort: engine.missionShipDisabled(missionID: missionID)
        case .board, .rescue:   engine.missionShipBoarded(missionID: missionID)
        default:                engine.missionShipDestroyed(missionID: missionID)
        }
    }

    /// A mission ship left the fight: destroyed (counted against a disable,
    /// escort or unboarded board/rescue goal, which then fails) or — for a
    /// chase-off goal — jumped out (MS-11).
    public static func shipLost(engine: StoryEngine, missionID: Int, goal: MissionShipGoal) {
        if goal == .chaseOff {
            engine.missionShipLeft(missionID: missionID)
        } else {
            engine.missionShipDestroyed(missionID: missionID)
        }
    }

    /// Fail every active mission whose static `mïsn` matches `predicate` (the
    /// `fail-if-disabled/boarded` conditions). Returns whether any failed.
    @discardableResult
    public static func failActive(engine: StoryEngine, where predicate: (MissionRes) -> Bool) -> Bool {
        let ids = engine.player.activeMissions.map(\.missionID)
        var failedAny = false
        for id in ids {
            guard let m = engine.game.mission(id), predicate(m) else { continue }
            engine.failMission(id)
            failedAny = true
        }
        return failedAny
    }

    /// Live auxiliary ships go back to their missions' budgets as the player
    /// leaves the system (0x0041ad50), capped at AuxShipCount.
    public static func creditSurvivingAuxShips(_ survivors: [Int: Int], state: inout PlayerState, game: NovaGame) {
        for (missionID, count) in survivors {
            guard let m = game.mission(missionID), !m.infiniteAuxShips,
                  let i = state.activeMissions.firstIndex(where: { $0.missionID == missionID })
            else { continue }
            let left = state.activeMissions[i].auxShipsRemaining ?? m.auxShipCount
            state.activeMissions[i].auxShipsRemaining = min(m.auxShipCount, left + count)
        }
    }
}
