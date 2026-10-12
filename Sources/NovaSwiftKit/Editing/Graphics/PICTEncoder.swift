import Foundation

/// Encoder for QuickDraw version-2 `PICT` images: a `DirectBitsRect` (0x009A)
/// with PackBits-compressed rows, in 32-bit (lossless planar RGB) or 16-bit
/// (1-5-5-5) form. Readable by `PICT.decode`; the layout is the standard one
/// QuickDraw writes (v2 header 0x0C00, clip region, DirectBitsRect, EndPic).
///
/// A PICT has no alpha channel: pixels are written as RGB exactly as given
/// (use `encodeSpritePair` to carry transparency in a separate mask PICT, the
/// way `spïn`-based PICT sprite sheets do).
public enum PICTEncoder {

    public enum Depth: Sendable {
        /// 32 bits per pixel, 3 components (R, G, B planes, PackBits bytes). Lossless.
        case bits32
        /// 16 bits per pixel 1-5-5-5, PackBits words. Lossy to 5 bits/channel.
        case bits16
    }

    /// Encode a decoded sheet's whole surface as one picture.
    public static func encode(_ sheet: SpriteSheet, depth: Depth = .bits32) throws -> Data {
        try encode(rgba: sheet.rgba, width: sheet.surfaceWidth, height: sheet.surfaceHeight, depth: depth)
    }

    /// Encode a top-left RGBA8 buffer.
    public static func encode(rgba: [UInt8], width: Int, height: Int, depth: Depth = .bits32) throws -> Data {
        guard width > 0, height > 0, width < 8192, height < 8192 else {
            throw GraphicsEncodeError.badGeometry("PICT \(width)x\(height) (must be 1..<8192)")
        }
        guard rgba.count == width * height * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: width * height * 4, actual: rgba.count)
        }
        // A 1-pixel-wide 32-bit row is 4 bytes, which QuickDraw stores unpacked as
        // xRGB (not planar). Use the 16-bit form for such slivers.
        let depth: Depth = (depth == .bits32 && width < 2) ? .bits16 : depth
        let is32 = depth == .bits32
        let rowBytes = is32 ? width * 4 : width * 2

        var out = [UInt8]()
        out.reserveCapacity(128 + width * height * (is32 ? 3 : 2) / 2)
        out.appendBE16(0)                                       // size, patched at the end
        out.appendBE16(0); out.appendBE16(0)                    // frame top, left
        out.appendBE16(height); out.appendBE16(width)           // frame bottom, right
        out.appendBE16(0x0011); out.appendBE16(0x02FF)          // version 2
        out.appendBE16(0x0C00)                                  // extended header
        out.appendBE16(0xFFFE); out.appendBE16(0)               // version -2, reserved
        out.appendBE32(72 << 16); out.appendBE32(72 << 16)      // hRes, vRes (Fixed)
        out.appendBE16(0); out.appendBE16(0)                    // srcRect top, left
        out.appendBE16(height); out.appendBE16(width)           //   bottom, right
        out.appendBE32(0)                                       // reserved
        out.appendBE16(0x0001); out.appendBE16(10)              // clip region: rect
        out.appendBE16(0); out.appendBE16(0)
        out.appendBE16(height); out.appendBE16(width)

        out.appendBE16(0x009A)                                  // DirectBitsRect
        out.appendBE32(0x0000_00FF)                             // baseAddr
        out.appendBE16(0x8000 | rowBytes)                       // rowBytes | PixMap flag
        out.appendBE16(0); out.appendBE16(0)                    // bounds top, left
        out.appendBE16(height); out.appendBE16(width)           //        bottom, right
        out.appendBE16(0)                                       // pmVersion
        out.appendBE16(is32 ? 4 : 3)                            // packType
        out.appendBE32(0)                                       // packSize
        out.appendBE32(72 << 16); out.appendBE32(72 << 16)      // hRes, vRes
        out.appendBE16(16)                                      // pixelType: RGBDirect
        out.appendBE16(is32 ? 32 : 16)                          // pixelSize
        out.appendBE16(3)                                       // cmpCount
        out.appendBE16(is32 ? 8 : 5)                            // cmpSize
        out.appendBE32(0); out.appendBE32(0); out.appendBE32(0) // planeBytes, pmTable, pmReserved
        out.appendBE16(0); out.appendBE16(0)                    // srcRect
        out.appendBE16(height); out.appendBE16(width)
        out.appendBE16(0); out.appendBE16(0)                    // dstRect
        out.appendBE16(height); out.appendBE16(width)
        out.appendBE16(0)                                       // mode: srcCopy

        var plane = [UInt8](repeating: 0, count: is32 ? width * 3 : width * 2)
        var packed = [UInt8](); packed.reserveCapacity(plane.count + plane.count / 64 + 8)
        let longCount = rowBytes > 250
        rgba.withUnsafeBufferPointer { px in
            for y in 0..<height {
                var i = y * width * 4
                if is32 {
                    for x in 0..<width {
                        plane[x] = px[i]; plane[width + x] = px[i + 1]; plane[2 * width + x] = px[i + 2]
                        i += 4
                    }
                } else {
                    for x in 0..<width {
                        let v = GfxColor.pack555(px[i], px[i + 1], px[i + 2])
                        plane[2 * x] = UInt8(v >> 8); plane[2 * x + 1] = UInt8(v & 0xFF)
                        i += 4
                    }
                }
                if rowBytes < 8 {                       // QuickDraw stores narrow rows unpacked
                    out.append(contentsOf: plane)
                    continue
                }
                packed.removeAll(keepingCapacity: true)
                PackBits.pack(plane, unit: is32 ? 1 : 2, into: &packed)
                if longCount { out.appendBE16(packed.count) } else { out.append(UInt8(packed.count)) }
                out.append(contentsOf: packed)
            }
        }

        if out.count & 1 == 1 { out.append(0) }
        out.appendBE16(0x00FF)                                  // EndPic
        let size = out.count & 0xFFFF
        out[0] = UInt8(size >> 8); out[1] = UInt8(size & 0xFF)
        return Data(out)
    }

    /// The sprite PICT + mask PICT pair the original loads for sprites that have
    /// no `rlëD` (`Sprite_CreateFromSpriteSheetResources`): the image PICT holds
    /// the frames of `sheet` in its grid with transparent pixels black; the mask
    /// PICT is white where the sprite is opaque (alpha >= `alphaThreshold`) and
    /// black elsewhere. Pair it with a `spïn` of `tilesAcross`×`tilesDown` tiles
    /// of `frameWidth`×`frameHeight` (see `SpinBuilder`).
    public static func encodeSpritePair(_ sheet: SpriteSheet, alphaThreshold: UInt8 = 128,
                                        depth: Depth = .bits32) throws
        -> (image: Data, mask: Data, tilesAcross: Int, tilesDown: Int) {
        let n = sheet.surfaceWidth * sheet.surfaceHeight
        guard sheet.rgba.count == n * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: n * 4, actual: sheet.rgba.count)
        }
        var img = sheet.rgba
        var msk = [UInt8](repeating: 255, count: n * 4)
        img.withUnsafeMutableBufferPointer { ip in
            msk.withUnsafeMutableBufferPointer { mp in
                var i = 0
                for _ in 0..<n {
                    if ip[i + 3] >= alphaThreshold {
                        mp[i] = 255; mp[i + 1] = 255; mp[i + 2] = 255
                    } else {
                        ip[i] = 0; ip[i + 1] = 0; ip[i + 2] = 0
                        mp[i] = 0; mp[i + 1] = 0; mp[i + 2] = 0
                    }
                    ip[i + 3] = 255
                    i += 4
                }
            }
        }
        let image = try encode(rgba: img, width: sheet.surfaceWidth, height: sheet.surfaceHeight, depth: depth)
        // Masks are always 16-bit: white (31,31,31) is exact, and it's smaller.
        let mask = try encode(rgba: msk, width: sheet.surfaceWidth, height: sheet.surfaceHeight, depth: .bits16)
        return (image, mask, sheet.columns, sheet.rows)
    }
}

