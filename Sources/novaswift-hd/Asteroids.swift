import Foundation
import NovaSwiftHD
import SceneKit
import simd

/// Procedural asteroids: a noise-displaced, cratered, slightly elongated rock
/// with a matching surface texture, tinted to a classic sprite's colours.
/// Deterministic: the same seed always makes the same rock.
enum AsteroidMaker {
    /// rock: jagged, matte (metal ores) · ice: faceted, glossy · pitted: many deep holes (silicates)
    enum Style: String { case rock, ice, pitted }

    static func make(seed: UInt64, tint: SIMD3<Double>, style: Style = .rock, textureURL: URL) -> SCNScene? {
        let noise = Noise3(seed: seed)
        var rng = SplitMix(seed &+ 77)
        let stretch = SIMD3(rng.range(1.0, 1.35), rng.range(0.75, 0.95), rng.range(0.85, 1.1))
        let craterCount = style == .pitted ? 70 : 14
        let craterSize = style == .pitted ? (0.08, 0.22) : (0.12, 0.38)
        let craterDepth = style == .pitted ? 0.35 : 0.09
        let craters: [(SIMD3<Double>, Double)] = (0..<craterCount).map { _ in
            (simd_normalize(SIMD3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1))),
             rng.range(craterSize.0, craterSize.1))
        }
        let jag = style == .ice ? 0.16 : 0.11
        // Height at a unit-sphere direction: lumps + ridges + bowl craters with raised rims.
        func crater(_ d: SIMD3<Double>) -> Double {
            var h = 0.0
            for (c, r) in craters {
                let t = acos(max(-1, min(1, simd_dot(d, c)))) / r
                if t < 1 { h -= craterDepth * r * (1 - t * t) }                 // bowl
                else if t < 1.3 { h += 0.02 * r * sin((t - 1) / 0.3 * .pi) }   // rim
            }
            return h
        }
        // Chunky silhouette: the rock is a random convex polyhedron (cut planes)
        // before the noise roughens it, so it reads angular, not pillowy.
        let planes: [(SIMD3<Double>, Double)] = (0..<(style == .ice ? 30 : 26)).map { _ in
            (simd_normalize(SIMD3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1))), rng.range(0.86, 1.0))
        }
        func facet(_ d: SIMD3<Double>) -> Double {
            var r = 1.25
            for (n, o) in planes { let c = simd_dot(d, n); if c > 0.05 { r = min(r, o / c) } }
            return r - 1
        }
        func height(_ d: SIMD3<Double>) -> Double {
            0.7 * facet(d) + 0.16 * noise.fbm(d * 1.3, octaves: 3) + jag * noise.ridged(d * 3.0, octaves: 4)
                + 0.035 * noise.fbm(d * 9, octaves: 3) + crater(d)
        }

        // Ice reads as faceted: a coarser mesh with flat-ish facets.
        let rings = style == .ice ? 28 : 72, segs = style == .ice ? 56 : 144
        var pos: [SCNVector3] = [], uv: [CGPoint] = [], idx: [UInt32] = []
        var p3: [SIMD3<Double>] = []
        for r in 0...rings {
            let v = Double(r) / Double(rings), phi = v * .pi
            for s in 0...segs {
                let u = Double(s) / Double(segs), th = u * 2 * .pi
                let d = SIMD3(-sin(phi) * sin(th), cos(phi), -sin(phi) * cos(th))
                let p = d * (1 + height(d)) * stretch
                p3.append(p)
                pos.append(SCNVector3(SCNScalar(p.x), SCNScalar(p.y), SCNScalar(p.z)))
                uv.append(CGPoint(x: u, y: v))
            }
        }
        for r in 0..<rings {
            for s in 0..<segs {
                let a = UInt32(r * (segs + 1) + s), b = a + 1, c = a + UInt32(segs + 1), d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        // Smooth normals from the displaced faces; the seam column is welded.
        var nrm = [SIMD3<Double>](repeating: .zero, count: p3.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let n = simd_cross(p3[b] - p3[a], p3[c] - p3[a])
            nrm[a] += n; nrm[b] += n; nrm[c] += n
        }
        for r in 0...rings {
            let first = r * (segs + 1), last = first + segs
            let n = nrm[first] + nrm[last]; nrm[first] = n; nrm[last] = n
        }
        let normals = nrm.map { n -> SCNVector3 in
            let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            return SCNVector3(SCNScalar(u.x), SCNScalar(u.y), SCNScalar(u.z))
        }

        guard let tex = texture(noise: noise, tint: tint, contrast: style == .ice ? 0.8 : 1.7, crater: crater),
              let png = HDAtlas.encodePNG(tex), (try? png.write(to: textureURL)) != nil else { return nil }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: normals),
                                        SCNGeometrySource(textureCoordinates: uv)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = textureURL
        m.metalness.contents = NSNumber(value: style == .ice ? 0.35 : 0.05)
        m.roughness.contents = NSNumber(value: style == .ice ? 0.32 : 0.9)
        geo.materials = [m]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geo))
        return scene
    }

    /// Equirectangular albedo: tinted grit and strata, darker crater floors.
    private static func texture(noise: Noise3, tint: SIMD3<Double>, contrast: Double,
                                crater: (SIMD3<Double>) -> Double) -> CGImage? {
        let w = 1024, h = 512
        guard let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let bpr = ctx.bytesPerRow
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let phi = (Double(y) + 0.5) / Double(h) * .pi
            for x in 0..<w {
                let th = (Double(x) + 0.5) / Double(w) * 2 * .pi
                let d = SIMD3(-sin(phi) * sin(th), cos(phi), -sin(phi) * cos(th))
                // Coarse light/dark mottling plus fine speckle, like the classic art.
                let mottle = noise.fbm(d * 7, octaves: 4)
                let grit = noise.fbm(d * 26, octaves: 3)
                let speck = noise.noise(d * 90)
                let cavity = max(0, -crater(d)) * 14
                let shade = 0.72 + contrast * (0.75 * mottle + 0.30 * grit + 0.22 * speck)
                    - min(0.7, cavity)
                let c = simd_clamp(tint * shade, SIMD3(repeating: 0), SIMD3(repeating: 1))
                // The context's rows run bottom-up.
                let o = (h - 1 - y) * bpr + x * 4
                px[o] = UInt8(c.x * 255); px[o + 1] = UInt8(c.y * 255); px[o + 2] = UInt8(c.z * 255); px[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }
}
