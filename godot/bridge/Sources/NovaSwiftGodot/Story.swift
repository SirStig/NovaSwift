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

// MARK: - Story Map / Story Guide state
//
// Plain-Swift backing for NovaWorld's "Story Map" callables. The Apple
// `StoryGuideModel` builds the campaign graph off the main thread, memoizes each
// lane's flow and prewarms the mission->storyline tag table; this is the same,
// minus SwiftUI. `StorylineAnalyzer` is not Sendable, so it only ever runs on
// the one serial queue below; results cross back under `lock`.

private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class StoryMapState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "novaswift.storymap", qos: .userInitiated)
    private let lock = NSLock()
    private var analyzer: StorylineAnalyzer?
    private var map: StoryMap?
    private var pending = 0                 // builds queued or running
    private var tags: [Int: MissionStorylineTag]?
    private var tagsPending = false
    private var flowCache: [String: [StoryFlowRow]] = [:]
    private var crossLinkCache: [Int: [CrossLink]]?
    private var palette: GovernmentMapPalette?
    /// Identity of the game the analyzer/tags were built for (a reload drops them).
    private var gameStamp = ""

    /// Forget everything when the loaded data set changes.
    private func reset(for stamp: String) {
        guard stamp != gameStamp else { return }
        gameStamp = stamp
        analyzer = nil; map = nil; tags = nil; palette = nil
        flowCache = [:]; crossLinkCache = nil
    }

    static func stamp(of game: NovaGame) -> String {
        // FNV-1a over mission ids + names: stable across launches (Hasher is not).
        var h: UInt64 = 0xcbf29ce484222325
        for m in game.missions() {
            for b in "\(m.id)\(m.name)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        }
        return String(h, radix: 16)
    }

    /// Start (or restart) a background map build for `player`. The previous map
    /// stays readable until the new one lands.
    func begin(game: NovaGame, player: PlayerState) {
        let stamp = Self.stamp(of: game)
        lock.lock(); reset(for: stamp); pending += 1; lock.unlock()
        let box = UncheckedBox(game)
        queue.async { [self] in
            lock.lock(); let existing = analyzer; lock.unlock()
            let a = existing ?? StorylineAnalyzer(game: box.value)
            let built = a.storyMap(for: player)
            lock.lock()
            if gameStamp == stamp {
                analyzer = a
                map = built
                flowCache = [:]; crossLinkCache = nil
                palette = GovernmentMapPalette(game: box.value)
            }
            pending -= 1
            lock.unlock()
        }
    }

    var isBuilding: Bool { lock.lock(); defer { lock.unlock() }; return pending > 0 }
    var hasMap: Bool { lock.lock(); defer { lock.unlock() }; return map != nil }

    // MARK: Tags

    /// The mission's storyline tag; nil while the table is still prewarming (and
    /// the first call starts that prewarm, off-thread, through the disk cache).
    func tag(forMission id: Int, game: NovaGame) -> MissionStorylineTag? {
        lock.lock()
        let stamp = Self.stamp(of: game)
        reset(for: stamp)
        if let tags { lock.unlock(); return tags[id] }
        let start = !tagsPending
        tagsPending = true
        lock.unlock()
        if start {
            let box = UncheckedBox(game)
            queue.async { [self] in
                let cache = StorylineTagCache(fingerprint: "godot-\(stamp)")
                let table: [Int: MissionStorylineTag]
                if let cached = cache?.load() { table = cached } else {
                    lock.lock(); let existing = analyzer; lock.unlock()
                    let a = existing ?? StorylineAnalyzer(game: box.value)
                    table = a.storylineTags()
                    cache?.store(table)
                    lock.lock(); if gameStamp == stamp { analyzer = a }; lock.unlock()
                }
                lock.lock()
                if gameStamp == stamp { tags = table }
                tagsPending = false
                lock.unlock()
            }
        }
        return nil
    }

    var tagsReady: Bool { lock.lock(); defer { lock.unlock() }; return tags != nil }

    // MARK: Read-out

    private func rgb(_ govt: Int?) -> [Double] {
        guard let govt, let palette else { return GovernmentMapPalette.independent }
        return palette.color(for: govt)
    }

    /// `{lanes:[...], untagged, pluginLabels}` — lane = key/title/done/total/complete/
    /// govt/govtName/color/plugin/current (the "you are here" step's id) / currentName.
    func lanesJSON(game: NovaGame) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let map else { return ["lanes": [Any](), "untagged": 0] }
        let lanes = map.lanes.map { l -> [String: Any] in
            let nodes = map.nodes.filter { $0.storylineKey == l.key }
            let cur = StoryGuideLogic.currentStepID(in: nodes)
            let curNode = nodes.first { $0.id == cur }
            return ["key": l.key, "title": l.title, "done": l.completedCount, "total": l.totalCount,
                    "complete": l.isComplete, "govt": l.governmentID ?? -1,
                    "govtName": l.governmentID.flatMap { game.govt($0)?.displayName } ?? "",
                    "color": rgb(l.governmentID), "plugin": l.pluginID,
                    "current": cur ?? -1, "currentName": curNode?.step.displayName ?? "",
                    "currentStatus": curNode?.step.status.rawValue ?? ""]
        }
        // Display names of the plug-ins lanes can come from (Apple `StoryGuideModel.pluginLabel`).
        let labels = Dictionary(PluginRuntime.shared.plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return ["lanes": lanes, "untagged": map.untaggedCount, "pluginLabels": labels]
    }

    func flowJSON(key: String, game: NovaGame, player: PlayerState) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let map else { return [] }
        let rows: [StoryFlowRow]
        if let cached = flowCache[key] { rows = cached } else {
            let links = crossLinkCache ?? StoryGuideLogic.crossLinks(in: map)
            crossLinkCache = links
            rows = StoryGuideLogic.flow(for: key, in: map, crossLinks: links)
            flowCache[key] = rows
        }
        return rows.map { r -> [String: Any] in
            let s = r.step
            return [
                "id": r.id, "name": s.displayName, "step": s.stepNumber, "status": s.status.rawValue,
                "depth": r.depth, "connector": r.connector.label ?? "", "current": r.isCurrent,
                "objective": s.objective, "reward": s.reward, "offeredAt": s.offeredAt,
                "synopsis": s.synopsis, "govt": s.governmentID ?? -1,
                "govtName": s.governmentID.flatMap { game.govt($0)?.displayName } ?? "",
                "blockers": s.blockers.map { b -> [String: Any] in
                    ["bit": b.bit, "needsSet": b.needsSet,
                     "hint": b.unlockedBy.first.map { "\($0.hint)\(b.unlockedBy.count > 1 ? " (or others)" : "")" } ?? "",
                     "unknown": b.unlockedBy.isEmpty]
                },
                // Every offer gate with met (true / false / null = depends where you look).
                "requirements": s.requirements.map { q -> [String: Any] in
                    ["kind": q.kind.rawValue, "text": q.text, "met": q.met.map { $0 ? 1 : 0 } ?? -1]
                },
                // The chain of missions / events to do first, deepest = where to start.
                "path": s.unlockPath.map { p -> [String: Any] in
                    ["depth": p.depth, "kind": p.kind?.rawValue ?? "", "id": p.id, "name": p.name,
                     "action": p.action, "status": p.status.rawValue, "offeredAt": p.offeredAt,
                     "storyline": p.storyline ?? "", "unmet": p.unmet, "alternatives": p.alternatives]
                },
                "jumps": r.jumps.map { ["id": $0.targetID, "label": $0.connector.label ?? "Leads to",
                                        "name": $0.targetName] as [String: Any] },
                "cross": r.crossLinks.map { ["key": $0.key, "outgoing": $0.outgoing] as [String: Any] },
                "deadEnds": r.node.deadEndOutcomes.map(\.rawValue).joined(separator: " / "),
                "canAbort": s.status == .active && (game.mission(r.id)?.canAbort ?? false)
                    && player.activeMission(r.id) != nil,
            ]
        }
    }
}
