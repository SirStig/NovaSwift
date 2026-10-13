import Foundation
import NovaSwiftKit

extension World {
    /// Place the player where a gate transport puts them (`NovaTravel_CompleteRestrictedTravel`,
    /// OS-06): at the destination gate's own position, facing its emergence angle
    /// (else a random whole degree), at half the effective top speed. Returns the
    /// heading used.
    @discardableResult
    public func placePlayerEmergingFromGate(_ gate: StellarBody) -> Double {
        let ang = gate.gateEmergeAngle ?? Double(rng.range(360)) * .pi / 180
        player.position = gate.position
        player.angle = ang
        player.velocity = Vec2.heading(ang) * (effectiveMaxSpeed(of: player) * 0.5)
        player.entryOverspeed = 0
        player.entryOverspeedDecayPerSec = 0
        return ang
    }
}
