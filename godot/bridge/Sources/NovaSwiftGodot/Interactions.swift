// Plain-Swift state for the bridge's in-flight interaction section
// (`// MARK: Interactions` in NovaWorld.swift); same split as Navigation.swift /
// Audio.swift — `@Godot` registers only what is declared in the class body, so
// the callables live in NovaWorld and this is just the data they share.
//
// No game logic here: the hail windows, boarding/plunder and the escort wing are
// the shared `FlightComm` / `FlightPlunder` / `FlightEscorts` (NovaSwiftStory)
// the Apple app's rules were extracted into.

import NovaSwiftStory

struct InteractionState {
    let comm = FlightComm()
    let plunder = FlightPlunder()
    let escorts = FlightEscorts()
    /// Status-line lines raised by the above, drained by GDScript.
    var messages: [String] = []
    /// A successful capture waiting for "use as escort / take command".
    var captureChoice: FlightPlunder.CaptureChoice?
    /// The Take Command prompt's default name, rolled once per capture.
    var captureName: String?
    /// The system the comm state was last reset for (bribes last per system).
    var lastSystem: Int?

    /// A world was (re)built: every open window is stale.
    mutating func resetForNewWorld(system: Int?) {
        if system != lastSystem { comm.systemChanged() }
        lastSystem = system
        comm.close(world: nil)
        plunder.abort(world: nil)
        escorts.reset()
        captureChoice = nil
        captureName = nil
    }
}
