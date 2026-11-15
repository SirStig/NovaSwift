import Foundation

/// StuffIt fork decompressors. Methods 0–3, 5 (LZAH), 13 (LZ+Huffman) and
/// 15 (Arsenic) are implemented. Anything else throws `.unsupportedMethod`.
enum StuffItCodecs {
    static func decode(method: Int, _ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        switch method {
        case 0:
            guard src.count >= outLen else { throw MacArchiveError.corrupt("stored fork truncated") }
            return Array(src.prefix(outLen))
        case 1: return try MacBytes.rleDecode(src, limit: outLen)
        case 2: return try lzw(src, outLen: outLen, maxBits: 14)
        case 3: return try huffman(src, outLen: outLen)
        case 5: return try lzah(src, outLen: outLen)
        case 13: return try lzHuffman(src, outLen: outLen)
        case 15: return try arsenic(src, outLen: outLen)
        default: throw MacArchiveError.unsupportedMethod(method)
        }
    }

    // MARK: Method 2 — "compress" style LZW (LSB-first, block mode, 9...maxBits)

    static func lzw(_ src: ArraySlice<UInt8>, outLen: Int, maxBits: Int) throws -> [UInt8] {
        let s = Array(src)
        let totalBits = s.count * 8
        var prefix = [UInt16](repeating: 0, count: 1 << maxBits)
        var suffix = [UInt8](repeating: 0, count: 1 << maxBits)
        for i in 0..<256 { suffix[i] = UInt8(i) }
        var out: [UInt8] = []
        out.reserveCapacity(outLen)
        var bits = 9, freeEnt = 257, pos = 0, groupStart = 0
        var clearPending = false

        func realign() {
            // "compress" emits codes in groups of 8; a width change or clear
            // abandons the rest of the current group.
            let group = bits * 8
            let rel = pos - groupStart
            if rel % group != 0 { pos += group - rel % group }
            groupStart = pos
        }
        func readCode() -> Int? {
            if freeEnt > (1 << bits) - 1 && bits < maxBits { realign(); bits += 1 }
            if clearPending { realign(); bits = 9; clearPending = false }
            if pos + bits > totalBits { return nil }
            var v = 0
            for k in 0..<bits {
                let p = pos + k
                v |= Int((s[p >> 3] >> UInt8(p & 7)) & 1) << k
            }
            pos += bits
            if pos - groupStart >= bits * 8 { groupStart = pos }
            return v
        }

        guard var oldCode = readCode() else {
            if outLen > 0 { throw MacArchiveError.corrupt("LZW data ended early") }
            return out
        }
        guard oldCode < 256 else { throw MacArchiveError.corrupt("bad first LZW code") }
        var finChar = UInt8(oldCode)
        out.append(finChar)
        var stack: [UInt8] = []
        while out.count < outLen, var code = readCode() {
            if code == 256 {
                freeEnt = 256; clearPending = true
                guard let c = readCode() else { break }
                code = c
            }
            let inCode = code
            stack.removeAll(keepingCapacity: true)
            if code >= freeEnt {
                guard code == freeEnt else { throw MacArchiveError.corrupt("bad LZW code") }
                stack.append(finChar); code = oldCode
            }
            // A real chain is at most one entry per table slot; a crafted stream (a clear
            // code followed by another, which leaves slot 256 pointing at a stale code)
            // can loop, so bound the walk.
            var steps = 0
            while code >= 256 {
                steps += 1
                guard steps <= (1 << maxBits) else { throw MacArchiveError.corrupt("LZW chain loops") }
                stack.append(suffix[code]); code = Int(prefix[code])
            }
            finChar = suffix[code]
            stack.append(finChar)
            out.append(contentsOf: stack.reversed())
            if freeEnt < (1 << maxBits) {
                prefix[freeEnt] = UInt16(oldCode); suffix[freeEnt] = finChar; freeEnt += 1
            }
            oldCode = inCode
        }
        guard out.count >= outLen else { throw MacArchiveError.corrupt("LZW data ended early") }
        if out.count > outLen { out.removeSubrange(outLen...) }
        return out
    }

    // MARK: Method 3 — static Huffman, tree stored in the stream (MSB-first)

    static func huffman(_ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        let s = Array(src)
        var pos = 0
        func bit() throws -> Int {
            guard pos >> 3 < s.count else { throw MacArchiveError.corrupt("Huffman data ended early") }
            let v = Int(s[pos >> 3] >> UInt8(7 - (pos & 7))) & 1
            pos += 1
            return v
        }
        // Node table: children[n] = (left, right) or leaf value (negative = -(value + 1)).
        var left: [Int] = [], right: [Int] = []
        func readTree(depth: Int) throws -> Int {
            guard depth < 300, left.count < 600 else { throw MacArchiveError.corrupt("bad Huffman tree") }
            if try bit() == 1 {
                var v = 0
                for _ in 0..<8 { v = v << 1 | (try bit()) }
                return -(v + 1)
            }
            let idx = left.count
            left.append(0); right.append(0)
            let l = try readTree(depth: depth + 1)
            let r = try readTree(depth: depth + 1)
            left[idx] = l; right[idx] = r
            return idx
        }
        let root = try readTree(depth: 0)
        var out: [UInt8] = []
        out.reserveCapacity(outLen)
        if root < 0 {   // degenerate single-symbol tree
            return [UInt8](repeating: UInt8(-root - 1), count: outLen)
        }
        while out.count < outLen {
            var n = root
            while n >= 0 { n = try bit() == 0 ? left[n] : right[n] }
            out.append(UInt8(-n - 1))
        }
        return out
    }

    private static let sit13First1: [Int] = [
        4, 5, 7, 8, 8, 9, 9, 9, 9, 7, 9, 9, 9, 8, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 10, 9, 9, 10, 10, 9, 10, 9, 9,
        5, 9, 9, 9, 9, 10, 9, 9, 9, 9, 9, 9, 9, 9, 7, 9,
        9, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9, 8, 9, 9, 8, 8, 9, 9, 9, 9, 9, 9, 9, 7, 8, 9,
        7, 9, 9, 7, 7, 9, 9, 9, 9, 10, 9, 10, 10, 10, 9, 9,
        9, 5, 9, 8, 7, 5, 9, 8, 8, 7, 9, 9, 8, 8, 5, 5,
        7, 10, 5, 8, 5, 8, 9, 9, 9, 9, 9, 10, 9, 9, 10, 9,
        9, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 9, 9, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 9, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 9, 10, 9, 5,
        6, 5, 5, 8, 9, 9, 9, 9, 9, 9, 10, 10, 10, 9, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 9, 10, 9, 9, 9, 10, 9, 10, 9, 10, 9, 10, 9,
        10, 10, 10, 9, 10, 9, 10, 10, 9, 9, 9, 6, 9, 9, 10, 9,
        5
    ]

