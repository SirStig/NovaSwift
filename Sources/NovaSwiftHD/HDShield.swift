import Foundation
import CoreGraphics

/// Shield bubbles for HD hulls. EV Nova draws a shield only when a hull's
/// `shän` has a shield layer (none of the stock hulls do), so an HD pack can ask
/// for one instead: for every heading, an elliptical bubble fitted to the
/// ship's outline in that frame, a bright rim fading to a faint fill. The game
/// shows it additively and only while the shields take hits.
public enum HDShield {
    /// How much bigger than the hull frame a shield frame is, so the bubble
    /// around a long ship isn't clipped.
    public static let frameGrowth = 1.4

    /// Shield frames for the first `frames` frames (one rotation set) of a
    /// hull's HD atlas, in `color` (0…1 each).
    public static func make(from hull: HDAtlas, frames: Int, color: [Double]) -> HDAtlas? {
        let n = min(frames, hull.frameCount)
        guard n > 0, color.count == 3 else { return nil }
        let s = hull.pixelScale
        let fw = Int((Double(hull.frameWidth) * frameGrowth).rounded())
        let fh = Int((Double(hull.frameHeight) * frameGrowth).rounded())
        let pw = Int((Double(fw) * s).rounded()), ph = Int((Double(fh) * s).rounded())
        let columns = min(6, n), rows = (n + columns - 1) / columns
        guard let out = HDAtlas.makeContext(width: pw * columns, height: ph * rows),
              let outData = out.data else { return nil }
        let outPx = outData.bindMemory(to: UInt8.self, capacity: out.bytesPerRow * ph * rows)

        for i in 0..<n {
            guard let frame = hull.frameImage(i),
                  let fit = outline(of: frame) else { continue }
            // The hull frame sits centred in the bigger shield frame.
            let offX = Double(pw - frame.width) / 2, offY = Double(ph - frame.height) / 2
            let cx = fit.cx + offX, cy = fit.cy + offY
            // Bubble: the outline's ellipse, grown so it clears the hull.
            let a = fit.a * 1.18 + 2 * s, b = max(fit.b * 1.18 + 2 * s, a * 0.55)
            let ca = cos(fit.angle), sa = sin(fit.angle)
            let col = i % columns, row = i / columns
            for y in 0..<ph {
                // Bitmap memory runs top-down, like the frame grid.
                let dstRow = row * ph + y
                for x in 0..<pw {
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    let u = (dx * ca + dy * sa) / a, v = (-dx * sa + dy * ca) / b
                    let r = (u * u + v * v).squareRoot()
                    if r > 1.1 { continue }
                    // A clean, see-through bubble: nearly clear in the middle,
                    // rising softly to a faint edge (a fresnel look), no noise.
                    let body = pow(smooth(0.35, 1.0, r), 2.2) * 0.3
                    let edge = smooth(0.9, 0.99, r) * (1 - smooth(0.99, 1.1, r)) * 0.24
                    let alpha = min(1, (body + edge) * (r <= 1.0 ? 1 : 1 - smooth(1.0, 1.1, r)))
                    if alpha <= 0.004 { continue }
                    let o = dstRow * out.bytesPerRow + (col * pw + x) * 4
                    // Mostly white-hot, with only a hint of the pack's colour.
                    let tint = 0.35
                    outPx[o]     = UInt8(min(255, (1 - tint + color[0] * tint) * alpha * 255))
                    outPx[o + 1] = UInt8(min(255, (1 - tint + color[1] * tint) * alpha * 255))
                    outPx[o + 2] = UInt8(min(255, (1 - tint + color[2] * tint) * alpha * 255))
                    outPx[o + 3] = UInt8(alpha * 255)
                }
            }
        }
        guard let image = out.makeImage() else { return nil }
        return HDAtlas(image: image, frameWidth: fw, frameHeight: fh, frameCount: n, columns: columns, pixelScale: s)
    }

    private struct Fit { let cx, cy, a, b, angle: Double }

    /// Centre, half-length, half-width and angle of a frame's opaque outline
    /// (second moments of its alpha), in the frame's pixels, top-down.
    private static func outline(of image: CGImage) -> Fit? {
        let w = image.width, h = image.height
        guard let ctx = HDAtlas.makeContext(width: w, height: h), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var m = 0.0, mx = 0.0, my = 0.0
        var points: [(Double, Double, Double)] = []
        points.reserveCapacity(w * h / 4)
        for y in 0..<h {
            let row = y * ctx.bytesPerRow
            for x in 0..<w {
                let al = Double(px[row + x * 4 + 3]) / 255
                if al < 0.2 { continue }
                m += al; mx += al * Double(x); my += al * Double(y)
                points.append((Double(x) + 0.5, Double(y) + 0.5, al))
            }
        }
        guard m > 0 else { return nil }
        let cx = mx / m + 0.5, cy = my / m + 0.5
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (x, y, al) in points {
            let dx = x - cx, dy = y - cy
            sxx += al * dx * dx; syy += al * dy * dy; sxy += al * dx * dy
        }
        sxx /= m; syy /= m; sxy /= m
        // Eigen decomposition of the 2×2 covariance.
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-6)
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        // For a solid ellipse the half-axis is 2·sigma.
        return Fit(cx: cx, cy: cy, a: 2 * l1.squareRoot(), b: 2 * l2.squareRoot(), angle: angle)
    }

    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}
