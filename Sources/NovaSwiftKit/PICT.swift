import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Why a `PICT` failed to decode. Callers log it (never swallow it): a blank
/// landing picture or button in a plug-in is far easier to chase with the
/// reason in the log.
public enum PICTError: Swift.Error, CustomStringConvertible {
    case truncated(at: Int)
    case badHeader(String)
    case unsupportedPattern(Int)
    case noImage
    case badSize(Int, Int)
    case rowOverrun(row: Int)
    case unsupportedDepth(Int)
    case quickTime(String)

    public var description: String {
        switch self {
        case let .truncated(at): return "PICT data ends early (offset \(at))"
        case let .badHeader(why): return "PICT header: \(why)"
        case let .unsupportedPattern(op): return "PICT pattern opcode 0x\(String(op, radix: 16)) is not supported"
        case .noImage: return "PICT has no bits opcode before its end"
        case let .badSize(w, h): return "PICT implausible frame \(w)x\(h)"
        case let .rowOverrun(row): return "PICT packed row \(row) overruns its buffer"
        case let .unsupportedDepth(d): return "PICT pixel depth \(d) is not supported"
        case let .quickTime(why): return "Unable to decompress QT PICT (\(why))"
        }
    }
}

/// Decoder for QuickDraw `PICT` images — landing pictures, interface
/// backgrounds, button and menu art, mission pictures and the PICT sprite
/// sheets plug-ins use instead of `rlëD`.
///
/// This follows the Windows build's own reader (`Pict_ParseDirectBitsRect`
/// 0x004fd0a0, `Pict_DecodePixmapRows` 0x004fcc00, the bit unpacker 0x004fcac0),
/// quirks included:
/// - the output size is the picture frame, replaced by a 10-byte clip region
///   whose top and left are not negative; the v2 extended-header srcRect is
///   ignored;
/// - v1 (byte opcodes) and v2 (word opcodes, word aligned) are both read;
/// - every opcode it doesn't draw is skipped by the exe's length table
///   (0x570344) and range rules; only the pattern opcodes 0x12-0x14 fail;
/// - the FIRST of 0x90/0x91/0x98/0x99/0x9A/0x9B is decoded, then reading stops;
///   indexed PixMaps use their clut over a default palette of white at 0 and
///   black everywhere else; a plain BitMap is 1 bit, 0 = white, 1 = black;
/// - a row is packed exactly when rowBytes >= 8 (packType is never read);
///   PackBits uses 2-byte units at 16 bits, and 0x80 is a 129-fold repeat;
/// - a 32-bit PixMap with cmpCount 4 skips the alpha plane, and with any other
///   cmpCount is read as 24-bit planar RGB; every pixel comes out opaque;
/// - opcode 0x8200 (QuickTime-compressed) hands the ImageDescription's data to
///   the system decoder (JPEG and the other formats ImageIO reads).
public enum PICT {

    /// Byte lengths the exe skips for opcodes 0x00-0xA1 when it doesn't use
    /// them (0x570344). −1 means "skip 2 bytes".
    static let opcodeLengths: [Int] = [
        0, 0, 8, 2, 2, 2, 4, 4, 2, 8, 8, 4, 4, 2, 4, 4,             // 0x00
        8, 1, 0, 0, 0, 2, 2, 0, 0, 0, 6, 6, 0, 6, 0, 6,             // 0x10
        8, 4, 6, 2, -1, -1, -1, -1, 0, 0, 0, 0, -1, -1, -1, -1,     // 0x20
        8, 8, 8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0,             // 0x30
        8, 8, 8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0,             // 0x40
        8, 8, 8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0,             // 0x50
        12, 12, 12, 12, 12, 12, 12, 12, 4, 4, 4, 4, 4, 4, 4, 4,     // 0x60
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,             // 0x70
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,             // 0x80
        0, 0, -1, -1, -1, -1, -1, -1, 0, 0, 0, 0, -1, -1, -1, -1,   // 0x90
        2, 0,                                                       // 0xA0
    ]

    /// Decode a PICT into a single-frame RGBA sheet the size of its frame.
    public static func decode(_ data: Data) throws -> SpriteSheet {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.decode()
    }

