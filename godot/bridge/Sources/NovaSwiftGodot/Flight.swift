// Plain-Swift state for the bridge's in-flight travel section
// (`// MARK: Flight travel` in NovaWorld.swift); same split as Navigation.swift /
// Interactions.swift — `@Godot` registers only what is declared in the class body,
// so the callables live in NovaWorld and this is just the data they share.
//
// No game logic here: clearance, refusal text, the two-press landing, gate
// permission and the gate exits are the shared `LandedServices` / `OriginalText` /
// `PlayerLanding` / `NovaGame.gateDestinations` / `NovaGame.wormholeExit`
// types the Apple app's `GameScene` + `GameContainerView` use.

struct TravelState {
    /// The selected nav destination (planet/station) — the original's travel-stellar
    /// channel, independent of the ship target (`GameScene.selectedPlanetID`, UI-06).
    var selectedSpob: Int?
    /// The stellar a landing was requested from by the first Land press (UI-08;
    /// the original's `DAT_00597a10`). The 250 px clearance arm only runs for it.
    var landingRequest: Int?
    /// Bodies the player has been cleared to land on this visit (0x00459950).
    var cleared: Set<Int> = []
    /// Hypergates switched on this visit (landing on one lights it).
    var openGates: Set<Int> = []
    /// The stellar whose Land-press ladder (`landingRefusalReason`) passed, so docking or entering a
    /// gate does not run it again (0x00457580 runs it once, on the press).
    var ladderPassed: Int?
    /// While a hypergate's destination picker is up: the gate being used.
    var gatePicker: Int?
    /// The frontend plays the gate-entry movie itself (`GateTravelMovie`): a wormhole then picks its exit
    /// but waits in `pendingWormhole` for `wormholeEnterPending()` instead of transporting at once.
    var deferGateTransport = false
    var pendingWormhole: (system: Int, gate: Int)?
    /// Status-line lines raised here, drained by GDScript.
    var messages: [String] = []

    /// A world was (re)built: entity-keyed selection and clearance are stale.
    mutating func resetForNewWorld() {
        selectedSpob = nil
        landingRequest = nil
        ladderPassed = nil
        cleared = []
        openGates = []
        gatePicker = nil
    }
}
