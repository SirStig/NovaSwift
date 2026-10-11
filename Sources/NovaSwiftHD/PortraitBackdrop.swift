#if canImport(CoreGraphics)
import CoreGraphics
import simd

/// The coloured backdrop of EV Nova's shipyard pictures, behind HD portraits.
///
/// Each original picture sits on a gradient in its government's colour
/// (yellow, Federation blue, Auroran red, Polaris purple, Rebel green, pirate
/// grey) — it's how players told the factions apart at a glance. The gradient
/// is measured from the original picture's own border, which is always
/// backdrop, so every ship keeps exactly its own colour, plug-in art included.
public enum PortraitBackdrop {
    /// `portrait` (transparent) drawn over `classic`'s backdrop, at the
    /// portrait's size. nil when the classic picture can't be read.
    public static func composite(_ portrait: CGImage, over classic: CGImage) -> CGImage? {
        guard let fit = Gradient(measuring: classic) else { return nil }
        let w = portrait.width, h = portrait.height
        guard let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = fit.color(u: Double(x) / Double(max(1, w - 1)), v: Double(y) / Double(max(1, h - 1)))
                let i = y * ctx.bytesPerRow + x * 4
                p[i] = UInt8(c.x * 255); p[i + 1] = UInt8(c.y * 255); p[i + 2] = UInt8(c.z * 255); p[i + 3] = 255
            }
        }
        ctx.draw(portrait, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A linear colour ramp across the picture, `a + b·u + c·v` per channel
    /// (u, v in 0…1, in memory order), least-squares fitted to the border.
    struct Gradient {
        let coeffs: [SIMD3<Double>]   // per channel: constant, u, v

        init?(measuring image: CGImage) {
            let w = image.width, h = image.height
            guard w > 8, h > 8, let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
            let ring = max(3, min(w, h) / 25)
            var samples: [(basis: SIMD3<Double>, color: SIMD3<Double>)] = []
            for y in 0..<h {
                for x in 0..<w where x < ring || y < ring || x >= w - ring || y >= h - ring {
                    let i = y * ctx.bytesPerRow + x * 4
                    samples.append((SIMD3(1, Double(x) / Double(w - 1), Double(y) / Double(h - 1)),
                                    SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])) / 255))
                }
            }
            guard var fit = Self.solve(samples) else { return nil }
            // A ship that reaches the edge isn't backdrop: refit without the
            // border pixels the first ramp doesn't explain.
            let kept = samples.filter { simd_length($0.color - Self.eval(fit, $0.basis)) < 0.12 }
            if kept.count > samples.count / 2, let refit = Self.solve(kept) { fit = refit }
            coeffs = fit
        }

        func color(u: Double, v: Double) -> SIMD3<Double> {
            simd_clamp(Self.eval(coeffs, SIMD3(1, u, v)), SIMD3(repeating: 0), SIMD3(repeating: 1))
        }

        private static func eval(_ c: [SIMD3<Double>], _ basis: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(simd_dot(c[0], basis), simd_dot(c[1], basis), simd_dot(c[2], basis))
        }

        /// Normal equations, one 3×3 system shared by the three channels.
        private static func solve(_ s: [(basis: SIMD3<Double>, color: SIMD3<Double>)]) -> [SIMD3<Double>]? {
            var ata = simd_double3x3(0)
            var atb = [SIMD3<Double>](repeating: .zero, count: 3)
            for (b, c) in s {
                ata += simd_double3x3(columns: (b * b.x, b * b.y, b * b.z))
                for ch in 0..<3 { atb[ch] += b * c[ch] }
            }
            guard abs(ata.determinant) > 1e-9 else { return nil }
            let inv = ata.inverse
            return atb.map { inv * $0 }
        }
    }
}
#endif
