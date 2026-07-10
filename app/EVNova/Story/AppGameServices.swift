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

    // `GameServices` itself isn't main-actor-isolated (the CLI's
    // `LoggingGameServices` runs off the main actor), but every conformer in
    // this app is only ever driven by `StoryEngine` from SwiftUI/MainActor
    // code (see `MissionBoardView`). `nonisolated` + `MainActor.assumeIsolated`
    // satisfies the protocol without forcing an async hop that would delay
    // `@Published` updates a run-loop turn — safe because that MainActor-only
    // calling contract is real, not just assumed here.

    nonisolated func presentMissionOffer(_ offer: MissionOffer) {
        MainActor.assumeIsolated { pendingOffer = offer }
    }

    nonisolated func showStoryText(_ text: String, title: String) {
        MainActor.assumeIsolated { storyText = (title, text) }
    }

    nonisolated func playSound(id: Int) {
        MainActor.assumeIsolated { audio?.playSound(id) }
    }

    nonisolated func spawnMissionShips(missionID: Int, mission: MissionRes) {
        Log.story.notice("spawnMissionShips: not yet wired to combat/AI (mission #\(missionID, privacy: .public), count \(mission.shipCount, privacy: .public))")
    }

    nonisolated func changePlayerShip(to shipID: Int, mode: ChangeShipMode) {
        Log.story.notice("changePlayerShip: not yet wired (ship #\(shipID, privacy: .public))")
    }

    nonisolated func movePlayer(toSystem systemID: Int, keepPosition: Bool) {
        Log.story.notice("movePlayer: not yet wired (system #\(systemID, privacy: .public))")
    }

    nonisolated func setStellarDestroyed(spobID: Int, destroyed: Bool) {
        Log.story.notice("setStellarDestroyed: not yet wired (spöb #\(spobID, privacy: .public) destroyed=\(destroyed, privacy: .public))")
    }

    nonisolated func leaveStellar(message: String?) {
        Log.story.notice("leaveStellar: not yet wired (\(message ?? "", privacy: .public))")
    }

    nonisolated func notify(_ event: StoryNotification) {
        Log.story.debug("notify: \(String(describing: event), privacy: .public)")
    }
}