    private static let sit13Second1: [Int] = [
        4, 5, 6, 6, 7, 7, 6, 7, 7, 7, 6, 8, 7, 8, 8, 8,
        8, 9, 6, 9, 8, 9, 8, 9, 9, 9, 8, 10, 5, 9, 7, 9,
        6, 9, 8, 10, 9, 10, 8, 8, 9, 9, 7, 9, 8, 9, 8, 9,
        8, 8, 6, 9, 9, 8, 8, 9, 9, 10, 8, 9, 9, 10, 8, 10,
        8, 8, 8, 8, 8, 9, 7, 10, 6, 9, 9, 11, 7, 8, 8, 9,
        8, 10, 7, 8, 6, 9, 10, 9, 9, 10, 8, 11, 9, 11, 9, 10,
        9, 8, 9, 8, 8, 8, 8, 10, 9, 9, 10, 10, 8, 9, 8, 8,
        8, 11, 9, 8, 8, 9, 9, 10, 8, 11, 10, 10, 8, 10, 9, 10,
        8, 9, 9, 11, 9, 11, 9, 10, 10, 11, 10, 12, 9, 12, 10, 11,
        10, 11, 9, 10, 10, 11, 10, 11, 10, 11, 10, 11, 10, 10, 10, 9,
        9, 9, 8, 7, 6, 8, 11, 11, 9, 12, 10, 12, 9, 11, 11, 11,
        10, 12, 11, 11, 10, 12, 10, 11, 10, 10, 10, 11, 10, 11, 11, 11,
        9, 12, 10, 12, 11, 12, 10, 11, 10, 12, 11, 12, 11, 12, 11, 12,
        10, 12, 11, 12, 11, 11, 10, 12, 10, 11, 10, 12, 10, 12, 10, 12,
        10, 11, 11, 11, 10, 11, 11, 11, 10, 12, 11, 12, 10, 10, 11, 11,
        9, 12, 11, 12, 10, 11, 10, 12, 10, 11, 10, 12, 10, 11, 10, 7,
        5, 4, 6, 6, 7, 7, 7, 8, 8, 7, 7, 6, 8, 6, 7, 7,
        9, 8, 9, 9, 10, 11, 11, 11, 12, 11, 10, 11, 12, 11, 12, 11,
        12, 12, 12, 12, 11, 12, 12, 11, 12, 11, 12, 11, 13, 11, 12, 10,
        13, 10, 14, 14, 13, 14, 15, 14, 16, 15, 15, 18, 18, 18, 9, 18,
        8
    ]

    private static let sit13Offset1: [Int] = [
        5, 6, 3, 3, 3, 3, 3, 3, 3, 4, 6
    ]

    private static let sit13First2: [Int] = [
        4, 7, 7, 8, 7, 8, 8, 8, 8, 7, 8, 7, 8, 7, 9, 8,
        8, 8, 9, 9, 9, 9, 10, 10, 9, 10, 10, 10, 10, 10, 9, 9,
        5, 9, 8, 9, 9, 11, 10, 9, 8, 9, 9, 9, 8, 9, 7, 8,
        8, 8, 9, 9, 9, 9, 9, 10, 9, 9, 9, 10, 9, 9, 10, 9,
        8, 8, 7, 7, 7, 8, 8, 9, 8, 8, 9, 9, 8, 8, 7, 8,
        7, 10, 8, 7, 7, 9, 9, 9, 9, 10, 10, 11, 11, 11, 10, 9,
        8, 6, 8, 7, 7, 5, 7, 7, 7, 6, 9, 8, 6, 7, 6, 6,
        7, 9, 6, 6, 6, 7, 8, 8, 8, 8, 9, 10, 9, 10, 9, 9,
        8, 9, 10, 10, 9, 10, 10, 9, 9, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 11, 10, 10, 10, 10, 10, 10, 10, 11, 10, 11, 10, 10,
        9, 11, 10, 10, 10, 10, 10, 10, 9, 9, 10, 11, 10, 11, 10, 11,
        10, 12, 10, 11, 10, 12, 11, 12, 10, 12, 10, 11, 10, 11, 11, 11,
        9, 10, 11, 11, 11, 12, 12, 10, 10, 10, 11, 11, 10, 11, 10, 10,
        9, 11, 10, 11, 10, 11, 11, 11, 10, 11, 11, 12, 11, 11, 10, 10,
        10, 11, 10, 10, 11, 11, 12, 10, 10, 11, 11, 12, 11, 11, 10, 11,
        9, 12, 10, 11, 11, 11, 10, 11, 10, 11, 10, 11, 9, 10, 9, 7,
        3, 5, 6, 6, 7, 7, 8, 8, 8, 9, 9, 9, 11, 10, 10, 10,
        12, 13, 11, 12, 12, 11, 13, 12, 12, 11, 12, 12, 13, 12, 14, 13,
        14, 13, 15, 13, 14, 15, 15, 14, 13, 15, 15, 14, 15, 14, 15, 15,
        14, 15, 13, 13, 14, 15, 15, 14, 14, 16, 16, 15, 15, 15, 12, 15,
        10
    ]

    private static let sit13Second2: [Int] = [
        5, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 8, 7, 8, 7, 7,
        7, 8, 8, 8, 8, 9, 8, 9, 8, 9, 9, 9, 7, 9, 8, 8,
        6, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 9, 8, 8,
        8, 8, 8, 9, 8, 9, 8, 9, 9, 10, 8, 10, 8, 9, 9, 8,
        8, 8, 7, 8, 8, 9, 8, 9, 7, 9, 8, 10, 8, 9, 8, 9,
        8, 9, 8, 8, 8, 9, 9, 9, 9, 10, 9, 11, 9, 10, 9, 10,
        8, 8, 8, 9, 8, 8, 8, 9, 9, 8, 9, 10, 8, 9, 8, 8,
        8, 11, 8, 7, 8, 9, 9, 9, 9, 10, 9, 10, 9, 10, 9, 8,
        8, 9, 9, 10, 9, 10, 9, 10, 8, 10, 9, 10, 9, 11, 10, 11,
        9, 11, 10, 10, 10, 11, 9, 11, 9, 10, 9, 11, 9, 11, 10, 10,
        9, 10, 9, 9, 8, 10, 9, 11, 9, 9, 9, 11, 10, 11, 9, 11,
        9, 11, 9, 11, 10, 11, 10, 11, 10, 11, 9, 10, 10, 11, 10, 10,
        8, 10, 9, 10, 10, 11, 9, 11, 9, 10, 10, 11, 9, 10, 10, 9,
        9, 10, 9, 10, 9, 10, 9, 10, 9, 11, 9, 11, 10, 10, 9, 10,
        9, 11, 9, 11, 9, 11, 9, 10, 9, 11, 9, 11, 9, 11, 9, 10,
        8, 11, 9, 10, 9, 10, 9, 10, 8, 10, 8, 9, 8, 9, 8, 7,
        4, 4, 5, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 7, 8, 8,
        9, 9, 10, 10, 10, 10, 10, 10, 11, 11, 10, 10, 12, 11, 11, 12,
        12, 11, 12, 12, 11, 12, 12, 12, 12, 12, 12, 11, 12, 11, 13, 12,
        13, 12, 13, 14, 14, 14, 15, 13, 14, 13, 14, 18, 18, 17, 7, 16,
        9
    ]

