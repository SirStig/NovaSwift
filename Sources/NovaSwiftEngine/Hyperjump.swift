import Foundation
import NovaSwiftKit

/// The player's hyperspace jump as the original flies it (`Ship_HandlePlayerShipCore`
/// 0x0044aa70 and its fragments; FL-04). While a jump is engaged `World.step` hands
/// the player's motion to `tick` instead of the normal flight model:
///
/// 1. **Brake** (0x0044f127 / 0x0044f275). Turn to face the reverse of the
///    velocity, damp it × 0.99203847 per tick, and once within
///    `max(turn + 1, 20)°` of that heading thrust back along it. Ends when both
///    `|trunc(v)| < 2` px/tick. An inertialess hull bleeds its scalar speed by
///    its thrust instead. A fast-jump hull (class Flags2 0x0020 or ModType 37)
///    skips the brake.
/// 2. **Spin-up** (0x0044c528 / 0x0044c704). The velocity damps × 0.98006866 per
///    tick (not for a fast-jump hull) while the ship turns onto the map bearing.
///    The jump fires once the jump timer (seeded 2) reaches 30 ticks *and* the
///    "Warp up" cue (snd 128) has played out; the cue plays at the hull's
///    duration multiplier, so it lasts `cue / multiplier` 60 Hz ticks.
/// 3. **Tunnel** (0x0044ccaf). With `progress = elapsed60 × mult / (cue × 0.01)
///    − 35 / mult` positive and the nose within `max(turn, 30)°` of the bearing,
///    the *position* steps `min(progress, 50)` px per tick along the heading.
/// 4. **Collapse** (0x0044b037 / 0x0044b120). A disabled player's jump collapses;
///    once the tunnel had begun the ship leaves at `min(progress, max speed)`.
///
/// Velocities here are the engine's px/s; the original's px/tick thresholds are
/// converted through `OriginalClock`.
public struct PlayerHyperjump: Sendable {
    public enum Phase: Sendable, Equatable { case brake, spinUp, fired, collapsed }

    public private(set) var phase: Phase = .brake
    /// The jump bearing in radians (engine convention: 0 = up, clockwise),
    /// stored as the original's whole-degree desired heading.
    public let bearing: Double
    /// Class Flags2 0x0020 or an owned ModType-37 outfit
    /// (`Ship_CheckSpecialLoadoutCapability` 0x0046d080).
    public let fastJump: Bool
    /// Length of the "Warp up" cue in 60 Hz ticks (`numFrames × 60 / rate`,
    /// 350 when the sound is missing).
    public let cueTicks60: Double
    /// The hull's jump-duration multiplier (`durationMultiplier(hullFlags:)`).
    public let multiplier: Double

    /// The jump timer, in 30 Hz ticks since spin-up began (seeded at 2).
    public private(set) var timer: Double = 0
    /// The spin-up's 60 Hz clock.
    public private(set) var elapsed60: Double = 0
    /// Latched once progress passes 55: the Mac build starts its 1.5 s white
    /// fade-in here (`(progress − 55) × 5 > 0`). Presentation only.
    public private(set) var fadeTriggered = false

    public static let defaultCueTicks60: Double = 350
    static let turnaroundDamp = 0.99203847          // 0x005755f0
    static let spinUpDamp = 0.98006866               // 0x005755f8
    static let spinUpSeed = 2.0                      // jump timer seed at spin-up
    static let minSpinUpTicks = 30.0                 // 0x005755a8
    static let progressOffset = 35.0                 // 0x00575568
    static let tunnelStepCap = 50.0                  // 0x005755d8, px/tick
    static let stoppedVelocity = 2.0                 // px/tick, per axis

    public init(bearing: Double, fastJump: Bool,
                cueTicks60: Double = PlayerHyperjump.defaultCueTicks60, multiplier: Double = 1.3) {
        let deg = (Int((bearing * 180 / .pi).rounded()) % 360 + 360) % 360
        self.bearing = Double(deg) * .pi / 180
        self.fastJump = fastJump
        self.cueTicks60 = max(1, cueTicks60)
        self.multiplier = max(0.5, multiplier)
    }

    /// shïp Flags 0x0001 / 0x0002 / 0x0004 scale the jump (0.7 / 1.3 / 1.6, else
    /// 1.0), times 1.3 and floored at 0.5 (loader 0x004bd3c0): the cue plays this
    /// much faster, so a plain hull's spin-up lasts 364 / 1.3 ticks ≈ 4.67 s.
    public static func durationMultiplier(hullFlags: Int) -> Double {
        let scale = hullFlags & 0x1 != 0 ? 0.7 : hullFlags & 0x2 != 0 ? 1.3 : hullFlags & 0x4 != 0 ? 1.6 : 1.0
        return max(scale * 1.3, 0.5)
    }

