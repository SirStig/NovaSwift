import Foundation
#if canImport(SceneKit)
import SceneKit
import simd

/// Fewer triangles for a model, for the lower "Model detail" settings.
///
/// Vertex clustering: the model's space is cut into a grid of cubes, every
/// vertex in a cube that faces roughly the same way and sits in the same
/// patch of its texture merges into one, and triangles that collapse are
/// dropped. Coarse, but fast, predictable and safe on any mesh: big shapes
/// and silhouettes survive, small detail goes first. Texture coordinates
/// take part in the grid, so vertices from different islands of a texture
/// atlas never merge (generated models cut their atlases into many small
/// islands; merging across them scrambles the texture).
///
/// Geometry it can't read safely (non-float attributes, skinned or morphed
/// meshes, non-triangle primitives) is left as it is.
public enum MeshSimplifier {
    /// Simplify every geometry under `root` in place. `cells` is how many
    /// grid cubes span the model's widest side: smaller = fewer triangles.
    /// Each simplified node gets new geometry; materials are kept.
    @discardableResult
    public static func simplify(_ root: SCNNode, cells: Int) -> (before: Int, after: Int) {
        let uvCells = Float(cells * 2)
        let (lo, hi) = root.boundingBox
        let extent = max(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
        guard cells > 0, extent > 0 else { return (0, 0) }
        let cell = extent / Float(cells)
        var before = 0, after = 0
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let count = triangleCount(g)
            before += count
            // Key vertices in the root's space, so one grid covers every part.
            let toRoot = simd_float4x4(node.convertTransform(SCNMatrix4Identity, to: root))
            if node.skinner == nil, node.morpher == nil,
               let s = simplified(g, toRoot: toRoot, cell: cell, uvCells: uvCells) {
                node.geometry = s
                after += triangleCount(s)
            } else {
                after += count
            }
        }
        return (before, after)
    }

