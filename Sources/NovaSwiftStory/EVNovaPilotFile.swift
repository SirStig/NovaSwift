import Foundation
import NovaSwiftKit

/// Container decoding for original EV Nova pilot files (the "Pilot converter").
///
/// Two families are understood, both normalised to the Windows block layout
/// (`docs/reverse-engineering/PILOT_IMPORT.md`):
///
/// * **Windows / EV Nova CE `.plt`** — `[u32 size][block 1][u32 size][block 2]
///   [ship name C string]`, little-endian, each block XOR-obfuscated with a
///   running key (`PilotSave_DecodeBlock` 0x008725b0, transform 0x0046f960).
/// * **Classic Mac pilots** — the two blocks are the `Np•L` resources 128 and
///   129 of the file's resource fork; the ship name is resource 129's *name*.
///   Scalars are big-endian and every mission record carries 6 padding bytes.
///   Accepted as a plain resource-fork file, AppleDouble (`._name`), MacBinary,
///   or (macOS) the live `..namedfork/rsrc` of a file.
///
/// The source bytes are never written to.
public enum EVNovaPilotFile {

    /// Windows block 1 / block 2 sizes (`PilotFile_SaveGameCore` 0x004c7dd0).
    public static let block1Size = 0xE952
    public static let block2Size = 0x66FE
    /// Classic Mac block 1: six padding bytes in each of the 16 mission records.
    public static let macBlock1Size = 0xE9B2
    /// Mac mission record stride (Windows 0x8E6 + 6 padding bytes).
    static let macMissionStride = 0x8EC
    static let winMissionStride = 0x8E6
    static let missionTableOffset = 0x295E
    /// The cipher's initial key (the loader passes it to the block decoder).
    public static let cipherKey: UInt32 = 0xB36A210F
    /// The `Np•L` pilot resource type (Mac Roman bullet 0x95).
    static let pilotType = FourCharCode(bytes: [0x4E, 0x70, 0x95, 0x4C])

    public enum Format: String, Sendable {
        case windowsPLT = "EV Nova CE (.plt)"
        case classicMac = "Classic Mac EV Nova pilot"
    }

