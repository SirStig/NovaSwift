import Foundation

/// The star map's Find (`NovaUi_RunStarmapSearchDialog` 0x004aab30). The
/// query and each candidate's name are lower-cased and reduced to `[a-z0-9]`;
/// the candidate sharing the longest common prefix with the query wins, a
/// tie going to the shorter normalised name (else the earlier system). It
/// fails — a beep — when nothing shares a first character, or when the best
/// prefix is under 2 characters and more than one candidate matched at all.
/// A hit only moves the selection and centres the view; it never arms or
/// plots anything.
public enum StarMapFind {
    public static func normalize(_ s: String) -> [Character] {
        s.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map { $0 }
    }

    /// `candidates` in system index order (visible, discovery level > 0,
    /// latched). Returns the found id, or nil for the failure beep.
    public static func find(_ query: String, in candidates: [(id: Int, name: String)]) -> Int? {
        let q = normalize(query)
        var best: (id: Int, prefix: Int, length: Int)?
        var matches = 0
        for c in candidates {
            let n = normalize(c.name)
            var l = 0
            while l < q.count, l < n.count, q[l] == n[l] { l += 1 }
            guard l > 0 else { continue }
            matches += 1
            if best == nil || l > best!.prefix || (l == best!.prefix && n.count < best!.length) {
                best = (c.id, l, n.count)
            }
        }
        guard let best else { return nil }
        if best.prefix < 2 && matches != 1 { return nil }
        return best.id
    }
}
