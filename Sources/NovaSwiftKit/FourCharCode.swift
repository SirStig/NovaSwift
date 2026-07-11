import Foundation

/// A Macintosh OSType / resource type code: exactly four bytes.
///
/// EV Nova deliberately uses **extended Mac Roman** characters in its type codes
/// (Apple reserved the plain-ASCII space), so the on-disk bytes are literally
/// `shïp`, `wëap`, `oütf`, `mïsn`, `spöb`, `sÿst`, … We therefore key on the raw
/// four bytes and decode to a display string via Mac Roman — never by normalizing
/// to ASCII.
public struct FourCharCode: Hashable, Comparable, CustomStringConvertible {
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
    public static let snd         = FourCharCode("snd ")!
    public static let cicn        = FourCharCode("cicn")!
    public static let rle8        = FourCharCode("rlë8")!
    public static let rleD        = FourCharCode("rlëD")!
    public static let ditl        = FourCharCode("DITL")! // dialog item list (layout)
    public static let dlog       = FourCharCode("DLOG")! // dialog window template
}
