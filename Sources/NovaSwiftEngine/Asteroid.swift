import Foundation
import EVNovaKit

/// A rock in a system — EV Nova's `röid`. Real per-type stats (`Strength`,
/// `Mass`, fragmentation) come straight from the decoded `RoidRes`. The Bible
/// documents no position/velocity field for asteroids, only a rotation-frame-
/// advance rate (`SpinRate`), so asteroids are scattered once when a system is
/// entered and spin in place rather than drifting — that's what the source
/// data actually specifies, not an invented simplification.
public final class Asteroid {
    public let id: Int
    public let roidTypeID: Int
    public let position: Vec2
    public var angle: Double
    /// Degrees/sec, derived from `RoidRes.spinRate` (Bible: "100 = 30 frames
    /// per second" advancing through the 36-frame rotation sheet, i.e. 10° —
    /// 360°/36 frames — per frame at that rate).
    public let angularVelocityDegPerSec: Double
    public var hp: Double
    /// Collision radius (px), taken from the matching `spïn`'s real sprite
    /// tile width, not an invented constant.
    public let radius: Double
    public let mass: Double
    /// Sub-asteroid types to fragment into on death (-1 = none/unused).
    public let fragType1: Int
    public let fragType2: Int
    /// Average number of sub-asteroids on death, ±50% per the Bible.
    public let fragCount: Int
    public let explodeType: Int
    public var isAlive = true

    public init(id: Int, roidTypeID: Int, position: Vec2, angle: Double,
                roid: RoidRes, radius: Double, hpScale: Double) {
        self.id = id
        self.roidTypeID = roidTypeID
        self.position = position
        self.angle = angle
        self.angularVelocityDegPerSec = Double(roid.spinRate) / 100.0 * 30.0 * 10.0
        self.hp = max(1, Double(roid.strength) * hpScale)
        self.radius = radius
        self.mass = Double(roid.mass)
        self.fragType1 = roid.fragType1
        self.fragType2 = roid.fragType2
        self.fragCount = roid.fragCount
        self.explodeType = roid.explodeType
    }

    /// The 0..<36 rotation-sheet frame for the current angle — same bucketing
    /// as `Ship.spriteFrame`.
    public var spriteFrame: Int {
        let n = 36
        let twoPi = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return Int((a / twoPi * Double(n)).rounded()) % n
    }
}
