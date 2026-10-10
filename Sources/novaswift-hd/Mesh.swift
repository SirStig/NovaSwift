import Foundation
import SceneKit
import simd

typealias V3 = SIMD3<Float>
typealias V2 = SIMD2<Float>

/// A minimal hard-surface modelling kit for the demo ships. Every shape is
/// appended as flat-shaded triangles with tri-planar UVs (so one tiling
/// panel texture wraps any part without seams that matter at sprite size).
/// Each builder becomes one single-element `SCNGeometry`: Apple's USDZ
/// exporter wants exactly one material per element.
final class Mesh {
    private(set) var positions: [V3] = []
    private(set) var normals: [V3] = []
    private(set) var uvs: [V2] = []
    /// World units per texture repeat.
    var uvScale: Float = 0.5

    var isEmpty: Bool { positions.isEmpty }

    /// The centre of the part being built; faces are flipped to point away
    /// from it, so winding mistakes can't turn a face inside out.
    private var outwardFrom: V3?

    func part(center: V3, _ build: () -> Void) {
        let saved = outwardFrom
        outwardFrom = center
        build()
        outwardFrom = saved
    }

    func triangle(_ a: V3, _ b: V3, _ c: V3) {
        var b = b, c = c
        var n0 = simd_cross(b - a, c - a)
        guard simd_length(n0) > 1e-9 else { return }
        if let o = outwardFrom, simd_dot(n0, (a + b + c) / 3 - o) < 0 { swap(&b, &c); n0 = -n0 }
        let n = simd_normalize(n0)
        let ax = abs(n)
        for p in [a, b, c] {
            positions.append(p); normals.append(n)
            let uv: V2 = ax.y >= ax.x && ax.y >= ax.z ? V2(p.x, p.z) : ax.x >= ax.z ? V2(p.z, p.y) : V2(p.x, p.y)
            uvs.append(uv / uvScale)
        }
    }

    /// A planar quad, wound a→b→c→d (counter-clockwise seen from outside).
    func quad(_ a: V3, _ b: V3, _ c: V3, _ d: V3) {
        triangle(a, b, c); triangle(a, c, d)
    }

    /// A convex polygon, wound counter-clockwise seen from outside.
    func polygon(_ pts: [V3]) {
        guard pts.count >= 3 else { return }
        for i in 1..<(pts.count - 1) { triangle(pts[0], pts[i], pts[i + 1]) }
    }

    /// Skin a series of cross-sections (each a closed loop, same point count,
    /// wound counter-clockwise looking toward +Z), capping both ends.
    func loft(_ sections: [[V3]], capStart: Bool = true, capEnd: Bool = true) {
        guard sections.count >= 2, let n = sections.first?.count, n >= 3 else { return }
        let saved = outwardFrom
        func centre(_ ring: [V3]) -> V3 { ring.reduce(V3(0, 0, 0), +) / Float(ring.count) }
        for s in 0..<(sections.count - 1) {
            let a = sections[s], b = sections[s + 1]
            outwardFrom = (centre(a) + centre(b)) / 2
            for i in 0..<n {
                let j = (i + 1) % n
                quad(a[i], a[j], b[j], b[i])
            }
        }
        let mid = centre(sections.flatMap { $0 })
        outwardFrom = mid
        if capStart { polygon(sections[0].reversed()) }
        if capEnd { polygon(sections[sections.count - 1]) }
        outwardFrom = saved
    }

    /// A slab: a convex outline in the XZ plane (counter-clockwise seen from
    /// above), between heights y0 and y1, with its top edge bevelled inward
    /// by `bevel`.
    func slab(_ outline: [V2], y0: Float, y1: Float, bevel: Float = 0) {
        let c = outline.reduce(V2(0, 0), +) / Float(outline.count)
        let inset = outline.map { p -> V2 in
            let d = c - p; let l = simd_length(d)
            return l > bevel ? p + d / l * bevel : p
        }
        let saved = outwardFrom
        outwardFrom = V3(c.x, (y0 + y1) / 2, c.y)
        defer { outwardFrom = saved }
        let yb = y1 - bevel
        let bottom = outline.map { V3($0.x, y0, $0.y) }
        let mid = outline.map { V3($0.x, yb, $0.y) }
        let top = inset.map { V3($0.x, y1, $0.y) }
        polygon(top.reversed())
        polygon(bottom)
        let n = outline.count
        for i in 0..<n {
            let j = (i + 1) % n
            quad(bottom[i], bottom[j], mid[j], mid[i])
            if bevel > 0 { quad(mid[i], mid[j], top[j], top[i]) }
        }
    }

