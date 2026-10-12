import Foundation

/// Encoder for EV Nova's `rlëD` sprites (16-bit 1-5-5-5, run-length, multi-frame):
/// the exact inverse of `RLED.decode`.
///
/// Input is the same representation the decoder produces: a `SpriteSheet`
/// (top-left RGBA8, frames in a 6-wide grid). A pixel with alpha at or above
/// `alphaThreshold` is opaque and quantised to 5 bits per channel; any other
/// pixel is transparent. Feeding it the output of `RLED.decode` therefore
/// round-trips pixel-identically.
///
/// Token stream per frame (all big-endian, 4-byte tokens `op<<24 | count`):
/// `lineStart` per scanline, then transparent runs (skip), literal pixel
/// runs (padded to 4 bytes) and 2-pixel-pattern repeat runs, then `eof`.
/// Trailing transparent pixels of a line are omitted, as in the originals.
///
/// Only the 16-bit variant is supported (`RLED.decode` itself rejects `rlë8`).
public enum RLEDEncoder {

    /// Encode a whole sheet.
    public static func encode(_ sheet: SpriteSheet, paletteID: Int = 0,
                              alphaThreshold: UInt8 = 128) throws -> Data {
        try encode(rgba: sheet.rgba, surfaceWidth: sheet.surfaceWidth, surfaceHeight: sheet.surfaceHeight,
                   frameWidth: sheet.frameWidth, frameHeight: sheet.frameHeight,
                   frameCount: sheet.frameCount, paletteID: paletteID, alphaThreshold: alphaThreshold)
    }

    /// Encode a raw RGBA surface laid out as the decoder's grid:
    /// `min(6, frameCount)` columns, frame `n` at cell `(n % 6, n / 6)`.
    public static func encode(rgba: [UInt8], surfaceWidth: Int, surfaceHeight: Int,
                              frameWidth fw: Int, frameHeight fh: Int, frameCount: Int,
                              paletteID: Int = 0, alphaThreshold: UInt8 = 128) throws -> Data {
        guard fw > 0, fh > 0, fw < 4096, fh < 4096 else {
            throw GraphicsEncodeError.badGeometry("frame \(fw)x\(fh) (must be 1..<4096)")
        }
        guard frameCount > 0, frameCount <= Int(Int16.max) else {
            throw GraphicsEncodeError.badGeometry("frame count \(frameCount)")
        }
        let columns = min(SpriteSheet.framesPerRow, frameCount)
        let rows = (frameCount + SpriteSheet.framesPerRow - 1) / SpriteSheet.framesPerRow
        guard surfaceWidth >= columns * fw, surfaceHeight >= rows * fh else {
            throw GraphicsEncodeError.badGeometry("surface \(surfaceWidth)x\(surfaceHeight) too small for \(frameCount) frames of \(fw)x\(fh)")
        }
        guard rgba.count == surfaceWidth * surfaceHeight * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: surfaceWidth * surfaceHeight * 4, actual: rgba.count)
        }

        var out = [UInt8]()
        out.reserveCapacity(16 + frameCount * fh * (4 + fw))
        out.appendBE16(fw); out.appendBE16(fh); out.appendBE16(16)
        out.appendBE16(paletteID); out.appendBE16(frameCount)
        out.append(contentsOf: [0, 0, 0, 0, 0, 0])

        @inline(__always) func token(_ op: UInt8, _ count: Int) {
            out.append(op)
            out.append(UInt8(truncatingIfNeeded: count >> 16))
            out.append(UInt8(truncatingIfNeeded: count >> 8))
            out.append(UInt8(truncatingIfNeeded: count))
        }
        @inline(__always) func put16(_ v: UInt16) {
            out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
        }

        let transparent: UInt16 = 0x8000          // valid pixels are < 0x8000
        var row = [UInt16](repeating: transparent, count: fw)

        rgba.withUnsafeBufferPointer { px in
            for f in 0..<frameCount {
                let ox = (f % SpriteSheet.framesPerRow) * fw
                let oy = (f / SpriteSheet.framesPerRow) * fh
                for y in 0..<fh {
                    token(0x01, 0)
                    var i = ((oy + y) * surfaceWidth + ox) * 4
                    var last = -1
                    for x in 0..<fw {
                        if px[i + 3] >= alphaThreshold {
                            row[x] = GfxColor.pack555(px[i], px[i + 1], px[i + 2]); last = x
                        } else {
                            row[x] = transparent
                        }
                        i += 4
                    }
                    var x = 0
                    while x <= last {
                        var e = x
                        if row[x] == transparent {
                            while e <= last, row[e] == transparent { e += 1 }
                            token(0x03, (e - x) * 2)
                            x = e
                            continue
                        }
                        while e < fw, row[e] != transparent { e += 1 }
                        // Opaque segment [x, e): literal stretches and repeat runs.
                        var literalStart = x
                        func flushLiteral(_ upTo: Int) {
                            let n = upTo - literalStart
                            guard n > 0 else { return }
                            token(0x02, n * 2)
                            for k in literalStart..<upTo { put16(row[k]) }
                            if n & 1 == 1 { out.append(0); out.append(0) }
                        }
                        var p = x
                        while p < e {
                            var j = p + 1
                            while j < e, row[j] == row[p] { j += 1 }
                            if j - p >= 4 {
                                flushLiteral(p)
                                token(0x04, (j - p) * 2)
                                put16(row[p]); put16(row[p])
                                literalStart = j
                            }
                            p = j
                        }
                        flushLiteral(e)
                        x = e
                    }
                }
                token(0x00, 0)
            }
        }
        return Data(out)
    }
}
