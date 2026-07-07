import Foundation

/// Abstract control input. Touch, keyboard, and game controllers all translate
/// into this; the simulation only ever reads `ControlIntent`, never raw input.
/// See docs/MOBILE_AND_PLUGINS.md §1.
public struct ControlIntent: Equatable {
    public var turnLeft = false
    public var turnRight = false
    public var thrust = false
    public var reverse = false      // reverse thrust / brake-to-stop assist
    public var firePrimary = false
    public var fireSecondary = false
    /// Absolute heading (radians, compass) to rotate toward — used by mouse and
    /// analog-stick aiming. When set, it drives turning unless a discrete
    /// turnLeft/turnRight is also active (discrete input wins).
    public var desiredHeading: Double?
    public init() {}

    /// OR-merge several input sources into one intent (keyboard + touch +
    /// controller + mouse). Discrete turns win; otherwise the first supplied
    /// `desiredHeading` is used.
    public static func combined(_ sources: ControlIntent...) -> ControlIntent {
        var r = ControlIntent()
        for s in sources {
            r.turnLeft = r.turnLeft || s.turnLeft
            r.turnRight = r.turnRight || s.turnRight
            r.thrust = r.thrust || s.thrust
            r.reverse = r.reverse || s.reverse
            r.firePrimary = r.firePrimary || s.firePrimary
            r.fireSecondary = r.fireSecondary || s.fireSecondary
            if r.desiredHeading == nil { r.desiredHeading = s.desiredHeading }
        }
        return r
    }
}

/// Tuning that maps EV Nova's integer stat units into simulation units. Kept in
/// one place so flight feel can be adjusted without touching data decoding.
public struct FlightTuning {
    public var speedScale: Double      // stat → max px/sec
    public var accelScale: Double      // stat → px/sec²
    public var turnScale: Double       // stat → deg/sec
    public var dragPerSecond: Double   // gentle space drag so ships settle (0 = pure Newtonian)

    public static let `default` = FlightTuning(speedScale: 3.2, accelScale: 3.2,
                                               turnScale: 3.0, dragPerSecond: 0.0)
}

/// Derived, simulation-ready flight parameters for a ship.
public struct ShipStats {
    public let maxSpeed: Double        // px/sec
    public let acceleration: Double    // px/sec²
    public let turnRate: Double        // rad/sec
    public let rotationFrames: Int     // sprite frames for a full 360°

    public init(maxSpeed: Double, acceleration: Double, turnRate: Double, rotationFrames: Int = 36) {
        self.maxSpeed = maxSpeed
        self.acceleration = acceleration
        self.turnRate = turnRate
        self.rotationFrames = rotationFrames
    }

    /// Build from decoded ship stat integers (speed / accel / turnRate).
    public init(speed: Int, acceleration: Int, turnRate: Int,
                rotationFrames: Int = 36, tuning: FlightTuning = .default) {
        self.maxSpeed = Double(speed) * tuning.speedScale
        self.acceleration = Double(acceleration) * tuning.accelScale
        self.turnRate = Double(turnRate) * tuning.turnScale * .pi / 180.0
        self.rotationFrames = rotationFrames
    }
}

/// A moving ship in world space. `angle` is a compass heading in radians
/// (0 = up/north, increasing clockwise), matching EV Nova sprite frame 0.
public final class Ship {
    public var position: Vec2
    public var velocity: Vec2
    public var angle: Double
    public let stats: ShipStats
    public let name: String

    public init(name: String, stats: ShipStats, position: Vec2 = Vec2(), angle: Double = 0) {
        self.name = name
        self.stats = stats
        self.position = position
        self.velocity = Vec2()
        self.angle = angle
    }

    /// The sprite frame index (0..<rotationFrames) for the current heading.
    public var spriteFrame: Int {
        let n = stats.rotationFrames
        guard n > 0 else { return 0 }
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return Int((a / twoPi * Double(n)).rounded()) % n
    }

    func step(_ dt: Double, intent: ControlIntent, tuning: FlightTuning) {
        let maxTurn = stats.turnRate * dt
        if intent.turnLeft || intent.turnRight {
            if intent.turnLeft { angle -= maxTurn }
            if intent.turnRight { angle += maxTurn }
        } else if let target = intent.desiredHeading {
            // Rotate toward the target heading, clamped to this frame's turn budget.
            let twoPi = 2 * Double.pi
            var delta = (target - angle).truncatingRemainder(dividingBy: twoPi)
            if delta > .pi { delta -= twoPi }
            if delta < -.pi { delta += twoPi }
            angle += max(-maxTurn, min(maxTurn, delta))
        }

        let heading = Vec2.heading(angle)
        if intent.thrust { velocity += heading * (stats.acceleration * dt) }
        if intent.reverse { velocity += heading * (-stats.acceleration * 0.5 * dt) }

        if tuning.dragPerSecond > 0 {
            let k = max(0, 1 - tuning.dragPerSecond * dt)
            velocity = velocity * k
        }
        // Clamp to max speed.
        let speed = velocity.length
        if speed > stats.maxSpeed, speed > 0 {
            velocity = velocity.normalized * stats.maxSpeed
        }
        position += velocity * dt
    }
}

/// The live game simulation. Owns the player ship (and, later, NPCs, projectiles,
/// stellar objects). Deterministic: `step(dt)` advances everything from the
/// current `intent`. Rendering reads state; it never mutates it.
public final class World {
    public var player: Ship
    public var intent = ControlIntent()
    public var tuning: FlightTuning

    public init(player: Ship, tuning: FlightTuning = .default) {
        self.player = player
        self.tuning = tuning
    }

    public func step(_ dt: Double) {
        player.step(dt, intent: intent, tuning: tuning)
    }
}
