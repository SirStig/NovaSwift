import NovaSwiftStory

/// `GameScene` already has every mission-ship operation the shared
/// `FlightMissions` glue needs (it forwards to `World`), so it can serve as the
/// host directly.
extension GameScene: MissionShipHost {}
