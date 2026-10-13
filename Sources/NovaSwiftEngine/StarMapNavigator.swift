import Foundation
import NovaSwiftKit

/// How much the player currently knows about a system, for map fog-of-war.
public enum SystemVisibility: Sendable {
    /// Never seen, not adjacent to anywhere explored, not charted — not drawn.
    case unknown
    /// Not visited, but revealed by an owned map/chart outfit: real name + faction.
    case chartered
    /// Not visited, but linked to a system the player has been to: dim, unnamed.
    case adjacent
    /// Physically visited: full detail.
    case explored
}

/// The portable half of the galaxy map's navigation: which systems a jump can
/// reach (honouring story-hidden twin systems), the fewest-jumps course, the
/// fog-of-war classification and the outbound bearing. Extracted from the Apple
/// app's `NavigationModel` (an `ObservableObject`) so every frontend routes and
/// reveals the galaxy by the same rules; the model keeps only UI state.
public struct StarMapNavigator {
    public let game: NovaGame
    /// Systems the pilot's control bits currently hide (`NovaGame.hiddenSystemIDs`).
    public var hidden: Set<Int>
    /// Whether the owner has pushed the story's visibility yet. Until it has,
    /// a hidden system just drops out instead of resolving to its visible twin.
    public var visibilityKnown: Bool

    public init(game: NovaGame, hidden: Set<Int> = [], visibilityKnown: Bool = false) {
        self.game = game
        self.hidden = hidden
        self.visibilityKnown = visibilityKnown
    }

    /// `systemNeighbors`, each resolved to the first visible member of its
    /// twin group (`System_ResolveVisibleSystemForTravel` 0x0046b920, D-7): a
    /// link to a hidden system leads to its visible twin, or nowhere.
    public func visibleNeighbors(_ id: Int) -> [Int] {
        var out: [Int] = []
        for n in game.systemNeighbors(id) {
            let r = visibilityKnown ? game.visibleTwin(of: n, hidden: hidden)
                                    : (hidden.contains(n) ? nil : n)
            if let r, r != id, !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// The first visible member of `id`'s twin group, or nil (0x0046b920).
    public func resolveVisible(_ id: Int) -> Int? { game.visibleTwin(of: id, hidden: hidden) }

    /// Whether `b` is one visible hyperspace link from `a`.
    public func isLinked(_ a: Int, _ b: Int) -> Bool { visibleNeighbors(a).contains(b) }

    /// Whether a single jump from `from` can reach `to`.
    public func canJump(from: Int, to: Int) -> Bool {
        game.systemNeighbors(from).contains(to) || visibleNeighbors(from).contains(to)
    }

    /// Every system directly linked to a system in `explored`.
    public func adjacentToExplored(_ explored: Set<Int>) -> Set<Int> {
        Set(explored.flatMap { visibleNeighbors($0) })
    }

    /// The visible frontier one hop beyond all known space — neighbours of every
    /// visited (`explored`) or map-revealed (`charted`) system.
    public func adjacentToKnown(explored: Set<Int>, charted: Set<Int>) -> Set<Int> {
        adjacentToExplored(explored.union(charted))
    }

    /// What the player knows about system `id` (`adjacent` is `adjacentToKnown`).
    public static func visibility(of id: Int, explored: Set<Int>, adjacent: Set<Int>,
                                  charted: Set<Int>) -> SystemVisibility {
        if explored.contains(id) { return .explored }
        if charted.contains(id) { return .chartered }
        if adjacent.contains(id) { return .adjacent }
        return .unknown
    }

    /// Breadth-first fewest-jumps path (excluding `from`, ending at `to`).
    public func shortestPath(from: Int, to: Int) -> [Int]? {
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

    /// Compass heading (world radians, 0 = up, clockwise) from one system toward
    /// another on the galactic map — the direction the ship turns to before
    /// jumping. The map stores +y downward, so it's flipped into the world's
    /// +y-up convention (`Vec2.angle` == `atan2(x, y)`).
    public static func outboundHeading(game: NovaGame, from: Int, to: Int) -> Double {
        guard let a = game.system(from), let b = game.system(to),
              a.x != b.x || a.y != b.y else { return 0 }
        return atan2(Double(b.x - a.x), Double(-(b.y - a.y)))
    }
}

extension World {
    /// Whether the player is far enough from the system origin to enter
    /// hyperspace. `Stellar_ComputeTravelRangeSq` 0x00465610: the no-jump zone
    /// applies only when the system has a stellar that isn't a hypergate or
    /// wormhole, and is measured from the system's origin, not its centroid:
    /// refused while x² + y² ≤ r². `radius` is
    /// `PilotEconomy.hyperspaceNoJumpRadius` (1000 plus the pilot's outfits).
    public func isClearOfNoJumpZone(radius: Double) -> Bool {
        guard systemContext.bodies.contains(where: { !$0.isGate }) else { return true }
        let p = player.position
        return p.x * p.x + p.y * p.y > radius * radius
    }
}

/// Why the hyperdrive won't engage right now.
public enum HyperspaceRefusal: Sendable {
    /// Refused without a word: a wreck, an escape pod, a disabled ship
    /// (0x0044c1a3) or a tractor-beam lock on another ship (0x00415b80).
    case silent
    /// Too close to the system centre: STR# 2002 #42.
    case tooCloseToCentre
}

extension World {
    /// The player's ability to enter hyperspace, ahead of fuel and route checks
    /// (`GameScene.canEnterHyperspace`). nil = clear to jump.
    public func hyperspaceRefusal(noJumpRadius: Double) -> HyperspaceRefusal? {
        guard player.isAlive, !playerInEscapePod, !player.disabled else { return .silent }
        if let lock = player.velocityMatchTargetID, lock != player.entityID { return .silent }
        return isClearOfNoJumpZone(radius: noJumpRadius) ? nil : .tooCloseToCentre
    }
}
