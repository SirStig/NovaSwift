import NovaSwiftEngine
import NovaSwiftNet

/// Boundary mapping between the engine's `ControlIntent` and the wire `NetIntent`.
/// The two structs carry the same fields by design; keeping the conversion here
/// (not in either module) is what lets `NovaSwiftNet` stay engine-free and the
/// engine stay net-free. See `docs/MULTIPLAYER.md`.
extension NetIntent {
    /// Wire form of an engine control intent.
    public init(_ intent: ControlIntent) {
        self.init()
        turnLeft = intent.turnLeft
        turnRight = intent.turnRight
        thrust = intent.thrust
        reverse = intent.reverse
        afterburner = intent.afterburner
        firePrimary = intent.firePrimary
        fireSecondary = intent.fireSecondary
        desiredHeading = intent.desiredHeading
        turnScale = intent.turnScale
    }

    /// Engine form of a received wire intent.
    public var engineIntent: ControlIntent {
        var out = ControlIntent()
        out.turnLeft = turnLeft
        out.turnRight = turnRight
        out.thrust = thrust
        out.reverse = reverse
        out.afterburner = afterburner
        out.firePrimary = firePrimary
        out.fireSecondary = fireSecondary
        out.desiredHeading = desiredHeading
        out.turnScale = turnScale
        return out
    }
}
