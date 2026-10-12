import Foundation

/// Encoder for `rlë8` (see `RLE8` for the format notes): quantises RGBA to the nearest
/// palette entry and writes the shared token stream. The decoder's output re-encodes to the
/// same indices when the palette is the one used to decode (exact colours map to themselves,
/// except that duplicate palette colours collapse to the first matching index).
///
/// Per scanline: a line-start token whose count is the byte length of the row body (as in the
/// original streams), then transparent runs, 4-byte-padded literal runs and 4-byte-pattern
/// repeat runs; trailing transparency is omitted. Each frame ends with an end-of-frame token.
public enum RLE8Encoder {

    public static func encode(_ sheet: SpriteSheet, paletteID: Int = 0, palette: [UInt8]? = nil,
                              alphaThreshold: UInt8 = 128) throws -> Data {
        try encode(rgba: sheet.rgba, surfaceWidth: sheet.surfaceWidth, surfaceHeight: sheet.surfaceHeight,
                   frameWidth: sheet.frameWidth, frameHeight: sheet.frameHeight, frameCount: sheet.frameCount,
                   paletteID: paletteID, palette: palette, alphaThreshold: alphaThreshold)
    }

    public static func encode(rgba: [UInt8], surfaceWidth: Int, surfaceHeight: Int,
                              frameWidth fw: Int, frameHeight fh: Int, frameCount: Int,
                              paletteID: Int = 0, palette: [UInt8]? = nil,
                              alphaThreshold: UInt8 = 128) throws -> Data {
        let pal = palette ?? RLE8.macSystemPalette
        guard pal.count >= 768 else { throw GraphicsEncodeError.badInput("palette needs 256 RGB entries") }
        guard fw > 0, fh > 0, fw < 4096, fh < 4096 else {
            throw GraphicsEncodeError.badGeometry("frame \(fw)x\(fh) (must be 1..<4096)")
        }
        guard frameCount > 0, frameCount <= Int(Int16.max) else {
            throw GraphicsEncodeError.badGeometry("frame count \(frameCount)")
        }
        let columns = min(SpriteSheet.framesPerRow, frameCount)
        let rowsOfFrames = (frameCount + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        guard surfaceWidth >= columns * fw, surfaceHeight >= rowsOfFrames * fh else {
            throw GraphicsEncodeError.badGeometry("surface \(surfaceWidth)x\(surfaceHeight) too small for \(frameCount) frames of \(fw)x\(fh)")
        }
        guard rgba.count == surfaceWidth * surfaceHeight * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: surfaceWidth * surfaceHeight * 4, actual: rgba.count)
        }

        // Nearest palette index, memoised on the 24-bit colour.
        var cache: [UInt32: UInt8] = [:]
        func nearest(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            if let hit = cache[key] { return hit }
            var best = 0, bestD = Int.max
            for i in 0..<256 {
                let dr = Int(r) - Int(pal[i * 3]), dg = Int(g) - Int(pal[i * 3 + 1]), db = Int(b) - Int(pal[i * 3 + 2])
                let d = dr * dr + dg * dg + db * db
                if d < bestD { bestD = d; best = i; if d == 0 { break } }
            }
            cache[key] = UInt8(best)
            return UInt8(best)
        }

        var out = [UInt8]()
        out.reserveCapacity(16 + frameCount * fh * (4 + fw))
        out.appendBE16(fw); out.appendBE16(fh); out.appendBE16(8)
        out.appendBE16(paletteID); out.appendBE16(frameCount)
        out.append(contentsOf: [0, 0, 0, 0, 0, 0])

        func token(_ op: UInt8, _ count: Int, into buf: inout [UInt8]) {
            buf.append(op)
            buf.append(UInt8(truncatingIfNeeded: count >> 16))
            buf.append(UInt8(truncatingIfNeeded: count >> 8))
            buf.append(UInt8(truncatingIfNeeded: count))
        }

        var idx = [Int](repeating: -1, count: fw)          // -1 = transparent
        for f in 0..<frameCount {
            let ox = (f % SpriteSheet.framesPerRow) * fw
            let oy = (f / SpriteSheet.framesPerRow) * fh
            for y in 0..<fh {
                var i = ((oy + y) * surfaceWidth + ox) * 4
                var last = -1
                for x in 0..<fw {
                    if rgba[i + 3] >= alphaThreshold {
                        idx[x] = Int(nearest(rgba[i], rgba[i + 1], rgba[i + 2])); last = x
                    } else { idx[x] = -1 }
                    i += 4
                }
                var body = [UInt8]()
                var x = 0
                while x <= last {
                    var e = x
                    if idx[x] < 0 {
                        while e <= last, idx[e] < 0 { e += 1 }
                        token(0x03, e - x, into: &body)
                        x = e
                        continue
                    }
                    while e < fw, idx[e] >= 0 { e += 1 }
                    var literalStart = x
                    func flushLiteral(_ upTo: Int) {
                        let n = upTo - literalStart
                        guard n > 0 else { return }
                        token(0x02, n, into: &body)
                        for k in literalStart..<upTo { body.append(UInt8(idx[k])) }
                        let pad = (4 - (n & 3)) & 3
                        for _ in 0..<pad { body.append(0) }
                    }
                    var p = x
                    while p < e {
                        var j = p + 1
                        while j < e, idx[j] == idx[p] { j += 1 }
                        if j - p >= 8 {
                            flushLiteral(p)
                            token(0x04, j - p, into: &body)
                            for _ in 0..<4 { body.append(UInt8(idx[p])) }
                            literalStart = j
                        }
                        p = j
                    }
                    flushLiteral(e)
                    x = e
                }
                token(0x01, body.count, into: &out)
                out.append(contentsOf: body)
            }
            token(0x00, 0, into: &out)
        }
        return Data(out)
    }
}
