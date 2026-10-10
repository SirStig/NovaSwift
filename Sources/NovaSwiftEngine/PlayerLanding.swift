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
