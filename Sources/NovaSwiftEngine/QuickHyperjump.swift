import Foundation

/// The `quickHyperjump` enhancement's jump: turn to the outbound bearing, tear away with the
/// speed cap lifted, white out, then commit. It replaces the original's engine-flown jump
/// (`PlayerHyperjump`) only when the enhancement is on; the original remains the default.
///
/// Both frontends drive it the same way. Each display frame (or sim tick) they call `step`, fly
/// the returned `intent` through the normal flight model, draw the `flash` and `streak` values, play
/// the charge loop while `chargeLoopSounding`, and run their commit (spend fuel, swap the system)
/// on the frame `commit` is true. Logic moved out of the Apple `GameScene.stepJump` unchanged:
/// the constants below are the app's.
///
/// A gate transport reuses the flash alone (`init(flashOnly:)`): no maneuver and no charge sound.
public struct QuickHyperjump: Sendable {
    public enum Phase: Sendable { case align, accelerate, flash }

    /// Seconds the align may take before the safety cap forces the burst.
    public static let alignCapSeconds = 3.0
    /// Accelerate length, seconds (÷ `speed`): the quick jump, and the fast-jump (instant) variant.
    public static let accelerateSeconds = 0.45
    public static let instantAccelerateSeconds = 0.18
    /// The white-out ramp, seconds.
    public static let flashRampSeconds = 0.14
    /// The over-speed ceiling the burst lifts the ship to, in multiples of its top speed.
    public static let overspeedFactor = 4.0
    /// How long the destination fades back in after the commit, seconds.
    public static let arriveFadeSeconds = 0.35

    public private(set) var phase: Phase
    /// Seconds in the current phase.
    public private(set) var clock = 0.0
    public let outboundHeading: Double
    /// Fast jump (class Flags2 0x0020 / ModType 37): skip the align.
    public let instant: Bool
    /// Jump-animation speed-up from ModType 22 outfits (1 = stock).
    public let speed: Double
    public private(set) var committed = false
    /// snd 128 loops from the start of the maneuver until the commit (`SoundCues.hyperspaceChargeID`).
    public private(set) var chargeLoopSounding: Bool

    /// The full maneuver. A fast jump starts at the burst.
    public init(outboundHeading: Double, instant: Bool, speed: Double = 1) {
        self.outboundHeading = outboundHeading
        self.instant = instant
        self.speed = max(1, speed)
        phase = instant ? .accelerate : .align
        chargeLoopSounding = true
    }

    /// The gate transport's flash: straight to the white-out, silent.
    public init(flashOnly outboundHeading: Double) {
        self.outboundHeading = outboundHeading
        instant = true
        speed = 1
        phase = .flash
        chargeLoopSounding = false
    }

    /// What one step asks the frontend to do.
    public struct Frame {
        /// Controls to fly this step through the normal flight model.
        public var intent = ControlIntent()
        /// White overlay, 0...1 before the Reduce Flashing cap; nil = leave the overlay alone.
        public var flash: Double?
        /// Streak overlay opacity (0...1) and stretch; nil = leave it alone.
        public var streakIntensity: Double?
        public var streakStretch = 1.0
        /// True on the one step the jump fires: spend the fuel, swap the system, start the arrival fade.
        public var commit = false
        /// True on the same step: cut the charge loop.
        public var stopChargeLoop = false
    }

    /// Advance by `dt` seconds. Lifts the player's speed cap during the burst, so pass the live ship.
    public mutating func step(dt: Double, player p: Ship) -> Frame {
        clock += dt
        var frame = Frame()
        frame.intent.desiredHeading = outboundHeading
        switch phase {
        case .align:
            // Turn to the destination and nothing else; the auto-turn stops within one whole-degree step.
            let aimErr = abs(angleDelta(from: p.angle, to: outboundHeading))
            let settled = max(0.1, Double(p.stats.playerTurnDegPerTick) * .pi / 180 + 1e-6)
            if aimErr < settled || clock > Self.alignCapSeconds { enter(.accelerate) }

        case .accelerate:
            if abs(angleDelta(from: p.angle, to: outboundHeading)) < .pi / 2 { frame.intent.thrust = true }
            p.entryOverspeed = max(p.entryOverspeed, p.stats.maxSpeed * Self.overspeedFactor)
            p.entryOverspeedDecayPerSec = 0        // hold the boost through the launch
            frame.streakStretch = min(1 + clock * 12, 9)
            frame.streakIntensity = min(1, clock / 0.35)
            let length = instant ? Self.instantAccelerateSeconds : Self.accelerateSeconds
            if clock > length / speed { enter(.flash) }

        case .flash:
            let t = min(1, clock / Self.flashRampSeconds)
            frame.flash = t
            frame.streakIntensity = 1
            frame.streakStretch = 9
            if !committed, t >= 1 {
                committed = true
                chargeLoopSounding = false
                frame.commit = true
                frame.stopChargeLoop = true
            }
        }
        return frame
    }

    private mutating func enter(_ next: Phase) {
        phase = next
        clock = 0
    }
}
