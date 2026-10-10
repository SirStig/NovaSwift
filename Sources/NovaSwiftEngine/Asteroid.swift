import Foundation
import NovaSwiftKit

/// A rock in a system's asteroid field — EV Nova's `röid`. Real per-type stats
/// (`Strength`, `Mass`, fragmentation, yield) come straight from the decoded
/// `RoidRes`. The field itself is the original's 16-slot pool that drifts and
/// travels with the player (see `World.populateAsteroids`).
public final class Asteroid {
    public let id: Int
    public let roidTypeID: Int
    public var position: Vec2
    /// Drift, px/s (the original rolls ±2 px/tick per axis).
    public var velocity = Vec2()
    public var angle: Double
    /// Degrees/sec, derived from `RoidRes.spinRate` (Bible: "100 = 30 frames
    /// per second" advancing through the 36-frame rotation sheet, i.e. 10° —
    /// 360°/36 frames — per frame at that rate), then scaled by the spawn's
    /// 0.80–1.20 roll and given a random direction.
    public var angularVelocityDegPerSec: Double
    /// Render-interpolation snapshot (see `Ship.renderPrevPosition`).
    public var renderPrevPosition: Vec2
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
    /// The rock's death explosion as a resolved `bööm` resource id (or nil) —
    /// drives the real explosion sprite the renderer plays when it shatters.
    public let explosionBoomID: Int?
    /// `röid.partColor`/`partCount` — the debris spray's tint and chunk count,
    /// thrown as colored fragments alongside the explosion on death.
    public let partColor: NovaColor
    public let partCount: Int
    /// `röid.YieldType` — cargo id this rock yields when mined (0-5 standard
    /// commodity; -1 = nothing). `röid.YieldQty` is the average box count (±50%).
    public let yieldType: Int
    public let yieldQty: Int
    public var isAlive = true

    public init(id: Int, roidTypeID: Int, position: Vec2, angle: Double,
                roid: RoidRes, radius: Double, hpScale: Double) {
        self.id = id
        self.roidTypeID = roidTypeID
        self.position = position
        self.renderPrevPosition = position
        self.angle = angle
        self.angularVelocityDegPerSec = Double(roid.spinRate) / 100.0 * 30.0 * 10.0
        self.hp = max(1, Double(roid.strength) * hpScale)
        self.radius = radius
        self.mass = Double(roid.mass)
        self.fragType1 = roid.fragType1
        self.fragType2 = roid.fragType2
        self.fragCount = roid.fragCount
        self.explodeType = roid.explodeType
        self.explosionBoomID = roid.explosionBoomID
        self.partColor = roid.partColor
        self.partCount = roid.partCount
        self.yieldType = roid.yieldType
        self.yieldQty = roid.yieldQty
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

/// A freeflight object: the original's 64-slot pool of drifting boxes
/// (`Ship_SpawnFreeflightObjectAtPosition` 0x0041fb50, ticked by 0x0042c1b0).
/// A destroyed asteroid leaves its yield as these resource boxes; a ship with a
/// working scoop collects one ton per box by flying through it (OS-11).
public final class FreeflightObject {
    public let id: Int
    public var position: Vec2
    public var renderPrevPosition: Vec2
    /// px/s.
    public var velocity: Vec2
    /// Seconds left before the box expires (300–499 ticks at spawn).
    public var lifeRemaining: Double
    /// Rotation frame, 0..<36, advanced `spin` frames per tick.
    public var frame: Double
    public let spin: Int
    /// The commodity (0–5) or junk (1000–1127) a scoop collects.
    public let cargoType: Int
    /// Which `spïn` 500+n box set draws it (0 = jettisoned cargo; asteroid
    /// yields use 1–4 by rock size).
    public let spriteSet: Int

    init(id: Int, position: Vec2, velocity: Vec2, lifeRemaining: Double, frame: Double,
         spin: Int, cargoType: Int, spriteSet: Int) {
        self.id = id
        self.position = position
        self.renderPrevPosition = position
        self.velocity = velocity
        self.lifeRemaining = lifeRemaining
        self.frame = frame
        self.spin = spin
        self.cargoType = cargoType
        self.spriteSet = spriteSet
    }

    public var spriteFrame: Int { Int(frame.rounded(.down)) % 36 }
}
