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
    public func mapRevealedSystems(modVal: Int, from originSystem: Int,
                                   isVisible: (Int) -> Bool = { _ in true }) -> Set<Int> {
        Set(mapRevealOrder(modVal: modVal, from: originSystem, isVisible: isVisible))
    }

    /// The systems a map reveals, in the order the original reaches them —
    /// the order their nebula OnExplore scripts fire in. `isVisible` is the
    /// systems' NCB visibility; a hidden system blocks a positive map's flood.
    public func mapRevealOrder(modVal: Int, from originSystem: Int,
                               isVisible: (Int) -> Bool = { _ in true }) -> [Int] {
        if modVal >= 1 {
            return systemsWithin(jumps: modVal, of: originSystem, isVisible: isVisible)
        }
        if modVal == -1 {
            return inhabitedIndependentSystems()
        }
        if modVal <= -1000 {
            return systems(inGovtClass: -1000 - modVal).sorted()
        }
        return []   // modVal == 0, or the undefined (-1, -1000) band
    }

    /// The original's flood (0x00467ab0): a depth-first walk over each
    /// system's own declared links, depth ≤ `jumps`, with one visited mask
    /// marked on entry. Because a system first reached down a long path is
    /// not revisited from a shorter one, it can reveal less than the true
    /// `jumps` radius — a quirk kept on purpose (UI-04). A link to a hidden
    /// system follows to a visible twin at the same spot, or stops there.
    private func systemsWithin(jumps: Int, of origin: Int, isVisible: (Int) -> Bool) -> [Int] {
        guard system(origin) != nil else { return [] }
        let all = systems()
        var byID: [Int: SystRes] = [:]
        var twins: [String: [Int]] = [:]
        for s in all {
            byID[s.id] = s
            twins["\(s.x),\(s.y)", default: []].append(s.id)
        }
        func visibleTwin(_ id: Int) -> Int? {
            if isVisible(id) { return id }
            guard let s = byID[id] else { return nil }
            return twins["\(s.x),\(s.y)"]?.sorted().first(where: isVisible)
        }
        var visited: Set<Int> = []
        var order: [Int] = []
        func flood(_ id: Int, _ depth: Int) {
            guard depth <= jumps, byID[id] != nil, visited.insert(id).inserted else { return }
            order.append(id)
            for link in byID[id]?.links ?? [] where link >= 128 {
                if let target = visibleTwin(link) { flood(target, depth + 1) }
            }
        }
        flood(origin, 0)
        return order
    }

    /// The independent (`government == -1`) systems with a stellar that is
    /// neither uninhabited (`spöb.Flags` 0x20) nor a hypergate/wormhole
    /// (0x00468af0) — the Bible's "all inhabited independent systems".
    private func inhabitedIndependentSystems() -> [Int] {
        var result: [Int] = []
        for sys in systems() where sys.government < 128 {
            if sys.spobs.contains(where: { id in
                guard let s = spob(id) else { return false }
                return s.flags & 0x20 == 0 && s.flags2 & 0x3000 == 0
            }) {
                result.append(sys.id)
            }
        }
        return result.sorted()
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
