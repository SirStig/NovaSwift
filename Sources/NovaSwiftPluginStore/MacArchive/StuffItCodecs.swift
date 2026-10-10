import Foundation

/// StuffIt fork decompressors (methods 0-3). Methods 5 (LZAH), 13 and 15
/// (Arsenic) are not implemented; callers get `.unsupportedMethod`.
enum StuffItCodecs {
    static func decode(method: Int, _ src: ArraySlice<UInt8>, outLen: Int) throws -> [UInt8] {
        switch method {
        case 0:
            guard src.count >= outLen else { throw MacArchiveError.corrupt("stored fork truncated") }
            return Array(src.prefix(outLen))
        case 1: return try MacBytes.rleDecode(src, limit: outLen)
        case 2: return try lzw(src, outLen: outLen, maxBits: 14)
        case 3: return try huffman(src, outLen: outLen)
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

        guard var oldCode = readCode() else { return out }
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
            while code >= 256 { stack.append(suffix[code]); code = Int(prefix[code]) }
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
}
