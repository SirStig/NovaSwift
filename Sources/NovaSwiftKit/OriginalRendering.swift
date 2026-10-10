import Foundation

/// The original's in-flight drawing rules that don't depend on a renderer:
/// ship tints, the ambient starfield, sprite frame wrapping, SWParticle fade
/// and pool sizes. The SpriteKit scene applies them; tests pin them here.
public enum OriginalRendering {

    // MARK: Ship tint (0x0046e470)

    /// A 5-bit-per-channel tint where 0x20 (32) is neutral. The sprite is
    /// scaled per channel by `v / 32`.
    public struct Tint: Equatable, Sendable {
        public var r: Int, g: Int, b: Int
        public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
        public static let neutral = Tint(r: 0x20, g: 0x20, b: 0x20)
        public var isNeutral: Bool { self == .neutral }
        /// Channel multipliers for a multiply blend. Values above 32 brighten
        /// in the original (an additive boost this multiply can't show), so
        /// they are capped at 1.
        public var multipliers: (r: Double, g: Double, b: Double) {
            (min(1, Double(max(0, r)) / 32), min(1, Double(max(0, g)) / 32), min(1, Double(max(0, b)) / 32))
        }
    }

    /// 15-bit 0RRRRRGGGGGBBBBB → 5-bit channels.
    public static func tint(rgb555 v: Int) -> Tint {
        Tint(r: (v >> 10) & 0x1F, g: (v >> 5) & 0x1F, b: v & 0x1F)
    }

    /// The tint the original resolves for a ship:
    /// - the player: the global paint (oütf ModType 43), never the gövt colour;
    /// - an NPC with a përs: that përs's Color;
    /// - any other NPC: its gövt ShipColor, each byte stored shifted left 8
    ///   (so any non-zero byte saturates), or neutral with no gövt;
    /// - all-zero always becomes neutral.
    public static func shipTint(isPlayer: Bool, paint555: Int?, persColor555: Int?,
                                govtShipColor: (r: Int, g: Int, b: Int)?) -> Tint {
        var t: Tint
        if isPlayer {
            t = paint555.map(tint(rgb555:)) ?? Tint(r: 0, g: 0, b: 0)
        } else if let p = persColor555 {
            t = tint(rgb555: p)
        } else if let c = govtShipColor {
            t = Tint(r: c.r << 8, g: c.g << 8, b: c.b << 8)
        } else {
            t = .neutral
        }
        if t.r == 0 && t.g == 0 && t.b == 0 { t = .neutral }
        return t
    }

    // MARK: Sprite frames (0x00475830)

    /// `Sprite_SetCurrentFrame`: negative → 0, then wrap by the sheet's count.
    public static func wrappedFrame(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, index) % count
    }

    // MARK: Ambient starfield (0x0046ebf0 / 0x0046ee50 / 0x0042e590)

    /// Live stars: round(viewHeight / 600 · 20), at most the 20-slot pool.
    public static func starCount(viewHeight: Double) -> Int {
        max(0, min(20, Int((viewHeight / 600 * 20).rounded())))
    }

    /// A star's extra drift factor: Random(35) · 0.01 with the Parallax
    /// Starfield preference on (the default), else 0. Each tick the star moves
    /// by −playerVelocity · factor, so it streams past at (1 + factor)× the
    /// world's scroll.
    public static func starFactor(random35: Int, parallax: Bool) -> Double {
        parallax ? Double(random35) * 0.01 : 0
    }

    /// The star tint for the system's raw murk: neutral at 0, otherwise
    /// round(murk · 0.9) clamped to 2…29 (stars are hidden while murk < 0).
    public static func starTint(rawMurk: Int) -> Int {
        guard rawMurk != 0 else { return 0x20 }
        return min(29, max(2, Int((Double(rawMurk) * 0.9).rounded())))
    }

    /// Wrap a star's offset from the view centre along one axis: once its
    /// near edge is more than two star widths outside the view it jumps across
    /// by viewSize + 2·starSize. Returns nil when no wrap is needed.
    public static func wrapStar(offset: Double, viewSize: Double, starSize: Double) -> Double? {
        let span = viewSize + 2 * starSize
        let edge = viewSize / 2 + offset
        if edge < -2 * starSize { return offset + span }
        if edge > span { return offset - span }
        return nil
    }

    // MARK: SWParticles (0x0047bdd0 / 0x0047c800 / 0x004abd8d)

    /// The particle pool's size.
    public static let particlePoolSize = 100_000

    /// Opacity of a particle with `life` ticks left: opaque above 32, then
    /// fading as life/32; not drawn at life ≤ 1.
    public static func particleAlpha(life: Int) -> Double {
        guard life > 1 else { return 0 }
        return life > 32 ? 1 : Double(life) / 32
    }

    // MARK: Pools (0x004af020)

    public static let shotPoolSize = 128
    public static let explosionPoolSize = 32
    public static let cargoBoxPoolSize = 64
    public static let podPoolSize = 32
    public static let smokePoolSize = 64
    public static let asteroidPoolSize = 16
}
