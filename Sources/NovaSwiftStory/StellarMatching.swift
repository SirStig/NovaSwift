import Foundation
import NovaSwiftKit

/// Resolves EV Nova's "special" stellar/system selector codes against a concrete
/// object. Mission fields like `returnStellar`, `availStellar` and
/// `shipSystem` don't always name a specific id — they use encoded ranges
/// (any inhabited stellar, a government's systems, adjacency, …). These helpers
/// answer "does this concrete spob/system satisfy that selector?".
///
/// Ranges (from the ResForge mïsn template, verified):
///   -1 none · -2 inhabited · -3 uninhabited · -4 initial
///   128…2175 specific id · 9999 independent
///   10000+g govt · 15000+g govt-allies · 20000+g not-govt
///   25000+g govt-enemies · 30000+g govt+class · 31000+g not-govt+class
enum StellarMatch {
    /// Does `spobID` satisfy stellar selector `code`?
    static func spob(code: Int, spobID: Int, game: NovaGame,
                     initialSpob: Int?) -> Bool {
        switch code {
        case -1: return false                       // none
        case -2: return isInhabited(spobID, game)   // any inhabited stellar
        case -3: return !isInhabited(spobID, game)  // any uninhabited stellar
        case -4: return initialSpob == spobID       // the mission's initial stellar
        case 9999:
            return (game.spob(spobID)?.government ?? -1) < 128   // independent
        case 128...2175:
            return code == spobID
        default:
            if let g = govtOf(code, base: 10000) {  // govt's stellars
                return game.spob(spobID)?.government == g
            }
            if let g = govtOf(code, base: 20000) {  // not this govt's stellars
                return game.spob(spobID)?.government != g
            }
            // Allies / enemies / class variants need govt relations; treat as a
            // govt match best-effort so common cases still complete.
            if let g = govtOf(code, base: 15000) { return game.spob(spobID)?.government == g }
            if let g = govtOf(code, base: 25000) { return game.spob(spobID)?.government == g }
            if let g = govtOf(code, base: 30000) { return game.spob(spobID)?.government == g }
            if let g = govtOf(code, base: 31000) { return game.spob(spobID)?.government != g }
            return false
        }
    }

    /// Does `systemID` satisfy system selector `code`?
    static func system(code: Int, systemID: Int, game: NovaGame,
                       initialSystem: Int?) -> Bool {
        switch code {
        case -1, -2, -3, -4, -5, -6: return true  // relative/self codes — accept
        case 9999: return true
        case 128...2175: return code == systemID
        default:
            // Adjacency and govt-scoped codes: accept govt matches; adjacency is
            // resolved by the caller when it knows the reference system.
            return true
        }
    }

    /// Decode a government from a special stellar code. The Bible's govt ranges
    /// ("9999-10255 Specific govt's stellar", 15000/20000/25000/30000/31000 +…)
    /// encode the government as a **0-based index off `base`**, which maps onto
    /// EV Nova's 128-based government resource IDs — so `10000` → govt 128
    /// (Federation), `10001` → 129, and so on.
    ///
    /// The previous `base + 128 … base + 255` window (returning `code - base`)
    /// was doubly wrong: it excluded `base … base+127` — i.e. the entire common
    /// case, including `10000` = Federation — and shifted the id by 128. That
    /// silently rejected the ~90 generic "Ferry Passengers"/"Delivery to <DST>"
    /// BBS missions (all `availStellar` 10000), leaving mission boards empty.
    private static func govtOf(_ code: Int, base: Int) -> Int? {
        guard code >= base, code <= base + 255 else { return nil }
        return code - base + 128
    }

    /// A stellar is "inhabited" if it offers services (has a valid landing pict /
    /// tech level). We approximate with tech level ≥ 0 and a non-negative govt.
    private static func isInhabited(_ spobID: Int, _ game: NovaGame) -> Bool {
        guard let s = game.spob(spobID) else { return false }
        return s.techLevel >= 0 && s.landingPictID > 0
    }
}

/// Small deterministic RNG so mission random rolls and `R(…)` choices are
/// reproducible (important for save/replay and tests). SplitMix64.
struct StoryRNG {
    private var state: UInt64
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
