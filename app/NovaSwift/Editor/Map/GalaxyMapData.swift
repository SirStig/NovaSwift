#if os(macOS)
import SwiftUI
import CoreGraphics
import NovaSwiftKit

// Derived, cached geometry for the galaxy editor. Rebuilt only when the
// document revision changed AND the change touched a type the map shows.

struct MapSystem: Identifiable {
    let id: Int
    var name: String
    var x: CGFloat
    var y: CGFloat
    var govt: Int
    var links: [Int]
    var spobCount: Int
    var provenance: Provenance
    var touched: Bool { provenance == .new || provenance == .override }
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct MapNebulaRec: Identifiable {
    let id: Int
    var name: String
    var rect: CGRect          // top-left origin, map units
    var provenance: Provenance
    var touched: Bool { provenance == .new || provenance == .override }
}

struct MapGovt: Identifiable {
    let id: Int
    let name: String
    let color: Color
    var count = 0
}

struct MapLinkPair: Hashable {
    let a: Int, b: Int        // a < b
    let oneWay: Bool
}

/// Everything the galaxy canvas and inspector derive from the effective
/// collection. Built off the main actor (or patched in place for small
/// edits) and published as a whole.
struct MapSnapshot: @unchecked Sendable {
    var systems: [MapSystem] = []
    var index: [Int: Int] = [:]
    var nebulae: [MapNebulaRec] = []
    var pairs: [MapLinkPair] = []
    var govts: [MapGovt] = []
    var govtColor: [Int: Color] = [:]
    var bounds = CGRect(x: -200, y: -200, width: 400, height: 400)
    var touchedCount = 0
    var oneWayCount = 0
    // Raw resources the snapshot was decoded from; diffed against the next
    // effective collection to find what an edit actually changed.
    var systRes: [Int: Resource] = [:]
    var govtRes: [Int: Resource] = [:]
    var nebuRes: [Int: Resource] = [:]
}

@MainActor
final class GalaxyMapData: ObservableObject {
    /// One instance per editor session so re-opening the Galaxy tool is instant
    /// (the snapshot is revalidated against the document revision).
    static let shared = GalaxyMapData()

    private(set) var systems: [MapSystem] = []
    private(set) var index: [Int: Int] = [:]
    private(set) var nebulae: [MapNebulaRec] = []
    private(set) var pairs: [MapLinkPair] = []
    private(set) var govts: [MapGovt] = []
    private(set) var govtColor: [Int: Color] = [:]
    private(set) var bounds = CGRect(x: -200, y: -200, width: 400, height: 400)
    private(set) var touchedCount = 0
    private(set) var oneWayCount = 0
    @Published private(set) var nebulaImages: [Int: CGImage] = [:]
    @Published private(set) var version = 0
    /// True once a snapshot for the current document has been published.
    @Published private(set) var hasLoaded = false
    /// True while a full off-main rebuild is in flight.
    @Published private(set) var isBuilding = false

    private var snapshot = MapSnapshot()
    private var lastRevision = -1
    private var docID: ObjectIdentifier?
    private var buildTask: Task<Void, Never>?
    private var loadingImages: Set<Int> = []
    private var imageKeys: [Int: Int] = [:]   // nebula id → pict byte count it was decoded from

    static let relevant: Set<NovaSwiftKit.FourCharCode> = [NovaType.syst, NovaType.nebula, NovaType.govt, NovaType.pict]
    /// Edits to more systems than this at once are rebuilt off-main instead of patched.
    private static let patchLimit = 48

    static let independent = Color(white: 0.62)

    func system(_ id: Int) -> MapSystem? { index[id].map { systems[$0] } }
    func color(_ govt: Int) -> Color { govtColor[govt] ?? Self.independent }
    func govtName(_ id: Int) -> String {
        id < 128 ? "Independent" : (govts.first { $0.id == id }?.name ?? "Govt \(id)")
    }

