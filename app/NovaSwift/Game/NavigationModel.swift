import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// How much the player currently knows about a system, for map fog-of-war.
enum SystemVisibility {
    /// Never seen, not adjacent to anywhere explored, not charted — not drawn.
    case unknown
    /// Not visited, but revealed by an owned map/chart outfit: real name + faction.
    case chartered
    /// Not visited, but linked to a system the player has been to: dim, unnamed.
    case adjacent
    /// Physically visited: full detail.
    case explored
}

/// Tracks the player's location in the galaxy and handles hyperspace jumps along
/// `sÿst` links. Drives the galaxy map. As in EV Nova, a click on the map arms a
/// jump to one linked system and Shift+click builds a longer route hop by hop
/// (`StarMapRoute`, UI-05); the `autoRoutePlotting` enhancement plots the
/// fewest-jumps course to any system instead. The hyperdrive follows the route
/// hop by hop — multi-jump outfits let one jump command cross more than one hop
/// at once — and every jump costs one jump of real hyperspace fuel from the live
/// player ship, however many hops it crosses (FL-06).
@MainActor
final class NavigationModel: ObservableObject {
    private(set) var game: NovaGame?
    @Published var currentSystemID: Int
    @Published var showingMap = false
    /// The plotted route and whether its first hop is armed for a jump.
    @Published private(set) var plan = StarMapRoute()
    /// The plotted hyperspace course: the remaining hops, in order (empty = none).
    var route: [Int] { plan.hops }
    /// Whether a jump is armed: J goes to `route.first`. A plain map click away
    /// from the current system's links disarms it, H re-arms it.
    var jumpArmed: Bool { plan.armed }
    /// The system the map's info panel describes (the original's selection,
    /// which a click moves even when it arms nothing). `nil` = the current one.
    @Published var selectedSystemID: Int?
    /// The `autoRoutePlotting` enhancement: a tap plots the fewest-jumps course.
    var autoRoutePlotting = false
    /// Hyperlane hops one `jumpAlongRoute()` call can cross (multi-jump outfits).
    @Published var maxJumpHops: Int = 1

    /// Systems the pilot's control bits currently hide — a `sÿst.Visibility` NCB
    /// test evaluating false (see `StoryEngine.hiddenSystemIDs`). EV Nova uses
    /// this to swap a system for an identical-coordinate copy as a storyline
    /// progresses: Tuatha, which holds New Ireland, ships as four `sÿst` records
    /// gated on bits 850/851/852, exactly one of which is live at any time.
    ///
    /// Pushed in by whoever owns the pilot (the game container on configure, the
    /// galaxy map whenever it opens); empty for a standalone preview map, which
    /// simply shows everything. Used to keep *routing* off a system that isn't
    /// currently part of the galaxy — a course must never deposit the player in
    /// the swapped-out twin. Deliberately NOT consulted by `canJump`: a stale set
    /// there could refuse a jump the player can legitimately make, and stranding
    /// someone is the failure this whole area is meant to prevent.
    @Published var hiddenSystems: Set<Int> = [] {
        didSet {
            visibilityKnown = true
            if hiddenSystems != oldValue { revalidateRoute() }
        }
    }
    /// Whether the owner has pushed the story's visibility yet.
    private var visibilityKnown = false