/// QuickDraw PackBits over 1- or 2-byte units (2 for 16-bit PICT rows).
enum PackBits {
    /// Compress `row` (length a multiple of `unit`). Repeats of 2...128 units
    /// become `(257 - n)` + unit; other stretches become literals of up to 128
    /// units. The 0x80 no-op/129-fold flag is never emitted.
    static func pack(_ row: [UInt8], unit: Int, into out: inout [UInt8]) {
        let n = row.count / unit
        @inline(__always) func same(_ a: Int, _ b: Int) -> Bool {
            unit == 1 ? row[a] == row[b] : (row[2 * a] == row[2 * b] && row[2 * a + 1] == row[2 * b + 1])
        }
        var i = 0
        while i < n {
            var run = 1
            while i + run < n, run < 128, same(i, i + run) { run += 1 }
            if run >= 2 {
                out.append(UInt8(257 - run))
                out.append(contentsOf: row[(i * unit)..<((i + 1) * unit)])
                i += run
                continue
            }
            // Literal: extend until a repeat of 3+ starts or 128 units.
            var len = 1
            while i + len < n, len < 128 {
                let k = i + len
                if k + 2 < n, same(k, k + 1), same(k, k + 2) { break }
                len += 1
            }
            out.append(UInt8(len - 1))
            out.append(contentsOf: row[(i * unit)..<((i + len) * unit)])
            i += len
        }
    }
}