    private static let sit13Offset2: [Int] = [
        5, 6, 4, 4, 3, 3, 3, 3, 3, 4, 4, 4, 6
    ]

    private static let sit13First3: [Int] = [
        6, 6, 6, 6, 6, 9, 8, 8, 4, 9, 8, 9, 8, 9, 9, 9,
        8, 9, 9, 10, 8, 10, 10, 10, 9, 10, 10, 10, 9, 10, 10, 9,
        9, 9, 8, 10, 9, 10, 9, 10, 9, 10, 9, 10, 9, 9, 8, 9,
        8, 9, 9, 9, 10, 10, 10, 10, 9, 9, 9, 10, 9, 10, 9, 9,
        7, 8, 8, 9, 8, 9, 9, 9, 8, 9, 9, 10, 9, 9, 8, 9,
        8, 9, 8, 8, 8, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 9,
        8, 8, 9, 8, 9, 7, 8, 8, 9, 8, 10, 10, 8, 9, 8, 8,
        8, 10, 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 10, 9,
        7, 9, 9, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10, 10, 9,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 9, 9, 9, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 9,
        8, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9,
        9, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10, 10, 9, 9,
        9, 10, 10, 10, 10, 10, 10, 9, 9, 10, 9, 9, 8, 9, 8, 9,
        4, 6, 6, 6, 7, 8, 8, 9, 9, 10, 10, 10, 9, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 7, 10,
        10, 10, 7, 10, 10, 7, 7, 7, 7, 7, 6, 7, 10, 7, 7, 10,
        7, 7, 7, 6, 7, 6, 6, 7, 7, 6, 6, 9, 6, 9, 10, 6,
        10
    ]

    private static let sit13Second3: [Int] = [
        5, 6, 6, 6, 6, 7, 7, 7, 6, 8, 7, 8, 7, 9, 8, 8,
        7, 7, 8, 9, 9, 9, 9, 10, 8, 9, 9, 10, 8, 10, 9, 8,
        6, 10, 8, 10, 8, 10, 9, 9, 9, 9, 9, 10, 9, 9, 8, 9,
        8, 9, 8, 9, 9, 10, 9, 10, 9, 9, 8, 10, 9, 11, 10, 8,
        8, 8, 8, 9, 7, 9, 9, 10, 8, 9, 8, 11, 9, 10, 9, 10,
        8, 9, 9, 9, 9, 8, 9, 9, 10, 10, 10, 12, 10, 11, 10, 10,
        8, 9, 9, 9, 8, 9, 8, 8, 10, 9, 10, 11, 8, 10, 9, 9,
        8, 12, 8, 9, 9, 9, 9, 8, 9, 10, 9, 12, 10, 10, 10, 8,
        7, 11, 10, 9, 10, 11, 9, 11, 7, 11, 10, 12, 10, 12, 10, 11,
        9, 11, 9, 12, 10, 12, 10, 12, 10, 9, 11, 12, 10, 12, 10, 11,
        9, 10, 9, 10, 9, 11, 11, 12, 9, 10, 8, 12, 11, 12, 9, 12,
        10, 12, 10, 13, 10, 12, 10, 12, 10, 12, 10, 9, 10, 12, 10, 9,
        8, 11, 10, 12, 10, 12, 10, 12, 10, 11, 10, 12, 8, 12, 10, 11,
        10, 10, 10, 12, 9, 11, 10, 12, 10, 12, 11, 12, 10, 9, 10, 12,
        9, 10, 10, 12, 10, 11, 10, 11, 10, 12, 8, 12, 9, 12, 8, 12,
        8, 11, 10, 11, 10, 11, 9, 10, 8, 10, 9, 9, 8, 9, 8, 7,
        4, 3, 5, 5, 6, 5, 6, 6, 7, 7, 8, 8, 8, 7, 7, 7,
        9, 8, 9, 9, 11, 9, 11, 9, 8, 9, 9, 11, 12, 11, 12, 12,
        13, 13, 12, 13, 14, 13, 14, 13, 14, 13, 13, 13, 12, 13, 13, 12,
        13, 13, 14, 14, 13, 13, 14, 14, 14, 14, 15, 18, 17, 18, 8, 16,
        10
    ]

    private static let sit13Offset3: [Int] = [
        6, 7, 4, 4, 3, 3, 3, 3, 3, 4, 4, 4, 5, 7
    ]

    private static let sit13First4: [Int] = [
        2, 6, 6, 7, 7, 8, 7, 8, 7, 8, 8, 9, 8, 9, 9, 9,
        8, 8, 9, 9, 9, 10, 10, 9, 8, 10, 9, 10, 9, 10, 9, 9,
        6, 9, 8, 9, 9, 10, 9, 9, 9, 10, 9, 9, 9, 9, 8, 8,
        8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 9,
        7, 7, 8, 8, 8, 8, 9, 9, 7, 8, 9, 10, 8, 8, 7, 8,
        8, 10, 8, 8, 8, 9, 8, 9, 9, 10, 9, 11, 10, 11, 9, 9,
        8, 7, 9, 8, 8, 6, 8, 8, 8, 7, 10, 9, 7, 8, 7, 7,
        8, 10, 7, 7, 7, 8, 9, 9, 9, 9, 10, 11, 9, 11, 10, 9,
        7, 9, 10, 10, 10, 11, 11, 10, 10, 11, 10, 10, 10, 11, 11, 10,
        9, 10, 10, 11, 10, 11, 10, 11, 10, 10, 10, 11, 10, 11, 10, 10,
        9, 10, 10, 11, 10, 10, 10, 10, 9, 10, 10, 10, 10, 11, 10, 11,
        10, 11, 10, 11, 11, 11, 10, 12, 10, 11, 10, 11, 10, 11, 11, 10,
        8, 10, 10, 11, 10, 11, 11, 11, 10, 11, 10, 11, 10, 11, 11, 11,
        9, 10, 11, 11, 10, 11, 11, 11, 10, 11, 11, 11, 10, 10, 10, 10,
        10, 11, 10, 10, 11, 11, 10, 10, 9, 11, 10, 10, 11, 11, 10, 10,
        10, 11, 10, 10, 10, 10, 10, 10, 9, 11, 10, 10, 8, 10, 8, 6,
        5, 6, 6, 7, 7, 8, 8, 8, 9, 10, 11, 10, 10, 11, 11, 12,
        12, 10, 11, 12, 12, 12, 12, 13, 13, 13, 13, 13, 12, 13, 13, 15,
        14, 12, 14, 15, 16, 12, 12, 13, 15, 14, 16, 15, 17, 18, 15, 17,
        16, 15, 15, 15, 15, 13, 13, 10, 14, 12, 13, 17, 17, 18, 10, 17,
        4
    ]