    /// `systemNeighbors`, each resolved to the first visible member of its
    /// twin group (`System_ResolveVisibleSystemForTravel` 0x0046b920, D-7): a
    /// link to a hidden system leads to its visible twin, or nowhere.
    private func visibleNeighbors(_ id: Int) -> [Int] {
        guard let game else { return [] }
        var out: [Int] = []
        for n in game.systemNeighbors(id) {
            let r = visibilityKnown ? game.visibleTwin(of: n, hidden: hiddenSystems)
                                    : (hiddenSystems.contains(n) ? nil : n)
            if let r, r != id, !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// The first visible member of `id`'s twin group, or nil (0x0046b920).
    func resolveVisible(_ id: Int) -> Int? {
        guard let game else { return hiddenSystems.contains(id) ? nil : id }
        return game.visibleTwin(of: id, hidden: hiddenSystems)
    }

    /// D-1: hops whose system went hidden swap to their visible twin, or cut
    /// the route there (0x00432470). Runs whenever the visibility changes.
    func revalidateRoute() {
        plan.revalidate(isVisible: { !hiddenSystems.contains($0) }, resolveVisible: { resolveVisible($0) })
    }

    /// The live player ship, for fuel — attached/reattached by the container
    /// whenever the play session's ship is (re)built (it doesn't survive a jump).
    private(set) weak var ship: Ship?
    func attachShip(_ ship: Ship?) { self.ship = ship }

    var currentFuel: Double { ship?.fuel ?? 0 }
    var shipMaxFuel: Double { ship?.maxFuel ?? 0 }
    /// Whole hyperjumps the current fuel can pay for.
    var availableJumps: Int { Int((currentFuel / ShipFuel.perJump).rounded(.down)) }
    /// A jump needs fuel for one jump whatever its hop count: the original
    /// debits 100 once, after the multi-jump loop (OQ A3).
    func canAfford(hops: Int) -> Bool { hops > 0 && availableJumps >= 1 }
    /// How many leading route hops the next `jumpAlongRoute()` call will consume
    /// (none while no jump is armed).
    var nextJumpHopCount: Int { jumpArmed ? min(maxJumpHops, route.count) : 0 }

    init(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
    }

    /// Set the resolved game + starting system once data has loaded.
    func configure(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
        self.plan = StarMapRoute()
        self.selectedSystemID = nil
    }

    var current: SystRes? { game?.system(currentSystemID) }
    func systems() -> [SystRes] { game?.systems() ?? [] }
    func system(_ id: Int) -> SystRes? { game?.system(id) }

    /// Systems reachable in one jump from the current system.
    func neighbors() -> [SystRes] {
        visibleNeighbors(currentSystemID).compactMap { game?.system($0) }
    }

    func canJump(to id: Int) -> Bool {
        (game?.systemNeighbors(currentSystemID).contains(id) ?? false) || visibleNeighbors(currentSystemID).contains(id)
    }

    var destinationID: Int? { route.last }

    /// Plot a hyperspace course to a system: the fewest-jumps path along `sÿst`
    /// links (breadth-first) — the `autoRoutePlotting` enhancement's tap, its
    /// "Nearest System" button and the system finder. Returns false if the
    /// system is unreachable. Plotting to the current system clears the course.
    @discardableResult
    func plotCourse(to id: Int) -> Bool {
        selectedSystemID = id
        guard id != currentSystemID else { plan.clear(); return true }
        guard let path = shortestPath(from: currentSystemID, to: id) else { return false }
        plan.set(path, cap: false)
        return true
    }

    /// A plain click on a map system (UI-05): arms a jump to it when it is
    /// linked to the current system, otherwise only moves the selection.
    func click(system id: Int) {
        selectedSystemID = id
        plan.click(id, current: currentSystemID, linked: isLinked)
    }

    /// A Shift+click: extend the route from its tail, truncate it at a plotted
    /// hop, or clear it on the current system (at most 31 hops).
    func shiftClick(system id: Int) {
        selectedSystemID = id
        plan.shiftClick(id, current: currentSystemID, linked: isLinked)
    }

    /// The cycle key (0x0044b120): step the armed link through the current
    /// system's resolvable links, wrapping, and arm it. False without links.
    @discardableResult
    func cycleHyperspaceLink(forward: Bool = true) -> Bool {
        let links = Array(visibleNeighbors(currentSystemID).prefix(16))
        guard !links.isEmpty else { return false }
        let at = jumpArmed ? route.first.flatMap { links.firstIndex(of: $0) } : nil
        let next = at.map { (($0 + (forward ? 1 : links.count - 1)) % links.count) } ?? (forward ? 0 : links.count - 1)
        click(system: links[next])
        return true
    }

    /// Re-arm the route's first hop when it is linked to the current system
    /// (H, closing the map, a gate arrival: 0x004a8080). Otherwise nothing
    /// changes. Returns whether a jump is now armed.
    @discardableResult
    func rearmRoute() -> Bool { plan.sync(current: currentSystemID, linked: isLinked) }

    /// H: hyperspace mode with the slot cleared, then the route sync.
    @discardableResult
    func selectHyperspace() -> Bool { plan.selectHyperspace(current: currentSystemID, linked: isLinked) }

    func clearCourse() { plan.clear() }

    /// A stellar took the travel selection, or it was cleared: no jump armed.
    func disarmJump() { plan.disarm() }

    /// Whether `b` is one visible hyperspace link from `a`.
    private func isLinked(_ a: Int, _ b: Int) -> Bool { visibleNeighbors(a).contains(b) }

    /// Engage the hyperdrive along the plotted course: jump `nextJumpHopCount`
    /// hops at once (more than one only with a multi-jump outfit), keeping the
    /// rest of the route so the next jump continues it. Costs one jump of fuel.
    /// Returns true if the jump happened.
    @discardableResult
    func jumpAlongRoute() -> Bool {
        let hops = nextJumpHopCount
        guard canAfford(hops: hops), let ship else { return false }
        _ = ship.consumeJumpFuel()
        let dest = route[hops - 1]
        plan.arrive(at: dest, crossing: hops, linked: isLinked)
        currentSystemID = dest
        selectedSystemID = nil
        showingMap = false
        return true
    }

    /// Commit a hyperspace *arrival* at `dest` after crossing `hops` hops: spend
    /// one jump's fuel, drop those hops from the plotted route, and set the current
    /// system. Used by the in-scene jump animation's flash-peak commit so the
    /// arrival is atomic and the destination can't drift even if the route was
    /// re-plotted mid-animation (in which case the stale route is just cleared).
    /// Returns false (spending nothing) if the fuel isn't there.
    @discardableResult
    func commitArrival(at dest: Int, hops: Int) -> Bool {
        guard hops > 0, canAfford(hops: hops), let ship else { return false }
        _ = ship.consumeJumpFuel()
        plan.arrive(at: dest, crossing: hops, linked: isLinked)   // a route that drifted under us is kept, disarmed
        currentSystemID = dest
        selectedSystemID = nil
        showingMap = false
        return true
    }

    /// Every system directly linked to a system in `explored` (the "you can see
    /// there's something there" ring around what you've actually visited).
    func adjacentToExplored(_ explored: Set<Int>) -> Set<Int> {
        Set(explored.flatMap { visibleNeighbors($0) })
    }

    /// The visible frontier one hop beyond *all* known space — neighbours of
    /// every system the player has either visited (`explored`) or revealed with
    /// a purchased/granted map (`charted`). Charting a system therefore also
    /// surfaces *its* neighbours as `.adjacent`, so a bought map doesn't dead-end
    /// at its own edge: you can keep plotting a course onward through the
    /// systems it connects to (previously only *visited* systems projected a
    /// frontier, leaving charted-but-unvisited systems' links invisible and
    /// unroutable).
    func adjacentToKnown(explored: Set<Int>, charted: Set<Int>) -> Set<Int> {
        adjacentToExplored(explored.union(charted))
    }

    /// What the player currently knows about system `id`, for map fog-of-war.
    /// `explored` is the player's visited-systems set; `adjacent` is its
    /// precomputed `adjacentToExplored(_:)`; `charted` is the set of systems a
    /// purchased/granted map outfit has revealed (`oütf` ModType 16 — a scoped
    /// reveal recorded at acquisition, NOT the whole galaxy).
    func visibility(of id: Int, explored: Set<Int>, adjacent: Set<Int>, charted: Set<Int>) -> SystemVisibility {
        if explored.contains(id) { return .explored }
        if charted.contains(id) { return .chartered }
        if adjacent.contains(id) { return .adjacent }
        return .unknown
    }

    /// Jump directly to a linked system (clears any plotted course that doesn't
    /// start with it). Returns true if the jump happened.
    @discardableResult
    func jump(to id: Int) -> Bool {
        guard canJump(to: id) else { return false }
        plan.arrive(at: id, linked: isLinked)
        currentSystemID = id
        selectedSystemID = nil
        showingMap = false
        return true
    }

    /// Arrive at `dest` via a gate (hypergate/wormhole): no fuel spent and no
    /// hyperspace link required — the gate did the travelling. The plotted
    /// course is kept (0x00457580 doesn't normalise it); its head re-arms only
    /// when it is linked from `dest`.
    @discardableResult
    func arriveViaGate(at dest: Int) -> Bool {
        plan.arriveViaGate(at: dest, linked: isLinked)
        currentSystemID = dest
        selectedSystemID = nil
        showingMap = false
        return true
    }

    /// Breadth-first fewest-jumps path (excluding `from`, ending at `to`).
    private func shortestPath(from: Int, to: Int) -> [Int]? {
        guard let game else { return nil }
        var cameFrom: [Int: Int] = [:]
        var frontier = [from]
        var visited: Set<Int> = [from]
        while !frontier.isEmpty {
            var next: [Int] = []
            for id in frontier {
                guard game.system(id) != nil else { continue }
                for link in visibleNeighbors(id) where !visited.contains(link) {
                    visited.insert(link)
                    cameFrom[link] = id
                    if link == to {
                        var path = [to]
                        var cursor = id
                        while cursor != from {
                            path.append(cursor)
                            cursor = cameFrom[cursor]!
                        }
                        return path.reversed()
                    }
                    next.append(link)
                }
            }
            frontier = next
        }
        return nil
    }
}
