import Foundation

// A dependency-free PNG writer for the platforms that have no CoreGraphics /
// ImageIO — Linux and Windows, where `novaswift-extract` still has to turn a
// decoded rlëD / PICT / cicn surface into a file. `SpriteSheet+Image.swift`
// provides the same `pngData()` / `writePNG(to:)` on Apple platforms via
// ImageIO, so extractor call sites stay platform-agnostic.
//
// The deflate stream is emitted as *stored* (uncompressed) blocks. That is a
// legal RFC 1951 stream, so every PNG reader accepts the result, and it keeps
// this file free of any zlib/system dependency — corelibs-Foundation ships no
// compression at all, which is exactly why the Apple-only path existed. The
// cost is file size, the right trade for a developer-side extraction tool that
// runs offline.
#if !canImport(CoreGraphics)

public extension SpriteSheet {

    /// Encode the full grid as PNG bytes (8-bit RGBA, straight alpha).
    func pngData() -> Data? {
        PNGEncoder.encodeRGBA8(width: surfaceWidth, height: surfaceHeight, rgba: rgba)
    }

    /// Write the full grid to a PNG file.
    @discardableResult
    func writePNG(to url: URL) -> Bool {
        guard let data = pngData() else { return false }
        return (try? data.write(to: url)) != nil
    }
}

/// Minimal PNG serialiser: signature + IHDR + IDAT + IEND, colour type 6
/// (truecolour with alpha) at bit depth 8, no interlacing, filter type 0 on
/// every scanline.
enum PNGEncoder {

    static func encodeRGBA8(width: Int, height: Int, rgba: [UInt8]) -> Data? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }

        // Raw scanlines: each row is prefixed with its filter-type byte (0 = None).
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 4 + 1))
        let stride = width * 4
        for row in 0..<height {
            raw.append(0)
            let start = row * stride
            raw.append(contentsOf: rgba[start..<(start + stride)])
        }

        var ihdr = Data()
        ihdr.append(beUInt32(UInt32(width)))
        ihdr.append(beUInt32(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // bit depth, colour type, compression, filter, interlace

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    // MARK: - Chunks

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.append(beUInt32(UInt32(payload.count)))
        var body = Data(type.utf8)
        body.append(payload)
        out.append(body)
        out.append(beUInt32(crc32(body)))
        return out
    }

    private static func beUInt32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }

    // MARK: - zlib stream of stored deflate blocks

    /// RFC 1950 wrapper around RFC 1951 stored blocks. A stored block carries at
    /// most 0xFFFF bytes, so the payload is chunked; the last one sets BFINAL.
    private static func zlibStored(_ bytes: [UInt8]) -> Data {
        var out = Data()
        out.append(contentsOf: [0x78, 0x01]) // CM/CINFO = deflate/32K, FCHECK for FLEVEL 0
        out.reserveCapacity(bytes.count + bytes.count / 0xFFFF * 5 + 16)

        let maxBlock = 0xFFFF
        var offset = 0
        repeat {
            let len = Swift.min(maxBlock, bytes.count - offset)
            let isFinal = (offset + len == bytes.count)
            out.append(isFinal ? 0x01 : 0x00)
            let l = UInt16(len)
            let n = ~l
            out.append(contentsOf: [UInt8(truncatingIfNeeded: l), UInt8(truncatingIfNeeded: l >> 8),
                                    UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)])
            out.append(contentsOf: bytes[offset..<(offset + len)])
            offset += len
        } while offset < bytes.count

        out.append(beUInt32(adler32(bytes)))
        return out
    }

    // MARK: - Checksums

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Adler-32 with the usual NMAX deferred-modulo chunking — a `% 65521` per
    /// byte would dominate the cost on a full sprite surface.
    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let base: UInt32 = 65521, nmax = 5552
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = Swift.min(i + nmax, bytes.count)
            while i < end {
                a &+= UInt32(bytes[i])
                b &+= a
                i += 1
            }
            a %= base
            b %= base
        }
        return (b << 16) | a
    }
}

#endif