    private static let sit13Second4: [Int] = [
        4, 5, 6, 6, 6, 6, 7, 7, 6, 7, 7, 9, 6, 8, 8, 7,
        7, 8, 8, 8, 6, 9, 8, 8, 7, 9, 8, 9, 8, 9, 8, 9,
        6, 9, 8, 9, 8, 10, 9, 9, 8, 10, 8, 10, 8, 9, 8, 9,
        8, 8, 7, 9, 9, 9, 9, 9, 8, 10, 9, 10, 9, 10, 9, 8,
        7, 8, 9, 9, 8, 9, 9, 9, 7, 10, 9, 10, 9, 9, 8, 9,
        8, 9, 8, 8, 8, 9, 9, 10, 9, 9, 8, 11, 9, 11, 10, 10,
        8, 8, 10, 8, 8, 9, 9, 9, 10, 9, 10, 11, 9, 9, 9, 9,
        8, 9, 8, 8, 8, 10, 10, 9, 9, 8, 10, 11, 10, 11, 11, 9,
        8, 9, 10, 11, 9, 10, 11, 11, 9, 12, 10, 10, 10, 12, 11, 11,
        9, 11, 11, 12, 9, 11, 9, 10, 10, 10, 10, 12, 9, 11, 10, 11,
        9, 11, 11, 11, 10, 11, 11, 12, 9, 10, 10, 12, 11, 11, 10, 11,
        9, 11, 10, 11, 10, 11, 9, 11, 11, 9, 8, 11, 10, 11, 11, 10,
        7, 12, 11, 11, 11, 11, 11, 12, 10, 12, 11, 13, 11, 10, 12, 11,
        10, 11, 10, 11, 10, 11, 11, 11, 10, 12, 11, 11, 10, 11, 10, 10,
        10, 11, 10, 12, 11, 12, 10, 11, 9, 11, 10, 11, 10, 11, 10, 12,
        9, 11, 11, 11, 9, 11, 10, 10, 9, 11, 10, 10, 9, 10, 9, 7,
        4, 5, 5, 5, 6, 6, 7, 6, 8, 7, 8, 9, 9, 7, 8, 8,
        10, 9, 10, 10, 12, 10, 11, 11, 11, 11, 10, 11, 12, 11, 11, 11,
        11, 11, 13, 12, 11, 12, 13, 12, 12, 12, 13, 11, 9, 12, 13, 7,
        13, 11, 13, 11, 10, 11, 13, 15, 15, 12, 14, 15, 15, 15, 6, 15,
        5
    ]

    private static let sit13Offset4: [Int] = [
        3, 6, 5, 4, 2, 3, 3, 3, 4, 4, 6
    ]

    private static let sit13First5: [Int] = [
        7, 9, 9, 9, 9, 9, 9, 9, 9, 8, 9, 9, 9, 7, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 10, 9, 10, 9, 10, 9, 10, 9, 9,
        5, 9, 7, 9, 9, 9, 9, 9, 7, 7, 7, 9, 7, 7, 8, 7,
        8, 8, 7, 7, 9, 9, 9, 9, 7, 7, 7, 9, 9, 9, 9, 9,
        9, 7, 9, 7, 7, 7, 7, 9, 9, 7, 9, 9, 7, 7, 7, 7,
        7, 9, 7, 8, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9, 7, 8, 7, 7, 7, 8, 8, 6, 7, 9, 7, 7, 8, 7, 5,
        6, 9, 5, 7, 5, 6, 7, 7, 9, 8, 9, 9, 9, 9, 9, 9,
        9, 9, 10, 9, 10, 10, 10, 9, 9, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 10,
        9, 10, 10, 10, 9, 9, 10, 9, 9, 9, 9, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 9, 10, 10, 10, 9, 9, 9, 10, 10, 10, 10, 10,
        9, 10, 9, 10, 10, 9, 10, 10, 9, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        9, 10, 10, 10, 10, 10, 10, 10, 9, 10, 9, 10, 9, 10, 10, 9,
        5, 6, 8, 8, 7, 7, 7, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
        9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 9, 10, 10, 5, 10, 8, 9, 8,
        9
    ]

    private static let sit13Second5: [Int] = [
        8, 10, 11, 11, 11, 12, 11, 11, 12, 6, 11, 12, 10, 5, 12, 12,
        12, 12, 12, 12, 12, 13, 13, 14, 13, 13, 12, 13, 12, 13, 12, 15,
        4, 10, 7, 9, 11, 11, 10, 9, 6, 7, 8, 9, 6, 7, 6, 7,
        8, 7, 7, 8, 8, 8, 8, 8, 8, 9, 8, 7, 10, 9, 10, 10,
        11, 7, 8, 6, 7, 8, 8, 9, 8, 7, 10, 10, 8, 7, 8, 8,
        7, 10, 7, 6, 7, 9, 9, 8, 11, 11, 11, 10, 11, 11, 11, 8,
        11, 6, 7, 6, 6, 6, 6, 8, 7, 6, 10, 9, 6, 7, 6, 6,
        7, 10, 6, 5, 6, 7, 7, 7, 10, 8, 11, 9, 13, 7, 14, 16,
        12, 14, 14, 15, 15, 16, 16, 14, 15, 15, 15, 15, 15, 15, 15, 15,
        14, 15, 13, 14, 14, 16, 15, 17, 14, 17, 15, 17, 12, 14, 13, 16,
        12, 17, 13, 17, 14, 13, 13, 14, 14, 12, 13, 15, 15, 14, 15, 17,
        14, 17, 15, 14, 15, 16, 12, 16, 15, 14, 15, 16, 15, 16, 17, 17,
        15, 15, 17, 17, 13, 14, 15, 15, 13, 12, 16, 16, 17, 14, 15, 16,
        15, 15, 13, 13, 15, 13, 16, 17, 15, 17, 17, 17, 16, 17, 14, 17,
        14, 16, 15, 17, 15, 15, 14, 17, 15, 17, 15, 16, 15, 15, 16, 16,
        14, 17, 17, 15, 15, 16, 15, 17, 15, 14, 16, 16, 16, 16, 16, 12,
        4, 4, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8, 8, 9, 9,
        9, 9, 9, 10, 10, 10, 11, 10, 11, 11, 11, 11, 11, 12, 12, 12,
        13, 13, 12, 13, 12, 14, 14, 12, 13, 13, 13, 13, 14, 12, 13, 13,
        14, 14, 14, 13, 14, 14, 15, 15, 13, 15, 13, 17, 17, 17, 9, 17,
        7
    ]

