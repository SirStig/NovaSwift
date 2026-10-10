import Foundation

/// A small, fast, seedable PRNG (SplitMix64). The simulation uses it for spawn
/// choices, weapon spread, and patrol wander so that a given seed replays
/// identically — which makes the AI testable and deterministic.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in 0..<1.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform Double in a closed range.
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// Uniform Int in a closed range.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// The original game's one random-number generator (`NovaRandom_Range`
/// 0x004683b0): the Mac Toolbox `Random()`, a Park–Miller "minimal standard"
/// Lehmer generator (`seed = seed × 16807 mod (2³¹ − 1)`). A draw uses only the
/// low 16 bits of the new seed, with 0x8000 read as 0, and scales them as
/// `(n × u) >> 16`, so `range(n)` is `0..<n` with 0 very slightly over-weighted.
///
/// The simulation draws from this exactly where the original draws an integer
/// range (headings `range(360)`, asteroid drift `range(400)`, skill variance
/// `range(2p + 1)`, …). The `unit`/`double`/`int` helpers below serve the
/// port's own continuous draws, built from the same stream.
public struct NovaRandom: RandomNumberGenerator {
    /// The 32-bit state (the original's u32 at 0x007ccdd8).
    public private(set) var seed: UInt32

    public init(seed: UInt32) { self.seed = seed }

    /// Seeds from a 64-bit session seed, folding it into the 32-bit state.
    public init(seed: UInt64) {
        self.init(seed: UInt32(truncatingIfNeeded: seed ^ (seed >> 32)))
    }

    /// One state step, in the original's division-free form so every u32 seed
    /// (including ones ≥ 2³¹) advances exactly as it does in the exe.
    private mutating func step() {
        let lo = (seed & 0xFFFF) &* 16807
        let hi = (seed >> 16) &* 16807 &+ (lo >> 16)
        var x = (lo & 0xFFFF) &- 0x7FFF_FFFF &+ ((hi & 0x7FFF) << 16) &+ ((hi &* 2) >> 16)
        if x & 0x8000_0000 != 0 { x = x &+ 0x7FFF_FFFF }
        seed = x
    }

    /// The next 16-bit draw (0x8000 reads as 0; the stored seed keeps it).
    private mutating func nextWord() -> UInt32 {
        step()
        let u = seed & 0xFFFF
        return u == 0x8000 ? 0 : u
    }

    /// `NovaRandom_Range(n)`: `0..<n`. `n` is the original's 16-bit argument.
    /// A negative `n` returns the logical shift of the signed product, as the
    /// exe does. `n == 0` is the original's reseed path, which reseeds from the
    /// clock and returns the caller's stale EBP; a deterministic simulation
    /// can't do either, so it returns 0 and leaves the seed alone.
    public mutating func range(_ n: Int) -> Int {
        let bound = Int32(Int16(truncatingIfNeeded: n))
        guard bound != 0 else { return 0 }
        let product = bound &* Int32(nextWord())
        return Int(UInt32(bitPattern: product) >> 16)
    }

    public mutating func next() -> UInt64 {
        var r: UInt64 = 0
        for _ in 0..<4 { r = (r << 16) | UInt64(nextWord()) }
        return r
    }

    /// Uniform Double in 0..<1 (one 16-bit draw).
    public mutating func unit() -> Double { Double(nextWord()) / 65536.0 }

    /// Uniform Double in a closed range.
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// Uniform Int in a closed range: one `range(n)` draw when the span fits the
    /// original's 16-bit argument, otherwise a wide draw.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        let span = range.upperBound - range.lowerBound + 1
        if span <= 0x7FFF { return range.lowerBound + self.range(span) }
        return range.lowerBound + Int(next() % UInt64(span))
    }
}