    /// Bring the map up to date with the model. Never blocks: small edits are
    /// patched synchronously (a handful of `sÿst` decodes); anything bigger
    /// (first open, government edits, bulk changes) is rebuilt off-main while
    /// the previous geometry stays on screen.
    func refresh(_ model: EditorModel, force: Bool = false) {
        let doc = model.document
        let id = ObjectIdentifier(doc)
        let rev = model.revision
        let sameDoc = (id == docID)
        if !force, sameDoc, rev == lastRevision { return }
        if !force, sameDoc, hasLoaded || isBuilding, rev == lastRevision + 1,
           model.lastChanged.allSatisfy({ !Self.relevant.contains($0.type) }) {
            lastRevision = rev
            return
        }
        lastRevision = rev
        if !sameDoc {
            // New document: drop everything and show the loading state.
            buildTask?.cancel()
            docID = id
            snapshot = MapSnapshot()
            install(snapshot)
            hasLoaded = false
            nebulaImages = [:]; imageKeys = [:]; loadingImages = []
        }
        if !force, sameDoc, hasLoaded, !isBuilding, patch(doc) { return }
        startFullBuild(doc, delay: hasLoaded ? .milliseconds(120) : .zero)
    }

    // MARK: Full rebuild (off-main)

    private func startFullBuild(_ doc: PluginDocument, delay: Duration) {
        buildTask?.cancel()
        isBuilding = true
        buildTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            // Snapshot on main (value types), decode elsewhere.
            let eff = doc.effective, layer = doc.layer, base = doc.base
            let snap = await Task.detached(priority: .userInitiated) {
                Self.build(eff: eff, layer: layer, base: base)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.snapshot = snap
            self.install(snap)
            self.hasLoaded = true
            self.isBuilding = false
            self.version &+= 1
            self.objectWillChange.send()
            self.refreshNebulaImages(eff)
        }
    }

    nonisolated private static func provenance(_ type: NovaSwiftKit.FourCharCode, _ id: Int,
                                               layer: ResourceCollection, base: ResourceCollection) -> Provenance {
        let inBase = base.resource(type, id)
        if layer.resource(type, id) != nil { return inBase == nil ? .new : .override }
        guard let inBase else { return .base }
        return inBase.pluginID.isEmpty ? .base : .otherPlugin(inBase.pluginID)
    }

    nonisolated private static func system(_ r: Resource, layer: ResourceCollection, base: ResourceCollection) -> MapSystem {
        let s = SystRes(r)
        return MapSystem(id: r.id, name: s.name, x: CGFloat(s.x), y: CGFloat(s.y), govt: s.government,
                         links: s.links, spobCount: s.spobs.count,
                         provenance: provenance(NovaType.syst, r.id, layer: layer, base: base))
    }

    nonisolated private static func nebula(_ r: Resource, layer: ResourceCollection, base: ResourceCollection) -> MapNebulaRec {
        let n = NebuRes(r)
        return MapNebulaRec(id: r.id, name: r.name.isEmpty ? "Nebula \(r.id)" : r.name,
                            rect: CGRect(x: n.x, y: n.y, width: max(1, n.width), height: max(1, n.height)),
                            provenance: provenance(NovaType.nebula, r.id, layer: layer, base: base))
    }

    /// Pure function of the three collections; safe to run on any thread.
    nonisolated private static func build(eff: ResourceCollection, layer: ResourceCollection, base: ResourceCollection) -> MapSnapshot {
        var snap = MapSnapshot()
        snap.systRes = eff.byType[NovaType.syst] ?? [:]
        snap.govtRes = eff.byType[NovaType.govt] ?? [:]
        snap.nebuRes = eff.byType[NovaType.nebula] ?? [:]

        // Governments + colours (authentic mapColor via GovernmentPalette).
        let game = NovaGame(eff)
        let palette = GovernmentPalette(game: game)
        var gl: [MapGovt] = []
        var colors: [Int: Color] = [:]
        for g in game.govts().sorted(by: { $0.id < $1.id }) {
            let c = palette.color(for: g.id)
            colors[g.id] = c
            gl.append(MapGovt(id: g.id, name: g.name.isEmpty ? "Govt \(g.id)" : g.name, color: c))
        }
        snap.govtColor = colors
        snap.govts = gl

        var out: [MapSystem] = []
        out.reserveCapacity(snap.systRes.count)
        for r in snap.systRes.values.sorted(by: { $0.id < $1.id }) {
            out.append(Self.system(r, layer: layer, base: base))
        }
        snap.systems = out
        snap.nebulae = snap.nebuRes.values.sorted(by: { $0.id < $1.id }).map { nebula($0, layer: layer, base: base) }
        finish(&snap)
        return snap
    }

