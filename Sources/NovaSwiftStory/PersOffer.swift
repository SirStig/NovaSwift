import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// A `pêrs`'s LinkMission offered in flight, on a hail (or, with Flags 0x0200,
/// on boarding) — the accept/decline panel Apple's `GameContainerView` raises.
/// The offer flow itself is `StoryEngine.present/accept/decline`; this holds the
/// person-specific aftermath of an acceptance so every frontend does the same.
public enum FlightPersOffer {

    /// Raise the offer for `missionID`. True when a window is up; false when
    /// the mission isn't there or a can't-refuse offer with no text activated
    /// silently (the caller then adopts `engine.player`).
    public static func present(missionID: Int, engine: StoryEngine, game: NovaGame) -> Bool {
        guard let mission = game.mission(missionID) else { return false }
        return engine.present(mission)
    }

    /// After `offer` was accepted by `personID`: the person's flags apply —
    /// 0x0100 never spawns again, 0x0800 leaves the system, 0x0040 swaps the
    /// ship for the mission's one special ship (AI-39, its hull becoming the
    /// slot's locked hull under `mïsn` Flags 0x0800).
    public static func afterAccept(personID: Int, offer: MissionOffer, engine: StoryEngine,
                                   state: inout PlayerState, world: World?, game: NovaGame) {
        guard let pers = game.pers(personID) else { return }
        if pers.deactivateAfterMission { state.recordPersDefeated(personID) }
        guard let world else { return }
        if pers.leaveAfterMission {
            world.npcs.first { $0.personID == personID }?.brain?.state = .departing
        }
        if pers.replacedByMissionShip, offer.mission.shipCount == 1, offer.mission.shipDude >= 128,
           let am = state.activeMission(offer.mission.id),
           let ship = world.npcs.first(where: { $0.personID == personID }),
           let id = world.replaceWithMissionShip(entityID: ship.entityID, missionID: offer.mission.id,
                                                 dudeID: offer.mission.shipDude,
                                                 goal: offer.mission.shipGoal,
                                                 behavior: offer.mission.shipBehaviorMode,
                                                 name: engine.missionShipName(am, offer.mission),
                                                 subtitle: engine.missionShipSubtitle(am, offer.mission)),
           let hull = world.ship(id: id)?.shipTypeID,
           offer.mission.flags1 & 0x0800 != 0,
           let i = state.activeMissions.firstIndex(where: { $0.missionID == offer.mission.id }) {
            state.activeMissions[i].lockedShipType = hull
        }
    }
}
