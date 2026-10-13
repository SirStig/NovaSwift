import Foundation
import NovaSwiftKit
import NovaSwiftEngine

/// The pilot-side bookkeeping of a completed hyperjump, for frontends that don't
/// carry the Apple app's full mission-services plumbing (the Godot bridge): the
/// ship's fuel is folded into the pilot, the destination becomes explored and its
/// nebula events fire (the hops crossed on the way fire theirs too), mission
/// offers re-roll, and the calendar advances by the jump's travel days
/// (`PilotEconomy.travelDays`, FL-05) — crons, tribute, disasters and salaries
/// ride along inside `StoryEngine.advanceDays`.
public enum HyperjumpCommit {
    /// Apply an arrival in `destination`. `passedThrough` are the intermediate
    /// systems of a multi-jump; `extraDays` is the most any attached escort's
    /// hull costs (`World.attachedShipsTravelDays`). Returns the days elapsed.
    @discardableResult
    public static func apply(_ state: inout PlayerState, game: NovaGame, galaxy: Galaxy,
                             destination: Int, passedThrough: [Int] = [],
                             shipFuel: Double?, extraDays: Int = 0,
                             services: GameServices? = nil) -> Int {
        state.fuel = shipFuel
        let days = max(PilotEconomy.travelDays(state, galaxy: galaxy), extraDays)
        let engine = StoryEngine(game: game, player: state, services: services)
        engine.playerJumped(toSystem: destination, via: passedThrough)
        engine.advanceDays(days)
        state = engine.player
        return days
    }
}
