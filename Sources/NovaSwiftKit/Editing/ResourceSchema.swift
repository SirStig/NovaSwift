import Foundation

// TMPL-style field model for EV Nova resources. One `ResourceSchema` per type
// describes every field once (offset, width, meaning) and is used for both
// reading and editing, so the editor, the linter and the reference graph all
// agree with the byte layouts the typed decoders (`NovaModels.swift` & co.)
// and the original loader use. All multi-byte values are big-endian.

/// Width of an integer field in bytes.
public enum IntWidth: Int, Sendable, Hashable {
    case w8 = 1, w16 = 2, w32 = 4
}

/// What an NCB expression field is for (affects the syntax rules the linter
/// applies: tests allow `&`, `|`, `!`, parentheses and comparison operators;
/// sets allow assignment verbs).
public enum NCBKind: Sendable, Hashable {
    case test
    case set
}

/// The wire shape of one field. Meaning beyond the shape (flag labels, named
/// values, id ranges) lives on `SchemaField`.
public enum FieldKind: Sendable, Hashable {
    /// Plain integer.
    case int(IntWidth, signed: Bool)
    /// Bit set; per-bit labels in `SchemaField.flagBits`.
    case flags(IntWidth)
    /// Integer drawn from named values / ranges in `SchemaField.options`.
    case enumeration(IntWidth, signed: Bool)
    /// A resource id (16-bit signed). The stored value is `id - base`, so
    /// `base` 0 is a plain id and e.g. `bööm.SoundIndex` is `snd ` base 300.
    /// -1 and 0 (plus any `options` sentinels) mean "none".
    case ref(FourCharCode, base: Int)
    /// NUL-terminated Mac Roman text in a fixed-size field (size includes the NUL).
    case cString(Int)
    /// Length-prefixed Mac Roman text in a fixed-size field (size includes the length byte).
    case pString(Int)
    /// `00RRGGBB` (the high byte is preserved on write).
    case color
    /// Control-bit expression in a fixed-size C-string field.
    case ncb(NCBKind, Int)
    /// Opaque bytes (unused padding, unknown fields).
    case blob(Int)
    /// Two signed 16-bit values, stored (x or horizontal, y or vertical).
    case point
    /// Four signed 16-bit values in stored order: top, left, bottom, right.
    case rect
    /// 64-bit Contribute / Require flag word.
    case mask64
    /// A bit-slice of a wider integer sharing its offset with siblings
    /// (`value = (container >> shift) & ((1 << width) - 1)`).
    case bits(IntWidth, shift: Int, width: Int)

    public static let i8 = FieldKind.int(.w8, signed: true)
    public static let u8 = FieldKind.int(.w8, signed: false)
    public static let i16 = FieldKind.int(.w16, signed: true)
    public static let u16 = FieldKind.int(.w16, signed: false)
    public static let i32 = FieldKind.int(.w32, signed: true)
    public static let u32 = FieldKind.int(.w32, signed: false)

    /// Bytes this kind occupies at its offset (per element).
    public var byteSize: Int {
        switch self {
        case let .int(w, _), let .flags(w), let .enumeration(w, _), let .bits(w, _, _): return w.rawValue
        case .ref: return 2
        case let .cString(n), let .pString(n), let .ncb(_, n), let .blob(n): return n
        case .color: return 4
        case .point: return 4
        case .rect: return 8
        case .mask64: return 8
        }
    }
}

/// A decoded field value. Flag sets, enumerations and refs are all `.int`.
public enum FieldValue: Sendable, Hashable {
    case int(Int)
    case uint64(UInt64)
    case string(String)
    case color(r: UInt8, g: UInt8, b: UInt8)
    case bytes(Data)
    case point(Int, Int)
    case rect(Int, Int, Int, Int)
    case array([FieldValue])

    public var intValue: Int? { if case let .int(v) = self { return v }; return nil }
    public var stringValue: String? { if case let .string(v) = self { return v }; return nil }
}

/// One named bit of a flag field.
public struct FlagBit: Sendable, Hashable {
    public let mask: Int
    public let label: String
    public init(_ mask: Int, _ label: String) { self.mask = mask; self.label = label }
}

