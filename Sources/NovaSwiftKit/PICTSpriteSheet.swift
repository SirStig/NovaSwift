import Foundation

/// The original's fallback for sprites that have no `rlëD`: a PICT sheet plus a
/// mask PICT, cut into frames (`Sprite_CreateFromSpriteSheetResources`
/// 0x00474ab0). Every spïn and shän consumer takes this path when the `rlëD`
/// with the sprite id doesn't exist (0x004ad960, 0x004b0a30, 0x004b4ee0).
public enum PICTSpriteSheet {

    public enum Failure: Swift.Error, CustomStringConvertible {
        case sameSpriteAndMask(Int)
        case badFrameSize(Int, Int)
        case pastImageEdge(frame: Int)     // the exe's error 0x6b

        public var description: String {
            switch self {
            case let .sameSpriteAndMask(id): return "sprite and mask are the same PICT \(id)"
            case let .badFrameSize(w, h): return "bad frame size \(w)x\(h)"
            case let .pastImageEdge(f): return "frame \(f) runs past the image edge (error 0x6b)"
            }
        }
    }

    /// Whether a decoded mask pixel lets the sprite through. The original
    /// inverts the mask canvas after loading it and draws where it is then
    /// zero, so only a pixel that is white at 16-bit depth (every 5-bit channel
    /// 31) is opaque; black and grey are transparent.
    @inline(__always)
    static func maskIsOpaque(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        r >> 3 == 31 && g >> 3 == 31 && b >> 3 == 31
    }

    /// Cut `image` into frames of `frameWidth`×`frameHeight`, row-major from the
    /// top-left: after each frame move right by the width plus `gapX`; when the
    /// next frame's right edge passes the image width, drop down by the height
    /// plus `gapY` back at the left edge, and fail if its bottom passes the
    /// image height. `frameCount` 0 means (height / fh)·(width / fw).
    ///
    /// Alpha comes from `mask` (sampled at the same coordinates; outside the
    /// mask is transparent). Frames are packed into the usual 6-wide grid.
    public static func slice(image: SpriteSheet, mask: SpriteSheet,
                             frameWidth fw: Int, frameHeight fh: Int,
                             frameCount: Int, gapX: Int = 0, gapY: Int = 0) throws -> SpriteSheet {
        guard fw > 0, fh > 0 else { throw Failure.badFrameSize(fw, fh) }
        let iw = image.surfaceWidth, ih = image.surfaceHeight
        let count = frameCount > 0 ? frameCount : (ih / fh) * (iw / fw)
        guard count > 0 else { throw Failure.badFrameSize(fw, fh) }

        // Frame origins, following the exe's walk (the edge test runs after
        // every frame but the last).
        var origins: [(x: Int, y: Int)] = []
        var left = 0, top = 0
        for i in 0..<count {
            origins.append((left, top))
            guard i < count - 1 else { break }
            left += fw + gapX
            if left + fw > iw {
                top += fh + gapY
                left = 0
                if top + fh > ih { throw Failure.pastImageEdge(frame: i + 1) }
            }
        }

        let columns = min(SpriteSheet.framesPerRow, count)
        let rows = (count + columns - 1) / columns
        let sw = columns * fw, sh = rows * fh
        var rgba = [UInt8](repeating: 0, count: sw * sh * 4)
        let mw = mask.surfaceWidth, mh = mask.surfaceHeight
        for (f, o) in origins.enumerated() {
            let dx = (f % columns) * fw, dy = (f / columns) * fh
            for y in 0..<fh {
                let sy = o.y + y
                guard sy < ih else { break }
                for x in 0..<fw {
                    let sx = o.x + x
                    guard sx < iw else { break }
                    guard sx < mw, sy < mh else { continue }
                    let m = (sy * mw + sx) * 4
                    guard maskIsOpaque(mask.rgba[m], mask.rgba[m + 1], mask.rgba[m + 2]) else { continue }
                    let s = (sy * iw + sx) * 4
                    let d = ((dy + y) * sw + dx + x) * 4
                    rgba[d] = image.rgba[s]; rgba[d + 1] = image.rgba[s + 1]
                    rgba[d + 2] = image.rgba[s + 2]; rgba[d + 3] = 255
                }
            }
        }
        return SpriteSheet(frameWidth: fw, frameHeight: fh, frameCount: count, columns: columns,
                           rows: rows, surfaceWidth: sw, surfaceHeight: sh, rgba: rgba)
    }

    /// Per-frame 1-bit opaque masks of a sheet built by `slice` (collision).
    public static func masks(of sheet: SpriteSheet) -> SpriteMaskSet {
        let w = sheet.frameWidth, h = sheet.frameHeight
        let wordsPerRow = (w + 63) >> 6
        var bits = [UInt64](repeating: 0, count: wordsPerRow * h * sheet.frameCount)
        for f in 0..<sheet.frameCount {
            let ox = (f % sheet.columns) * w, oy = (f / sheet.columns) * h
            for y in 0..<h {
                for x in 0..<w where sheet.rgba[((oy + y) * sheet.surfaceWidth + ox + x) * 4 + 3] != 0 {
                    bits[(f * h + y) * wordsPerRow + (x >> 6)] |= 1 << UInt64(x & 63)
                }
            }
        }
        return SpriteMaskSet(width: w, height: h, frameCount: sheet.frameCount, bits: bits)
    }
}
