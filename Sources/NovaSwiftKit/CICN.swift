import Foundation

/// Decoder for classic Mac OS `cicn` (color icon) resources — small indexed-color
/// icon+mask pairs EV Nova uses for interface controls (list/grid scroll arrows,
/// checkboxes, etc.), as distinct from `PICT` (direct-color backgrounds/pictures).
///
/// Layout reference: Graphite `quickdraw/cicn.cpp` + `clut.cpp` (Inside Macintosh, Imaging).
public enum CICN {
    public static func decode(_ data: Data) throws -> SpriteSheet {
        let r = BinaryReader(data, bigEndian: true)

        // Pixmap header (50 bytes on disk; leading baseAddr is unused for cicn).
        try r.advance(4)                        // baseAddr
        let rowBytes = Int(try r.readU16() & 0x7FFF)
        let top = Int(try r.readI16()), left = Int(try r.readI16())
        let bottom = Int(try r.readI16()), right = Int(try r.readI16())
        try r.advance(2)                        // pmVersion
        try r.advance(2)                        // packType (cicn pixel data is never packed)
        try r.advance(4 + 4 + 4)                // packSize, hRes, vRes
        try r.advance(2)                        // pixelType
        let pixelSize = Int(try r.readI16())
        try r.advance(2)                        // cmpCount
        try r.advance(2)                        // cmpSize
        try r.advance(4 + 4 + 4)                // planeBytes, pmTable, pmExtension

        let width = right - left, height = bottom - top
        guard width > 0, height > 0, width < 512, height < 512 else {
            throw ResourceFileError.corrupt("cicn implausible frame \(width)x\(height)")
        }

        try r.advance(4)                         // mask baseAddr
        let maskRowBytes = Int(try r.readU16())
        let maskTop = Int(try r.readI16()); try r.advance(4)
        let maskBottom = Int(try r.readI16())
        let maskHeight = maskBottom - maskTop

        try r.advance(4)                         // bitmap baseAddr
        let bmapRowBytes = Int(try r.readU16())
        let bmapTop = Int(try r.readI16()); try r.advance(4)
        let bmapBottom = Int(try r.readI16())
        let bmapHeight = bmapBottom - bmapTop
        try r.advance(4)                         // reserved (icon handle)

        let maskData = try r.readBytes(max(0, maskRowBytes * maskHeight))
        _ = try r.readBytes(max(0, bmapRowBytes * bmapHeight))   // old-style 1-bit icon, unused
        let clut = try readCLUT(r)
        let pixmapData = try r.readBytes(rowBytes * height)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let rowOffset = y * rowBytes
            let maskRowOffset = y * maskRowBytes
            for x in 0..<width {
                let maskByteIndex = maskRowOffset + x / 8
                guard maskByteIndex < maskData.count else { continue }
                let maskShift = 7 - (x % 8)
                guard (maskData[maskByteIndex] >> maskShift) & 1 == 1 else { continue } // transparent

                var index = 0
                switch pixelSize {
                case 1:
                    let byteIndex = rowOffset + x / 8
                    guard byteIndex < pixmapData.count else { continue }
                    index = Int((pixmapData[byteIndex] >> (7 - (x % 8))) & 0x1)
                case 2:
                    let byteIndex = rowOffset + x / 4
                    guard byteIndex < pixmapData.count else { continue }
                    index = Int((pixmapData[byteIndex] >> ((3 - (x % 4)) * 2)) & 0x3)
                case 4:
                    let byteIndex = rowOffset + x / 2
                    guard byteIndex < pixmapData.count else { continue }
                    index = Int((pixmapData[byteIndex] >> ((1 - (x % 2)) * 4)) & 0xF)
                case 8:
                    let byteIndex = rowOffset + x
                    guard byteIndex < pixmapData.count else { continue }
                    index = Int(pixmapData[byteIndex])
                default:
                    continue
                }
                guard index < clut.count else { continue }
                let c = clut[index]
                let idx = (y * width + x) * 4
                rgba[idx] = c.0; rgba[idx + 1] = c.1; rgba[idx + 2] = c.2; rgba[idx + 3] = 255
            }
        }
        return SpriteSheet(frameWidth: width, frameHeight: height, frameCount: 1, columns: 1, rows: 1,
                            surfaceWidth: width, surfaceHeight: height, rgba: rgba)
    }

    /// Classic `ColorTable`: seed(4) + flags(2) + (count-1)(2), then `count`
    /// entries of value(2) + r/g/b(2 each, 0-65535 scaled to 0-255).
    private static func readCLUT(_ r: BinaryReader) throws -> [(UInt8, UInt8, UInt8)] {
        try r.advance(4) // seed
        _ = try r.readU16() // flags
        let count = Int(try r.readU16()) + 1
        var indexed: [Int: (UInt8, UInt8, UInt8)] = [:]
        var maxIndex = -1
        for _ in 0..<count {
            let value = Int(try r.readU16())
            let r16 = Int(try r.readU16()), g16 = Int(try r.readU16()), b16 = Int(try r.readU16())
            let color = (UInt8(r16 * 255 / 65535), UInt8(g16 * 255 / 65535), UInt8(b16 * 255 / 65535))
            indexed[value] = color
            maxIndex = max(maxIndex, value)
        }
        guard maxIndex >= 0 else { return [] }
        var out = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: maxIndex + 1)
        for (k, v) in indexed { out[k] = v }
        return out
    }
}