    /// A vertical slab (fins, pylons): a convex outline in the ZY plane
    /// (points are (z, y)), extruded across x0…x1.
    func slabX(_ outline: [V2], x0: Float, x1: Float) {
        let c = outline.reduce(V2(0, 0), +) / Float(outline.count)
        let saved = outwardFrom
        outwardFrom = V3((x0 + x1) / 2, c.y, c.x)
        defer { outwardFrom = saved }
        let a = outline.map { V3(x0, $0.y, $0.x) }, b = outline.map { V3(x1, $0.y, $0.x) }
        polygon(a); polygon(b)
        for i in 0..<outline.count {
            let j = (i + 1) % outline.count
            quad(a[i], a[j], b[j], b[i])
        }
    }

    /// A vertical cylinder (turret bases, domes' collars).
    func cylinderY(x: Float, z: Float, y0: Float, y1: Float, r: Float, segments: Int = 14) {
        let ring = (0..<segments).map { i -> V2 in
            let a = Float(i) / Float(segments) * 2 * .pi
            return V2(x + cos(a) * r, z + sin(a) * r)
        }
        slab(ring, y0: y0, y1: y1)
    }

    /// An axis-aligned box.
    func box(center: V3, size: V3, bevel: Float = 0) {
        let h = size / 2
        slab([V2(center.x - h.x, center.z - h.z), V2(center.x - h.x, center.z + h.z),
              V2(center.x + h.x, center.z + h.z), V2(center.x + h.x, center.z - h.z)],
             y0: center.y - h.y, y1: center.y + h.y, bevel: bevel)
    }

    /// A cylinder along +Z from z0 to z1 (radii may differ — a cone or nozzle).
    func cylinderZ(x: Float, y: Float, z0: Float, z1: Float, r0: Float, r1: Float, segments: Int = 12,
                   capStart: Bool = true, capEnd: Bool = true) {
        func ring(_ z: Float, _ r: Float) -> [V3] {
            (0..<segments).map { i in
                let a = Float(i) / Float(segments) * 2 * .pi
                return V3(x + cos(a) * r, y + sin(a) * r, z)
            }
        }
        loft([ring(z0, r0), ring(z1, r1)], capStart: capStart, capEnd: capEnd)
    }

    /// A squashed dome (upper half by default).
    func dome(center: V3, scale: V3, rings: Int = 6, segments: Int = 14, lower: Bool = false) {
        func p(_ r: Int, _ s: Int) -> V3 {
            let phi = Float(r) / Float(rings) * (.pi / 2) * (lower ? -1 : 1)
            let th = Float(s) / Float(segments) * 2 * .pi
            return center + V3(cos(phi) * cos(th), sin(phi), cos(phi) * sin(th)) * scale
        }
        let saved = outwardFrom
        outwardFrom = center
        defer { outwardFrom = saved }
        for r in 0..<rings {
            for s in 0..<segments {
                let a = p(r, s), b = p(r, s + 1), c = p(r + 1, s + 1), d = p(r + 1, s)
                if lower { quad(a, b, c, d) } else { quad(a, d, c, b) }
            }
        }
    }

    /// Mirror everything built so far across X (model one side, mirror it).
    func mirrorX() {
        let n = positions.count
        for t in stride(from: 0, to: n, by: 3) {
            let a = positions[t], b = positions[t + 1], c = positions[t + 2]
            triangle(V3(-a.x, a.y, a.z), V3(-c.x, c.y, c.z), V3(-b.x, b.y, b.z))
        }
    }

    func geometry(_ material: SCNMaterial) -> SCNGeometry {
        let src = [
            SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }),
        ]
        let element = SCNGeometryElement(indices: (0..<positions.count).map { UInt32($0) }, primitiveType: .triangles)
        let g = SCNGeometry(sources: src, elements: [element])
        g.materials = [material]
        return g
    }

    func node(_ material: SCNMaterial, name: String) -> SCNNode {
        let n = SCNNode(geometry: geometry(material))
        n.name = name
        return n
    }
}
