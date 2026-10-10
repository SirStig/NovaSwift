import Foundation

/// StuffIt archive container parsing (classic "SIT!"/"rLau" and StuffIt 5).
enum StuffIt {
    struct Fork {
        var method: Int
        var length: Int      // uncompressed
        var offset: Int      // compressed data start
        var packed: Int      // compressed length
        var crc: UInt16
        var encrypted: Bool
    }

    private static let classicSigs: Set<String> = ["SIT!", "ST46", "ST50", "ST60", "ST65", "STin", "STi2", "STi3", "STi4"]
    private static let sit5Banner = Array("StuffIt (c)1997-".utf8)

    enum Kind { case classic, v5, x }

    /// Detects an archive at `at`.
    static func kind(_ b: [UInt8], at o: Int = 0) -> Kind? {
        guard b.count >= o + 22 else { return nil }
        let sig = String(decoding: b[o..<o + 4], as: UTF8.self)
        if classicSigs.contains(sig), String(decoding: b[o + 10..<o + 14], as: UTF8.self) == "rLau" { return .classic }
        if b.count >= o + 16, b[o..<o + 16].elementsEqual(sit5Banner) { return .v5 }
        if b[o..<o + 8].elementsEqual("StuffIt!".utf8) || b[o..<o + 7].elementsEqual("StuffIt".utf8) { return .x }
        return nil
    }

    /// Scans for an embedded archive (self-extracting .sea).
    static func findEmbedded(_ b: [UInt8]) -> Int? {
        var i = 0
        while i + 22 <= b.count {
            if (b[i] == 0x53 || b[i] == 0x73), kind(b, at: i) != nil { return i }
            i += 1
        }
        return nil
    }

    static func extract(_ all: [UInt8], at base: Int = 0) throws -> [MacFile] {
        let b = base == 0 ? all : Array(all[base...])
        switch kind(b) {
        case .classic: return try classic(b)
        case .v5: return try version5(b)
        case .x: throw MacArchiveError.stuffItX
        case nil: throw MacArchiveError.unrecognized
        }
    }

    // MARK: Fork decoding

    private static func decodeFork(_ f: Fork, _ b: [UInt8]) throws -> [UInt8] {
        if f.length == 0 { return [] }
        if f.encrypted { throw MacArchiveError.encrypted }
        guard f.offset >= 0, f.offset + f.packed <= b.count else { throw MacArchiveError.corrupt("fork runs past end of file") }
        let out = try StuffItCodecs.decode(method: f.method, b[f.offset..<f.offset + f.packed], outLen: f.length)
        guard MacBytes.crc16(out) == f.crc else { throw MacArchiveError.corrupt("checksum mismatch") }
        return out
    }

    // MARK: Classic

    private static func classic(_ b: [UInt8]) throws -> [MacFile] {
        let total = MacBytes.u32(b, 6)
        let end = (total >= 22 && total <= b.count) ? total : b.count
        var pos = 22
        var stack: [String] = []
        var out: [MacFile] = []
        while pos + 112 <= end {
            let rm = Int(b[pos]), dm = Int(b[pos + 1])
            let nlen = min(Int(b[pos + 2]), 63)
            let name = MacBytes.macRoman(b[pos + 3..<pos + 3 + nlen])
            if rm == 32 || dm == 32 {
                out.append(MacFile(folders: stack, name: name, isFolder: true))
                stack.append(name); pos += 112; continue
            }
            if rm == 33 || dm == 33 { _ = stack.popLast(); pos += 112; continue }
            let rLen = MacBytes.u32(b, pos + 84), dLen = MacBytes.u32(b, pos + 88)
            let rPacked = MacBytes.u32(b, pos + 92), dPacked = MacBytes.u32(b, pos + 96)
            let rCRC = UInt16(MacBytes.u16(b, pos + 100)), dCRC = UInt16(MacBytes.u16(b, pos + 102))
            let dataStart = pos + 112
            let rsrc = Fork(method: rm & 0x0F, length: rLen, offset: dataStart, packed: rPacked,
                            crc: rCRC, encrypted: rm & 0x10 != 0)
            let data = Fork(method: dm & 0x0F, length: dLen, offset: dataStart + rPacked, packed: dPacked,
                            crc: dCRC, encrypted: dm & 0x10 != 0)
            out.append(MacFile(folders: stack, name: name,
                               fileType: MacBytes.fourCC(b, pos + 66), creator: MacBytes.fourCC(b, pos + 70),
                               data: try decodeFork(data, b), rsrc: try decodeFork(rsrc, b)))
            pos = dataStart + rPacked + dPacked
        }
        guard !out.isEmpty else { throw MacArchiveError.corrupt("no entries") }
        return out
    }

    // MARK: StuffIt 5