/// A named value or value range a numeric field accepts (the TMPL `CASE` /
/// `CASR` lines). A range may also *encode a resource id*: e.g. `mïsn.AvailStel`
/// 10000...10255 means "a stellar of govt (value − 10000 + 128)".
public struct ValueOption: Sendable, Hashable {
    public let label: String
    /// Value at which the range starts (equals `end` for an exact value).
    public let start: Int
    /// Last value of the range; `Int.max` / `Int.min` when open-ended.
    public let end: Int
    /// When set, values in the range encode a resource of this type.
    public let refType: FourCharCode?
    /// The resource id (or payload) at `start`; defaults to `start`.
    public let base: Int

    public init(_ label: String, start: Int, end: Int? = nil, refType: FourCharCode? = nil, base: Int? = nil) {
        self.label = label
        self.start = start
        self.end = end ?? start
        self.refType = refType
        self.base = base ?? start
    }

    public var step: Int { end < start ? -1 : 1 }
    public var isExact: Bool { start == end }
    public var range: ClosedRange<Int> { Swift.min(start, end)...Swift.max(start, end) }
    public func contains(_ v: Int) -> Bool { range.contains(v) }

    /// The resource id / payload a value in this range stands for.
    public func payload(for v: Int) -> Int { base + (v - start) * step }
    /// The stored value for a payload (inverse of `payload(for:)`).
    public func value(forPayload p: Int) -> Int { start + (p - base) * step }
}

/// A resource this one implicitly owns by id arithmetic rather than by a stored
/// field (e.g. `shïp` N has its target-display PICT at 2872 + N).
public struct RelatedResource: Sendable, Hashable {
    public let label: String
    public let type: FourCharCode
    /// The related id is `self.id + idOffset`.
    public let idOffset: Int
    public init(_ label: String, _ type: FourCharCode, _ idOffset: Int) {
        self.label = label; self.type = type; self.idOffset = idOffset
    }
}

/// Which editor the UI should open for a type.
public enum EditorKind: String, Sendable, Hashable {
    case form      // schema-driven field inspector
    case text      // STR#, STR , dësc, TEXT
    case graphic   // PICT, rlëD, rlë8, cicn, ppat, classic icons/cursors/patterns, NSbl/PNG/icns
    case sound     // snd
    case raw       // hex only
}

/// What a field's value means depends on another field (`oütf` ModVal follows
/// ModType; `spöb` CustSndID is an exit angle on gates; `wëap` AmmoType names a
/// ship for fighter bays). `reference(for:selector:)` and the editor use this to
/// pick the right control.
public struct ContextualValue: Sendable, Hashable {
    public struct Meaning: Sendable, Hashable {
        public let label: String
        /// When set, the value is a resource of this type with id `value + idBase`.
        public let refType: FourCharCode?
        public let idBase: Int
        /// Values below this are "none" / not a reference.
        public let minValue: Int
        public let flagBits: [FlagBit]
        public let help: String
        public init(_ label: String, refType: FourCharCode? = nil, idBase: Int = 0, minValue: Int = 1,
                    flagBits: [FlagBit] = [], help: String = "") {
            self.label = label; self.refType = refType; self.idBase = idBase; self.minValue = minValue
            self.flagBits = flagBits; self.help = help
        }
    }
    /// Key of the field whose value selects the meaning (element-wise for arrays).
    public let selector: String
    /// Bits of the selector value that matter (-1 = all).
    public let selectorMask: Int
    public let meanings: [Int: Meaning]
    public let fallback: Meaning
    public init(selector: String, selectorMask: Int = -1, meanings: [Int: Meaning], fallback: Meaning) {
        self.selector = selector; self.selectorMask = selectorMask
        self.meanings = meanings; self.fallback = fallback
    }
    public func meaning(for selectorValue: Int) -> Meaning {
        meanings[selectorMask == -1 ? selectorValue : selectorValue & selectorMask] ?? fallback
    }
}