    /// `decode`, but a failure is logged with its reason and the PICT id
    /// instead of being thrown — for callers that fall back to nothing.
    public static func decodeLogged(_ data: Data, id: Int) -> SpriteSheet? {
        do { return try decode(data) } catch {
            Log.graphics.error("PICT \(id, privacy: .public) (\(data.count, privacy: .public) bytes) failed to decode: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Reader

    struct Reader {
        let b: [UInt8]
        init(bytes: [UInt8]) { b = bytes }

        func u8(_ p: Int) throws -> Int {
            guard p >= 0, p < b.count else { throw PICTError.truncated(at: p) }
            return Int(b[p])
        }
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p + 1 < b.count else { throw PICTError.truncated(at: p) }
            return Int(b[p]) << 8 | Int(b[p + 1])
        }
        func i16(_ p: Int) throws -> Int { Int(Int16(truncatingIfNeeded: try u16(p))) }
        func u32(_ p: Int) throws -> Int {
            guard p >= 0, p + 3 < b.count else { throw PICTError.truncated(at: p) }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }

        mutating func decode() throws -> SpriteSheet {
            // Picture frame (top,left,bottom,right) after the 2-byte size word.
            var width = try u16(8) - u16(4)
            var height = try u16(6) - u16(2)

            // Skip zero bytes to the 0x11 version opcode, then the version.
            var p = 10
            while try u8(p) == 0 { p += 1 }
            guard try u8(p) == 0x11 else {
                throw PICTError.badHeader("0x11 not found")
            }
            let version = try u8(p + 1)
            switch version {
            case 2:
                guard try u8(p + 2) == 0xFF else { throw PICTError.badHeader("0x02,0xFF not found") }
                p += 3
            case 1:
                p += 2
            default:
                throw PICTError.badHeader("bad version \(version)")
            }

            while true {
                let op: Int
                if version == 1 {
                    op = try u8(p); p += 1
                } else {
                    if p & 1 != 0 { p += 1 }      // v2 opcodes are word aligned
                    op = try u16(p); p += 2
                }

                if op < 0xA2 {
                    switch op {
                    case 0x01:                     // clip region
                        let size = try u16(p)
                        if size == 10, try i16(p + 2) >= 0, try i16(p + 4) >= 0 {
                            width = try u16(p + 8) - u16(p + 4)
                            height = try u16(p + 6) - u16(p + 2)
                        }
                        p += size
                    case 0x12, 0x13, 0x14:
                        throw PICTError.unsupportedPattern(op)
                    case 0x1B:
                        p += 6
                    case 0x70...0x77:
                        p += try u16(p)
                    case 0x90, 0x91, 0x98, 0x99, 0x9A, 0x9B:
                        return try decodeBits(op: op, at: p, width: width, height: height)
                    case 0xA1:                     // long comment
                        p += try u16(p + 2) + 4
                    default:
                        let n = PICT.opcodeLengths[op]
                        p += n == -1 ? 2 : n
                    }
                }

                if op == 0x0C00 {
                    p += 24
                } else if op == 0x28 {             // long text: point + pstring
                    p += 4 + 1 + (try u8(p + 4))
                } else if !(0xB0...0xCF).contains(op), !(0x8000...0x80FF).contains(op) {
                    if op == 0x8200 {
                        if let sheet = try decodeQuickTime(at: p, width: width, height: height) {
                            return sheet
                        }
                        p += try u32(p) + 4
                    } else if op == 0x8201 {
                        p += try u32(p) + 4
                    } else if op == 0xFF || op == 0xFFFF {
                        throw PICTError.noImage
                    } else if (0xD0...0xFE).contains(op) || op >= 0x8100 {
                        // The exe skips the value of the first length word
                        // without consuming the word itself.
                        p += try u16(p)
                    } else if op > 0xFF, op < 0x8000 {
                        p += (op >> 7) & 0xFF
                    }
                }
                guard p < b.count else { throw PICTError.truncated(at: p) }
            }
        }

        // MARK: Bits opcodes

        func decodeBits(op: Int, at start: Int, width: Int, height: Int) throws -> SpriteSheet {
            guard width > 0, height > 0, width < 8192, height < 8192 else {
                throw PICTError.badSize(width, height)
            }
            let direct = op == 0x9A || op == 0x9B
            var q = start
            let rowBytesRaw: Int
            if direct {
                rowBytesRaw = try u16(q + 4); q += 6   // baseAddr, rowBytes
            } else {
                rowBytesRaw = try u16(q); q += 2
            }
            q += 8                                      // bounds
            let isPixMap = direct || rowBytesRaw & 0x8000 != 0
            var depth = 1
            if isPixMap {
                depth = try i16(q + 18)
                let cmpCount = try i16(q + 20)
                q += 36
                if depth == 32, cmpCount != 4 { depth = 24 }
            }

            // Default palette (0x5705cc): white at 0, black everywhere else.
            var palette = [UInt8](repeating: 0, count: 256 * 3)
            palette[0] = 0xFF; palette[1] = 0xFF; palette[2] = 0xFF
            if !direct, isPixMap {
                let flags = try u16(q + 4)
                let count = try u16(q + 6) + 1
                q += 8
                for i in 0..<count {
                    let index = flags & 0x8000 != 0 ? i : try u16(q)
                    if index < 256 {
                        palette[index * 3] = try UInt8(u8(q + 2))
                        palette[index * 3 + 1] = try UInt8(u8(q + 4))
                        palette[index * 3 + 2] = try UInt8(u8(q + 6))
                    }
                    q += 8
                }
            }
            q += 18                                     // srcRect, dstRect, mode
            if op == 0x91 || op == 0x99 || op == 0x9B {
                q += try i16(q)                         // mask region
            }

            let pixels = try decodeRows(at: q, rowBytes: rowBytesRaw & 0x7FFF,
                                        width: width, height: height, depth: depth)
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            switch depth {
            case 1, 2, 4, 8:
                for i in 0..<(width * height) {
                    let c = Int(pixels[i]) * 3
                    rgba[i * 4] = palette[c]; rgba[i * 4 + 1] = palette[c + 1]; rgba[i * 4 + 2] = palette[c + 2]
                }
            case 16:
                for i in 0..<(width * height) {
                    let v = Int(pixels[i * 2]) << 8 | Int(pixels[i * 2 + 1])
                    let r5 = (v >> 10) & 0x1F, g5 = (v >> 5) & 0x1F, b5 = v & 0x1F
                    rgba[i * 4] = UInt8(r5 << 3 | r5 >> 2)
                    rgba[i * 4 + 1] = UInt8(g5 << 3 | g5 >> 2)
                    rgba[i * 4 + 2] = UInt8(b5 << 3 | b5 >> 2)
                }
            default:                                    // 24 (and 32 → 24)
                for i in 0..<(width * height) {
                    rgba[i * 4] = pixels[i * 3]; rgba[i * 4 + 1] = pixels[i * 3 + 1]; rgba[i * 4 + 2] = pixels[i * 3 + 2]
                }
            }
            return PICT.sheet(width, height, rgba)
        }

        /// One decoded row per frame row, `width` pixels each: a byte per pixel
        /// for indexed depths, big-endian words at 16, RGB triplets at 24/32.
        func decodeRows(at start: Int, rowBytes rawRowBytes: Int, width: Int, height: Int,
                        depth: Int) throws -> [UInt8] {
            let rowLength: Int        // working row bytes (local_54)
            switch depth {
            case 1, 2, 4, 8: rowLength = width
            case 16: rowLength = width * 2
            case 24: rowLength = width * 3
            case 32: rowLength = width * 4
            default: throw PICTError.unsupportedDepth(depth)
            }
            let outRow = depth >= 24 ? width * 3 : rowLength
            let rowBytes = rawRowBytes == 0 ? rowLength : rawRowBytes
            let unit = depth == 16 ? 2 : 1
            var out = [UInt8](repeating: 0, count: outRow * height)
            var row = [UInt8](repeating: 0, count: rowLength)
            var q = start

            for y in 0..<height {
                for i in 0..<rowLength { row[i] = 0 }
                var w = 0
                func put(_ chunk: [UInt8]) {
                    let n = min(chunk.count, rowLength - w)
                    if n > 0 { for i in 0..<n { row[w + i] = chunk[i] }; w += n }
                }
                if rowBytes < 8 {
                    put(PICT.unpack(slice(q, rowBytes), depth: depth))
                    q += rowBytes
                } else {
                    let n: Int
                    if rowBytes > 250 { n = try u16(q); q += 2 } else { n = try u8(q); q += 1 }
                    guard n <= width * 4 else { throw PICTError.rowOverrun(row: y) }
                    guard q + n <= b.count else { throw PICTError.truncated(at: q + n) }
                    var k = 0
                    while k < n {
                        let flag = Int(b[q + k])
                        if flag & 0x80 == 0 {
                            let len = (flag + 1) * unit
                            put(PICT.unpack(slice(q + k + 1, len), depth: depth))
                            k += len + 1
                        } else {
                            let chunk = PICT.unpack(slice(q + k + 1, unit), depth: depth)
                            for _ in 0..<((flag ^ 0xFF) + 2) { put(chunk) }
                            k += unit + 1
                        }
                    }
                    q += n
                }
                let o = y * outRow
                switch depth {
                case 24:
                    for x in 0..<width {
                        out[o + 3 * x] = row[x]; out[o + 3 * x + 1] = row[width + x]; out[o + 3 * x + 2] = row[2 * width + x]
                    }
                case 32:                                // alpha plane skipped
                    for x in 0..<width {
                        out[o + 3 * x] = row[width + x]; out[o + 3 * x + 1] = row[2 * width + x]
                        out[o + 3 * x + 2] = row[3 * width + x]
                    }
                default:
                    for i in 0..<rowLength { out[o + i] = row[i] }
                }
            }
            return out
        }

        /// Bytes `[p, p+n)`, clipped to the data (the exe reads past a short
        /// literal from its scratch buffer; zeros stand in for that).
        func slice(_ p: Int, _ n: Int) -> [UInt8] {
            guard n > 0 else { return [] }
            var s = [UInt8](repeating: 0, count: n)
            let end = min(p + n, b.count)
            if p < end { for i in p..<end { s[i - p] = b[i] } }
            return s
        }

        // MARK: 0x8200 — QuickTime-compressed

        /// nil when the opcode's ImageDescription isn't the 0x56-byte kind (the
        /// exe then skips it); throws when the data can't be decompressed.
        func decodeQuickTime(at p: Int, width: Int, height: Int) throws -> SpriteSheet? {
            let matteSize = try u32(p + 0x2A)
            let maskSize = try u32(p + 0x44)
            let desc = p + 0x48 + matteSize + maskSize
            guard try u32(desc) == 0x56 else { return nil }
            let codec = String(bytes: slice(desc + 4, 4), encoding: .macOSRoman) ?? "????"
            let dataSize = try u32(desc + 0x2C)
            guard width > 0, height > 0, width < 8192, height < 8192 else {
                throw PICTError.badSize(width, height)
            }
            let start = desc + 0x56
            let end = dataSize > 0 ? min(b.count, start + dataSize) : b.count
            guard start < end else { throw PICTError.quickTime("no data for '\(codec)'") }
            #if canImport(ImageIO)
            let payload = Data(b[start..<end])
            guard let src = CGImageSourceCreateWithData(payload as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw PICTError.quickTime("codec '\(codec)'")
            }
            // Drawn at its own size at the top-left of a frame-sized, opaque canvas.
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return false
                }
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(image, in: CGRect(x: 0, y: height - image.height,
                                           width: image.width, height: image.height))
                return true
            }
            guard drawn else { throw PICTError.quickTime("no drawing context") }
            var i = 3
            while i < rgba.count { rgba[i] = 255; i += 4 }
            return PICT.sheet(width, height, rgba)
            #else
            throw PICTError.quickTime("no image decoder on this platform for '\(codec)'")
            #endif
        }
    }

    // MARK: - Helpers

    /// Expand 1/2/4-bit pixels MSB-first to a byte each (0x004fcac0); other
    /// depths pass through.
    static func unpack(_ bytes: [UInt8], depth: Int) -> [UInt8] {
        let per: Int
        switch depth {
        case 1: per = 8
        case 2: per = 4
        case 4: per = 2
        default: return bytes
        }
        let bits = 8 / per, mask = UInt8((1 << bits) - 1)
        var out = [UInt8](); out.reserveCapacity(bytes.count * per)
        for v in bytes {
            for k in 0..<per { out.append((v >> UInt8(8 - bits * (k + 1))) & mask) }
        }
        return out
    }

    static func sheet(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> SpriteSheet {
        SpriteSheet(frameWidth: w, frameHeight: h, frameCount: 1, columns: 1, rows: 1,
                    surfaceWidth: w, surfaceHeight: h, rgba: rgba)
    }
}
