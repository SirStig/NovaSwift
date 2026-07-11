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
/// `sÿst` links. Drives the galaxy map. As in EV Nova, you plot a course to any
/// reachable system (fewest jumps) and the hyperdrive follows it hop by hop —
/// multi-jump outfits let one jump command cross more than one hop at once — and
/// every hop costs real hyperspace fuel drawn from the live player ship.
@MainActor
final class NavigationModel: ObservableObject {
    private(set) var game: NovaGame?
    @Published var currentSystemID: Int
    @Published var showingMap = false
    /// The plotted hyperspace course: the remaining hops, in order (empty = none).
    @Published private(set) var route: [Int] = []
    /// Hyperlane hops one `jumpAlongRoute()` call can cross (multi-jump outfits).
    @Published var maxJumpHops: Int = 1

    /// The live player ship, for fuel — attached/reattached by the container
    /// whenever the play session's ship is (re)built (it doesn't survive a jump).
    private(set) weak var ship: Ship?
    func attachShip(_ ship: Ship?) { self.ship = ship }

    var currentFuel: Double { ship?.fuel ?? 0 }
    var shipMaxFuel: Double { ship?.maxFuel ?? 0 }
    /// Whole hyperjumps the current fuel can pay for.
    var availableJumps: Int { Int((currentFuel / ShipFuel.perJump).rounded(.down)) }
    func canAfford(hops: Int) -> Bool { hops > 0 && hops <= availableJumps }
    /// How many leading route hops the next `jumpAlongRoute()` call will consume.
    var nextJumpHopCount: Int { min(maxJumpHops, route.count) }

    init(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
    }

    /// Set the resolved game + starting system once data has loaded.
    func configure(game: NovaGame?, startSystemID: Int) {
        self.game = game
        self.currentSystemID = startSystemID
        self.route = []
    }

    var current: SystRes? { game?.system(currentSystemID) }
    func systems() -> [SystRes] { game?.systems() ?? [] }
    func system(_ id: Int) -> SystRes? { game?.system(id) }

    /// Systems reachable in one jump from the current system.
    func neighbors() -> [SystRes] {
        (current?.links ?? []).compactMap { game?.system($0) }
    }

    func canJump(to id: Int) -> Bool { current?.links.contains(id) ?? false }

    var destinationID: Int? { route.last }

    /// Plot a hyperspace course to a system: the fewest-jumps path along `sÿst`
    /// links (breadth-first). Returns false if the system is unreachable.
    /// Plotting to the current system clears the course.
    @discardableResult
    func plotCourse(to id: Int) -> Bool {
        guard id != currentSystemID else { route = []; return true }
        guard let path = shortestPath(from: currentSystemID, to: id) else { return false }
        route = path
        return true
    }

    func clearCourse() { route = [] }

    /// Engage the hyperdrive along the plotted course: jump `nextJumpHopCount`
    /// hops at once (more than one only with a multi-jump outfit), keeping the
    /// rest of the route so the next jump continues it. Requires enough fuel for
    /// every hop consumed. Returns true if the jump happened.
    @discardableResult
    func jumpAlongRoute() -> Bool {
        let hops = nextJumpHopCount
        guard canAfford(hops: hops), let ship else { return false }
        for _ in 0..<hops { _ = ship.consumeJumpFuel() }
        currentSystemID = route[hops - 1]
        route.removeFirst(hops)
        showingMap = false
        return true
    }

    /// Commit a hyperspace *arrival* at `dest` after crossing `hops` hops: spend
    /// the fuel, drop those hops from the plotted route, and set the current
    /// system. Used by the in-scene jump animation's flash-peak commit so the
    /// arrival is atomic and the destination can't drift even if the route was
    /// re-plotted mid-animation (in which case the stale route is just cleared).
    /// Returns false (spending nothing) if the fuel isn't there.
    @discardableResult
    func commitArrival(at dest: Int, hops: Int) -> Bool {
        guard hops > 0, canAfford(hops: hops), let ship else { return false }
        for _ in 0..<hops { _ = ship.consumeJumpFuel() }
        if route.count >= hops, route[hops - 1] == dest {
            route.removeFirst(hops)
        } else {
            route = []                       // route drifted under us — drop it
        }
        currentSystemID = dest
        showingMap = false
        return true
    }

    /// Every system directly linked to a system in `explored` (the "you can see
    /// there's something there" ring around what you've actually visited).
    func adjacentToExplored(_ explored: Set<Int>) -> Set<Int> {
        Set(explored.flatMap { game?.system($0)?.links ?? [] })
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
        if route.first == id { route.removeFirst() } else { route = [] }
        currentSystemID = id
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
                guard let sys = game.system(id) else { continue }
                for link in sys.links where !visited.contains(link) {
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
