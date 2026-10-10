import Foundation

/// `ppat` pixel patterns (the classic UI's tiled backgrounds, ppat 128-137).
/// `Resource_LoadPixPat` 0x004bbd50 / `FUN_0087293e`: patType 1, a PixMap whose
/// `pixelSize` is 1/2/4/8 with unpacked rows (rowBytes & 0x3FFF), and a clut
/// reached through the PixMap's pmTable field (an offset inside the resource).
/// Anything else is refused.
public enum PixPat {
    public enum Failure: Swift.Error { case unsupported }

    public static func decode(_ data: Data) throws -> SpriteSheet {
        let b = [UInt8](data)
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p + 2 <= b.count else { throw Failure.unsupported }
            return Int(b[p]) << 8 | Int(b[p + 1])
        }
        func i16(_ p: Int) throws -> Int { Int(Int16(truncatingIfNeeded: try u16(p))) }
        func u32(_ p: Int) throws -> Int { try u16(p) << 16 | u16(p + 2) }

        guard try u16(0) == 1 else { throw Failure.unsupported }
        let map = try u32(2), pixOffset = try u32(6)
        guard map > 0, pixOffset > 0 else { throw Failure.unsupported }
        let rowBytesField = try u16(map + 4)
        let height = try i16(map + 10) - i16(map + 6)
        let width = try i16(map + 12) - i16(map + 8)
        guard width > 0, height > 0, width < 4096, height < 4096,
              rowBytesField & 0xC000 == 0x8000,
              try u16(map + 14) == 0, try u16(map + 16) == 0 else { throw Failure.unsupported }
        let depth = try u16(map + 32)
        guard [1, 2, 4, 8].contains(depth) else { throw Failure.unsupported }
        let clut = try u32(map + 42)
        guard clut > 0 else { throw Failure.unsupported }

        var palette = [UInt8](repeating: 0, count: 256 * 3)
        let count = try i16(clut + 6) + 1
        for i in 0..<max(0, count) {
            let e = clut + 8 + i * 8
            let index = try u16(e)
            guard index < 256 else { continue }
            guard e + 8 <= b.count else { throw Failure.unsupported }
            palette[index * 3] = b[e + 3]; palette[index * 3 + 1] = b[e + 5]; palette[index * 3 + 2] = b[e + 7]
        }

        let rowBytes = rowBytesField & 0x3FFF
        let per = 8 / depth, mask = (1 << depth) - 1
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let at = pixOffset + y * rowBytes + x / per
                guard at < b.count else { throw Failure.unsupported }
                let shift = 8 - depth - (x % per) * depth
                let c = (Int(b[at]) >> shift & mask) * 3
                let o = (y * width + x) * 4
                rgba[o] = palette[c]; rgba[o + 1] = palette[c + 1]; rgba[o + 2] = palette[c + 2]
            }
        }
        return PICT.sheet(width, height, rgba)
    }
}
