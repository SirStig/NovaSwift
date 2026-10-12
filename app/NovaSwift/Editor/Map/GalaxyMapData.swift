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

@MainActor
final class GalaxyMapData: ObservableObject {
    private(set) var systems: [MapSystem] = []
    private(set) var index: [Int: Int] = [:]
    private(set) var nebulae: [MapNebulaRec] = []
    private(set) var pairs: [MapLinkPair] = []
    private(set) var govts: [MapGovt] = []
    private(set) var govtColor: [Int: Color] = [:]
    private(set) var bounds = CGRect(x: -200, y: -200, width: 400, height: 400)
    @Published private(set) var nebulaImages: [Int: CGImage] = [:]
    @Published private(set) var version = 0

    private var lastRevision = -1
    private var loadingImages: Set<Int> = []
    private var imageKeys: [Int: Int] = [:]   // nebula id → pict byte count it was decoded from

    static let relevant: Set<NovaSwiftKit.FourCharCode> = [NovaType.syst, NovaType.nebula, NovaType.govt, NovaType.pict]

    static let independent = Color(white: 0.62)

    func system(_ id: Int) -> MapSystem? { index[id].map { systems[$0] } }
    func color(_ govt: Int) -> Color { govtColor[govt] ?? Self.independent }
    func govtName(_ id: Int) -> String {
        id < 128 ? "Independent" : (govts.first { $0.id == id }?.name ?? "Govt \(id)")
    }

    /// Refresh from the model if needed. Cheap when nothing relevant changed.
    func refresh(_ model: EditorModel, force: Bool = false) {
        let rev = model.revision
        if !force, rev == lastRevision { return }
        if !force, lastRevision >= 0, rev == lastRevision + 1,
           model.lastChanged.allSatisfy({ !Self.relevant.contains($0.type) }) {
            lastRevision = rev
            return
        }
        lastRevision = rev
        rebuild(model)
    }

    private func rebuild(_ model: EditorModel) {
        let doc = model.document
        let eff = doc.effective
        let game = NovaGame(eff)

        // Governments + colours (authentic mapColor via GovernmentPalette).
        let palette = GovernmentPalette(game: game)
        var gl: [MapGovt] = []
        var colors: [Int: Color] = [:]
        for g in game.govts().sorted(by: { $0.id < $1.id }) {
            let c = palette.color(for: g.id)
            colors[g.id] = c
            gl.append(MapGovt(id: g.id, name: g.name.isEmpty ? "Govt \(g.id)" : g.name, color: c))
        }
        govtColor = colors

        var out: [MapSystem] = []
        out.reserveCapacity(1600)
        var idx: [Int: Int] = [:]
        for r in eff.resources(of: NovaType.syst) {
            let s = SystRes(r)
            idx[r.id] = out.count
            out.append(MapSystem(id: r.id, name: s.name, x: CGFloat(s.x), y: CGFloat(s.y), govt: s.government,
                                 links: s.links, spobCount: s.spobs.count,
                                 provenance: doc.provenance(NovaType.syst, r.id) ?? .base))
        }
        systems = out
        index = idx

        var counts: [Int: Int] = [:]
        for s in out where s.govt >= 128 { counts[s.govt, default: 0] += 1 }
        for i in gl.indices { gl[i].count = counts[gl[i].id] ?? 0 }
        govts = gl

        // Deduped link pairs; mark one-way links.
        var seen: Set<Int> = []
        var pr: [MapLinkPair] = []
        pr.reserveCapacity(out.count * 3)
        for s in out {
            for t in s.links {
                guard let ti = idx[t] else { continue }
                let a = min(s.id, t), b = max(s.id, t)
                let key = a << 16 | b
                if !seen.insert(key).inserted { continue }
                let back = systems[ti].links.contains(s.id)
                pr.append(MapLinkPair(a: a, b: b, oneWay: !back))
            }
        }
        pairs = pr

        nebulae = eff.resources(of: NovaType.nebula).map { r in
            let n = NebuRes(r)
            return MapNebulaRec(id: r.id, name: r.name.isEmpty ? "Nebula \(r.id)" : r.name,
                                rect: CGRect(x: n.x, y: n.y, width: max(1, n.width), height: max(1, n.height)),
                                provenance: doc.provenance(NovaType.nebula, r.id) ?? .base)
        }

        if !out.isEmpty {
            var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for s in out { minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y) }
            bounds = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
        loadNebulaImages(eff)
        version &+= 1
        objectWillChange.send()
    }

    private func loadNebulaImages(_ eff: ResourceCollection) {
        let game = NovaGame(eff)
        for n in nebulae {
            let base = game.nebulaImageID(index: n.id - 128)
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
        return systems.filter { $0.id != id && !excluding.contains($0.id) }
            .sorted { hypot($0.x - s.x, $0.y - s.y) < hypot($1.x - s.x, $1.y - s.y) }
            .prefix(count).map { $0 }
    }
}
#endif