    /// Recompute everything derived from `systems` (index, link pairs, counts, bounds).
    nonisolated private static func finish(_ snap: inout MapSnapshot) {
        let out = snap.systems
        var idx: [Int: Int] = [:]
        idx.reserveCapacity(out.count)
        for (i, s) in out.enumerated() { idx[s.id] = i }
        snap.index = idx

        var counts: [Int: Int] = [:]
        var touched = 0
        for s in out {
            if s.govt >= 128 { counts[s.govt, default: 0] += 1 }
            if s.touched { touched += 1 }
        }
        for i in snap.govts.indices { snap.govts[i].count = counts[snap.govts[i].id] ?? 0 }
        snap.touchedCount = touched

        // Deduped link pairs; mark one-way links.
        var seen: Set<Int> = []
        var pr: [MapLinkPair] = []
        pr.reserveCapacity(out.count * 3)
        var oneWay = 0
        for s in out {
            for t in s.links {
                guard let ti = idx[t] else { continue }
                let a = min(s.id, t), b = max(s.id, t)
                let key = a << 16 | b
                if !seen.insert(key).inserted { continue }
                let back = out[ti].links.contains(s.id)
                if !back { oneWay += 1 }
                pr.append(MapLinkPair(a: a, b: b, oneWay: !back))
            }
        }
        snap.pairs = pr
        snap.oneWayCount = oneWay

        if !out.isEmpty {
            var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for s in out { minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y) }
            snap.bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
    }

    private func install(_ s: MapSnapshot) {
        systems = s.systems; index = s.index; nebulae = s.nebulae; pairs = s.pairs
        govts = s.govts; govtColor = s.govtColor; bounds = s.bounds
        touchedCount = s.touchedCount; oneWayCount = s.oneWayCount
    }

    // MARK: Incremental patch (main, tiny edits only)

    /// Diff the effective collection against what the snapshot was decoded
    /// from and patch just the changed systems / nebulae. Returns false when
    /// the change needs the full off-main rebuild (government edits, bulk edits).
    private func patch(_ doc: PluginDocument) -> Bool {
        let eff = doc.effective
        let govtNow = eff.byType[NovaType.govt] ?? [:]
        guard govtNow == snapshot.govtRes else { return false }

        let layer = doc.layer, base = doc.base
        var snap = snapshot
        var changed = false

        let nebuNow = eff.byType[NovaType.nebula] ?? [:]
        if nebuNow != snap.nebuRes {
            guard nebuNow.count < 400 else { return false }
            snap.nebuRes = nebuNow
            snap.nebulae = nebuNow.values.sorted(by: { $0.id < $1.id }).map { Self.nebula($0, layer: layer, base: base) }
            changed = true
        }

        let systNow = eff.byType[NovaType.syst] ?? [:]
        var dirty: [Resource] = []
        for (id, r) in systNow {
            if let o = snap.systRes[id], o.data == r.data, o.name == r.name, o.pluginID == r.pluginID { continue }
            dirty.append(r)
            if dirty.count > Self.patchLimit { return false }
        }
        var removed: [Int] = []
        for id in snap.systRes.keys where systNow[id] == nil { removed.append(id) }
        if dirty.count + removed.count > Self.patchLimit { return false }

        if !dirty.isEmpty || !removed.isEmpty {
            var structural = !removed.isEmpty
            for r in dirty {
                let rec = Self.system(r, layer: layer, base: base)
                if let i = snap.index[r.id] { snap.systems[i] = rec }
                else { snap.systems.append(rec); structural = true }
            }
            if !removed.isEmpty {
                let gone = Set(removed)
                snap.systems.removeAll { gone.contains($0.id) }
            }
            if structural { snap.systems.sort { $0.id < $1.id } }
            snap.systRes = systNow
            Self.finish(&snap)
            changed = true
        }

        publishPatch(snap, changed: changed, eff: eff)
        return true
    }