    private static let sit13Offset5: [Int] = [
        6, 7, 7, 6, 4, 3, 2, 2, 3, 3, 6
    ]

    private static let sit13MetaCodes: [Int] = [
        1496, 88, 64, 192, 0, 120, 43, 20, 12, 28, 27, 11, 16, 32, 56, 24,
        216, 3032, 384, 1664, 896, 3968, 1920, 1152, 128, 640, 984, 4056, 2008, 2520, 472, 4,
        1, 2, 7, 3, 8
    ]

    private static let sit13MetaLengths: [Int] = [
        11, 8, 8, 8, 8, 7, 6, 5, 5, 5, 5, 6, 5, 6, 7, 7,
        9, 12, 10, 11, 11, 12, 12, 11, 11, 11, 12, 12, 12, 12, 12, 5,
        2, 2, 3, 4, 5
    ]

    private static let arsenicRand: [Int] = [
        238, 86, 248, 195, 157, 159, 174, 44,
        173, 205, 36, 157, 166, 257, 24, 185,
        161, 130, 117, 233, 159, 85, 102, 106,
        134, 113, 220, 132, 86, 150, 86, 161,
        132, 120, 183, 50, 106, 3, 227, 2,
        17, 257, 8, 68, 131, 256, 67, 227,
        28, 240, 134, 106, 107, 15, 3, 45,
        134, 23, 123, 16, 246, 128, 120, 122,
        161, 225, 239, 140, 246, 135, 75, 167,
        226, 119, 250, 184, 129, 238, 119, 192,
        157, 41, 32, 39, 113, 18, 224, 107,
        209, 124, 10, 137, 125, 135, 196, 257,
        193, 49, 175, 56, 3, 104, 27, 118,
        121, 63, 219, 199, 27, 54, 123, 226,
        99, 129, 238, 12, 99, 139, 120, 56,
        151, 155, 215, 143, 221, 242, 163, 119,
        140, 195, 57, 32, 179, 18, 17, 14,
        23, 66, 128, 44, 196, 146, 89, 200,
        219, 64, 118, 100, 180, 85, 26, 158,
        254, 95, 6, 60, 65, 239, 212, 170,
        152, 41, 205, 31, 2, 168, 135, 210,
        160, 147, 152, 239, 12, 67, 237, 157,
        194, 235, 129, 233, 100, 35, 104, 30,
        37, 87, 222, 154, 207, 127, 229, 186,
        65, 234, 234, 54, 26, 40, 121, 32,
        94, 24, 78, 124, 142, 88, 122, 239,
        145, 2, 147, 187, 86, 161, 73, 27,
        121, 146, 243, 88, 79, 82, 156, 2,
        119, 175, 42, 143, 73, 208, 153, 77,
        152, 257, 96, 147, 256, 117, 49, 206,
        73, 32, 86, 87, 226, 245, 38, 43,
        138, 191, 222, 208, 131, 52, 244, 23
    ]

    // MARK: Method 5 — LZAH
    //
    // 4 KiB LZSS (matches of 3...60) plus one 314-symbol adaptive Huffman tree,
    // and a fixed 64-symbol code for the top 6 bits of the distance. The
    // Window seed and the 64-symbol distance code follow XADMaster
    // XADLZHDynamicHandle (MSB-first; the window is not LHA's fill of spaces).
    // The adaptive tree uses the LZHUF child order (compcol src/lzah): a 0 bit
    // selects the lower-index child. That order matches real method-5 forks.

    private static func lzah(_ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        let distanceLengths = [
            3, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6,
            6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7,
            7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
            8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        ]
        let distances = try canonicalTree(distanceLengths)
        let tree = LZAHTree()
        var bits = BitIO(src)
        var window = [UInt8](repeating: 0, count: 4096)
        for i in 0..<256 {
            for k in 0..<13 { window[i * 13 + 18 + k] = UInt8(i) }
        }
        let seeded = 256 * 13 + 18
        for i in 0..<256 { window[seeded + i] = UInt8(i) }
        for i in 0..<256 { window[seeded + 256 + i] = UInt8(255 - i) }
        for i in 0..<(128 - 18) { window[seeded + 512 + 128 + i] = 0x20 }

        var out: [UInt8] = []
        out.reserveCapacity(outLen)
        var pos = 0
        while out.count < outLen {
            let lit = try tree.decode { try bits.bit(msb: true) }
            tree.update(lit)
            if lit < 0x100 {
                let byte = UInt8(lit)
                window[pos & 4095] = byte
                pos += 1
                out.append(byte)
            } else {
                let match = lit - 0x100 + 3
                let high = try bits.symbol(distances, msb: true)
                let low = try bits.bits(6, msb: true)
                let offset = (high << 6) + low + 1
                if match < 3 || offset < 1 { throw MacArchiveError.corrupt("bad LZAH match") }
                for _ in 0..<match where out.count < outLen {
                    let byte = window[(pos - offset) & 4095]
                    window[pos & 4095] = byte
                    pos += 1
                    out.append(byte)
                }
            }
        }
        return out
    }

    /// Sibling-property adaptive Huffman tree for LZAH, in the LZHUF order
    /// (root at the high index). A 0 bit selects the lower-index child. This is
    /// the bit mapping checked against real method-5 forks.
    private final class LZAHTree {
        private static let symbols = 314
        private static let nodes = symbols * 2 - 1
        private static let root = nodes - 1
        private var freq = [Int](repeating: 0, count: nodes + 1)
        private var son = [Int](repeating: 0, count: nodes)
        private var parent = [Int](repeating: 0, count: nodes + symbols)
        private var leafIndex = [Int](repeating: 0, count: symbols)

        init() {
            let symbols = Self.symbols
            let nodes = Self.nodes
            for i in 0..<symbols {
                freq[i] = 1
                son[i] = i + nodes
                parent[i + nodes] = i
                leafIndex[i] = i
            }
            var i = 0
            var j = symbols
            while j < nodes {
                freq[j] = freq[i] + freq[i + 1]
                son[j] = i
                parent[i] = j
                parent[i + 1] = j
                i += 2
                j += 1
            }
            freq[nodes] = 0xFFFF
        }

        func decode(_ bit: () throws -> Int) throws -> Int {
            var c = son[Self.root]
            var steps = 0
            while true {
                if c >= Self.nodes { throw MacArchiveError.corrupt("bad LZAH code") }
                let node = try bit() == 0 ? c : c + 1
                if node >= Self.nodes { throw MacArchiveError.corrupt("bad LZAH code") }
                let s = son[node]
                if s >= Self.nodes { return s - Self.nodes }
                c = s
                steps += 1
                if steps > Self.nodes { throw MacArchiveError.corrupt("bad LZAH code") }
            }
        }