    /// The "Warp up" cue's length in 60 Hz ticks, truncated as the preload does.
    public static func cueTicks60(of sound: NovaSound?) -> Double {
        guard let sound, sound.sampleRate > 0, sound.frameCount > 0 else { return defaultCueTicks60 }
        return Double(max(1, min(0x7fff, Int(Double(sound.frameCount) * 60 / sound.sampleRate))))
    }

    /// The tunnel ramp's progress.
    public var progress: Double {
        elapsed60 * multiplier / (cueTicks60 * 0.01) - Self.progressOffset / multiplier
    }

    /// Whether the cue, playing at `multiplier`, has finished.
    var cueDone: Bool { elapsed60 >= cueTicks60 / multiplier }

    /// Fly one step of the engaged jump. The caller skips the normal flight
    /// model for the player while this runs.
    mutating func tick(_ player: Ship, dt: Double) {
        let ticks = dt * OriginalClock.ticksPerSecond
        let turnDeg = Double(max(1, player.stats.playerTurnDegPerTick))
        let thrust = player.effectiveAcceleration

        if player.disabled, phase == .brake || phase == .spinUp {
            // Ship disabled - hyperspace field collapsed (STR# 2002 #35).
            if phase == .spinUp, progress > 0 {
                let speed = min(OriginalClock.perSecond(progress), player.effectiveMaxSpeed)
                player.velocity = Vec2.heading(player.angle) * speed
                player.throttleSpeed = speed
            }
            phase = .collapsed
            return
        }

        switch phase {
        case .brake:
            let vx = OriginalClock.perTick(player.velocity.x).rounded(.towardZero)
            let vy = OriginalClock.perTick(player.velocity.y).rounded(.towardZero)
            let stopped = fastJump || (abs(vx) < Self.stoppedVelocity && abs(vy) < Self.stoppedVelocity)
            guard !stopped else {
                phase = .spinUp
                timer = Self.spinUpSeed
                elapsed60 = 0
                return
            }
            if player.inertialess {
                player.throttleSpeed = max(0, player.throttleSpeed - thrust * dt)
                steerInertialess(player, thrust: thrust, dt: dt)
            } else {
                let reverse = player.velocity.angle + .pi
                turn(player, toward: reverse, stepDeg: turnDeg * ticks)
                let off = abs(angleDelta(from: player.angle, to: reverse)) * 180 / .pi
                if off < max(turnDeg + 1, 20) {
                    player.velocity += Vec2.heading(player.angle) * (thrust * dt)
                }
                player.velocity = player.velocity * pow(Self.turnaroundDamp, ticks)
            }
            player.position += player.velocity * dt

        case .spinUp:
            if !fastJump {
                player.velocity = player.velocity * pow(Self.spinUpDamp, ticks)
            }
            turn(player, toward: bearing, stepDeg: turnDeg * ticks)
            if player.inertialess { steerInertialess(player, thrust: thrust, dt: dt) }
            player.position += player.velocity * dt

            timer += ticks
            elapsed60 += dt * 60
            if progress > 55 { fadeTriggered = true }
            if timer >= Self.minSpinUpTicks, cueDone {
                phase = .fired
                return
            }
            // The tunnel: a direct position step, not thrust.
            let off = abs(angleDelta(from: player.angle, to: bearing)) * 180 / .pi
            if off <= max(turnDeg, 30), progress > 0 {
                player.position += Vec2.heading(player.angle) * (min(progress, Self.tunnelStepCap) * ticks)
            }

        case .fired, .collapsed:
            break
        }
    }

    /// The player's auto-turn: whole-degree steps that stop within one step of
    /// the target (FL-10).
    private func turn(_ player: Ship, toward target: Double, stepDeg: Double) {
        let step = stepDeg * .pi / 180
        let delta = angleDelta(from: player.angle, to: target)
        if abs(delta) > step { player.angle += delta > 0 ? step : -step }
    }