    public static func triangleCount(_ g: SCNGeometry) -> Int {
        g.elements.reduce(0) { $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0) }
    }

    private struct Key: Hashable {
        var x: Int32, y: Int32, z: Int32, u: Int32, v: Int32, octant: Int8
    }

    static func simplified(_ g: SCNGeometry, toRoot: simd_float4x4, cell: Float, uvCells: Float) -> SCNGeometry? {
        let sources = g.sources
        guard let pk = sources.firstIndex(where: { $0.semantic == .vertex }),
              sources[pk].componentsPerVector >= 3, !g.elements.isEmpty else { return nil }
        for s in sources where !(s.usesFloatComponents && s.bytesPerComponent == 4) { return nil }
        // One index per corner shared by every source, or (USD face-varying
        // data) one index channel per source, in source order.
        let channels = g.elements[0].indicesChannelCount
        guard channels == 1 || channels == sources.count else { return nil }
        for e in g.elements where !(e.primitiveType == .triangles && (e.bytesPerIndex == 2 || e.bytesPerIndex == 4)
                                    && e.indicesChannelCount == channels) {
            return nil
        }
        if channels == 1 {
            let n = sources[pk].vectorCount
            for s in sources where s.vectorCount != n { return nil }
        }
        let data = sources.map(read)
        let comps = sources.map(\.componentsPerVector)
        let counts = sources.map(\.vectorCount)
        let nk = sources.firstIndex(where: { $0.semantic == .normal && $0.componentsPerVector >= 3 })
        let tk = sources.firstIndex(where: { $0.semantic == .texcoord && $0.componentsPerVector >= 2 })

        // Cluster each triangle corner: grid cube of its position + which way
        // it faces (octant), so hard edges and thin two-sided parts don't fold
        // into each other.
        var index: [Key: Int32] = [:]
        // Per cluster: every source's components summed (averaged at the end), and the member count.
        var acc: [[Float]] = sources.map { _ in [] }
        var members: [Float] = []
        var elements: [SCNGeometryElement] = []
        var before = 0, kept = 0
        var corner = [Int32](repeating: 0, count: sources.count)
        for e in g.elements {
            let idx = readIndices(e)
            let cornersInElement = e.primitiveCount * 3
            guard idx.count >= cornersInElement * channels else { return nil }
            before += e.primitiveCount
            var out: [UInt32] = []
            out.reserveCapacity(cornersInElement)
            var tri = [Int32](repeating: 0, count: 3)
            for t in 0..<e.primitiveCount {
                for v in 0..<3 {
                    let c = (t * 3 + v) * channels
                    for k in 0..<sources.count {
                        let i = Int(idx[c + (channels == 1 ? 0 : k)])
                        guard i < counts[k] else { return nil }
                        corner[k] = Int32(i)
                    }
                    let pi = Int(corner[pk]) * comps[pk]
                    let p = SIMD3(data[pk][pi], data[pk][pi + 1], data[pk][pi + 2])
                    let w = toRoot * SIMD4(p, 1)
                    var key = Key(x: Int32(clamping: Int((w.x / cell).rounded(.down))),
                                  y: Int32(clamping: Int((w.y / cell).rounded(.down))),
                                  z: Int32(clamping: Int((w.z / cell).rounded(.down))), u: 0, v: 0, octant: 0)
                    if let nk {
                        let ni = Int(corner[nk]) * comps[nk]
                        key.octant = (data[nk][ni] < 0 ? 1 : 0) | (data[nk][ni + 1] < 0 ? 2 : 0) | (data[nk][ni + 2] < 0 ? 4 : 0)
                    }
                    if let tk {
                        let ti = Int(corner[tk]) * comps[tk]
                        key.u = Int32(clamping: Int((data[tk][ti] * uvCells).rounded(.down)))
                        key.v = Int32(clamping: Int((data[tk][ti + 1] * uvCells).rounded(.down)))
                    }
                    let id: Int32
                    if let found = index[key] {
                        id = found
                        let j = Int(found)
                        for k in 0..<sources.count {
                            let c = comps[k], src = Int(corner[k]) * c
                            for q in 0..<c { acc[k][j * c + q] += data[k][src + q] }
                        }
                        members[j] += 1
                    } else {
                        id = Int32(members.count)
                        index[key] = id
                        for k in 0..<sources.count {
                            let c = comps[k], src = Int(corner[k]) * c
                            acc[k].append(contentsOf: data[k][src ..< src + c])
                        }
                        members.append(1)
                    }
                    tri[v] = id
                }
                // Triangles that collapsed to a line or a point go.
                if tri[0] != tri[1], tri[1] != tri[2], tri[0] != tri[2] {
                    out.append(UInt32(tri[0])); out.append(UInt32(tri[1])); out.append(UInt32(tri[2]))
                }
            }
            // Keep every element, even an emptied one, so materials stay matched by index.
            if out.isEmpty { out = [0, 0, 0] } else { kept += out.count / 3 }
            elements.append(SCNGeometryElement(data: out.withUnsafeBufferPointer { Data(buffer: $0) },
                                               primitiveType: .triangles, primitiveCount: out.count / 3,
                                               bytesPerIndex: 4))
        }
        guard kept > 0, Double(kept) < Double(before) * 0.9 else { return nil }   // not worth a new mesh

        // One vertex per cluster, every attribute averaged (normals renormalised).
        let m = members.count
        var newSources: [SCNGeometrySource] = []
        for (k, s) in sources.enumerated() {
            let c = comps[k]
            var out = acc[k]
            for j in 0..<m {
                for q in 0..<c { out[j * c + q] /= members[j] }
                if k == nk {
                    let v = SIMD3(out[j * c], out[j * c + 1], out[j * c + 2]), len = simd_length(v)
                    let u = len > 1e-6 ? v / len : SIMD3<Float>(0, 1, 0)
                    out[j * c] = u.x; out[j * c + 1] = u.y; out[j * c + 2] = u.z
                }
            }
            newSources.append(SCNGeometrySource(data: out.withUnsafeBufferPointer { Data(buffer: $0) },
                                                semantic: s.semantic, vectorCount: m, usesFloatComponents: true,
                                                componentsPerVector: c, bytesPerComponent: 4,
                                                dataOffset: 0, dataStride: c * 4))
        }
        let result = SCNGeometry(sources: newSources, elements: elements)
        result.materials = g.materials
        result.name = g.name
        return result
    }

    private static func read(_ s: SCNGeometrySource) -> [Float] {
        let n = s.vectorCount, c = s.componentsPerVector
        var out = [Float](repeating: 0, count: n * c)
        guard s.data.count >= s.dataOffset + max(0, n - 1) * s.dataStride + c * 4 else { return out }
        s.data.withUnsafeBytes { raw in
            if s.dataStride == c * 4 {   // tightly packed: one copy
                out.withUnsafeMutableBytes { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[s.dataOffset ..< s.dataOffset + n * c * 4]))
                }
                return
            }
            for i in 0..<n {
                let base = s.dataOffset + i * s.dataStride
                for k in 0..<c { out[i * c + k] = raw.loadUnaligned(fromByteOffset: base + k * 4, as: Float.self) }
            }
        }
        return out
    }

    private static func readIndices(_ e: SCNGeometryElement) -> [UInt32] {
        let count = e.data.count / e.bytesPerIndex
        var out = [UInt32](repeating: 0, count: count)
        e.data.withUnsafeBytes { raw in
            if e.bytesPerIndex == 4 {
                out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[0 ..< count * 4])) }
            } else {
                for i in 0..<count { out[i] = UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) }
            }
        }
        return out
    }
}
#endif
