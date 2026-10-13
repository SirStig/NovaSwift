// Plain-Swift state for the bridge's story section (`// MARK: Story & missions`
// in NovaWorld.swift); same split as Navigation.swift / Interactions.swift —
// `@Godot` registers only what is declared in the class body, so the callables
// live in NovaWorld and this is the data (and the `GameServices` seam) they share.
//
// No game logic here: offers, objectives, rewards, crons and the mission ships'
// decisions are `StoryEngine` / `FlightMissions` (NovaSwiftStory), the same code
// the Apple app's `AppGameServices` + `GameContainerView` drive.

import Foundation
import NovaSwiftEngine
import NovaSwiftKit
import NovaSwiftStory

/// The Godot build's `GameServices`: the seam `StoryEngine` reaches the world and
/// the UI through. Everything that is UI (texts, offers, "close the spaceport
/// screen", "you were thrown out") is queued for GDScript to drain; everything
/// that touches the live world is a hook `NovaWorld` installs.
final class GodotGameServices: GameServices {
    struct StoryText {
        var title: String
        var text: String
        var descID: Int?
    }

    /// The mission being offered right now, if any (one window at a time).
    var pendingOffer: MissionOffer?
    /// Narrative texts, oldest first — each a modal dialog of its own, as the
    /// original shows them (0x004982a0).
    var texts: [StoryText] = []
    /// Status-line lines (overlay messages, notices), drained by GDScript.
    var messages: [String] = []
    /// A `Q` fired while landed: GDScript closes whichever spaceport screen is open.
    var closeScreenRequested = false
    /// A `Q` fired while landed bounced the pilot back into space.
    var forcedLaunch = false

    var onPlaySound: ((Int) -> Void)?
    var onSpawnShips: (() -> Void)?
    var onChangeShip: ((Int, ChangeShipMode) -> Void)?
    var onMovePlayer: ((Int, Bool) -> Void)?
    var onStellarDestroyed: ((Int, Bool) -> Void)?
    var onReleaseShips: ((Int) -> Void)?
    var onEscortDeparted: ((Int) -> Void)?
    var onOverlay: ((String) -> Void)?
    var isLanded: () -> Bool = { false }
    var stellarName: (Int) -> String = { _ in "A stellar object" }

    func presentMissionOffer(_ offer: MissionOffer) { pendingOffer = offer }

    func showStoryText(_ text: String, title: String) {
        texts.append(StoryText(title: title, text: text, descID: nil))
    }

    func showStoryText(_ text: String, title: String, descID: Int) {
        texts.append(StoryText(title: title, text: text, descID: descID))
    }

    func playSound(id: Int) { onPlaySound?(id) }

    func spawnMissionShips(missionID: Int, mission: MissionRes) { onSpawnShips?() }

    func changePlayerShip(to shipID: Int, mode: ChangeShipMode) { onChangeShip?(shipID, mode) }

    func movePlayer(toSystem systemID: Int, keepPosition: Bool) { onMovePlayer?(systemID, keepPosition) }

    func setStellarDestroyed(spobID: Int, destroyed: Bool) { onStellarDestroyed?(spobID, destroyed) }

    func leaveStellar(message: String?) {
        if isLanded() {
            forcedLaunch = true
            if let message, !message.isEmpty { messages.append(message) }
        } else if let message, !message.isEmpty {
            messages.append(message)
        }
    }

    func showOverlayMessage(_ text: String) {
        if let onOverlay { onOverlay(text) } else { messages.append(text) }
    }

    func closeSpaceportScreen() {
        pendingOffer = nil
        closeScreenRequested = true
    }

    func releaseMissionShips(missionID: Int) { onReleaseShips?(missionID) }

    func notify(_ event: StoryNotification) {
        if case let .escortDeparted(escortID, _) = event { onEscortDeparted?(escortID) }
    }

    // A cron's news is read at a station's Holovid, not popped when it fires.
    func showNews(text: String, govt: Int?) {}
}

/// An edit to the live world the story asked for mid-tick (a hull swap, a move)
/// — applied after the tick loop, never inside it.
struct StoryWorldOps {
    var swapShip = false
    var moveToSystem: Int?
}

struct StoryState {
    let services = GodotGameServices()
    var hooksBound = false
    /// The pending offer was presented inside the Mission BBS pane, which draws
    /// it itself — the modal offer dialog must not also pop it.
    var inlineOffer = false
    var host: WorldMissionShipHost?
    var viewHalfExtent = Vec2(640, 400)
    /// Seconds since the last escort/observe sighting pass (the Apple app's 3 s heartbeat).
    var sightingClock = 0.0
    var spawnRequested = false
    var deferred = StoryWorldOps()
}