    private func publishPatch(_ snap: MapSnapshot, changed: Bool, eff: ResourceCollection) {
        if changed {
            snapshot = snap
            install(snap)
            version &+= 1
            objectWillChange.send()
        }
        // Cheap lookups only; PICT decodes happen detached.
        refreshNebulaImages(eff)
    }

    // MARK: Nebula art

    /// Nebula `n` (id − 128) draws PICT `9502 + 7n`, falling back to the next
    /// two lower ids. Lookups are dictionary hits; decoding runs off-main.
    private func refreshNebulaImages(_ eff: ResourceCollection) {
        for n in nebulae {
            let base = 9502 + 7 * (n.id - 128)
            var data: Data?
            for pid in [base, base - 1, base - 2] {
                if let d = eff.resource(NovaType.pict, pid)?.data { data = d; break }
            }
            guard let data else { nebulaImagesRemove(n.id); continue }
            if imageKeys[n.id] == data.count, nebulaImages[n.id] != nil { continue }
            if loadingImages.contains(n.id) { continue }
            loadingImages.insert(n.id)
            let id = n.id, size = data.count
            Task.detached(priority: .utility) { [weak self] in
                let img = PICT.decodeLogged(data, id: id)?.makeCGImage()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loadingImages.remove(id)
                    if let img {
                        self.nebulaImages[id] = img
                        self.imageKeys[id] = size
                    }
                }
            }
        }
    }

    private func nebulaImagesRemove(_ id: Int) {
        if nebulaImages[id] != nil { nebulaImages[id] = nil; imageKeys[id] = nil }
    }

    // MARK: Hit testing

    func systemAt(screen p: CGPoint, vp: MapViewport, size: CGSize, radius: CGFloat, moving: (Set<Int>, CGSize)? = nil) -> Int? {
        var best: (Int, CGFloat)?
        let r2 = radius * radius
        for s in systems {
            var w = s.point
            if let (ids, d) = moving, ids.contains(s.id) { w.x += d.width; w.y += d.height }
            let sp = vp.toScreen(w, size)
            let dx = sp.x - p.x, dy = sp.y - p.y
            let d2 = dx * dx + dy * dy
            if d2 <= r2, d2 < (best?.1 ?? .infinity) { best = (s.id, d2) }
        }
        return best?.0
    }

    func linkAt(screen p: CGPoint, vp: MapViewport, size: CGSize, tolerance: CGFloat) -> MapLinkPair? {
        var best: (MapLinkPair, CGFloat)?
        for l in pairs {
            guard let ai = index[l.a], let bi = index[l.b] else { continue }
            let a = vp.toScreen(systems[ai].point, size), b = vp.toScreen(systems[bi].point, size)
            let d = Self.distance(p, a, b)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (l, d) }
        }
        return best?.0
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let l2 = abx * abx + aby * aby
        var t: CGFloat = l2 == 0 ? 0 : ((p.x - a.x) * abx + (p.y - a.y) * aby) / l2
        t = min(1, max(0, t))
        let cx = a.x + t * abx, cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    func nearest(to id: Int, count: Int, excluding: Set<Int>) -> [MapSystem] {
        guard let s = system(id) else { return [] }
        // Squared distances computed once (no per-comparison hypot), then ranked.
        var scored: [(d: CGFloat, i: Int)] = []
        scored.reserveCapacity(systems.count)
        for (i, o) in systems.enumerated() where o.id != id && !excluding.contains(o.id) {
            let dx = o.x - s.x, dy = o.y - s.y
            scored.append((dx * dx + dy * dy, i))
        }
        scored.sort { $0.d < $1.d }
        return scored.prefix(count).map { systems[$0.i] }
    }
}
#endif
