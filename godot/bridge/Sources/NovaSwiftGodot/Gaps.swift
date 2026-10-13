// Plain-Swift state for the bridge's gameplay-gaps section (`// MARK: Gameplay
// gaps` in NovaWorld.swift); same split as Navigation.swift / Interactions.swift /
// Story.swift — `@Godot` registers only what is declared in the class body, so the
// callables live in NovaWorld and this is just the data they share.
//
// No game logic here: the bar's hire list (`EscortHire`), the racing game
// (`RaceSession`), the scan consequence (`ContrabandScan.scanPlayer`), the
// përs offer aftermath (`FlightPersOffer`), the escape pod (`EscapePodRespawn`)
// and the escort fleet pass (`PilotEconomy.processEscortFleetAtStellar`) are the
// shared NovaSwiftStory types the Apple app's views and container call too.

import NovaSwiftStory

struct GapsState {
    /// The bar's Galaxy Racing Network session (remembers the last winner).
    var race = RaceSession()
    /// The përs whose LinkMission offer is on screen (accept/decline aftermath).
    var persOfferPerson: Int?
    /// The self-destruct command is held (Alt-−).
    var selfDestructHeld = false
    /// The wrapping 0…1024 frame counter the junk-cargo events run off (EC-24).
    var junkFrame = 0
    /// The pod finished flying: the respawn runs after the tick loop.
    var podRespawnPending = false
    /// The death sequence ran out with no eject: a real game over.
    var playerDestroyed = false
    /// Status-line lines raised here, drained with the travel messages.
    var messages: [String] = []

    /// A world was (re)built.
    mutating func resetForNewWorld() {
        persOfferPerson = nil
        selfDestructHeld = false
        podRespawnPending = false
    }
}
