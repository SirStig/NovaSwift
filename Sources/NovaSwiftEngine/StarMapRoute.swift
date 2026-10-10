import Foundation

/// The original star map's route rules (UI-05; the map loop 0x004a4353, the
/// route normalisers 0x004a7e80 / 0x004a7fc0 and the jump-arm sync 0x004a8080).
/// There is no pathfinding:
///
/// - a plain click on a system **directly linked** to the current one arms a
///   jump to it; a plain click anywhere else only moves the map selection and
///   disarms the jump;
/// - Shift+click builds a route by hand, one linked hop at a time from the
///   route's tail, up to 31 hops past the current system (a `short[0x20]`
///   including the current system). Shift+click on a plotted hop truncates the
///   route after it; on the current system it clears the route;
/// - a jump goes to the armed system; on arrival the route's head is popped and
///   the next hop re-armed.
///
/// The port's shortest-path plotting is the `autoRoutePlotting` enhancement;
/// the app keeps that path itself.
public struct StarMapRoute: Equatable, Sendable {
    /// The original route array holds the current system plus 31 hops.
    public static let maxHops = 31

    /// The plotted hops, in order, excluding the current system.
    public private(set) var hops: [Int] = []
    /// Whether a hyperspace jump is armed (travel mode 3). The armed system is
    /// always the route's head.
    public private(set) var armed = false

    public init(hops: [Int] = [], armed: Bool = false) {
        self.hops = Array(hops.prefix(Self.maxHops))
        self.armed = armed && !self.hops.isEmpty
    }

    /// The system a jump would go to now, if any.
    public var armedSystem: Int? { armed ? hops.first : nil }

    /// A plain click on `system`. `linked(a, b)` says whether `b` is one
    /// hyperspace link from `a`. Returns true when the click armed a jump.
    @discardableResult
    public mutating func click(_ system: Int, current: Int, linked: (Int, Int) -> Bool) -> Bool {
        guard system != current, linked(current, system) else {
            armed = false
            return false
        }
        // Arming the route's own first hop keeps the plotted route; any other
        // linked system replaces it.
        if hops.first != system { hops = [system] }
        armed = true
        return true
    }

    /// A Shift+click on `system`: extend, truncate or clear the route. Returns
    /// false when the click changed nothing (not linked to the tail, or the
    /// route is full).
    @discardableResult
    public mutating func shiftClick(_ system: Int, current: Int, linked: (Int, Int) -> Bool) -> Bool {
        if system == current {
            let changed = !hops.isEmpty
            hops = []
            armed = false
            return changed
        }
        if let at = hops.firstIndex(of: system) {
            // The clicked hop and everything after it are dropped, then the hop
            // re-appends (it is linked to the new tail): a truncation after it.
            hops.removeSubrange((at + 1)...)
            armed = true
            return true
        }
        guard hops.count < Self.maxHops else { return false }
        let tail = hops.last ?? current
        guard linked(tail, system) else { return false }
        hops.append(system)
        armed = true
        return true
    }

    /// Re-arm the route's first hop (the H key, and the sync after closing the
    /// map). Returns whether a jump is now armed.
    @discardableResult
    public mutating func rearm() -> Bool {
        armed = !hops.isEmpty
        return armed
    }

    public mutating func disarm() { armed = false }

    public mutating func clear() {
        hops = []
        armed = false
    }

    /// Replace the hops wholesale (the shortest-path enhancement, a mission's
    /// plotted course) and arm the first.
    public mutating func set(_ newHops: [Int], cap: Bool = true) {
        hops = cap ? Array(newHops.prefix(Self.maxHops)) : newHops
        armed = !hops.isEmpty
    }

    /// Arrival in `system` after crossing `count` hops: the crossed hops are
    /// popped when they match the route, otherwise the route no longer starts
    /// here and is dropped. The next hop is re-armed.
    public mutating func arrive(at system: Int, crossing count: Int = 1) {
        if count > 0, hops.count >= count, hops[count - 1] == system {
            hops.removeFirst(count)
        } else {
            hops = []
        }
        armed = !hops.isEmpty
    }
}