    public enum FileError: Error, LocalizedError, Equatable {
        case unrecognized
        case truncated(String)
        case invalidBlock(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unrecognized:
                return "This is not an EV Nova pilot file (expected a .plt, or a classic Mac pilot's resource fork)."
            case .truncated(let w): return "The pilot file is truncated (\(w))."
            case .invalidBlock(let w): return "The pilot file is damaged (\(w))."
            case .unsupportedVersion(let v): return "Unsupported pilot file version \(v)."
            }
        }
    }

    /// Both blocks decrypted, byte-order tagged, in the Windows layout.
    public struct Blocks: Sendable {
        public var format: Format
        public var bigEndian: Bool
        public var block1: [UInt8]
        public var block2: [UInt8]
        public var shipName: String
        /// The pilot's name when the container carries one (MacBinary header).
        public var containerName: String?
    }

    // MARK: Cipher

    /// The block transform (symmetric). The key advances per 32-bit word as
    /// `key = (key + 0xDEADBEEF) ^ 0xDEADBEEF`; words are big-endian regardless
    /// of platform; the 0–3 trailing bytes use the key's high bytes in turn.
    public static func crypt(_ bytes: [UInt8], key initial: UInt32 = cipherKey) -> [UInt8] {
        var out = bytes
        var key = initial
        let words = out.count / 4
        for w in 0..<words {
            let o = w * 4
            let v = UInt32(out[o]) << 24 | UInt32(out[o + 1]) << 16 | UInt32(out[o + 2]) << 8 | UInt32(out[o + 3])
            let x = v ^ key
            out[o] = UInt8(truncatingIfNeeded: x >> 24)
            out[o + 1] = UInt8(truncatingIfNeeded: x >> 16)
            out[o + 2] = UInt8(truncatingIfNeeded: x >> 8)
            out[o + 3] = UInt8(truncatingIfNeeded: x)
            key = (key &+ 0xDEAD_BEEF) ^ 0xDEAD_BEEF
        }
        var shift: UInt32 = 24
        for i in (words * 4)..<out.count {
            out[i] ^= UInt8(truncatingIfNeeded: key >> shift)
            shift = shift >= 8 ? shift - 8 : 0
        }
        return out
    }

    // MARK: Entry points

    /// Read a pilot file from disk (never modifies it).
    public static func load(url: URL) throws -> Blocks {
        let data = try Data(contentsOf: url)
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("._") { name.removeFirst(2) }
        do {
            var blocks = try decode(data)
            if blocks.containerName == nil { blocks.containerName = name }
            return blocks
        } catch FileError.unrecognized {
            #if os(macOS)
            // A native Mac pilot keeps everything in its resource fork.
            let fork = url.appendingPathComponent("..namedfork/rsrc")
            if let forkData = try? Data(contentsOf: fork), !forkData.isEmpty {
                var blocks = try decode(forkData)
                blocks.containerName = url.lastPathComponent
                return blocks
            }
            #endif
            throw FileError.unrecognized
        }
    }

    /// Decode in-memory file bytes of any supported container.
    public static func decode(_ data: Data) throws -> Blocks {
        let bytes = [UInt8](data)
        if bytes.count >= 26, bytes[0] == 0x00, bytes[1] == 0x05, bytes[2] == 0x16, bytes[3] == 0x07,
           let fork = appleDoubleResourceFork(bytes) {
            return try decodeResourceFork(fork, containerName: nil)
        }
        if let (name, fork) = macBinaryResourceFork(bytes) {
            return try decodeResourceFork(fork, containerName: name)
        }
        if bytes.count >= 8, le32(bytes, 0) == UInt32(block1Size) {
            return try decodeWindows(bytes)
        }
        if (try? ClassicResourceFork.parse(data))?.resource(pilotType, 128) != nil {
            return try decodeResourceFork(data, containerName: nil)
        }
        throw FileError.unrecognized
    }

    // MARK: Windows

    static func decodeWindows(_ b: [UInt8]) throws -> Blocks {
        let n1 = Int(le32(b, 0))
        guard n1 == block1Size else { throw FileError.invalidBlock("block 1 size \(n1)") }
        guard b.count >= 4 + n1 + 4 else { throw FileError.truncated("block 1") }
        let raw1 = Array(b[4..<(4 + n1)])
        let n2 = Int(le32(b, 4 + n1))
        guard n2 == block2Size else { throw FileError.invalidBlock("block 2 size \(n2)") }
        let start2 = 8 + n1
        guard b.count >= start2 + n2 else { throw FileError.truncated("block 2") }
        let raw2 = Array(b[start2..<(start2 + n2)])
        var nameBytes: [UInt8] = []
        for c in b[(start2 + n2)...] { if c == 0 { break }; nameBytes.append(c) }
        let ship = String(bytes: nameBytes.prefix(0x3F), encoding: .macOSRoman) ?? ""
        let (block2, big) = try decodeBlock2(raw2)
        let block1 = decodeBlock1(raw1, bigEndian: big)
        return Blocks(format: .windowsPLT, bigEndian: big, block1: block1, block2: block2,
                      shipName: ship, containerName: nil)
    }

    /// `PilotSave_DecodeBlock`: a block whose first little-endian word is below
    /// 0x800 is plaintext, otherwise it is transformed. A classic-Mac payload
    /// (big-endian) is recognised by its version word and handled explicitly.
    static func decodeBlock2(_ raw: [UInt8]) throws -> (block: [UInt8], bigEndian: Bool) {
        let candidates: [[UInt8]] = le16(raw, 0) < 0x800 ? [raw, crypt(raw)] : [crypt(raw), raw]
        for c in candidates {
            if (300...399).contains(Int(le16(c, 0))) { return (c, false) }
            if (300...399).contains(Int(be16(c, 0))) { return (c, true) }
        }
        let v = Int(be16(raw, 0))
        throw v < 300 ? FileError.unsupportedVersion(v) : FileError.invalidBlock("block 2 version word")
    }

    static func decodeBlock1(_ raw: [UInt8], bigEndian: Bool) -> [UInt8] {
        if bigEndian {
            // Mac payloads are always transformed; keep the plaintext only if the
            // transformed jump-destination is nonsense and the raw one is not.
            let t = crypt(raw)
            if plausibleJump(be16(t, 0)) || !plausibleJump(be16(raw, 0)) { return t }
            return raw
        }
        return le16(raw, 0) < 0x800 ? raw : crypt(raw)
    }

    private static func plausibleJump(_ v: UInt16) -> Bool { v < 0x800 || v == 0xFFFF }

    // MARK: Classic Mac

    static func decodeResourceFork(_ fork: Data, containerName: String?) throws -> Blocks {
        guard let rc = try? ClassicResourceFork.parse(fork) else { throw FileError.unrecognized }
        guard let r1 = rc.resource(pilotType, 128), let r2 = rc.resource(pilotType, 129) else {
            throw FileError.unrecognized
        }
        var p1 = [UInt8](r1.data)
        let raw2 = [UInt8](r2.data)
        guard raw2.count == block2Size else { throw FileError.invalidBlock("resource 129 size \(raw2.count)") }
        guard p1.count == macBlock1Size || p1.count == block1Size else {
            throw FileError.invalidBlock("resource 128 size \(p1.count)")
        }
        let (block2, big) = try decodeBlock2(raw2)
        p1 = decodeBlock1(p1, bigEndian: true)
        if p1.count == macBlock1Size { p1 = stripMacMissionPadding(p1) }
        return Blocks(format: .classicMac, bigEndian: big, block1: p1, block2: block2,
                      shipName: r2.name, containerName: containerName)
    }

    /// Remove the six platform padding bytes of each mission record: two at
    /// +0x20, one at +0x35 and three trailing (Mac stride 0x8EC → 0x8E6).
    static func stripMacMissionPadding(_ mac: [UInt8]) -> [UInt8] {
        var out = Array(mac[0..<missionTableOffset])
        for slot in 0..<16 {
            let o = missionTableOffset + slot * macMissionStride
            out += mac[o..<(o + 0x20)]
            out += mac[(o + 0x22)..<(o + 0x35)]
            out += mac[(o + 0x36)..<(o + macMissionStride - 3)]
        }
        out += mac[(missionTableOffset + 16 * macMissionStride)...]
        return out
    }

    static func appleDoubleResourceFork(_ b: [UInt8]) -> Data? {
        let count = Int(be16(b, 24))
        for i in 0..<count {
            let d = 26 + i * 12
            guard d + 12 <= b.count else { return nil }
            let id = be32(b, d), off = Int(be32(b, d + 4)), len = Int(be32(b, d + 8))
            if id == 2, off >= 0, len > 0, off + len <= b.count { return Data(b[off..<(off + len)]) }
        }
        return nil
    }

    static func macBinaryResourceFork(_ b: [UInt8]) -> (String, Data)? {
        guard b.count >= 128, b[0] == 0, b[74] == 0, b[82] == 0, (1...63).contains(Int(b[1])) else { return nil }
        let dataLen = Int(be32(b, 83)), resLen = Int(be32(b, 87))
        let resOff = 128 + (dataLen + 127) / 128 * 128
        guard resLen > 0, resOff + resLen <= b.count else { return nil }
        let name = String(bytes: b[2..<(2 + Int(b[1]))], encoding: .macOSRoman) ?? ""
        return (name, Data(b[resOff..<(resOff + resLen)]))
    }

    // MARK: Byte helpers

    static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
