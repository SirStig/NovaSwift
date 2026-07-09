import Foundation
import EVNovaKit
import EVNovaStory

/// The app's `GameServices` conformer — the seam the story/mission engine
/// (`StoryEngine`) reaches out through for anything beyond its own control-bit
/// state. Combat/AI ship-spawning, hull swaps and system-retargeting aren't
/// wired to the story engine yet (those systems don't consume mission events
/// today), so those log instead of no-oping silently, so the gap is visible
/// in Console rather than looking like a silent success.
@MainActor
final class AppGameServices: GameServices, ObservableObject {
    /// The mission currently being offered, if any — a mission/spöb screen
    /// observes this to show the briefing sheet.
    @Published var pendingOffer: MissionOffer?
    /// The most recent narrative text the engine wants shown (mission
    /// completion, cron news), if any.
    @Published var storyText: (title: String, text: String)?

    var audio: GameAudio?

    func presentMissionOffer(_ offer: MissionOffer) {
        pendingOffer = offer
    }

    func showStoryText(_ text: String, title: String) {
        storyText = (title, text)
    }

    func playSound(id: Int) {
        audio?.playSound(id)
    }

    func spawnMissionShips(missionID: Int, mission: MissionRes) {
        Log.story.notice("spawnMissionShips: not yet wired to combat/AI (mission #\(missionID, privacy: .public), count \(mission.shipCount, privacy: .public))")
    }

    func changePlayerShip(to shipID: Int, mode: ChangeShipMode) {
        Log.story.notice("changePlayerShip: not yet wired (ship #\(shipID, privacy: .public))")
    }

    func movePlayer(toSystem systemID: Int, keepPosition: Bool) {
        Log.story.notice("movePlayer: not yet wired (system #\(systemID, privacy: .public))")
    }

    func setStellarDestroyed(spobID: Int, destroyed: Bool) {
        Log.story.notice("setStellarDestroyed: not yet wired (spöb #\(spobID, privacy: .public) destroyed=\(destroyed, privacy: .public))")
    }

    func leaveStellar(message: String?) {
        Log.story.notice("leaveStellar: not yet wired (\(message ?? "", privacy: .public))")
    }

    func notify(_ event: StoryNotification) {
        Log.story.debug("notify: \(String(describing: event), privacy: .public)")
    }
}
