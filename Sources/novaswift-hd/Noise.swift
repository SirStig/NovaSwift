import Foundation
import simd

/// Seeded 3D gradient noise (Perlin-style, improved fade) and fractal sums,
/// for the procedural planet surfaces and hull textures. Deterministic: the
/// same seed always paints the same planet.
struct Noise3 {
    private var perm: [Int] = []

    init(seed: UInt64) {
        var rng = SplitMix(seed)
        var p = Array(0..<256)
        for i in stride(from: 255, to: 0, by: -1) { p.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        perm = p + p
    }

    private static func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
    private static func grad(_ h: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        let h = h & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    /// Roughly −1…1.
    func noise(_ p: SIMD3<Double>) -> Double {
        let fx = floor(p.x), fy = floor(p.y), fz = floor(p.z)
        let X = Int(fx) & 255, Y = Int(fy) & 255, Z = Int(fz) & 255
        let x = p.x - fx, y = p.y - fy, z = p.z - fz
        let u = Self.fade(x), v = Self.fade(y), w = Self.fade(z)
        let A = perm[X] + Y, AA = perm[A] + Z, AB = perm[A + 1] + Z
        let B = perm[X + 1] + Y, BA = perm[B] + Z, BB = perm[B + 1] + Z
        func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double { a + t * (b - a) }
        return lerp(w, lerp(v, lerp(u, Self.grad(perm[AA], x, y, z), Self.grad(perm[BA], x - 1, y, z)),
                               lerp(u, Self.grad(perm[AB], x, y - 1, z), Self.grad(perm[BB], x - 1, y - 1, z))),
                       lerp(v, lerp(u, Self.grad(perm[AA + 1], x, y, z - 1), Self.grad(perm[BA + 1], x - 1, y, z - 1)),
                               lerp(u, Self.grad(perm[AB + 1], x, y - 1, z - 1), Self.grad(perm[BB + 1], x - 1, y - 1, z - 1))))
    }

    /// Fractal Brownian motion, normalised to roughly −1…1.
    func fbm(_ p: SIMD3<Double>, octaves: Int, lacunarity: Double = 2.03, gain: Double = 0.5) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            sum += amp * noise(p * freq + SIMD3(Double(o) * 17.3, Double(o) * 5.1, Double(o) * 11.7))
            norm += amp; amp *= gain; freq *= lacunarity
        }
        return sum / norm
    }

    /// Ridged fractal (sharp crests), 0…1.
    func ridged(_ p: SIMD3<Double>, octaves: Int) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0
        for _ in 0..<octaves {
            let n = 1 - abs(noise(p * freq))
            sum += n * n * amp; amp *= 0.5; freq *= 2.1
        }
        return sum
    }
}

/// Small deterministic RNG.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}
