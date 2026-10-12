import Foundation

/// Encoder for classic `cicn` colour icons, the layout `CICN.decode` reads:
/// 8-bit indexed PixMap + colour table + 1-bit mask (+ an empty 1-bit icon).
///
/// Images with more than 256 distinct opaque colours are reduced by dropping
/// low bits of every channel until the palette fits (deterministic, no dithering).
public enum CICNEncoder {

    /// Encode one icon (alpha >= `alphaThreshold` is opaque). Max 511x511.
    public static func encode(_ sheet: SpriteSheet, alphaThreshold: UInt8 = 128) throws -> Data {
        try encode(rgba: sheet.rgba, width: sheet.surfaceWidth, height: sheet.surfaceHeight,
                   alphaThreshold: alphaThreshold)
    }

    public static func encode(rgba: [UInt8], width: Int, height: Int, alphaThreshold: UInt8 = 128) throws -> Data {
        guard width > 0, height > 0, width < 512, height < 512 else {
            throw GraphicsEncodeError.badGeometry("cicn \(width)x\(height) (must be 1..<512)")
        }
        guard rgba.count == width * height * 4 else {
            throw GraphicsEncodeError.bufferSize(expected: width * height * 4, actual: rgba.count)
        }

        // Palette: exact colours if <= 256, else progressively coarser.
        var dropBits = 0
        var palette: [UInt32] = []
        var indexOf: [UInt32: Int] = [:]
        func key(_ i: Int, _ drop: Int) -> UInt32 {
            let m = UInt8(truncatingIfNeeded: 0xFF << drop)
            return UInt32(rgba[i] & m) << 16 | UInt32(rgba[i + 1] & m) << 8 | UInt32(rgba[i + 2] & m)
        }
        while true {
            palette.removeAll(keepingCapacity: true); indexOf.removeAll(keepingCapacity: true)
            var overflow = false
            var i = 0
            while i < rgba.count {
                if rgba[i + 3] >= alphaThreshold {
                    let k = key(i, dropBits)
                    if indexOf[k] == nil {
                        if palette.count == 256 { overflow = true; break }
                        indexOf[k] = palette.count; palette.append(k)
                    }
                }
                i += 4
            }
            if !overflow { break }
            dropBits += 1
        }
        if palette.isEmpty { palette = [0]; indexOf[0] = 0 }

        let rowBytes = width
        let maskRowBytes = (width + 7) / 8
        var out = [UInt8]()
        out.reserveCapacity(120 + maskRowBytes * height * 2 + 8 + palette.count * 8 + rowBytes * height)

        // PixMap (50 bytes).
        out.appendBE32(0)
        out.appendBE16(0x8000 | rowBytes)
        out.appendBE16(0); out.appendBE16(0); out.appendBE16(height); out.appendBE16(width)
        out.appendBE16(0); out.appendBE16(0)               // pmVersion, packType
        out.appendBE32(0); out.appendBE32(72 << 16); out.appendBE32(72 << 16)
        out.appendBE16(0); out.appendBE16(8)               // pixelType (indexed), pixelSize
        out.appendBE16(1); out.appendBE16(8)               // cmpCount, cmpSize
        out.appendBE32(0); out.appendBE32(0); out.appendBE32(0)
        // Mask BitMap, icon BitMap (14 bytes each), icon handle.
        for _ in 0..<2 {
            out.appendBE32(0); out.appendBE16(maskRowBytes)
            out.appendBE16(0); out.appendBE16(0); out.appendBE16(height); out.appendBE16(width)
        }
        out.appendBE32(0)
        // Mask bits (1 = opaque), then the unused 1-bit icon.
        var mask = [UInt8](repeating: 0, count: maskRowBytes * height)
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] >= alphaThreshold {
                mask[y * maskRowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: [UInt8](repeating: 0, count: maskRowBytes * height))
        // Colour table.
        out.appendBE32(0); out.appendBE16(0); out.appendBE16(palette.count - 1)
        for (i, c) in palette.enumerated() {
            out.appendBE16(i)
            for shift in [16, 8, 0] {
                let v = Int((c >> UInt32(shift)) & 0xFF)
                out.appendBE16(v * 257)
            }
        }
        // Pixels.
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                out.append(rgba[i + 3] >= alphaThreshold ? UInt8(indexOf[key(i, dropBits)] ?? 0) : 0)
            }
        }
        return Data(out)
    }
}
