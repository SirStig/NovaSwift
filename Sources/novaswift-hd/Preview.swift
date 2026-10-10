import Foundation
import NovaSwiftKit
import NovaSwiftHD
import CoreGraphics
import ImageIO

/// Side-by-side sheets for judging an HD asset against the art it replaces:
/// each pair is one frame — the classic sprite blown up with hard pixels on
/// the left, the HD frame at the same on-screen size on the right — over the
/// game's black space.
enum Preview {
    static func compare(classic: SpriteSheet, hd: HDAtlas, frames: [Int], displayScale: Int) -> CGImage? {
        let cw = classic.frameWidth * displayScale, ch = classic.frameHeight * displayScale
        let pad = 8
        let cols = min(frames.count, 6)
        let rowsOfPairs = (frames.count + cols - 1) / cols
        let w = cols * (2 * cw + 3 * pad) + pad
        let h = rowsOfPairs * (ch + pad) + pad
        guard let ctx = HDAtlas.makeContext(width: w, height: h),
              let classicImage = classicCGImage(classic) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (n, f) in frames.enumerated() {
            let c = n % cols, r = n / cols
            let x = pad + c * (2 * cw + 3 * pad)
            let y = h - (r + 1) * (ch + pad)
            let fx = (f % SpriteSheet.framesPerRow) * classic.frameWidth
            let fy = (f / SpriteSheet.framesPerRow) * classic.frameHeight
            if let crop = classicImage.cropping(to: CGRect(x: fx, y: fy, width: classic.frameWidth, height: classic.frameHeight)) {
                ctx.interpolationQuality = .none
                ctx.draw(crop, in: CGRect(x: x, y: y, width: cw, height: ch))
            }
            if f < hd.frameCount, let frame = hd.frameImage(f) {
                ctx.interpolationQuality = .high
                ctx.draw(frame, in: CGRect(x: x + cw + pad, y: y, width: cw, height: ch))
            }
        }
        return ctx.makeImage()
    }

    /// Classic frame | HD hull | HD hull with its effect layers added the
    /// way the game draws them (additive, centred) — "thrusting, lights on".
    static func compareLayers(classic: SpriteSheet, hd: HDAtlas, layers: [HDAtlas], frames: [Int],
                              displayScale: Int) -> CGImage? {
        let cw = classic.frameWidth * displayScale, ch = classic.frameHeight * displayScale
        let pad = 8, cell = 3 * cw + 4 * pad
        let cols = min(frames.count, 4)
        let rowsN = (frames.count + cols - 1) / cols
        let w = cols * cell + pad, h = rowsN * (ch + pad) + pad
        guard let ctx = HDAtlas.makeContext(width: w, height: h), let classicImage = classicCGImage(classic) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (n, f) in frames.enumerated() {
            let x = pad + (n % cols) * cell, y = h - (n / cols + 1) * (ch + pad)
            let fx = (f % SpriteSheet.framesPerRow) * classic.frameWidth
            let fy = (f / SpriteSheet.framesPerRow) * classic.frameHeight
            if let crop = classicImage.cropping(to: CGRect(x: fx, y: fy, width: classic.frameWidth, height: classic.frameHeight)) {
                ctx.interpolationQuality = .none
                ctx.draw(crop, in: CGRect(x: x, y: y, width: cw, height: ch))
            }
            ctx.interpolationQuality = .high
            guard let hull = hd.frameImage(f) else { continue }
            ctx.draw(hull, in: CGRect(x: x + cw + pad, y: y, width: cw, height: ch))
            ctx.draw(hull, in: CGRect(x: x + 2 * (cw + pad), y: y, width: cw, height: ch))
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            for layer in layers where f < layer.frameCount {
                guard let img = layer.frameImage(f) else { continue }
                // Overlays are centred on the hull; scale by their own frame size.
                let lw = Double(layer.frameWidth * displayScale), lh = Double(layer.frameHeight * displayScale)
                let cx = Double(x + 2 * (cw + pad)) + Double(cw) / 2, cy = Double(y) + Double(ch) / 2
                ctx.draw(img, in: CGRect(x: cx - lw / 2, y: cy - lh / 2, width: lw, height: lh))
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func classicCGImage(_ s: SpriteSheet) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(s.rgba) as CFData) else { return nil }
        return CGImage(width: s.surfaceWidth, height: s.surfaceHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: s.surfaceWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func write(_ image: CGImage, to url: URL) {
        try? HDAtlas.encodePNG(image)?.write(to: url)
    }
}
