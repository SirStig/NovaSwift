import Foundation

/// A Macintosh OSType / resource type code: exactly four bytes.
///
/// EV Nova deliberately uses **extended Mac Roman** characters in its type codes
/// (Apple reserved the plain-ASCII space), so the on-disk bytes are literally
/// `shïp`, `wëap`, `oütf`, `mïsn`, `spöb`, `sÿst`, … We therefore key on the raw
/// four bytes and decode to a display string via Mac Roman — never by normalizing
/// to ASCII.
public struct FourCharCode: Hashable, Comparable, CustomStringConvertible, Sendable {
    /// The four bytes packed big-endian into a UInt32.
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(bytes b: [UInt8]) {
        precondition(b.count == 4, "FourCharCode requires exactly 4 bytes")
        rawValue = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    /// Build from a display string (e.g. "shïp"), encoding it as Mac Roman.
    /// Returns nil if the string is not exactly four Mac Roman bytes.
    public init?(_ string: String) {
        guard let d = string.data(using: .macOSRoman), d.count == 4 else { return nil }
        self.init(bytes: [UInt8](d))
    }

    public var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: rawValue >> 24),
         UInt8(truncatingIfNeeded: rawValue >> 16),
         UInt8(truncatingIfNeeded: rawValue >> 8),
         UInt8(truncatingIfNeeded: rawValue)]
    }

    /// Human-readable form, decoded as Mac Roman (so `shïp` renders correctly).
    public var stringValue: String {
        String(data: Data(bytes), encoding: .macOSRoman) ?? "????"
    }

    /// Hex form of the raw bytes, useful when a code is non-printable.
    public var hexValue: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    public var description: String { stringValue }

    public static func < (lhs: FourCharCode, rhs: FourCharCode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The EV Nova resource type codes (raw Mac Roman four-char codes).
/// See docs/DATA_FORMAT.md for what each holds.
public enum NovaType {
    public static let ship    = FourCharCode("shïp")!
    public static let weapon  = FourCharCode("wëap")!
    public static let outfit  = FourCharCode("oütf")!
    public static let mission = FourCharCode("mïsn")!
    public static let spob    = FourCharCode("spöb")! // stellar object / planet
    public static let syst    = FourCharCode("sÿst")! // star system
    public static let govt    = FourCharCode("gövt")! // government
    public static let dude     = FourCharCode("düde")! // ship-type grouping for AI
    public static let fleet    = FourCharCode("flët")!
    public static let pers      = FourCharCode("përs")! // named character
    public static let char      = FourCharCode("chär")! // starting pilot
    public static let cron       = FourCharCode("crön")! // time-based events
    public static let junk       = FourCharCode("jünk")!
    public static let oops       = FourCharCode("öops")!
    public static let roid        = FourCharCode("röid")! // asteroid
    public static let nebula   = FourCharCode("nëbu")!
    public static let rank       = FourCharCode("ränk")!
    public static let spin        = FourCharCode("spïn")! // sprite descriptor
    public static let shan       = FourCharCode("shän")! // ship animation
    public static let boom      = FourCharCode("bööm")! // explosion
    public static let desc       = FourCharCode("dësc")! // description text
    public static let intf        = FourCharCode("ïntf")! // interface
    public static let colr       = FourCharCode("cölr")! // colors

    // Standard Mac resource types EV Nova also uses.
    public static let strList   = FourCharCode("STR#")!
    public static let pict        = FourCharCode("PICT")!
    public static let ppat        = FourCharCode("ppat")!
    public static let ppatAlt     = FourCharCode("PPat")!
    public static let snd         = FourCharCode("snd ")!
    public static let cicn        = FourCharCode("cicn")!
    public static let rle8        = FourCharCode("rlë8")!
    public static let rleD        = FourCharCode("rlëD")!
    public static let ditl        = FourCharCode("DITL")! // dialog item list (layout)
    public static let dlog       = FourCharCode("DLOG")! // dialog window template
}

// MARK: Loader normalisation

extension NovaType {
    /// The size every record of a scenario type is zero-padded to before any
    /// field is read (`Resource_ByteSwapAndPadRecordByType` 0x004ce700), so a
    /// short or old plug-in record reads its missing tail as zeros.
    public static let minimumRecordSize: [FourCharCode: Int] = [
        mission: 1970, ship: 1860, spob: 1118, outfit: 1028, cron: 822, junk: 676,
        nebula: 518, syst: 428, pers: 400, fleet: 306, oops: 282, colr: 244, govt: 192,
        shan: 192, intf: 166, rank: 152, weapon: 134, dude: 88, roid: 40, spin: 12,
        boom: 6, char: 362,
    ]

    /// The ids the scenario loader (0x004bd3c0) keeps for each slot-table type:
    /// a fixed number of slots, id = slot + 128. Records outside are ignored.
    public static let slotRange: [FourCharCode: ClosedRange<Int>] = [
        spob: 128...(128 + 0x800 - 1), syst: 128...(128 + 0x800 - 1),
        outfit: 128...(128 + 0x200 - 1), weapon: 128...(128 + 0x100 - 1),
        ship: 128...(128 + 0x300 - 1), dude: 128...(128 + 0x200 - 1),
        govt: 128...(128 + 0x100 - 1), pers: 128...(128 + 0x400 - 1),
        fleet: 128...(128 + 0x100 - 1), cron: 128...(128 + 0x200 - 1),
        junk: 128...(128 + 0x80 - 1),
        // 0x0043bbb0 (1000 mission slots) and 0x004bd3c0.
        mission: 128...(128 + 1000 - 1), oops: 128...(128 + 0x100 - 1),
        nebula: 128...(128 + 0x20 - 1), boom: 128...(128 + 0x40 - 1),
        rank: 128...(128 + 0x80 - 1), roid: 128...(128 + 0x10 - 1),
    ]
}

extension ResourceCollection {
    /// Applies the original loader's view of the merged data: scenario records
    /// outside their type's slot range are dropped, and short records are
    /// zero-padded to their type's minimum size.
    public mutating func normalizeScenarioRecords() {
        for (type, range) in NovaType.slotRange {
            for resource in resources(of: type) where !range.contains(resource.id) {
                remove(type, resource.id)
            }
        }
        for (type, size) in NovaType.minimumRecordSize {
            for resource in resources(of: type) where resource.data.count < size {
                var padded = resource
                var data = Data(resource.data)
                data.append(Data(count: size - data.count))
                padded.data = data
                add(padded)
            }
        }
    }
}
