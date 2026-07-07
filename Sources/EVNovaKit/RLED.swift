import Foundation

/// A decoded sprite sheet: all frames laid out in a grid (max 6 columns), stored
/// as top-left-origin RGBA8. Unwritten pixels are fully transparent.
public struct SpriteSheet {
    public let frameWidth: Int
    public let frameHeight: Int
    public let frameCount: Int
    /// Columns / rows in the grid the frames are packed into.
    public let columns: Int
    public let rows: Int
    public let surfaceWidth: Int
    public let surfaceHeight: Int
    /// surfaceWidth * surfaceHeight * 4 bytes, RGBA, row-major, top-left origin.
    public let rgba: [UInt8]

    /// Frames are always packed 6-across in the source format (fewer if there are
    /// fewer than 6 frames), so a frame's grid cell is (index % 6, index / 6).
    public static let framesPerRow = 6
}

/// Decoder for EV Nova's `rlëD` sprites: 16-bit (1-5-5-5) direct-colour,
/// run-length-encoded, multi-frame. Big-endian QuickDraw data.
///
/// Algorithm cross-checked against Graphite `quickdraw/rle.cpp` (opcodes,
/// 1-5-5-5 unpack, 6-wide frame grid) and NovaJS `RledResource.ts`.
/// See docs/DATA_FORMAT.md §3.2.
public enum RLED {
    private enum Opcode: UInt32 {
        case eof = 0x00
        case lineStart = 0x01
        case pixelData = 0x02
        case transparentRun = 0x03
        case pixelRun = 0x04
    }

    public static func decode(_ data: Data) throws -> SpriteSheet {
        let reader = BinaryReader(data, bigEndian: true)

        // Header: width, height (PICT order), bpp, palette id, frame count, 6 reserved.
        let width = Int(try reader.readI16())
        let height = Int(try reader.readI16())
        let bpp = Int(try reader.readI16())
        _ = try reader.readI16() // palette id (unused for 16-bit direct colour)
        let frameCount = Int(try reader.readI16())
        try reader.advance(6)

        guard bpp == 16 else {
            throw ResourceFileError.corrupt("rlëD colour depth \(bpp) unsupported (only 16-bit)")
        }
        guard width > 0, height > 0, frameCount > 0, width < 4096, height < 4096 else {
            throw ResourceFileError.corrupt("rlëD implausible geometry \(width)x\(height) × \(frameCount)")
        }

        let columns = min(SpriteSheet.framesPerRow, frameCount)
        let rows = Int((Double(frameCount) / Double(SpriteSheet.framesPerRow)).rounded(.up))
        let surfaceWidth = columns * width
        let surfaceHeight = rows * height
        var rgba = [UInt8](repeating: 0, count: surfaceWidth * surfaceHeight * 4)

        @inline(__always)
        func putPixel(_ p: UInt16, at pixelOffset: Int) {
            let idx = pixelOffset * 4
            guard idx >= 0, idx + 3 < rgba.count else { return }
            let r5 = Int((p >> 10) & 0x1F)
            let g5 = Int((p >> 5) & 0x1F)
            let b5 = Int(p & 0x1F)
            // Expand 5-bit channel to 8-bit, replicating the high bits into the low.
            rgba[idx]     = UInt8((r5 << 3) | (r5 >> 2))
            rgba[idx + 1] = UInt8((g5 << 3) | (g5 >> 2))
            rgba[idx + 2] = UInt8((b5 << 3) | (b5 >> 2))
            rgba[idx + 3] = 255
        }

        @inline(__always)
        func surfaceOffset(frame: Int, line: Int) -> Int {
            let col = frame % SpriteSheet.framesPerRow
            let row = frame / SpriteSheet.framesPerRow
            let x = col * width
            let y = row * height + line
            return y * surfaceWidth + x
        }

        var currentFrame = 0
        var currentLine = -1
        var currentOffset = 0
        var done = false

        while !done, reader.remaining >= 4 {
            let token = try reader.readU32()
            let count = Int(token & 0x00FF_FFFF)
            guard let opcode = Opcode(rawValue: token >> 24) else {
                throw ResourceFileError.corrupt("unknown rlëD opcode 0x\(String(token >> 24, radix: 16))")
            }

            switch opcode {
            case .eof:
                currentFrame += 1
                if currentFrame >= frameCount { done = true }
                currentLine = -1

            case .lineStart:
                currentLine += 1
                currentOffset = surfaceOffset(frame: currentFrame, line: currentLine)

            case .pixelData:
                var i = 0
                while i < count {
                    putPixel(try reader.readU16(), at: currentOffset)
                    currentOffset += 1
                    i += 2
                }
                if count & 3 != 0 { try reader.advance(4 - (count & 3)) }

            case .transparentRun:
                currentOffset += count >> 1 // skip pixels; they stay transparent

            case .pixelRun:
                let pair = try reader.readU32()
                let a = UInt16(truncatingIfNeeded: pair >> 16)
                let b = UInt16(truncatingIfNeeded: pair)
                var i = 0
                while i < count {
                    putPixel(a, at: currentOffset); currentOffset += 1
                    if i + 2 < count { putPixel(b, at: currentOffset); currentOffset += 1 }
                    i += 4
                }
            }
        }

        return SpriteSheet(frameWidth: width, frameHeight: height, frameCount: frameCount,
                           columns: columns, rows: rows,
                           surfaceWidth: surfaceWidth, surfaceHeight: surfaceHeight, rgba: rgba)
    }
}
