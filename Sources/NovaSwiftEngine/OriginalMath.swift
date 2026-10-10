import Foundation

/// The original's integer bearing (C-1). Every "which way is that point"
/// question in the original goes through `Math_BearingFromPointToPoint`
/// (0x0043b670) → `Math_AngleFromVector2D` (0x004619b0), which looks the
/// angle up in a quantised arctan table instead of calling `atan2`. The table
/// truncates, so a true 45° reads as 44 and the result is off from the exact
/// angle by up to 2°.
public enum OriginalMath {

    /// `atanT[i] = trunc(atan(i × 0.01) × 57.2957795)` (`Math_InitTrigLookupTables`
    /// 0x00461830). Only 0...100 is reachable: the ratio is never above 1.
    static let atanTable: [Int] = (0...100).map {
        Int((atan(Double($0) * 0.01) * 57.2957795).rounded(.towardZero))
    }

    /// `Math_AngleFromVector2D(dx, dy)`: the compass bearing (0 = up,
    /// clockwise, whole degrees 0...359) of the vector `(−dx, −dy)` in screen
    /// space (+y down). The original passes `p1 − p2` and gets the bearing
    /// from p1 to p2.
    public static func angleFromVector(dx: Float, dy: Float) -> Int {
        if dx == 0 && dy == 0 { return 0 }
        let ax = Double(abs(dx)), ay = Double(abs(dy))
        let steep = ax < ay
        let ratio = steep ? ax / ay : ay / ax
        let i = min(1023, max(0, Int((ratio * 100).rounded(.towardZero))))
        var u = atanTable[min(i, 100)]
        if steep { u = 90 - u }
        if dx < 0 && dy >= 0 { u = 180 - u }
        if dx < 0 && dy < 0 { u += 180 }
        if dx >= 0 && dy < 0 { u = -u }
        var b = u - 90
        if b < 0 { b = u + 270 }
        if b > 359 { b -= 360 }
        return b
    }

    /// `Math_BearingFromPointToPoint` from `a` to `b`, in the engine's +y-up
    /// coordinates: whole degrees, 0 = up, clockwise.
    public static func bearing(from a: Vec2, to b: Vec2) -> Int {
        angleFromVector(dx: Float(a.x - b.x), dy: Float(b.y - a.y))
    }

    /// The same bearing as a compass heading in radians.
    public static func bearingRadians(from a: Vec2, to b: Vec2) -> Double {
        Double(bearing(from: a, to: b)) * .pi / 180
    }

    /// The bearing of a direction vector (engine +y up), as from the origin
    /// to `v`.
    public static func bearingRadians(of v: Vec2) -> Double {
        bearingRadians(from: Vec2(), to: v)
    }
}
