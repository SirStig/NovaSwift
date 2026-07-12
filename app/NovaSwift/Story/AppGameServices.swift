import Foundation
import NovaSwiftKit
import NovaSwiftStory

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

    // Live-world effect hooks. The engine mutates the persistent `PlayerState`
    // itself (credits, bits, `shipType`, `currentSystem`, outfits, ranks), so
    // those survive regardless. These callbacks are what makes the *running*
    // game react — swap the live hull, relocate/rebuild the world, force a
    // takeoff, drop mission ships into the current system. The container sets
    // them on the flight-side services instance; the bar/spaceport per-view
    // instances leave them nil (the mutation still lands and takes visible
    // effect on the next takeoff, which rebuilds the ship/system from state).
    var onChangePlayerShip: ((_ shipID: Int, _ mode: ChangeShipMode) -> Void)?
    var onMovePlayer: ((_ systemID: Int, _ keepPosition: Bool) -> Void)?
    var onLeaveStellar: ((_ message: String?) -> Void)?
    var onSetStellarDestroyed: ((_ spobID: Int, _ destroyed: Bool) -> Void)?
    var onSpawnMissionShips: ((_ missionID: Int, _ mission: MissionRes) -> Void)?

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
        MainActor.assumeIsolated {
            if let onSpawnMissionShips {
                onSpawnMissionShips(missionID, mission)
            } else {
                // No live world attached (e.g. accepted from a bar/spaceport view):
                // the container spawns from the active-mission list on the next
                // system (re)build, so nothing to do here.
                Log.story.debug("spawnMissionShips: no live world (mission #\(missionID, privacy: .public)); deferred to next system build")
            }
        }
    }

    nonisolated func changePlayerShip(to shipID: Int, mode: ChangeShipMode) {
        MainActor.assumeIsolated {
            // The engine already set `PlayerState.shipType` (and adjusted outfits
            // per C/E/H), so the swap persists and rebuilds on takeoff regardless;
            // the callback makes it happen live when the player is already flying.
            onChangePlayerShip?(shipID, mode)
        }
    }

    nonisolated func movePlayer(toSystem systemID: Int, keepPosition: Bool) {
        MainActor.assumeIsolated {
            // `PlayerState.currentSystem` is already updated by the engine; the
            // callback relocates/rebuilds the live world when in flight.
            onMovePlayer?(systemID, keepPosition)
        }
    }

    nonisolated func setStellarDestroyed(spobID: Int, destroyed: Bool) {
        MainActor.assumeIsolated { onSetStellarDestroyed?(spobID, destroyed) }
    }

    nonisolated func leaveStellar(message: String?) {
        MainActor.assumeIsolated {
            if let onLeaveStellar {
                onLeaveStellar(message)
            } else if let message {
                // No takeoff hook wired here — at least surface the message.
                storyText = ("", message)
            }
        }
    }

    nonisolated func notify(_ event: StoryNotification) {
        Log.story.debug("notify: \(String(describing: event), privacy: .public)")
    }

    // Surface active-crön news as a dialog. The Bible's local-over-independent
    // precedence is a per-station rendering rule; here (fired at cron start,
    // station unknown) we simply show the text so it isn't dropped. A dedicated
    // news reader can refine presentation later.
    nonisolated func showNews(text: String, govt: Int?) {
        guard !text.isEmpty else { return }
        MainActor.assumeIsolated { storyText = ("Galactic News", text) }
    }
}
