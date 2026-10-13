import NovaSwiftStory

/// `GameScene` already has every mission-ship operation the shared
/// `FlightMissions` glue needs (it forwards to `World`), so it can serve as the
/// host directly. `@preconcurrency`: the scene is main-actor, the protocol is
/// not (the Godot bridge's host isn't), and every caller here is on the main actor.
extension GameScene: @preconcurrency MissionShipHost {}
