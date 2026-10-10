import Foundation
import CoreGraphics
import NovaSwiftHD
import simd

/// The demo pack's planets: painted procedurally, pixel by pixel, as lit
/// spheres in the classic stellar style (key light upper left, soft
/// terminator, atmosphere rim). Original noise-generated surfaces; only the
/// type, palette and size follow the planet each one stands in for.
enum PlanetPainter {
    enum Kind {
        case oceanic(ocean: SIMD3<Double>, land: SIMD3<Double>, highland: SIMD3<Double>, seaLevel: Double)
        case cloudy(ocean: SIMD3<Double>, land: SIMD3<Double>)
        case desert(low: SIMD3<Double>, high: SIMD3<Double>)
        case gasGiant(bands: [SIMD3<Double>])
    }

    struct Style {
        var kind: Kind
        var atmosphere: SIMD3<Double>
        var atmosphereStrength = 1.0
        var clouds = 0.5          // cloud cover 0…1
        var seed: UInt64
        var tilt = 0.35           // axial tilt, radians
    }

    /// Paint one frame `width`×`height` px with the planet's disc of `radius` px centred.
    static func paint(_ style: Style, width: Int, height: Int, radius: Double) -> CGImage? {
        guard let ctx = HDAtlas.makeContext(width: width, height: height), let raw = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let px = raw.bindMemory(to: UInt8.self, capacity: stride * height)
        nonisolated(unsafe) let out = px
        let noise = Noise3(seed: style.seed), cloudNoise = Noise3(seed: style.seed &+ 7)
        let light = simd_normalize(SIMD3<Double>(-0.62, 0.55, 0.56))
        let cx = Double(width) / 2, cy = Double(height) / 2
        let ct = cos(style.tilt), st = sin(style.tilt)
        let halo = radius * 1.06

        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                var acc = SIMD4<Double>(0, 0, 0, 0)    // premultiplied rgba, 2×2 supersampled
                for sy in 0..<2 { for sx in 0..<2 {
                    let fx = (Double(x) + 0.25 + 0.5 * Double(sx) - cx) / radius
                    let fy = (cy - (Double(y) + 0.25 + 0.5 * Double(sy))) / radius
                    let d2 = fx * fx + fy * fy
                    if d2 > 1 {
                        // Atmosphere halo just outside the limb, brighter on the lit side.
                        let d = sqrt(d2) * radius
                        guard d < halo else { continue }
                        let t = 1 - (d - radius) / (halo - radius)
                        let lit = max(0, simd_dot(simd_normalize(SIMD3(fx, fy, 0)), light) * 0.8 + 0.35)
                        let a = pow(t, 2.2) * 0.55 * lit * style.atmosphereStrength
                        acc += SIMD4(style.atmosphere * a, a)
                        continue
                    }
                    let n = SIMD3(fx, fy, sqrt(1 - d2))
                    // Surface coordinates: the normal turned by the axial tilt.
                    let p = SIMD3(n.x * ct - n.y * st, n.x * st + n.y * ct, n.z)
                    var albedo: SIMD3<Double>
                    var spec = 0.0
                    switch style.kind {
                    case let .oceanic(ocean, land, high, sea):
                        let h = noise.fbm(p * 1.8, octaves: 7)
                        if h < sea {
                            albedo = ocean * (0.75 + 0.35 * (h - sea + 0.5)); spec = 0.55
                        } else {
                            let t = min(1, (h - sea) / 0.35)
                            albedo = land * (1 - t) + high * t
                            albedo *= 0.85 + 0.3 * noise.fbm(p * 9, octaves: 3)
                        }
                        if abs(p.y) > 0.86 { albedo = albedo * 0.3 + SIMD3(0.88, 0.92, 0.95) * 0.7 }   // ice caps
                    case let .cloudy(ocean, land):
                        let h = noise.fbm(p * 1.6, octaves: 6)
                        albedo = h < 0.05 ? ocean : land * (0.8 + 0.4 * h)
                        spec = h < 0.05 ? 0.4 : 0
                    case let .desert(low, high):
                        let r = noise.ridged(p * 2.4, octaves: 6)
                        let h = noise.fbm(p * 1.3, octaves: 5) * 0.5 + 0.5
                        albedo = low * (1 - h) + high * h
                        albedo *= 0.75 + 0.5 * r
                    case let .gasGiant(bands):
                        let warp = noise.fbm(p * SIMD3(2.0, 6.0, 2.0), octaves: 5) * 0.12
                        let lat = p.y + warp + 0.02 * noise.fbm(p * 24, octaves: 3)
                        let f = (lat * 0.5 + 0.5) * Double(bands.count) * 2.3
                        let i = Int(floor(f)), t = f - floor(f)
                        let a = bands[((i % bands.count) + bands.count) % bands.count]
                        let b = bands[(((i + 1) % bands.count) + bands.count) % bands.count]
                        let s = t * t * (3 - 2 * t)
                        albedo = a * (1 - s) + b * s
                        albedo *= 0.88 + 0.24 * noise.fbm(p * SIMD3(3, 14, 3), octaves: 4)
                    }
                    // Clouds (swirled by domain warping), with a soft shadow on the ground.
                    var cloud = 0.0
                    if style.clouds > 0 {
                        let w = SIMD3(cloudNoise.fbm(p * 2.2, octaves: 3), cloudNoise.fbm(p * 2.2 + 5.2, octaves: 3), 0)
                        let c = cloudNoise.fbm(p * 2.6 + w * 1.4, octaves: 6)
                        cloud = min(1, max(0, (c - (0.42 - style.clouds * 0.6)) * 2.6))
                    }
                    let ndl = simd_dot(n, light)
                    let diffuse = max(0, min(1, (ndl + 0.08) / 1.08))
                    let soft = diffuse * diffuse * (3 - 2 * diffuse)
                    var col = albedo * (1 - cloud * 0.35) * soft
                    col = col * (1 - cloud) + SIMD3(0.95, 0.96, 0.98) * cloud * soft
                    if spec > 0 && cloud < 0.5 {
                        let h = simd_normalize(light + SIMD3(0, 0, 1))
                        col += SIMD3(1, 0.97, 0.9) * pow(max(0, simd_dot(n, h)), 40) * spec * (1 - cloud)
                    }
                    // Atmosphere: rim scattering on the lit side, faint on the dark side.
                    let rim = pow(1 - n.z, 2.6)
                    col += style.atmosphere * rim * (0.25 + 0.9 * max(0, ndl + 0.2)) * style.atmosphereStrength
                    col += style.atmosphere * 0.06 * soft * style.atmosphereStrength
                    // Limb antialiasing.
                    let edge = min(1, (1 - sqrt(d2)) * radius * 2)
                    acc += SIMD4(simd_clamp(col, SIMD3(0, 0, 0), SIMD3(1, 1, 1)) * edge, edge)
                }}
                acc /= 4
                let i = y * stride + x * 4
                out[i] = UInt8(min(255, acc.x * 255)); out[i + 1] = UInt8(min(255, acc.y * 255))
                out[i + 2] = UInt8(min(255, acc.z * 255)); out[i + 3] = UInt8(min(255, acc.w * 255))
            }
        }
        return ctx.makeImage()
    }
}
