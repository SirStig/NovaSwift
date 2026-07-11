import Foundation

// Map outfits (`oütf` ModType 16, "map") — the set of star systems a map reveals
// when it is ACQUIRED. This is the ground-truth reveal math, kept in the base
// Kit layer so both the shop (app `PilotStore`) and mission grants (story
// `StoryEngine`) resolve a map the exact same way.
//
// EV Nova Bible, oütf ModType 16 ("map"), ModVal semantics (verbatim):
//   "1 and up      How many jumps away from present system to explore
//    -1            Explore all inhabited independent systems
//    -1000 & down  Explore all systems of this govt class
//                  (-1000 is govt class 0, -1001 is govt class 1, etc.)"
//
// Crucially this is a ONE-SHOT reveal computed at purchase/grant time — a map is
// not a persistent "see everything" toggle. A positive value floods outward from
// the buyer's *current* system by hyperspace-link distance; the negative values
// reveal a fixed, position-independent set. The revealed ids are then recorded
// permanently in the pilot's charted-systems set (see `PlayerState`), so the map
// stays revealed even after the (usually intangible) map item is consumed.

extension NovaGame {
    /// The star systems a map with `modVal` reveals when acquired while the
    /// player is in system `originSystem`. See the ModType-16 table above:
    /// positive = that many hyperjumps out from `originSystem` (inclusive of the
    /// origin), `-1` = every inhabited independent system, `<= -1000` = every
    /// system belonging to govt class `-1000 - modVal`.
    ///
    /// Returns an empty set for `modVal == 0` (nothing to reveal) and for
    /// `-1000 < modVal < 0` other than `-1` (the Bible defines no meaning for
    /// that band, so nothing is revealed rather than guessing).
    public func mapRevealedSystems(modVal: Int, from originSystem: Int) -> Set<Int> {
        if modVal >= 1 {
            return systemsWithin(jumps: modVal, of: originSystem)
        }
        if modVal == -1 {
            return inhabitedIndependentSystems()
        }
        if modVal <= -1000 {
            return systems(inGovtClass: -1000 - modVal)
        }
        return []   // modVal == 0, or the undefined (-1, -1000) band
    }

    /// Breadth-first flood over `sÿst` hyperspace links: every system reachable
    /// in `jumps` hops or fewer from `origin`, including `origin` itself. Matches
    /// the Bible's "How many jumps away from present system to explore" — a map
    /// value of 2 reveals the origin, its neighbours, and their neighbours.
    private func systemsWithin(jumps: Int, of origin: Int) -> Set<Int> {
        guard system(origin) != nil else { return [] }
        var seen: Set<Int> = [origin]
        var frontier: [Int] = [origin]
        var depth = 0
        while depth < jumps, !frontier.isEmpty {
            var next: [Int] = []
            for id in frontier {
                for link in system(id)?.links ?? [] where !seen.contains(link) {
                    seen.insert(link)
                    next.append(link)
                }
            }
            frontier = next
            depth += 1
        }
        return seen
    }

    /// Every independent (`government == -1`) system that has at least one
    /// landable stellar — the Bible's "all inhabited independent systems".
    private func inhabitedIndependentSystems() -> Set<Int> {
        var result: Set<Int> = []
        for sys in systems() where sys.government == -1 {
            if sys.spobs.contains(where: { spob($0)?.canLand ?? false }) {
                result.insert(sys.id)
            }
        }
        return result
    }

    /// Every system whose controlling government is a member of `govtClass`
    /// (one of the up-to-four class ids a `gövt` declares) — the Bible's
    /// "all systems of this govt class".
    private func systems(inGovtClass govtClass: Int) -> Set<Int> {
        var result: Set<Int> = []
        for sys in systems() where sys.government >= 0 {
            if govt(sys.government)?.classes.contains(govtClass) ?? false {
                result.insert(sys.id)
            }
        }
        return result
    }
}
