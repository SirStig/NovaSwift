import Foundation

/// BinHex 4.0 (.hqx) codec, written from the public format description.
enum BinHex {
    private static let alphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
    private static let lookup: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    private static func find(_ needle: [UInt8], in hay: ArraySlice<UInt8>) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = hay.startIndex
        while i + needle.count <= hay.endIndex {
            if hay[i] == needle[0], hay[i..<i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    /// Offset of the opening ':' of the encoded body, or nil if this isn't BinHex.
    static func bodyStart(_ b: [UInt8]) -> Int? {
        let banner = Array("must be converted with BinHex".utf8)
        var i = 0
        if let at = find(banner, in: b.prefix(8192)) { i = at }
        else {
            // Bare body: ':' after optional whitespace at the very start.
            while i < min(b.count, 64), [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
            return (i < b.count && b[i] == UInt8(ascii: ":")) ? i : nil
        }
        while i < b.count {
            if b[i] == UInt8(ascii: ":"), i == 0 || b[i - 1] == 0x0A || b[i - 1] == 0x0D { return i }
            i += 1
        }
        return nil
    }

    static func decode(_ b: [UInt8]) throws -> MacFile {
        guard let start = bodyStart(b) else { throw MacArchiveError.unrecognized }
        var raw: [UInt8] = []
        raw.reserveCapacity(b.count * 3 / 4)
        var acc = 0, nbits = 0
        var i = start + 1
        var terminated = false
        while i < b.count {
            let c = b[i]; i += 1
            if c == UInt8(ascii: ":") { terminated = true; break }
            if c == 0x0A || c == 0x0D || c == 0x20 || c == 0x09 { continue }
            let v = lookup[Int(c)]
            guard v >= 0 else { throw MacArchiveError.corrupt("bad BinHex character") }
            acc = (acc << 6) | Int(v); nbits += 6
            if nbits >= 8 { nbits -= 8; raw.append(UInt8((acc >> nbits) & 0xFF)); acc &= (1 << nbits) - 1 }
        }
        guard terminated else { throw MacArchiveError.corrupt("BinHex data is truncated") }
        let d = try MacBytes.rleDecode(raw[...])
        guard d.count > 21 else { throw MacArchiveError.corrupt("BinHex header too short") }
        let nlen = Int(d[0])
        let h = 1 + nlen + 1   // after name + version byte
        guard d.count >= h + 20 else { throw MacArchiveError.corrupt("BinHex header too short") }
        let name = MacBytes.macRoman(d[1..<1 + nlen])
        let type = MacBytes.fourCC(d, h), creator = MacBytes.fourCC(d, h + 4)
        let dlen = MacBytes.u32(d, h + 10), rlen = MacBytes.u32(d, h + 14)
        let dStart = h + 20            // type4 creator4 flags2 dlen4 rlen4 crc2
        guard dStart + dlen + 2 + rlen <= d.count else { throw MacArchiveError.corrupt("BinHex forks truncated") }
        let data = Array(d[dStart..<dStart + dlen])
        let rStart = dStart + dlen + 2
        let rsrc = Array(d[rStart..<rStart + rlen])
        return MacFile(name: name, fileType: type, creator: creator, data: data, rsrc: rsrc)
    }

    /// Encoder, used by tests.
    static func encode(_ f: MacFile, name: String) -> [UInt8] {
        var body: [UInt8] = []
        let nm = Array(name.data(using: .macOSRoman) ?? Data(name.utf8))
        body.append(UInt8(nm.count)); body += nm; body.append(0)
        body += Array(f.fileType.utf8.prefix(4)) + Array(f.creator.utf8.prefix(4))
        body += [0, 0]
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        body += be32(f.data.count) + be32(f.rsrc.count) + [0, 0]
        body += f.data + [0, 0] + f.rsrc + [0, 0]
        var rle: [UInt8] = []
        for c in body { rle.append(c); if c == 0x90 { rle.append(0) } }
        var out = Array("(This file must be converted with BinHex 4.0)\r\r:".utf8)
        var acc = 0, nbits = 0, col = 1
        func emit(_ v: Int) {
            out.append(alphabet[v]); col += 1
            if col >= 64 { out.append(0x0D); col = 0 }
        }
        for c in rle {
            acc = (acc << 8) | Int(c); nbits += 8
            while nbits >= 6 { nbits -= 6; emit((acc >> nbits) & 63); acc &= (1 << nbits) - 1 }
        }
        if nbits > 0 { emit((acc << (6 - nbits)) & 63) }
        out.append(UInt8(ascii: ":")); out.append(0x0D)
        return out
    }
}
