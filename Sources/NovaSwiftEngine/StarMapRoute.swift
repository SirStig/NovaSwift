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
    public private(set) var armed = false {
        didSet { if armed { hyperspaceMode = true } }
    }
    /// Travel mode 3 (hyperspace) with or without an armed link slot. H, a
    /// map click and arming a hop select it; a stellar selection or N clears
    /// it. With the mode on and nothing armed the nav panel reads
    /// "Hyperspace" / "No Destination" (#345 / #344), not "Nav System Off".
    public private(set) var hyperspaceMode = false

    public init(hops: [Int] = [], armed: Bool = false) {
        self.hops = Array(hops.prefix(Self.maxHops))
        self.armed = armed && !self.hops.isEmpty
        self.hyperspaceMode = self.armed
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

    /// Re-arm the route's first hop when it is one link from `current` — the
    /// sync `NovaUi_SyncTravelSelectionFromStarmapRoute` 0x004a8080 run by H,
    /// by closing the map and after a gate arrival. When the head is not
    /// linked (or there is no route) nothing changes: a disarmed jump stays
    /// disarmed. Returns whether a jump is armed afterwards.
    @discardableResult
    public mutating func sync(current: Int, linked: (Int, Int) -> Bool) -> Bool {
        if let head = hops.first, head != current, linked(current, head) { armed = true }
        return armed
    }

    /// Re-arm the route's first hop without a link check (the old H).
    @discardableResult
    public mutating func rearm() -> Bool {
        armed = !hops.isEmpty
        return armed
    }

    public mutating func disarm() {
        armed = false
        hyperspaceMode = false
    }

    /// H (0x0044b120): travel mode 3 with the slot cleared, then the sync —
    /// the route's head re-arms when it is linked, otherwise the panel shows
    /// "Hyperspace" / "No Destination".
    @discardableResult
    public mutating func selectHyperspace(current: Int, linked: (Int, Int) -> Bool) -> Bool {
        armed = false
        hyperspaceMode = true
        return sync(current: current, linked: linked)
    }

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

    /// Hyperspace arrival in `system` after crossing `count` hops
    /// (`System_NormalizePlannedRouteToCurrentSystem` 0x004a7fc0, then the
    /// 0x004a8080 sync): the crossed hops are popped when they match the
    /// route. A route that no longer starts here is kept as it is (the
    /// original only clears an already-empty route). The next hop is armed
    /// when it is linked to `system`.
    public mutating func arrive(at system: Int, crossing count: Int = 1,
                                linked: (Int, Int) -> Bool = { _, _ in true }) {
        if count > 0, hops.count >= count, hops[count - 1] == system {
            hops.removeFirst(count)
        }
        armed = false
        hyperspaceMode = false      // 0x0044f3d0 resets the travel mode
        sync(current: system, linked: linked)
    }

    /// A gate arrival (0x00457580): the travel slot is cleared and the route
    /// synced, but the route itself is not normalised — an off-route arrival
    /// keeps the old route and re-arms its head only if it is linked here.
    public mutating func arriveViaGate(at system: Int, linked: (Int, Int) -> Bool) {
        armed = false
        sync(current: system, linked: linked)
    }

    /// Revalidate the hops against the story's visibility — the first loop
    /// of `System_UpdateSystemAndStellarDisplayState` 0x00432470: each hop
    /// whose system has gone hidden is replaced by its visible twin
    /// (`resolveVisible`, 0x0046b920); a hop with no visible twin cuts the
    /// route there. Returns whether anything changed.
    @discardableResult
    public mutating func revalidate(isVisible: (Int) -> Bool, resolveVisible: (Int) -> Int?) -> Bool {
        var changed = false
        for i in hops.indices where !isVisible(hops[i]) {
            if let twin = resolveVisible(hops[i]) {
                hops[i] = twin
            } else {
                hops.removeSubrange(i...)
                changed = true
                break
            }
            changed = true
        }
        if hops.isEmpty { armed = false }
        return changed
    }
}
