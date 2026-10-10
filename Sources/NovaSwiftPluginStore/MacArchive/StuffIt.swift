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
        var out: [MacFile] = []
        var seen = Set<Int>()
        // Members form linked lists (via the "next" offset); a folder's contents
        // are a separate list starting at its "first entry" offset.
        func walk(first: Int, count: Int, folders: [String], depth: Int) throws {
            guard depth < 32 else { throw MacArchiveError.corrupt("folders nested too deeply") }
            var pos = first, n = 0
            while pos != 0, n < count {
                guard pos + 48 <= b.count, MacBytes.u32(b, pos) == 0xA5A5A5A5, seen.insert(pos).inserted else {
                    throw MacArchiveError.corrupt("bad StuffIt 5 entry")
                }
                let hdr = MacBytes.u16(b, pos + 6)
                guard hdr >= 48, pos + hdr <= b.count else { throw MacArchiveError.corrupt("bad StuffIt 5 header") }
                let flags = Int(b[pos + 9])
                let next = MacBytes.u32(b, pos + 22)
                let nlen = MacBytes.u16(b, pos + 30)
                let isFolder = flags & 0x40 != 0
                let encrypted = flags & 0x20 != 0
                var p = pos + 48
                var dLen = 0, dPacked = 0, dMethod = 0
                var dCRC: UInt16 = 0
                var firstChild = 0, childCount = 0
                if isFolder {
                    firstChild = MacBytes.u32(b, pos + 34)
                    childCount = MacBytes.u16(b, pos + 46)
                } else {
                    dLen = MacBytes.u32(b, pos + 34); dPacked = MacBytes.u32(b, pos + 38)
                    dCRC = UInt16(MacBytes.u16(b, pos + 42))
                    dMethod = Int(b[pos + 46]) & 0x0F
                    p += Int(b[pos + 47])
                }
                guard p + nlen <= pos + hdr else { throw MacArchiveError.corrupt("bad StuffIt 5 name") }
                let name = MacBytes.macRoman(b[p..<p + nlen])
                if isFolder {
                    out.append(MacFile(folders: folders, name: name, isFolder: true))
                    try walk(first: firstChild, count: childCount, folders: folders + [name], depth: depth + 1)
                } else {
                    // Second block follows the base header: flags, Finder info, resource-fork descriptor.
                    var q = pos + hdr
                    guard q + 36 <= b.count else { throw MacArchiveError.corrupt("StuffIt 5 entry truncated") }
                    let flags2 = MacBytes.u16(b, q)
                    let type = MacBytes.fourCC(b, q + 4), creator = MacBytes.fourCC(b, q + 8)
                    q += 36
                    var rLen = 0, rPacked = 0, rMethod = 0
                    var rCRC: UInt16 = 0
                    if flags2 & 1 != 0 {
                        guard q + 14 <= b.count else { throw MacArchiveError.corrupt("StuffIt 5 entry truncated") }
                        rLen = MacBytes.u32(b, q); rPacked = MacBytes.u32(b, q + 4)
                        rCRC = UInt16(MacBytes.u16(b, q + 8))
                        rMethod = Int(b[q + 12]) & 0x0F
                        q += 14 + Int(b[q + 13])
                    }
                    let rsrcFork = Fork(method: rMethod, length: rLen, offset: q, packed: rPacked, crc: rCRC, encrypted: encrypted)
                    let dataFork = Fork(method: dMethod, length: dLen, offset: q + rPacked, packed: dPacked, crc: dCRC, encrypted: encrypted)
                    out.append(MacFile(folders: folders, name: name, fileType: type, creator: creator,
                                       data: try decodeFork(dataFork, b), rsrc: try decodeFork(rsrcFork, b)))
                }
                pos = next; n += 1
            }
        }
        try walk(first: MacBytes.u32(b, 94), count: MacBytes.u16(b, 92), folders: [], depth: 0)
        guard !out.isEmpty else { throw MacArchiveError.corrupt("no entries") }
        return out
    }

    /// Builds a StuffIt 5 container with stored (method 0) forks (tests):
    /// one folder holding the given files.
    static func buildV5(folder: String, files: [(name: String, data: [UInt8], rsrc: [UInt8])]) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func mr(_ s: String) -> [UInt8] { Array(s.data(using: .macOSRoman) ?? Data(s.utf8)) }
        var banner = Array("StuffIt (c)1997-2002 Aladdin Systems, Inc., http://www.aladdinsys.com/StuffIt/\r\n".utf8)
        banner += [UInt8](repeating: 0, count: max(0, 80 - banner.count))
        let archiveHdrLen = 100
        let folderPos = archiveHdrLen
        let folderName = mr(folder)
        let folderHdrLen = 48 + folderName.count
        var entries: [[UInt8]] = []
        var pos = folderPos + folderHdrLen
        var positions: [Int] = []
        for f in files {
            positions.append(pos)
            pos += 48 + mr(f.name).count + 36 + (f.rsrc.isEmpty ? 0 : 14) + f.rsrc.count + f.data.count
        }
        var folderHdr = [UInt8](repeating: 0, count: folderHdrLen)
        folderHdr.replaceSubrange(0..<4, with: be32(0xA5A5A5A5))
        folderHdr.replaceSubrange(6..<8, with: be16(folderHdrLen))
        folderHdr[9] = 0x40
        folderHdr.replaceSubrange(30..<32, with: be16(folderName.count))
        folderHdr.replaceSubrange(34..<38, with: be32(positions.first ?? 0))
        folderHdr.replaceSubrange(46..<48, with: be16(files.count))
        folderHdr.replaceSubrange(48..<48 + folderName.count, with: folderName)
        entries.append(folderHdr)
        for (i, f) in files.enumerated() {
            let nm = mr(f.name)
            let hdrLen = 48 + nm.count
            var h = [UInt8](repeating: 0, count: hdrLen)
            h.replaceSubrange(0..<4, with: be32(0xA5A5A5A5))
            h.replaceSubrange(6..<8, with: be16(hdrLen))
            h.replaceSubrange(22..<26, with: be32(i + 1 < files.count ? positions[i + 1] : 0))
            h.replaceSubrange(26..<30, with: be32(folderPos))
            h.replaceSubrange(30..<32, with: be16(nm.count))
            h.replaceSubrange(34..<38, with: be32(f.data.count)); h.replaceSubrange(38..<42, with: be32(f.data.count))
            h.replaceSubrange(42..<44, with: be16(Int(MacBytes.crc16(f.data))))
            h.replaceSubrange(48..<48 + nm.count, with: nm)
            var block = [UInt8](repeating: 0, count: 36)
            block[1] = f.rsrc.isEmpty ? 0 : 1
            block.replaceSubrange(4..<8, with: Array("rsrc".utf8)); block.replaceSubrange(8..<12, with: Array("NOVA".utf8))
            if !f.rsrc.isEmpty {
                block += be32(f.rsrc.count) + be32(f.rsrc.count) + be16(Int(MacBytes.crc16(f.rsrc))) + [0, 0, 0, 0]
            }
            entries.append(h + block + f.rsrc + f.data)
        }
        var ah = banner + [0, 0, 5, 0] + be32(pos) + [0, 0, 0, 0] + be16(1) + be32(folderPos) + be16(0)
        ah += [UInt8](repeating: 0, count: archiveHdrLen - ah.count)
        return ah + entries.flatMap { $0 }
    }


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
