import Foundation
import NovaSwiftKit

/// Small deterministic RNG so mission random rolls and `R(…)` choices are
/// reproducible (important for save/replay and tests). SplitMix64.
struct StoryRNG {
    private(set) var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in 0..<n.
    mutating func int(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        return Int(next() % UInt64(n))
    }

    /// True with probability `percent`/100.
    mutating func chance(percent: Int) -> Bool {
        if percent <= 0 { return false }
        if percent >= 100 { return true }
        return int(100) < percent
    }
}