    /// `Ship_SteerVelocityTowardShipHeading` (0x0043b020): at most 4 × thrust per
    /// tick on each axis toward heading × speed.
    private func steerInertialess(_ player: Ship, thrust: Double, dt: Double) {
        let target = Vec2.heading(player.angle) * player.throttleSpeed
        let maxDv = 4 * thrust * dt
        player.velocity = Vec2(player.velocity.x + max(-maxDv, min(maxDv, target.x - player.velocity.x)),
                               player.velocity.y + max(-maxDv, min(maxDv, target.y - player.velocity.y)))
    }
}

extension World {
    /// FL-13: the player emerges 1350 px from the system origin on the near side
    /// (along the jump bearing + 180°), with velocity zeroed and then set to its
    /// effective top speed — non-strict ×1.5 and ModType 8 included — along its
    /// whole-degree heading. An inertialess hull takes that as its scalar speed
    /// instead. Shields and armor are not touched (decomp `FireJump`; OQ A4).
    public func placePlayerAtHyperspaceArrival(bearing: Double) {
        let p = player
        p.position = Vec2.heading(bearing) * -1350
        p.velocity = Vec2()
        let speed = effectiveMaxSpeed(of: p)
        if p.inertialess {
            p.throttleSpeed = speed
        } else {
            p.velocity = Vec2.heading(p.wholeDegreeHeading) * speed
        }
        p.entryOverspeed = 0
        p.entryOverspeedDecayPerSec = 0
    }
}

extension World {
    /// At the jump's fire, the player's deployed bay fighters come along if they
    /// could jump themselves (fuel for one jump; `Stellar_CanShipInitiateJumpSequence`)
    /// and dock back into their bay; the rest are abandoned and lost (0x0044f8d6).
    /// Returns how many were abandoned, for the arrival line.
    /// The most travel days any ship jumping with the player costs (FL-05;
    /// 0x0044f8d6): every attached, non-disabled ship — escorts, and bay fighters
    /// that can make the jump — by its hull alone. 0 with nobody attached.
    public func attachedShipsTravelDays(galaxy: Galaxy) -> Int {
        npcs.filter { s in
            s.isAlive && !s.disabled && s.brain?.leaderID == World.playerEntityID
                && (s.carrierID == nil || s.fuel >= ShipFuel.perJump)
        }
        .compactMap { $0.shipTypeID }
        .map { galaxy.hyperspaceTravelDays(hull: $0, ownedOutfits: nil) }
        .max() ?? 0
    }

    @discardableResult
    public func returnJumpingFighters() -> Int {
        var abandoned = 0
        for bay in player.fighterBays {
            for id in bay.deployed {
                guard let f = ship(id: id), f.isAlive, !f.disabled else { continue }
                if f.fuel >= ShipFuel.perJump {
                    bay.docked = min(bay.spec.capacity, bay.docked + 1)
                } else {
                    abandoned += 1
                }
            }
            bay.deployed.removeAll()
        }
        return abandoned
    }
}

extension Galaxy {
    /// `Stellar_ComputeHyperspaceTravelDays` (0x00465550; FL-05): 1 day for a hull
    /// of mass ≤ 99, 2 for 100–199, 3 from 200, plus — for the player only —
    /// `count × ModVal` of every owned ModType-22 outfit. Each term goes through
    /// an unsigned 16-bit cast and the caller reads the sum back as a signed
    /// short, so a negative ModVal subtracts; the result is at least 1.
    /// `ownedOutfits` is nil for an NPC or escort.
    public func hyperspaceTravelDays(hull shipID: Int, ownedOutfits: [Int: Int]?) -> Int {
        let mass = game.ship(shipID)?.mass ?? 0
        var days = 1
        if mass > 99 { days = 2 }
        if mass > 199 { days += 1 }
        for (oid, count) in ownedOutfits ?? [:] where count > 0 {
            guard let o = game.outfit(oid) else { continue }
            for (type, value) in o.modifiers where type == .hyperspaceSpeed {
                days += Int(UInt16(truncatingIfNeeded: count * value))
            }
        }
        let short = Int(Int16(truncatingIfNeeded: days))
        return short < 1 ? 1 : short
    }

    /// The "Warp up" cue (snd 128) in 60 Hz ticks: the spin-up length.
    public var hyperspaceCueTicks60: Double { PlayerHyperjump.cueTicks60(of: game.sound(128)) }

    /// The hull's jump-duration multiplier (`PlayerHyperjump.durationMultiplier`).
    public func jumpDurationMultiplier(hull shipID: Int) -> Double {
        PlayerHyperjump.durationMultiplier(hullFlags: Int(game.ship(shipID)?.flags ?? 0))
    }
}