        func update(_ symbol: Int) {
            if freq[Self.root] >= 0x8000 { rebuild() }
            var c = leafIndex[symbol]
            while true {
                freq[c] += 1
                let f = freq[c]
                if c + 1 < Self.nodes && f > freq[c + 1] {
                    var l = c + 1
                    while f > freq[l + 1] { l += 1 }
                    swapNodes(c, l)
                    c = l
                }
                if c == Self.root { break }
                c = parent[c]
            }
        }

        private func swapNodes(_ a: Int, _ b: Int) {
            if a == b { return }
            freq.swapAt(a, b)
            son.swapAt(a, b)
            fixLinks(a)
            fixLinks(b)
        }

        private func fixLinks(_ slot: Int) {
            let child = son[slot]
            if child >= Self.nodes {
                parent[child] = slot
                leafIndex[child - Self.nodes] = slot
            } else {
                parent[child] = slot
                parent[child + 1] = slot
            }
        }

        private func rebuild() {
            let symbols = Self.symbols
            let nodes = Self.nodes
            var j = 0
            for i in 0..<nodes where son[i] >= nodes {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
            var f = 0
            var i = symbols
            while i < nodes {
                let sum = freq[f] + freq[f + 1]
                var k = i - 1
                while sum < freq[k] {
                    if k == 0 { break }
                    k -= 1
                }
                let insertAt = sum < freq[k] ? k : k + 1
                var m = i
                while m > insertAt {
                    freq[m] = freq[m - 1]
                    son[m] = son[m - 1]
                    m -= 1
                }
                freq[insertAt] = sum
                son[insertAt] = f
                f += 2
                i += 1
            }
            for k in 0..<symbols { leafIndex[k] = 0 }
            for slot in 0..<nodes {
                let child = son[slot]
                if child >= nodes {
                    parent[child] = slot
                    leafIndex[child - nodes] = slot
                } else {
                    parent[child] = slot
                    parent[child + 1] = slot
                }
            }
            freq[nodes] = 0xFFFF
        }
    }

    // MARK: Method 13 — LZ + Huffman
    //
    // 64 KiB LZSS. Literals and match lengths share two canonical Huffman trees
    // (321 symbols); distances use a third. The first byte selects five published
    // length tables or stores the lengths under a 37-symbol meta code. Bits are
    // LSB-first. Tables match XADMaster StuffItAlgorithm13 / XADStuffIt13Handle.

    private static func lzHuffman(_ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        var bits = BitIO(src)
        guard let headerByte = bits.byte() else { throw MacArchiveError.corrupt("method 13 header missing") }
        let header = Int(headerByte)
        let which = header >> 4
        let first: HuffNode
        let second: HuffNode
        let offset: HuffNode
        if which == 0 {
            let meta = try explicitTree(codes: sit13MetaCodes, lengths: sit13MetaLengths, lowBitFirst: true)
            first = try parseStoredLengths(321, meta: meta, bits: &bits)
            second = (header & 0x08) != 0 ? first : try parseStoredLengths(321, meta: meta, bits: &bits)
            offset = try parseStoredLengths((header & 0x07) + 10, meta: meta, bits: &bits)
        } else if which < 6 {
            let preset: ([Int], [Int], [Int])
            switch which {
            case 1: preset = (sit13First1, sit13Second1, sit13Offset1)
            case 2: preset = (sit13First2, sit13Second2, sit13Offset2)
            case 3: preset = (sit13First3, sit13Second3, sit13Offset3)
            case 4: preset = (sit13First4, sit13Second4, sit13Offset4)
            default: preset = (sit13First5, sit13Second5, sit13Offset5)
            }
            first = try canonicalTree(preset.0)
            second = try canonicalTree(preset.1)
            offset = try canonicalTree(preset.2)
        } else {
            throw MacArchiveError.corrupt("bad method 13 table selector")
        }

        var window = [UInt8](repeating: 0, count: 65536)
        var out: [UInt8] = []
        out.reserveCapacity(outLen)
        var pos = 0
        var useFirst = true
        while out.count < outLen {
            let val = try bits.symbol(useFirst ? first : second, msb: false)
            if val < 0x100 {
                useFirst = true
                let byte = UInt8(val)
                window[pos & 65535] = byte
                pos += 1
                out.append(byte)
            } else if val == 320 {
                break
            } else {
                useFirst = false
                let match: Int
                if val < 0x13e { match = val - 0x100 + 3 }
                else if val == 0x13e { match = try bits.bits(10, msb: false) + 65 }
                else if val == 0x13f { match = try bits.bits(15, msb: false) + 65 }
                else { throw MacArchiveError.corrupt("bad method 13 symbol") }
                let bitLength = try bits.symbol(offset, msb: false)
                let dist: Int
                if bitLength == 0 { dist = 1 }
                else if bitLength == 1 { dist = 2 }
                else if bitLength <= 24 {
                    dist = (1 << (bitLength - 1)) + (try bits.bits(bitLength - 1, msb: false)) + 1
                } else {
                    throw MacArchiveError.corrupt("bad method 13 distance")
                }
                for _ in 0..<match where out.count < outLen {
                    let byte = window[(pos - dist) & 65535]
                    window[pos & 65535] = byte
                    pos += 1
                    out.append(byte)
                }
            }
        }
        guard out.count >= outLen else { throw MacArchiveError.corrupt("method 13 data ended early") }
        return out
    }

    /// Stored code lengths, themselves Huffman-coded. A repeat also writes one
    /// more symbol, which is what XADStuffIt13Handle's length loop does.
    private static func parseStoredLengths(_ count: Int, meta: HuffNode, bits: inout BitIO) throws -> HuffNode {
        var lengths = [Int](repeating: 0, count: count)
        var length = 0
        var i = 0
        while i < count {
            switch try bits.symbol(meta, msb: false) {
            case 31: length = -1
            case 32: length += 1
            case 33: length -= 1
            case 34:
                if try bits.bit(msb: false) == 1 {
                    guard i < count else { throw MacArchiveError.corrupt("bad method 13 lengths") }
                    lengths[i] = length
                    i += 1
                }
            case 35:
                var n = try bits.bits(3, msb: false) + 2
                while n > 0 {
                    guard i < count else { throw MacArchiveError.corrupt("bad method 13 lengths") }
                    lengths[i] = length
                    i += 1
                    n -= 1
                }
            case 36:
                var n = try bits.bits(6, msb: false) + 10
                while n > 0 {
                    guard i < count else { throw MacArchiveError.corrupt("bad method 13 lengths") }
                    lengths[i] = length
                    i += 1
                    n -= 1
                }
            case let val:
                length = val + 1
            }
            guard i < count else { throw MacArchiveError.corrupt("bad method 13 lengths") }
            lengths[i] = length
            i += 1
        }
        return try canonicalTree(lengths)
    }

