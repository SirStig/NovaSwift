import Foundation

/// The original game's two simulation clocks, and the conversions between them
/// and NovaSwift's fixed 30 Hz step.
///
/// `Frame_MeasureFrameTiming` (0x00432ea0) busy-waits each spaceflight loop
/// iteration to at least 21 ms, so on any machine that keeps up the loop runs
/// at ≤ 47.62 calls/s. It publishes a normalized tick scale of
/// `elapsed_ms × 0.03` (averaged `avg = (avg × 3 + sample) / 4`), which settles
/// at 0.63 at the 21 ms floor: one normalized tick is 1/30 s. Most per-frame
/// rules multiply by that scale and so run at 30 ticks/s whatever the frame
/// rate — NovaSwift's fixed step reproduces them as-is. A few rules run once
/// per *raw call* with no scale (the afterburner push and cap decay, the
/// disabled 0.995 damp, the inertialess 0.985 damp, beam life, rocket blend,
/// jamming retargets, particle life, collision tests); at 30 Hz they must run
/// 1/0.63 ≈ 1.587 times per step to match the original at full speed.
public enum OriginalClock {
    /// Normalized ticks per second (the unit of every px/tick figure).
    public static let ticksPerSecond: Double = 30
    /// The raw loop's busy-wait floor.
    public static let rawCallSeconds: Double = 0.021
    /// Raw calls per second at the floor (≈ 47.62).
    public static let rawCallsPerSecond: Double = 1 / rawCallSeconds
    /// The steady-state normalized scale of one raw call (21 ms × 0.03).
    public static let rawCallTickScale: Double = 0.63

    /// px/tick → px/s.
    @inlinable public static func perSecond(_ perTick: Double) -> Double { perTick * ticksPerSecond }
    /// px/tick² → px/s².
    @inlinable public static func perSecondSquared(_ perTick2: Double) -> Double {
        perTick2 * ticksPerSecond * ticksPerSecond
    }
    /// px/s → px/tick.
    @inlinable public static func perTick(_ perSecond: Double) -> Double { perSecond / ticksPerSecond }
    /// px/s² → px/tick².
    @inlinable public static func perTickSquared(_ perSecond2: Double) -> Double {
        perSecond2 / (ticksPerSecond * ticksPerSecond)
    }
}

/// Counts the original's raw calls that fall inside each fixed simulation step:
/// a 21 ms accumulator over game time. A per-call rule runs `advance(dt)` times
/// per step — 1 or 2 at 30 Hz, 47 or 48 over a second — so its effect over any
/// stretch of play matches the original running at its 21 ms floor.
///
/// Whether to reproduce the original's hitch behaviour (its averaged scale
/// stretches a slow frame's tick instead of dropping time) is open question
/// Q-FL-13; this assumes a machine that holds the floor.
public struct RawCallCadence: Sendable {
    private var accumulator: Double = 0

    public init() {}

    /// Game time `dt` (seconds) has passed; returns how many raw calls it held.
    public mutating func advance(_ dt: Double) -> Int {
        guard dt > 0 else { return 0 }
        accumulator += dt / OriginalClock.rawCallSeconds
        let calls = Int(accumulator.rounded(.down))
        accumulator -= Double(calls)
        return calls
    }
}