    private static func version5(_ b: [UInt8]) throws -> [MacFile] {
        guard b.count >= 100 else { throw MacArchiveError.corrupt("StuffIt 5 header too short") }
        var pos = MacBytes.u32(b, 94)
        var out: [MacFile] = []
        var pathAt: [Int: [String]] = [:]    // folder entry offset -> its full path

        while pos + 48 <= b.count, MacBytes.u32(b, pos) == 0xA5A5A5A5 {
            let hdr = MacBytes.u16(b, pos + 6)
            let flags = Int(b[pos + 9])
            let parent = MacBytes.u32(b, pos + 26)
            let nlen = MacBytes.u16(b, pos + 30)
            let isFolder = flags & 0x40 != 0
            let encrypted = flags & 0x20 != 0
            guard hdr >= 48, pos + hdr <= b.count else { throw MacArchiveError.corrupt("bad StuffIt 5 entry") }
            let dLen = MacBytes.u32(b, pos + 34), dPacked = MacBytes.u32(b, pos + 38)
            let dCRC = UInt16(MacBytes.u16(b, pos + 42))
            let dMethod = Int(b[pos + 46])
            var p = pos + 48
            if encrypted { p += Int(b[pos + 47]) }
            guard p + nlen <= pos + hdr else { throw MacArchiveError.corrupt("bad StuffIt 5 name") }
            let name = MacBytes.macRoman(b[p..<p + nlen])
            p += nlen
            let folders = pathAt[parent] ?? []

            if isFolder {
                pathAt[pos] = folders + [name]
                out.append(MacFile(folders: folders, name: name, isFolder: true))
                pos += hdr
                continue
            }

            // Comment, then flags2 / Finder info / resource-fork descriptor.
            if p + 4 <= pos + hdr { p += 4 + MacBytes.u16(b, p) }
            guard p + 12 <= pos + hdr else { throw MacArchiveError.corrupt("bad StuffIt 5 header") }
            let flags2 = MacBytes.u16(b, p)
            let type = MacBytes.fourCC(b, p + 4), creator = MacBytes.fourCC(b, p + 8)
            var rLen = 0, rPacked = 0, rCRC: UInt16 = 0, rMethod = 0
            if flags2 & 1 != 0 {
                // Fixed gap between the Finder block and the descriptor; probe the
                // plausible widths and keep the one whose fields are coherent.
                var found = false
                for skip in [22, 18, 20, 24, 26, 14, 16, 28, 30, 12, 10, 32] {
                    let o = p + 12 + skip
                    guard o + 14 <= pos + hdr else { continue }
                    let rl = MacBytes.u32(b, o), rp = MacBytes.u32(b, o + 4)
                    let rm = Int(b[o + 10])
                    if [0, 1, 2, 3, 5, 13, 15].contains(rm), rp <= b.count, pos + hdr + rp + dPacked <= b.count, rl < 0x8000000 {
                        rLen = rl; rPacked = rp; rCRC = UInt16(MacBytes.u16(b, o + 8)); rMethod = rm
                        found = true; break
                    }
                }
                guard found else { throw MacArchiveError.corrupt("bad StuffIt 5 resource descriptor") }
            }
            let start = pos + hdr
            let dataFork = Fork(method: dMethod, length: dLen, offset: start + rPacked, packed: dPacked, crc: dCRC, encrypted: encrypted)
            let rsrcFork = Fork(method: rMethod, length: rLen, offset: start, packed: rPacked, crc: rCRC, encrypted: encrypted)
            out.append(MacFile(folders: folders, name: name, fileType: type, creator: creator,
                               data: try decodeFork(dataFork, b), rsrc: try decodeFork(rsrcFork, b)))
            pos = start + rPacked + dPacked
        }
        guard !out.isEmpty else { throw MacArchiveError.corrupt("no entries") }
        return out
    }

    // MARK: Test support

    /// Builds a classic archive from already-compressed forks (tests).
    static func buildClassic(_ items: [(name: String, rsrcMethod: Int, rsrc: [UInt8], rsrcPacked: [UInt8],
                                        dataMethod: Int, data: [UInt8], dataPacked: [UInt8])],
                             folderNames: [String] = []) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func header(name: String, rm: Int, dm: Int, rLen: Int, dLen: Int, rp: Int, dp: Int, rc: UInt16, dc: UInt16) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: 112)
            h[0] = UInt8(rm); h[1] = UInt8(dm)
            let nm = Array((name.data(using: .macOSRoman) ?? Data(name.utf8)).prefix(63))
            h[2] = UInt8(nm.count); h.replaceSubrange(3..<3 + nm.count, with: nm)
            h.replaceSubrange(84..<88, with: be32(rLen)); h.replaceSubrange(88..<92, with: be32(dLen))
            h.replaceSubrange(92..<96, with: be32(rp)); h.replaceSubrange(96..<100, with: be32(dp))
            h.replaceSubrange(100..<102, with: be16(Int(rc))); h.replaceSubrange(102..<104, with: be16(Int(dc)))
            return h
        }
        var body: [UInt8] = []
        for f in folderNames { body += header(name: f, rm: 32, dm: 32, rLen: 0, dLen: 0, rp: 0, dp: 0, rc: 0, dc: 0) }
        for it in items {
            body += header(name: it.name, rm: it.rsrcMethod, dm: it.dataMethod, rLen: it.rsrc.count, dLen: it.data.count,
                           rp: it.rsrcPacked.count, dp: it.dataPacked.count,
                           rc: MacBytes.crc16(it.rsrc), dc: MacBytes.crc16(it.data))
            body += it.rsrcPacked + it.dataPacked
        }
        for _ in folderNames { body += header(name: "", rm: 33, dm: 33, rLen: 0, dLen: 0, rp: 0, dp: 0, rc: 0, dc: 0) }
        var h = Array("SIT!".utf8) + be16(items.count) + be32(22 + body.count) + Array("rLau".utf8) + [1, 0]
        h += [UInt8](repeating: 0, count: 22 - h.count)
        return h + body
    }
}
