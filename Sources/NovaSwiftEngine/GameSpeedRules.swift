import Foundation

/// The original's Caps Lock "2x mode" (`DAT_00596d34`), and the same rules
/// generalised to any simulation-speed multiplier N (the Settings game-speed
/// options, with or without Caps Lock).
///
/// In the original, Caps Lock makes `Frame_SpaceflightLoop` (0x00417600) run the
/// world tick twice per frame (`Frame_TickSystems(0)` after the normal one).
/// Several rules that run once per *frame* or off the wall clock (`TickCount`)
/// then compensate for the doubled ticks; each one is generalised here by
/// replacing "2" with N. Work that the port already runs once per sim tick
/// (beam hit resolution, the star-field scroll) needs nothing: the extra ticks
/// scale it on their own.
public enum GameSpeedRules {
    /// Bounds on the combined multiplier (Settings 8x times Caps Lock 2x at most).
    public static let minimumMultiplier = 0.25
    public static let maximumMultiplier = 16.0

    /// The simulation-speed multiplier N: the Settings option times 2 while the
    /// x2 flag is on. In a co-op session the lobby's shared multiplier wins and
    /// Caps Lock is ignored, so every device runs one clock.
    public static func effectiveMultiplier(setting: Double, x2Flag: Bool, coopOverride: Double? = nil) -> Double {
        let raw = coopOverride ?? (setting * (x2Flag ? 2 : 1))
        return min(max(raw, minimumMultiplier), maximumMultiplier)
    }

    /// The x2 flag, re-evaluated every frame (`Frame_SpaceflightLoop`
    /// 0x00417600, all.c ~11248):
    /// - while the "2x" jump cue (snd 129) is sounding the flag stays on;
    /// - otherwise it follows the Caps Lock toggle state,
    /// - except that with Caps Lock on, a jump that began at 1x (snd 128 still
    ///   sounding) with the nose within 10 degrees of the jump heading
    ///   (`|delta| < 11`) holds the flag off, so toggling Caps Lock mid-jump
    ///   never switches a jump that started at normal speed.
    public static func x2Flag(capsLockOn: Bool, x2CueSounding: Bool, normalCueSounding: Bool,
                              headingWithinTenOfJump: Bool) -> Bool {
        if x2CueSounding { return true }
        guard capsLockOn else { return false }
        if headingWithinTenOfJump && normalCueSounding { return false }
        return true
    }

    /// The constant term's factor in the player's jump progress,
    /// `progress - factor * 35 / mult` (0x0044c8d0 ~340; 0x0044f3d0 ~726).
    /// The original uses 1.0 at normal speed and 1.5 (`_DAT_005755d0`) in 2x
    /// mode; the straight line through those two points is (1 + N) / 2.
    public static func jumpProgressOffsetFactor(multiplier n: Double) -> Double { (1 + n) / 2 }

    /// The wall-clock term's scale in a departing ship's jump progress
    /// (`Ship_HandleShip` 0x00433050 ~558 / ~585): 1.0 at normal speed, 0.667
    /// (the double 0x3fe55810_624dd2f2) for a ship following the player and 0.5
    /// for any other ship in 2x mode. Both keep the ship's travel per wall
    /// second equal to normal speed while the world ticks N times as often:
    /// 1 / N for an NPC, and 1 / jumpProgressOffsetFactor for the player's
    /// follower (1/1.5 at 2x) so it tracks the player's own tunnel.
    public static func departureProgressScale(multiplier n: Double, followsPlayer: Bool) -> Double {
        followsPlayer ? 1 / jumpProgressOffsetFactor(multiplier: n) : 1 / max(n, minimumMultiplier)
    }

    /// Sim ticks one display frame may run before the backlog is dropped. The
    /// frame delta is already clamped to 1/20 s, so a frame can bank at most
    /// 1.5 N ticks; never go below the normal 5.
    public static func catchupTickCap(multiplier n: Double, base: Int = 5) -> Int {
        max(base, Int((n * 1.5).rounded(.up)) + 1)
    }
}
