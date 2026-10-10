import Foundation

/// Errors raised while unpacking classic Mac archives (StuffIt / BinHex / MacBinary).
public enum MacArchiveError: Error, LocalizedError, Equatable {
    case unrecognized
    case stuffItX
    case encrypted
    case unsupportedMethod(Int)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognized: return "This isn't a StuffIt, BinHex or MacBinary file."
        case .stuffItX: return "This is a StuffIt X (.sitx) archive, a proprietary format that can't be opened here. Ask the plug-in's author for a .zip or classic .sit."
        case .encrypted: return "This archive is password-protected."
        case .unsupportedMethod(let m): return "This StuffIt archive uses compression method \(m), which isn't supported yet. Re-pack it as a .zip."
        case .corrupt(let why): return "The archive is damaged (\(why))."
        }
    }
}

/// One file or folder recovered from a classic Mac archive. Classic files carry
/// two forks; EV Nova plug-ins keep their resources in the resource fork.
public struct MacFile: Equatable, Sendable {
    /// Folder components leading to the file (Mac Roman decoded).
    public var folders: [String]
    public var name: String
    public var isFolder: Bool
    public var fileType: String
    public var creator: String
    public var data: [UInt8]
    public var rsrc: [UInt8]

    public init(folders: [String] = [], name: String, isFolder: Bool = false,
                fileType: String = "", creator: String = "",
                data: [UInt8] = [], rsrc: [UInt8] = []) {
        self.folders = folders; self.name = name; self.isFolder = isFolder
        self.fileType = fileType; self.creator = creator; self.data = data; self.rsrc = rsrc
    }
}

enum MacBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    static func macRoman(_ b: ArraySlice<UInt8>) -> String {
        String(bytes: b, encoding: .macOSRoman) ?? String(decoding: b, as: UTF8.self)
    }
    static func fourCC(_ b: [UInt8], _ o: Int) -> String { macRoman(b[o..<o + 4]) }

    /// CRC-16/ARC (reflected 0xA001, init 0) — StuffIt's fork checksum.
    static func crc16(_ b: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in b {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    /// CRC-16/XMODEM (0x1021, init 0) — MacBinary header checksum.
    static func crcCCITT(_ b: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in b {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// The 0x90-marker run-length scheme shared by BinHex and StuffIt method 1.
    static func rleDecode(_ src: ArraySlice<UInt8>, limit: Int? = nil) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limit ?? src.count)
        var i = src.startIndex
        while i < src.endIndex {
            if let limit, out.count >= limit { break }
            let c = src[i]; i += 1
            if c != 0x90 { out.append(c); continue }
            guard i < src.endIndex else { throw MacArchiveError.corrupt("truncated run") }
            let n = Int(src[i]); i += 1
            if n == 0 { out.append(0x90); continue }
            guard let last = out.last else { throw MacArchiveError.corrupt("run with no previous byte") }
            out.append(contentsOf: repeatElement(last, count: n - 1))
        }
        if let limit, out.count > limit { out.removeSubrange(limit...) }
        return out
    }
}
