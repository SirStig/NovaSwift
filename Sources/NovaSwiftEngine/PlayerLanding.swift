import Foundation

/// The player's landing approach as the original checks it on the second Land
/// press (0x00457580; FL-12, UI-08), and what the in-flight land hint should
/// say about it.
public enum PlayerLanding {
    /// `|vx|, |vy| ≤ 0.75` px/tick, in px/s (22.5).
    public static let perAxisSpeedLimit = OriginalClock.perSecond(0.75)
    /// The ±250 px per-axis arm that grants clearance (0x00459950).
    public static let clearanceRange = 250.0

    /// The square envelope's half-size: `round(spriteWidth × 1.75)`.
    public static func reach(radius: Double) -> Double { (radius * 2 * 1.75).rounded() }

    public static func inEnvelope(offset d: Vec2, radius: Double) -> Bool {
        let r = reach(radius: radius)
        return abs(d.x) < r && abs(d.y) < r
    }

    public static func isSlowEnough(_ velocity: Vec2) -> Bool {
        abs(velocity.x) <= perAxisSpeedLimit && abs(velocity.y) <= perAxisSpeedLimit
    }

    public static func inClearanceRange(offset d: Vec2) -> Bool {
        abs(d.x) < clearanceRange && abs(d.y) < clearanceRange
    }

    /// One of the current system's nav slots as the Land key's nearest search sees it.
    public struct TravelSlot: Sendable {
        public let id: Int
        public let position: Vec2
        /// `spöb.Flags` 0x0001 (can land).
        public let canLand: Bool
        /// A hypergate or wormhole (`Flags2` 0x3000).
        public let isGate: Bool
        /// The stellar's available byte (+0x44): false for a destroyed stellar, or an intact
        /// "land only when destroyed" one.
        public let available: Bool
        public init(id: Int, position: Vec2, canLand: Bool, isGate: Bool, available: Bool) {
            self.id = id; self.position = position; self.canLand = canLand
            self.isGate = isGate; self.available = available
        }
    }

    /// A hypergate or wormhole counts for the nearest search only inside this squared distance
    /// (500 px; the double at 0x00575750 reads 250000.0).
    public static let gateSearchRadiusSquared = 250_000.0

    /// The Land key's nearest stellar when nothing is selected
    /// (`Stellar_FindNearestAvailableTravelStellar` 0x00462db0; UI-06): only the system's first 16
    /// nav slots are searched; a slot counts when it is available and has Flags 0x0001; a gate
    /// counts only inside `gateSearchRadiusSquared`; the nearest wins, the first slot on a tie.
    /// Nil when nothing qualifies.
    public static func nearestTravelStellar(from position: Vec2, slots: [TravelSlot]) -> Int? {
        var best: Int?
        var bestD2 = -1.0
        for slot in slots.prefix(16) where slot.available && slot.canLand {
            let dx = position.x - slot.position.x, dy = position.y - slot.position.y
            let d2 = dx * dx + dy * dy
            if slot.isGate, !(d2 < gateSearchRadiusSquared) { continue }
            if bestD2 < 0 || d2 < bestD2 { best = slot.id; bestD2 = d2 }
        }
        return best
    }

    /// What the land hint says while a landable body is in reach. Landing is
    /// two presses: before clearance the hint asks for the request; "slow
    /// down" shows only when speed is what actually stops the landing.
    public enum Prompt: Equatable, Sendable { case land, request, slowDown, none }

    public static func prompt(canLandNow: Bool, slowEnough: Bool, needsRequest: Bool, cloaked: Bool) -> Prompt {
        if canLandNow { return .land }
        if cloaked { return .none }
        if !slowEnough { return .slowDown }
        return needsRequest ? .request : .land
    }
}
