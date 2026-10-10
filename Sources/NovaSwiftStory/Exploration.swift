import Foundation
import NovaSwiftKit

// MARK: - Exploration and nebula events (UI-04, OS-14)
//
// The original keeps one discovery level per system: 1 once arrived in by
// hyperspace or revealed by a mission `X`, 2 once landed in or charted by a
// map. NCB `E` tests level > 0. Here level 1 is `exploredSystems`, landing adds
// `landedSystems`, and a map adds `chartedSystems` (`isSystemExplored`).

extension StoryEngine {

    /// Arrival in `systemID` by hyperspace (or a gate): the system becomes
    /// explored, the nebula events of the system fire, and every mission's
    /// AvailRandom is rolled afresh (0x00458802). `via` lists a multi-jump's
    /// intermediate systems, whose nebula events fire on the way through.
    public func playerJumped(toSystem systemID: Int, via hops: [Int] = []) {
        for hop in hops { exploreNebulae(containing: hop) }
        player.currentSystem = systemID
        player.exploredSystems.insert(systemID)
        exploreNebulae(containing: systemID)
        rerollMissionOffers()
    }

    /// Fire the OnExplore of every active, not-yet-explored nebula whose rect
    /// (inset 8) holds one of `systems` — once per nebula per game
    /// (0x00467bd0).
    public func exploreNebulae(_ systems: [Int]) {
        for s in systems { exploreNebulae(containing: s) }
    }

    func exploreNebulae(containing systemID: Int) {
        guard let sys = game.system(systemID) else { return }
        for neb in game.nebulae() where neb.width != 0 && neb.height != 0 {
            guard !(player.exploredNebulae?.contains(neb.id) ?? false),
                  evaluate(test: neb.activeOn) else { continue }
            guard sys.x >= neb.x + 8, sys.x <= neb.x + neb.width - 8,
                  sys.y >= neb.y + 8, sys.y <= neb.y + neb.height - 8 else { continue }
            player.exploredNebulae = (player.exploredNebulae ?? []).union([neb.id])
            Log.mission.notice("nebula \(neb.id, privacy: .public) reached at system \(systemID, privacy: .public)")
            apply(set: neb.onExplore, source: "nëbu \(neb.id) \"\(neb.name)\" OnExplore")
        }
    }

    /// An outfit was acquired outside the engine (a shop purchase): run its
    /// map's nebula events over `state`.
    public static func exploreNebulae(_ systems: [Int], state: inout PlayerState, game: NovaGame) {
        guard !systems.isEmpty, game.nebulae().contains(where: { !$0.onExplore.isEmpty }) else { return }
        let engine = StoryEngine(game: game, player: state)
        engine.exploreNebulae(systems)
        state = engine.player
    }

    /// The galaxy-map detail level of a system: 0 unknown, 1 visited or
    /// revealed (services "<Unknown>"), 2 landed or charted by a map.
    public func discoveryLevel(_ systemID: Int) -> Int {
        if (player.landedSystems?.contains(systemID) ?? false) || player.isSystemCharted(systemID) { return 2 }
        return player.exploredSystems.contains(systemID) ? 1 : 0
    }
}
