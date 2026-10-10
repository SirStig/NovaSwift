import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// OS-02: what happens to the pilot when the escape pod comes down
/// (`PlayerTick_TimedActionTransition` 0x0044d490 / 0x0044d570 and
/// `Ship_ResetPlayerShipState` 0x004b3350), as pure edits of `PlayerState`.
/// The host runs them in the original's order: abort every active mission,
/// `resetToClassZero`, move to `respawnStellar`'s system, run `rand(30) + 15`
/// days, then `finishRespawn` (registration, standing, meters).
public enum EscapePodRespawn {

    /// The respawn hull: class 0, the first `shïp` (Q-UI-02: the original
    /// ignores the scenario's ship).
    public static let classZeroShipID = 128

    /// Days the world moves on while the pod drifts: `rand(30) + 15`.
    public static func driftDays(roll30: Int) -> Int { roll30 + 15 }

    /// `Stellar_FindValidRespawnStellar` (0x00467710): a depth-first flood out
    /// of the death system over visible, explored neighbours — at each system
    /// it checks every unvisited neighbour's stellars before recursing — for a
    /// stellar that is standing, landable, has a shipyard (spöb Flags 0x0008)
    /// and whose `MinStatus` the player's standing there meets (`-32767`
    /// always does, `32767` never). The death system itself is never chosen.
    /// Returns the stellar and its system, or nil (the host then uses the
    /// first system).
    public static func respawnStellar(from deathSystem: Int, state: PlayerState, game: NovaGame,
                                      isVisible: (Int) -> Bool) -> (spob: Int, system: Int)? {
        var visited: Set<Int> = [deathSystem]
        func eligible(_ id: Int) -> Bool {
            !visited.contains(id) && state.exploredSystems.contains(id) && isVisible(id)
        }
        func scan(_ systemID: Int) -> Int? {
            guard let sys = game.system(systemID) else { return nil }
            for spobID in sys.spobs {
                guard let spob = game.spob(spobID), !state.isStellarDestroyed(spobID),
                      spob.canLand, spob.hasShipyard, spob.minStatus != 32767 else { continue }
                let standing = state.reputation(atSystem: systemID)
                if spob.minStatus <= standing || spob.minStatus == -32767 { return spobID }
            }
            return nil
        }
        func recurse(_ systemID: Int) -> (Int, Int)? {
            visited.insert(systemID)
            let links = game.system(systemID)?.links ?? []
            for next in links where eligible(next) {
                if let found = scan(next) { return (found, next) }
            }
            for next in links where eligible(next) {
                if let found = recurse(next) { return found }
            }
            return nil
        }
        return recurse(deathSystem).map { (spob: $0.0, system: $0.1) }
    }

    /// The ship side of `Ship_ResetPlayerShipState`: class 0 with its stock
    /// weapons and DefaultItems (and its `OnPurchase` run), the outfits that
    /// stay with the pilot (`oütf` Flags 0x0004) kept, everything else — and
    /// all cargo and junk — gone.
    public static func resetToClassZero(_ state: inout PlayerState, game: NovaGame) {
        state.outfits = state.outfits.filter { id, _ in (game.outfit(id)?.flags ?? 0) & 0x0004 != 0 }
        state.cargo = [:]
        state.shipType = classZeroShipID
        if let ship = game.ship(classZeroShipID) {
            PilotEconomy.grantHullFittings(&state, ship: ship, game: game)
            runControlBitSet(&state, ship.onPurchase, game: game,
                             source: "shïp \(ship.id) \"\(ship.name)\" OnPurchase")
        }
    }

    /// The rest of the respawn: a fresh registration — the class name and
    /// four digits 1–9 — every system's standing back to its government's
    /// InitialRec, full shields and fuel, and armor refilled to the maximum
    /// *shield* value (the original's bug, 0x0044d83f).
    public static func finishRespawn(_ state: inout PlayerState, game: NovaGame, galaxy: Galaxy,
                                     registrationDigits: [Int]) {
        let className = game.ship(state.shipType)?.displayName ?? ""
        state.shipName = className + " " + registrationDigits.prefix(4).map(String.init).joined()
        state.systemReputation = SystemReputation.initial(statuses: [], govts: game.govtTable(),
                                                          map: game.reputationMap())
        state.shield = nil
        state.fuel = nil
        state.armor = PilotEconomy.loadout(state, galaxy: galaxy)?.maxShield
    }

    /// Ejecting (0x00451024): the old hull's `OnRetire` runs, the outfits
    /// that don't stay with the pilot are lost, and the new craft's stock
    /// fittings are owned.
    public static func eject(_ state: inout PlayerState, from oldShip: Int, into newShip: Int, game: NovaGame) {
        if let old = game.ship(oldShip) {
            runControlBitSet(&state, old.onRetire, game: game,
                             source: "shïp \(old.id) \"\(old.name)\" OnRetire")
        }
        state.outfits = state.outfits.filter { id, _ in (game.outfit(id)?.flags ?? 0) & 0x0004 != 0 }
        state.shipType = newShip
        if let ship = game.ship(newShip) {
            for (oid, count) in PilotEconomy.hullFittings(ship, game: game) { state.grantOutfit(oid, count: count) }
        }
    }

    private static func runControlBitSet(_ state: inout PlayerState, _ expr: String, game: NovaGame, source: String) {
        guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let engine = StoryEngine(game: game, player: state)
        engine.apply(set: expr, source: source)
        state = engine.player
    }
}
