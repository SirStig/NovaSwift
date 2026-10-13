// Plain-Swift state for the bridge's galaxy-map / hyperjump section
// (`// MARK: Navigation & hyperjump` in NovaWorld.swift). It lives in its own
// file because `@Godot` registers only what is declared inside the class body,
// so the callables themselves stay in NovaWorld; this is just the data they share.
//
// No game logic here: routing, visibility, fuel and the jump itself are the
// shared `StarMapRoute` / `StarMapNavigator` / `PlayerHyperjump` /
// `HyperjumpCommit` types the Apple app uses.

import NovaSwiftEngine

/// A hyperjump the engine is flying (`World.playerJump`): where it ends, how
/// many route hops it crosses, and the bearing it left on.
struct PendingHyperjump {
    var destination: Int
    var hops: Int
    var passedThrough: [Int]
    var bearing: Double
}

struct NavState {
    /// The plotted course and whether its first hop is armed (the original's
    /// route array + travel mode 3).
    var route = StarMapRoute()
    /// The map's selected system (a click moves it even when it arms nothing).
    var selected: Int?
    /// Systems the pilot's control bits currently hide.
    var hidden: Set<Int> = []
    var pending: PendingHyperjump?
    /// Messages for the status line (arrival, "field collapsed"), drained by GDScript.
    var messages: [String] = []
    /// Name of the system just arrived in, until `take_jump_arrival` reads it.
    var arrivedIn: String?
}
