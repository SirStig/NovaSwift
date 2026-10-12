import Foundation

/// Encode/decode for the text-bearing resource types the editor treats as
/// documents rather than field forms: `STR#` (counted list of Pascal strings),
/// `STR ` (one Pascal string) and `dësc` (NUL-terminated text + 36-byte trailer).
/// All text is Mac Roman; EV Nova stores line breaks as CR, so the `display`
/// helpers translate to and from `\n` for editing.
public enum TextResourceCodec {

    /// Mac Roman text with CR line breaks → Swift text with `\n`.
    public static func display(_ stored: String) -> String {
        stored.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    /// Swift text with `\n` → stored text with CR line breaks.
    public static func stored(_ display: String) -> String {
        display.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    }

    // MARK: STR#

    /// Longest Pascal string a `STR#` entry can hold.
    public static let maxPascalLength = 255

    public static func decodeStringList(_ data: Data) -> [String] {
        guard data.count >= 2 else { return [] }
        let count = Int(FieldCodec.readUInt(data, 0, 2))
        var out: [String] = []
        var off = 2
        for _ in 0..<count {
            guard off < data.count else { break }
            let len = Int(data[data.startIndex + off]); off += 1
            guard off + len <= data.count else { break }
            out.append(String(bytes: data[(data.startIndex + off)..<(data.startIndex + off + len)], encoding: .macOSRoman) ?? "")
            off += len
        }
        return out
    }

    /// Exact inverse of `decodeStringList` for well-formed lists; entries longer
    /// than 255 Mac Roman bytes are truncated (a Pascal string cannot hold more).
    public static func encodeStringList(_ strings: [String]) -> Data {
        var d = Data()
        let n = min(strings.count, 0xFFFF)
        d.append(UInt8(n >> 8)); d.append(UInt8(n & 0xFF))
        for s in strings.prefix(n) {
            let bytes = FieldCodec.macRoman(s).prefix(maxPascalLength)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        return d
    }

    // MARK: STR

    public static func decodeString(_ data: Data) -> String {
        guard let first = data.first else { return "" }
        let len = min(Int(first), data.count - 1)
        return String(bytes: data[(data.startIndex + 1)..<(data.startIndex + 1 + len)], encoding: .macOSRoman) ?? ""
    }

    public static func encodeString(_ s: String) -> Data {
        let bytes = FieldCodec.macRoman(s).prefix(maxPascalLength)
        return Data([UInt8(bytes.count)]) + Data(bytes)
    }
}

/// One `dësc` record: description text plus the trailer the briefing dialogs
/// read (PICT shown beside the text, an optional movie file and its flags).
/// Layout verified against `DescRes` and the Bible: `text\0`, `i16 pict`,
/// `char[32] movie`, `u16 flags`.
public struct DescRecord: Sendable, Hashable {
    /// Trailer bytes as read, so stray bytes after the movie name's NUL (common
    /// in shipped data) survive an edit untouched. Not part of equality.
    private var rawTrailer = Data()

    public static func == (a: DescRecord, b: DescRecord) -> Bool {
        a.text == b.text && a.pictureID == b.pictureID && a.movieFile == b.movieFile
            && a.flags == b.flags && a.extra == b.extra && a.hasTrailer == b.hasTrailer
    }
    public func hash(into h: inout Hasher) {
        h.combine(text); h.combine(pictureID); h.combine(movieFile); h.combine(flags); h.combine(extra); h.combine(hasTrailer)
    }

    public static let movieFieldSize = 32
    public static let trailerSize = 2 + movieFieldSize + 2

    /// Text as stored (CR line breaks, control-bit `{b001 "a" "b"}` markup intact).
    public var text: String
    /// PICT id shown with the text; 0 or -1 for none.
    public var pictureID: Int
    /// QuickTime file name in "Nova Files"/"Nova Plug-ins".
    public var movieFile: String
    public var flags: Int
    /// Bytes after the standard trailer (older plug-ins), preserved verbatim.
    public var extra: Data
    /// False for a record that stops after the text's NUL (very old plug-ins).
    public var hasTrailer: Bool

    public static let showMovieAfter = 0x0001
    public static let doubleSizeMovie = 0x0002
    public static let cinematicMovie = 0x0004

    public init(text: String = "", pictureID: Int = 0, movieFile: String = "", flags: Int = 0,
                extra: Data = Data(), hasTrailer: Bool = true) {
        self.text = text; self.pictureID = pictureID; self.movieFile = movieFile
        self.flags = flags; self.extra = extra; self.hasTrailer = hasTrailer
    }

    public init(_ data: Data) {
        let nul = data.firstIndex(of: 0) ?? data.endIndex
        text = String(bytes: data[data.startIndex..<nul], encoding: .macOSRoman) ?? ""
        let t = data.distance(from: data.startIndex, to: nul) + 1
        guard t < data.count else {
            pictureID = 0; movieFile = ""; flags = 0; extra = Data(); hasTrailer = false
            return
        }
        hasTrailer = true
        pictureID = FieldCodec.readInt(data, t, 2, signed: true)
        movieFile = FieldCodec.readCString(data, t + 2, Self.movieFieldSize)
        flags = FieldCodec.readInt(data, t + 2 + Self.movieFieldSize, 2, signed: false)
        let end = t + Self.trailerSize
        extra = end < data.count ? Data(data[(data.startIndex + end)...]) : Data()
        rawTrailer = Data(data[(data.startIndex + t)..<(data.startIndex + min(end, data.count))])
    }

    public func encode() -> Data {
        var d = Data(FieldCodec.macRoman(text).filter { $0 != 0 })
        d.append(0)
        let isBlank = pictureID == 0 && movieFile.isEmpty && flags == 0 && extra.isEmpty
        guard hasTrailer || !isBlank else { return d }
        let t = d.count
        var trailer = rawTrailer
        trailer.append(Data(count: max(0, Self.trailerSize - trailer.count)))
        d.append(trailer)
        FieldCodec.writeUInt(&d, t, 2, UInt64(truncatingIfNeeded: pictureID))
        FieldCodec.writeCString(&d, t + 2, Self.movieFieldSize, movieFile)
        FieldCodec.writeUInt(&d, t + 2 + Self.movieFieldSize, 2, UInt64(truncatingIfNeeded: flags))
        d.append(extra)
        return d
    }
}
