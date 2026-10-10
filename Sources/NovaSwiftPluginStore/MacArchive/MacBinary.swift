import Foundation

/// MacBinary I / II / III container codec.
enum MacBinary {
    /// Parses the 128-byte header; nil when `b` doesn't look like MacBinary.
    static func decode(_ b: [UInt8]) -> MacFile? {
        guard b.count >= 128, b[0] == 0, b[74] == 0, b[82] == 0 else { return nil }
        let nlen = Int(b[1])
        guard (1...63).contains(nlen) else { return nil }
        let dlen = MacBytes.u32(b, 83), rlen = MacBytes.u32(b, 87)
        guard dlen < 0x800000, rlen < 0x800000 else { return nil }
        let crcOK = MacBytes.crcCCITT(b[0..<124]) == UInt16(MacBytes.u16(b, 124))
        let isIII = b[102..<106].elementsEqual("mBIN".utf8)
        let isI = b[99...125].allSatisfy { $0 == 0 }
        guard crcOK || isIII || isI else { return nil }
        var pos = 128
        let secondary = crcOK ? MacBytes.u16(b, 120) : 0
        pos += (secondary + 127) / 128 * 128
        guard pos + dlen <= b.count else { return nil }
        let data = Array(b[pos..<pos + dlen])
        pos += (dlen + 127) / 128 * 128
        var rsrc: [UInt8] = []
        if rlen > 0 {
            guard pos + rlen <= b.count else { return nil }
            rsrc = Array(b[pos..<pos + rlen])
        }
        return MacFile(name: MacBytes.macRoman(b[2..<2 + nlen]),
                       fileType: MacBytes.fourCC(b, 65), creator: MacBytes.fourCC(b, 69),
                       data: data, rsrc: rsrc)
    }

    /// Encoder (MacBinary II), used by tests.
    static func encode(_ f: MacFile, name: String) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 128)
        let nm = Array((name.data(using: .macOSRoman) ?? Data(name.utf8)).prefix(63))
        h[1] = UInt8(nm.count); h.replaceSubrange(2..<2 + nm.count, with: nm)
        h.replaceSubrange(65..<69, with: Array(f.fileType.utf8.prefix(4)))
        h.replaceSubrange(69..<73, with: Array(f.creator.utf8.prefix(4)))
        func put(_ v: Int, _ o: Int) { for k in 0..<4 { h[o + k] = UInt8(v >> (24 - 8 * k) & 255) } }
        put(f.data.count, 83); put(f.rsrc.count, 87)
        h[122] = 129; h[123] = 129
        let crc = MacBytes.crcCCITT(h[0..<124]); h[124] = UInt8(crc >> 8); h[125] = UInt8(crc & 255)
        func padded(_ a: [UInt8]) -> [UInt8] { a + [UInt8](repeating: 0, count: (128 - a.count % 128) % 128) }
        return h + padded(f.data) + padded(f.rsrc)
    }
}
