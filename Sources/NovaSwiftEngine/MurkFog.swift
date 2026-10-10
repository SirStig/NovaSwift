import Foundation

/// The system murk as a per-sprite distance fog (0x00438db0): the level
/// grows with the squared distance from the player and the effective murk,
/// and the sprite is mixed toward the system's background colour by
/// level/32. The player (distance 0) is never fogged.
public enum MurkFog {
    /// The fog level 0...31 for a sprite `dx`, `dy` pixels from the player.
    public static func level(murk: Int, dx: Double, dy: Double) -> Int {
        guard murk > 0 else { return 0 }
        let ax = Double(Int(abs(dx))), ay = Double(Int(abs(dy)))
        let d = Int(Double(murk) * (ax * ax + ay * ay) * 1.2e-5)
        return max(0, min(31, d))
    }
}
