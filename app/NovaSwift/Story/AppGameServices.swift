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
    /// Narrative texts the engine wants shown (briefings, completion and
    /// failure texts, refusals), oldest first. The original shows each in a
    /// modal dialog of its own (0x004982a0), so none overwrites another.
    @Published private(set) var storyQueue: [(title: String, text: String)] = []
    private var queuedDescIDs: [Int?] = []
    private var stagedDescID: Int?
    /// The `dësc` the shown text came from (nil = plain text), so the dialog
    /// can draw that `dësc`'s graphic. Set just before assigning `storyText`.
    var storyDescID: Int? {
        get { queuedDescIDs.first ?? nil }
        set { stagedDescID = newValue }
    }
    /// The text on screen: the head of `storyQueue`. Assigning a text queues
    /// it behind any already waiting; assigning nil dismisses the one shown.
    var storyText: (title: String, text: String)? {
        get { storyQueue.first }
        set {
            if let newValue { storyQueue.append(newValue); queuedDescIDs.append(stagedDescID); stagedDescID = nil }
            else if !storyQueue.isEmpty { storyQueue.removeFirst(); if !queuedDescIDs.isEmpty { queuedDescIDs.removeFirst() } }
        }
    }

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
    /// An overlay line for the flight view (`showOverlayMessage`).
    var onOverlayMessage: ((_ message: String) -> Void)?
    /// A landed `Q`: the spaceport closes whichever screen is open. Each
    /// spaceport screen's services instance sets it.
    var onCloseSpaceportScreen: (() -> Void)?
    var onSetStellarDestroyed: ((_ spobID: Int, _ destroyed: Bool) -> Void)?
    var onSpawnMissionShips: ((_ missionID: Int, _ mission: MissionRes) -> Void)?
    /// A hired escort left the wing because its daily fee went unpaid — the
    /// container despawns the live ship whose `escortRecordID` matches.
    var onEscortDeparted: ((_ escortID: Int, _ name: String) -> Void)?
    /// A mission's ships are released (0x00440aa0); the container frees them
    /// in the live world.
    var onReleaseMissionShips: ((_ missionID: Int) -> Void)?

    nonisolated func releaseMissionShips(missionID: Int) {
        MainActor.assumeIsolated { onReleaseMissionShips?(missionID) }
    }

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
        MainActor.assumeIsolated { storyDescID = nil; storyText = (title, text) }
    }

    nonisolated func showStoryText(_ text: String, title: String, descID: Int) {
        MainActor.assumeIsolated { storyDescID = descID; storyText = (title, text) }
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
                storyDescID = nil
                storyText = ("", message)
            }
        }
    }

    nonisolated func showOverlayMessage(_ text: String) {
        MainActor.assumeIsolated {
            if let onOverlayMessage { onOverlayMessage(text) } else { storyText = ("", text) }
        }
    }

    nonisolated func closeSpaceportScreen() {
        MainActor.assumeIsolated {
            pendingOffer = nil
            onCloseSpaceportScreen?()
        }
    }

    nonisolated func notify(_ event: StoryNotification) {
        Log.story.debug("notify: \(String(describing: event), privacy: .public)")
        MainActor.assumeIsolated {
            switch event {
            case let .escortDeparted(escortID, name):
                onEscortDeparted?(escortID, name)
            default:
                break
            }
        }
    }

    // Crön news is NOT popped when the event fires — that's not how EV Nova
    // presents it. It's read at a spaceport, where the station's government
    // decides which local (or, failing that, independent) news applies. The
    // container resolves that on landing via `StoryEngine.stationNews(forGovt:)`;
    // this callback only logs, so the cron-start path stays a no-op.
    nonisolated func showNews(text: String, govt: Int?) {
        Log.story.debug("showNews (cron fired; read at station via stationNews): govt \(govt.map(String.init) ?? "independent", privacy: .public)")
    }
}
