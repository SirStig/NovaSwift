import Foundation
import SceneKit
import NovaSwiftHD
import simd

/// Physically-based materials for the demo ships, with procedurally painted
/// hull textures (albedo, roughness, normal) written as PNGs so the USDZ
/// exporter packs them into the model.
struct MaterialKit {
    let textureDir: URL

    init(textureDir: URL) {
        self.textureDir = textureDir
        try? FileManager.default.createDirectory(at: textureDir, withIntermediateDirectories: true)
    }

    struct Paint {
        var base: SIMD3<Double>          // albedo, 0…1
        var variation: Double = 0.07     // per-panel brightness spread
        var seam: Double = 0.45          // seam darkness multiplier
        var panelSize: Int = 64          // smallest panel, texels
        var metalness: Double = 0.65
        var roughness: Double = 0.42
        var seed: UInt64 = 1
    }

    /// Hull plating: random rectangular panels, recessed seams, a few
    /// hatches and rivet rows, light grime.
    func hull(_ name: String, _ paint: Paint) -> SCNMaterial {
        let size = 512
        var rng = SplitMix(paint.seed)
        var height = [Double](repeating: 1, count: size * size)
        var shade = [Double](repeating: 1, count: size * size)
        var rough = [Double](repeating: paint.roughness, count: size * size)

        func split(_ x: Int, _ y: Int, _ w: Int, _ h: Int, depth: Int) {
            if (w <= paint.panelSize * 2 && h <= paint.panelSize * 2) || depth > 6 || (depth > 2 && rng.unit() < 0.18) {
                let s = 1 + rng.range(-paint.variation, paint.variation)
                let r = paint.roughness + rng.range(-0.08, 0.1)
                let hatch = rng.unit() < 0.12 && w > 40 && h > 40
                for yy in y..<(y + h) {
                    for xx in x..<(x + w) {
                        let i = yy * size + xx
                        shade[i] = s; rough[i] = r
                        let edge = min(xx - x, yy - y, x + w - 1 - xx, y + h - 1 - yy)
                        if edge < 2 { height[i] = 0.0 }
                        else if edge < 3 { height[i] = 0.6 }
                        if hatch {
                            let he = min(xx - x - 10, yy - y - 10, x + w - 11 - xx, y + h - 11 - yy)
                            if he == 0 { height[i] = 0.3 }
                        }
                    }
                }
                if w > 30 && rng.unit() < 0.5 {
                    for xx in stride(from: x + 5, to: x + w - 4, by: 8) where y + 5 < size {
                        height[(y + 5) * size + xx] = 1.25
                    }
                }
                return
            }
            if w >= h {
                let cut = max(paint.panelSize, min(w - paint.panelSize, Int(Double(w) * rng.range(0.3, 0.7))))
                split(x, y, cut, h, depth: depth + 1); split(x + cut, y, w - cut, h, depth: depth + 1)
            } else {
                let cut = max(paint.panelSize, min(h - paint.panelSize, Int(Double(h) * rng.range(0.3, 0.7))))
                split(x, y, w, cut, depth: depth + 1); split(x, y + cut, w, h - cut, depth: depth + 1)
            }
        }
        split(0, 0, size, size, depth: 0)

        let noise = Noise3(seed: paint.seed &+ 99)
        var albedo = [UInt8](repeating: 255, count: size * size * 4)
        var roughPx = [UInt8](repeating: 255, count: size * size * 4)
        var normalPx = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x
                // Tileable grime: noise sampled on a torus.
                let u = Double(x) / Double(size) * 2 * .pi, v = Double(y) / Double(size) * 2 * .pi
                let p = SIMD3(cos(u) * 1.6, sin(u) * 1.6 + cos(v) * 1.6, sin(v) * 1.6)
                let grime = 0.92 + 0.08 * noise.fbm(p, octaves: 4)
                let seamDark = height[i] < 0.5 ? paint.seam : 1
                let k = shade[i] * grime * seamDark
                albedo[i * 4] = UInt8(min(255, max(0, paint.base.x * k * 255)))
                albedo[i * 4 + 1] = UInt8(min(255, max(0, paint.base.y * k * 255)))
                albedo[i * 4 + 2] = UInt8(min(255, max(0, paint.base.z * k * 255)))
                let rv = min(1, max(0, rough[i] + (1 - grime) * 0.8))
                roughPx[i * 4] = UInt8(rv * 255); roughPx[i * 4 + 1] = UInt8(rv * 255); roughPx[i * 4 + 2] = UInt8(rv * 255)
                let hl = height[y * size + (x + size - 1) % size], hr = height[y * size + (x + 1) % size]
                let hd = height[((y + size - 1) % size) * size + x], hu = height[((y + 1) % size) * size + x]
                let n = simd_normalize(SIMD3((hl - hr) * 1.5, (hd - hu) * 1.5, 1.0))
                normalPx[i * 4] = UInt8((n.x * 0.5 + 0.5) * 255)
                normalPx[i * 4 + 1] = UInt8((n.y * 0.5 + 0.5) * 255)
                normalPx[i * 4 + 2] = UInt8((n.z * 0.5 + 0.5) * 255)
            }
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = write(albedo, size, "\(name)_albedo.png")
        m.roughness.contents = write(roughPx, size, "\(name)_roughness.png")
        m.normal.contents = write(normalPx, size, "\(name)_normal.png")
        m.metalness.contents = NSNumber(value: paint.metalness)
        for p in [m.diffuse, m.roughness, m.normal] { p.wrapS = .repeat; p.wrapT = .repeat }
        m.name = name
        return m
    }

    /// A plain physically-based material.
    func solid(_ name: String, color: SIMD3<Double>, metalness: Double, roughness: Double,
               emission: SIMD3<Double>? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: 1)
        m.metalness.contents = NSNumber(value: metalness)
        m.roughness.contents = NSNumber(value: roughness)
        if let e = emission { m.emission.contents = NSColor(srgbRed: e.x, green: e.y, blue: e.z, alpha: 1) }
        m.name = name
        return m
    }

    func glow(_ name: String, _ c: SIMD3<Double>) -> SCNMaterial {
        solid(name, color: SIMD3(0.02, 0.02, 0.02), metalness: 0, roughness: 1, emission: c)
    }

    private func write(_ px: [UInt8], _ size: Int, _ file: String) -> URL {
        let url = textureDir.appendingPathComponent(file)
        let ctx = HDAtlas.makeContext(width: size, height: size)!
        let dst = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
        for y in 0..<size {
            for x in 0..<size {
                let s = (y * size + x) * 4, d = y * ctx.bytesPerRow + x * 4
                dst[d] = px[s]; dst[d + 1] = px[s + 1]; dst[d + 2] = px[s + 2]; dst[d + 3] = 255
            }
        }
        try? HDAtlas.encodePNG(ctx.makeImage()!)?.write(to: url)
        return url
    }
}
