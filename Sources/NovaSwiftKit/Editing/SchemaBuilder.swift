import Foundation

/// Terse construction helpers for the schema tables in `ResourceSchemas+*.swift`.
func ty(_ s: String) -> FourCharCode {
    guard let t = FourCharCode(s) else { preconditionFailure("bad type code \(s)") }
    return t
}

extension FlagBit {
    static func f(_ mask: Int, _ label: String) -> FlagBit { FlagBit(mask, label) }
}

extension ValueOption {
    /// An exact named value.
    static func v(_ label: String, _ value: Int) -> ValueOption { ValueOption(label, start: value) }
    /// A bounded range, optionally encoding a resource id (`base` = id at `start`).
    static func r(_ label: String, _ start: Int, _ end: Int, _ type: FourCharCode? = nil, _ base: Int? = nil) -> ValueOption {
        ValueOption(label, start: start, end: end, refType: type, base: base)
    }
    /// An open-ended range running away from zero (ascending when `start >= 0`).
    static func open(_ label: String, _ start: Int, _ type: FourCharCode? = nil, _ base: Int? = nil) -> ValueOption {
        ValueOption(label, start: start, end: start >= 0 ? Int.max : Int.min, refType: type, base: base)
    }
}

struct SchemaBuilder {
    private(set) var fields: [SchemaField] = []

    mutating func add(_ kind: FieldKind, _ offset: Int, _ key: String, _ label: String,
                      group: String = "General", help: String = "", count: Int = 1, stride: Int? = nil,
                      min: Int? = nil, max: Int? = nil, def: Int? = nil,
                      bits: [FlagBit] = [], opts: [ValueOption] = [], ctx: ContextualValue? = nil) {
        fields.append(SchemaField(key: key, label: label, group: group, help: help, offset: offset,
                                  kind: kind, count: count, stride: stride, min: min, max: max,
                                  flagBits: bits, options: opts, defaultValue: def, contextual: ctx))
    }

    /// `minimumSize` is the larger of the original loader's padding size and the
    /// last byte any field touches, so a fresh record always holds every field.
    func build(type: FourCharCode, name: String, related: [RelatedResource] = [],
               defaults: [String: Int] = [:]) -> ResourceSchema {
        let extent = fields.map { $0.offset + $0.byteSpan }.max() ?? 0
        return ResourceSchema(type: type, displayName: name, editorKind: .form,
                              minimumSize: Swift.max(NovaType.minimumRecordSize[type] ?? 0, extent),
                              fields: fields, related: related, defaults: defaults)
    }
}