public struct SchemaField: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    /// UI section heading.
    public let group: String
    /// Short plain-language explanation (from the Nova Bible).
    public let help: String
    public let offset: Int
    public let kind: FieldKind
    /// Repeated array: `count` elements `stride` bytes apart starting at `offset`.
    public let count: Int
    public let stride: Int
    public let minValue: Int?
    public let maxValue: Int?
    public let flagBits: [FlagBit]
    public let options: [ValueOption]
    /// Value a fresh record holds (zero when nil).
    public let defaultValue: Int?
    /// Set when the meaning of the value depends on a sibling field.
    public let contextual: ContextualValue?

    public var isArray: Bool { count > 1 }
    /// Bytes from `offset` to the end of the last element.
    public var byteSpan: Int { (count - 1) * stride + kind.byteSize }

    public init(key: String, label: String, group: String = "General", help: String = "",
                offset: Int, kind: FieldKind, count: Int = 1, stride: Int? = nil,
                min: Int? = nil, max: Int? = nil, flagBits: [FlagBit] = [],
                options: [ValueOption] = [], defaultValue: Int? = nil,
                contextual: ContextualValue? = nil) {
        self.key = key; self.label = label; self.group = group; self.help = help
        self.offset = offset; self.kind = kind; self.count = count
        self.stride = stride ?? kind.byteSize
        self.minValue = min; self.maxValue = max
        self.flagBits = flagBits; self.options = options; self.defaultValue = defaultValue
        self.contextual = contextual
    }

    /// The option (named value / range) a raw value falls in, if any.
    public func option(for value: Int) -> ValueOption? { options.first { $0.contains(value) } }

    /// The resource this value points at: `(type, id)`, or nil when it is a
    /// "none" sentinel, a plain number, or not a reference field.
    public func reference(for value: Int, selector: Int? = nil) -> (type: FourCharCode, id: Int)? {
        if let ctx = contextual {
            guard let selector else { return nil }
            let m = ctx.meaning(for: selector)
            guard let t = m.refType, value >= m.minValue else { return nil }
            return (t, value + m.idBase)
        }
        if let opt = option(for: value) {
            guard let t = opt.refType else { return nil }
            return (t, opt.payload(for: value))
        }
        if case let .ref(type, base) = kind {
            // Index-style refs (base ≠ 0) count from 0; plain ids use 0 and -1 for "none".
            guard base != 0 ? value >= 0 : value > 0 else { return nil }
            return (type, value + base)
        }
        return nil
    }
}

/// Layout and presentation of one resource type.
public struct ResourceSchema: Sendable {
    public let type: FourCharCode
    public let displayName: String
    public let editorKind: EditorKind
    /// The original loader zero-pads records to this size
    /// (`NovaType.minimumRecordSize`); fresh records are exactly this long.
    public let minimumSize: Int
    public let fields: [SchemaField]
    /// Ordered UI section names (derived from field order).
    public let groups: [String]
    public let related: [RelatedResource]
    /// Overrides for `makeDefault()` (key → value), on top of field defaults.
    public let defaults: [String: Int]
    /// Longest name the container can carry (Pascal string in classic forks).
    public static let maxNameLength = 255

    public init(type: FourCharCode, displayName: String, editorKind: EditorKind = .form,
                minimumSize: Int, fields: [SchemaField], related: [RelatedResource] = [],
                defaults: [String: Int] = [:]) {
        self.type = type; self.displayName = displayName; self.editorKind = editorKind
        self.minimumSize = minimumSize; self.fields = fields; self.related = related
        self.defaults = defaults
        var seen = Set<String>(), order: [String] = []
        for f in fields where seen.insert(f.group).inserted { order.append(f.group) }
        self.groups = order
        self.index = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private let index: [String: SchemaField]

    public func field(_ key: String) -> SchemaField? { index[key] }
    public func fields(in group: String) -> [SchemaField] { fields.filter { $0.group == group } }

    /// Highest byte any field touches.
    public var declaredExtent: Int { fields.map { $0.offset + $0.byteSpan }.max() ?? 0 }

    /// A blank record: `minimumSize` zero bytes with field defaults applied.
    public func makeDefault() -> Data {
        var d = Data(count: minimumSize)
        for f in fields {
            let v = defaults[f.key] ?? f.defaultValue
            guard let v, v != 0 else { continue }
            let value: FieldValue = f.isArray ? .array(Array(repeating: .int(v), count: f.count)) : .int(v)
            FieldCodec.write(value, field: f, into: &d)
        }
        return d
    }

    /// `data` zero-padded to the minimum record size (as the loader does).
    public func padded(_ data: Data) -> Data {
        guard data.count < minimumSize else { return data }
        return data + Data(count: minimumSize - data.count)
    }

    public func read(_ key: String, from data: Data) -> FieldValue? {
        field(key).map { FieldCodec.read($0, from: data) }
    }

    @discardableResult
    public func write(_ value: FieldValue, key: String, into data: inout Data) -> Bool {
        guard let f = field(key) else { return false }
        FieldCodec.write(value, field: f, into: &data)
        return true
    }

    /// Every field's value, keyed by field key.
    public func readAll(from data: Data) -> [String: FieldValue] {
        Dictionary(fields.map { ($0.key, FieldCodec.read($0, from: data)) }, uniquingKeysWith: { a, _ in a })
    }
}