    // MARK: Method 15 — Arsenic
    //
    // Arithmetic-coded Burrows–Wheeler block sort, move-to-front, and a 4-byte
    // run expansion. Matthew Russotto's format note (XADMaster wiki,
    // StuffItArsenicAlgorithm), with the coder, models, and randomization table
    // from XADStuffItArsenicHandle. A block's run expansion can grow past the
    // block size (Dag Ågren's errata). The stream CRC-32 is checked when present.

    private static func arsenic(_ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        var bits = BitIO(src)
        var coder = ArithCoder()
        try coder.start(&bits)
        var initial = ArithModel.make(first: 0, last: 1, increment: 1, limit: 256)
        var selector = ArithModel.make(first: 0, last: 10, increment: 8, limit: 1024)
        var mtfModels = [
            ArithModel.make(first: 2, last: 3, increment: 8, limit: 1024),
            ArithModel.make(first: 4, last: 7, increment: 4, limit: 1024),
            ArithModel.make(first: 8, last: 15, increment: 4, limit: 1024),
            ArithModel.make(first: 16, last: 31, increment: 4, limit: 1024),
            ArithModel.make(first: 32, last: 63, increment: 2, limit: 1024),
            ArithModel.make(first: 64, last: 127, increment: 2, limit: 1024),
            ArithModel.make(first: 128, last: 255, increment: 1, limit: 1024),
        ]
        guard try coder.bitString(&initial, 8, &bits) == 0x41,
              try coder.bitString(&initial, 8, &bits) == 0x73 else {
            throw MacArchiveError.corrupt("not an Arsenic stream")
        }
        let blockBits = try coder.bitString(&initial, 4, &bits) + 9
        let blockSize = 1 << blockBits
        guard blockSize > 0, blockSize <= MacBytes.maxUnpackedBytes else { throw MacBytes.tooBig() }

        var endOfBlocks = try coder.symbol(&initial, &bits) != 0
        var randomized = false
        var transformIndex = 0
        var block: [UInt8] = []
        // UInt32: a block is at most 1 << 24 bytes, and half the memory of [Int] on a 16 MB block.
        var transform: [UInt32] = []
        var numBytes = 0
        var byteCount = 0
        var repeatLeft = 0
        var lastByte = 0
        var runCount = 0
        var randIndex = 0
        var randCount = arsenicRand[0]
        var mtf = MTF()
        var crc: UInt32 = 0xFFFF_FFFF
        var storedCRC: UInt32 = 0
        var sawCRC = false

        func readBlock() throws {
            mtf.reset()
            randomized = try coder.symbol(&initial, &bits) != 0
            transformIndex = try coder.bitString(&initial, blockBits, &bits)
            var decoded: [UInt8] = []
            decoded.reserveCapacity(min(blockSize, max(outLen, 1)))
            while true {
                var sel = try coder.symbol(&selector, &bits)
                if sel == 0 || sel == 1 {
                    var zeroState = 1
                    var zeroCount = 0
                    while sel < 2 {
                        zeroCount += sel == 0 ? zeroState : 2 * zeroState
                        // A block never holds more than the fork's output (its runs only expand),
                        // so zero runs past that are a bomb, not data.
                        if zeroCount < 0 || decoded.count + zeroCount > min(blockSize, outLen + 256) {
                            throw MacArchiveError.corrupt("bad Arsenic block")
                        }
                        zeroState *= 2
                        sel = try coder.symbol(&selector, &bits)
                    }
                    let zero = UInt8(mtf.decode(0))
                    if zeroCount > 0 { decoded.append(contentsOf: [UInt8](repeating: zero, count: zeroCount)) }
                }
                if sel == 10 { break }
                let symbol: Int
                if sel == 2 { symbol = 1 }
                else if (3...9).contains(sel) { symbol = try coder.symbol(&mtfModels[sel - 3], &bits) }
                else { throw MacArchiveError.corrupt("bad Arsenic selector") }
                if decoded.count >= blockSize { throw MacArchiveError.corrupt("bad Arsenic block") }
                decoded.append(UInt8(mtf.decode(symbol)))
            }
            if transformIndex >= decoded.count || decoded.isEmpty {
                throw MacArchiveError.corrupt("bad Arsenic block index")
            }
            selector.reset()
            for i in mtfModels.indices { mtfModels[i].reset() }
            if try coder.symbol(&initial, &bits) != 0 {
                storedCRC = UInt32(truncatingIfNeeded: try coder.bitString(&initial, 32, &bits))
                sawCRC = true
                endOfBlocks = true
            }
            block = decoded
            numBytes = decoded.count
            transform = inverseBWT(decoded)
        }

        var out: [UInt8] = []
        out.reserveCapacity(outLen)
        while out.count < outLen {
            let byte: UInt8
            if repeatLeft > 0 {
                repeatLeft -= 1
                byte = UInt8(lastByte)
            } else {
                var produced = 0
                var have = false
                while !have {
                    if byteCount >= numBytes {
                        if endOfBlocks { throw MacArchiveError.corrupt("Arsenic data ended early") }
                        try readBlock()
                        byteCount = 0
                        runCount = 0
                        lastByte = 0
                        randIndex = 0
                        randCount = arsenicRand[0]
                    }
                    transformIndex = Int(transform[transformIndex])
                    var value = Int(block[transformIndex])
                    if randomized && randCount == byteCount {
                        value ^= 1
                        randIndex = (randIndex + 1) & 255
                        randCount += arsenicRand[randIndex]
                    }
                    byteCount += 1
                    if runCount == 4 {
                        runCount = 0
                        if value == 0 { continue }
                        repeatLeft = value - 1
                        produced = lastByte
                        have = true
                    } else {
                        if value == lastByte { runCount += 1 } else { runCount = 1; lastByte = value }
                        produced = value
                        have = true
                    }
                }
                byte = UInt8(produced)
            }
            crc = arsenicCRC[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            out.append(byte)
        }
        if sawCRC, storedCRC != ~crc { throw MacArchiveError.corrupt("Arsenic checksum mismatch") }
        return out
    }

    private static func inverseBWT(_ block: [UInt8]) -> [UInt32] {
        var counts = [Int](repeating: 0, count: 256)
        for byte in block { counts[Int(byte)] += 1 }
        var cumulative = [Int](repeating: 0, count: 256)
        var total = 0
        for i in 0..<256 {
            cumulative[i] = total
            total += counts[i]
            counts[i] = 0
        }
        var linked = [UInt32](repeating: 0, count: block.count)
        for i in block.indices {
            let byte = Int(block[i])
            linked[cumulative[byte] + counts[byte]] = UInt32(i)
            counts[byte] += 1
        }
        return linked
    }

    private struct MTF {
        var table = Array(0..<256)
        mutating func reset() { table = Array(0..<256) }
        mutating func decode(_ symbol: Int) -> Int {
            let value = table[symbol]
            if symbol > 0 {
                for i in stride(from: symbol, through: 1, by: -1) { table[i] = table[i - 1] }
            }
            table[0] = value
            return value
        }
    }

    /// 26-bit arithmetic coder. The multiply/subtract order matches
    /// XADStuffItArsenicHandle (it is not identical to MACM).
    private struct ArithCoder {
        private static let one = 1 << 25
        private static let half = 1 << 24
        var range = one
        var code = 0

        mutating func start(_ bits: inout BitIO) throws {
            range = Self.one
            code = try bits.bits(26, msb: true)
        }

        mutating func symbol(_ model: inout ArithModel, _ bits: inout BitIO) throws -> Int {
            if model.total <= 0 || range / model.total == 0 {
                throw MacArchiveError.corrupt("bad Arsenic coder")
            }
            let frequency = code / (range / model.total)
            var cumulative = 0
            var n = 0
            while n < model.freq.count - 1 {
                if cumulative + model.freq[n] > frequency { break }
                cumulative += model.freq[n]
                n += 1
            }
            try renormalize(low: cumulative, size: model.freq[n], total: model.total, bits: &bits)
            let value = model.symbols[n]
            model.increase(n)
            return value
        }

        mutating func bitString(_ model: inout ArithModel, _ count: Int, _ bits: inout BitIO) throws -> Int {
            var value = 0
            for i in 0..<count where try symbol(&model, &bits) != 0 { value |= 1 << i }
            return value
        }

        private mutating func renormalize(low: Int, size: Int, total: Int, bits: inout BitIO) throws {
            let factor = range / total
            let lowIncrement = factor * low
            code -= lowIncrement
            if low + size == total { range -= lowIncrement } else { range = size * factor }
            while range <= Self.half {
                range <<= 1
                code = (code << 1) | (try bits.bit(msb: true))
            }
        }
    }

    private struct ArithModel {
        var increment: Int
        var limit: Int
        var total: Int
        var symbols: [Int]
        var freq: [Int]

        static func make(first: Int, last: Int, increment: Int, limit: Int) -> ArithModel {
            let n = last - first + 1
            return ArithModel(increment: increment, limit: limit, total: increment * n,
                              symbols: Array(first...last), freq: Array(repeating: increment, count: n))
        }

        mutating func reset() {
            total = increment * freq.count
            for i in freq.indices { freq[i] = increment }
        }

        mutating func increase(_ index: Int) {
            freq[index] += increment
            total += increment
            if total > limit {
                total = 0
                for i in freq.indices {
                    freq[i] = (freq[i] + 1) >> 1
                    total += freq[i]
                }
            }
        }
    }

    private static let arsenicCRC: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    // MARK: Bit and prefix-code helpers

    private struct BitIO {
        let bytes: [UInt8]
        var pos = 0
        private var padding = 0

        init(_ src: ArraySlice<UInt8>) { bytes = Array(src) }

        mutating func byte() -> UInt8? {
            let index = pos >> 3
            guard pos & 7 == 0, index < bytes.count else { return nil }
            pos += 8
            return bytes[index]
        }

        mutating func bit(msb: Bool) throws -> Int {
            if pos >= bytes.count * 8 {
                padding += 1
                if padding > 64 { throw MacArchiveError.corrupt("compressed data ended early") }
                return 0
            }
            let raw = Int(bytes[pos >> 3])
            let bit = msb ? (raw >> (7 - (pos & 7))) & 1 : (raw >> (pos & 7)) & 1
            pos += 1
            padding = 0
            return bit
        }

        mutating func bits(_ count: Int, msb: Bool) throws -> Int {
            var value = 0
            if msb {
                for _ in 0..<count { value = (value << 1) | (try bit(msb: true)) }
            } else {
                for i in 0..<count { value |= (try bit(msb: false)) << i }
            }
            return value
        }

        mutating func symbol(_ root: HuffNode, msb: Bool) throws -> Int {
            var node = root
            var walked = 0
            while node.symbol == nil {
                walked += 1
                if walked > 64 { throw MacArchiveError.corrupt("bad Huffman code") }
                let bit = try bit(msb: msb)
                guard let next = bit == 0 ? node.zero : node.one else {
                    throw MacArchiveError.corrupt("bad Huffman code")
                }
                node = next
            }
            return node.symbol!
        }
    }

    private final class HuffNode {
        var zero: HuffNode?
        var one: HuffNode?
        var symbol: Int?
    }

    /// Canonical lengths, shortest code all zeros. The integer's high bit is the
    /// first branch. Read with `msb: false` when the stream is LSB-first, which
    /// is how method 13 consumes a high-bit-first tree.
    private static func canonicalTree(_ lengths: [Int]) throws -> HuffNode {
        let root = HuffNode()
        var code: UInt64 = 0
        let maxLen = min(32, lengths.max() ?? 0)
        if maxLen > 0 {
            for length in 1...maxLen {
                for symbol in 0..<lengths.count where lengths[symbol] == length {
                    if code >= (UInt64(1) << length) { throw MacArchiveError.corrupt("bad Huffman lengths") }
                    try insert(root, code: code, length: length, symbol: symbol, lowBitFirst: false)
                    code += 1
                }
                code <<= 1
            }
        }
        return root
    }

    private static func explicitTree(codes: [Int], lengths: [Int], lowBitFirst: Bool) throws -> HuffNode {
        let root = HuffNode()
        for symbol in 0..<codes.count {
            try insert(root, code: UInt64(codes[symbol]), length: lengths[symbol], symbol: symbol, lowBitFirst: lowBitFirst)
        }
        return root
    }

    private static func insert(_ root: HuffNode, code: UInt64, length: Int, symbol: Int, lowBitFirst: Bool) throws {
        guard length > 0 else { return }
        var node = root
        let positions: [Int] = lowBitFirst ? Array(0..<length) : Array(stride(from: length - 1, through: 0, by: -1))
        for (step, bitpos) in positions.enumerated() {
            if node.symbol != nil { throw MacArchiveError.corrupt("bad Huffman lengths") }
            let bit = Int((code >> UInt64(bitpos)) & 1)
            let last = step == positions.count - 1
            if bit == 0 {
                if node.zero == nil { node.zero = HuffNode() }
                node = node.zero!
            } else {
                if node.one == nil { node.one = HuffNode() }
                node = node.one!
            }
            if last {
                if node.symbol != nil || node.zero != nil || node.one != nil {
                    throw MacArchiveError.corrupt("bad Huffman lengths")
                }
                node.symbol = symbol
            }
        }
    }
}
