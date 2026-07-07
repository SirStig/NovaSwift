import Foundation

/// A 2D vector in world space (+x right, +y up). Doubles for simulation stability.
public struct Vec2: Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 { let l = length; return l > 0 ? Vec2(x / l, y / l) : Vec2() }

    /// Unit vector pointing along a compass angle: 0 = up (north), increasing clockwise.
    public static func heading(_ angle: Double) -> Vec2 { Vec2(sin(angle), cos(angle)) }
}
