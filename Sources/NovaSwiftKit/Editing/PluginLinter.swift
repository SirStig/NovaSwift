import Foundation

public struct LintIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String { "\(code)|\(key)|\(fieldKey ?? "")|\(message)" }
    public let severity: Severity
    /// Stable machine name of the rule, e.g. `dangling-ref`.
    public let code: String
    /// The plug-in resource the problem is in.
    public let key: ResourceKey
    /// Schema field key, when the problem is in one field.
    public let fieldKey: String?
    /// Plain-language explanation.
    public let message: String
}

/// Validation of a plug-in against the rules the original game applies
/// (slot ranges and padding from the scenario loader, id references, field
/// sizes, control-bit syntax). Only the plug-in's own resources are reported;
/// references are resolved against the full effective set so a plug-in that
/// depends on the base game isn't flagged for it.
public enum PluginLinter {

    public static func lint(_ document: PluginDocument) -> [LintIssue] {
        lint(layer: document.layer, effective: document.effective, base: document.base)
    }

    /// `base` (optional) enables the "identical to what it overrides" hint.
    public static func lint(layer: ResourceCollection, effective: ResourceCollection,
                            base: ResourceCollection? = nil) -> [LintIssue] {
        var issues: [LintIssue] = []
        let ctx = Context(effective: effective)

        for type in layer.types {
            for r in layer.resources(of: type) {
                let key = ResourceKey(type, r.id)
                func add(_ s: LintIssue.Severity, _ code: String, _ field: String? = nil, _ message: String) {
                    issues.append(LintIssue(severity: s, code: code, key: key, fieldKey: field, message: message))
                }
                checkContainer(r, key: key, add: add)
                if let schema = ResourceSchemas.schema(for: type), schema.editorKind == .form {
                    checkRecord(r, schema: schema, add: add)
                }
                checkReferences(r, key: key, effective: effective, add: add)
                switch type {
                case NovaType.syst: checkSystem(r, key: key, ctx: ctx, add: add)
                case NovaType.spob: checkStellar(key: key, ctx: ctx, add: add)
                case NovaType.ship: checkShip(r, key: key, ctx: ctx, add: add)
                case NovaType.weapon: checkWeapon(key: key, ctx: ctx, add: add)
                case NovaType.strList: checkStringList(r, add: add)
                default: break
                }
                if let under = base?.resource(type, r.id), under.data == r.data, under.name == r.name {
                    add(.info, "redundant-override", nil, "Identical to the version underneath; remove it to avoid needless conflicts")
                }
            }
        }
        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.message < $1.message
        }
    }

    // MARK: Context

    private struct Context {
        let effective: ResourceCollection
        /// stellar id → systems listing it
        let stellarsInSystems: Set<Int>
        /// weapon ids some outfit grants (modType 1 or 3)
        let weaponsWithOutfit: Set<Int>

        init(effective: ResourceCollection) {
            self.effective = effective
            var inSystems = Set<Int>()
            if let s = ResourceSchemas.schema(for: NovaType.syst), let f = s.field("navDefaults") {
                for sys in effective.resources(of: NovaType.syst) {
                    let d = s.padded(sys.data)
                    for i in 0..<f.count {
                        let v = FieldCodec.readInt(d, f.offset + i * f.stride, 2, signed: true)
                        if v >= 128 { inSystems.insert(v) }
                    }
                }
            }
            stellarsInSystems = inSystems
            var weapons = Set<Int>()
            if let s = ResourceSchemas.schema(for: NovaType.outfit) {
                for o in effective.resources(of: NovaType.outfit) {
                    let d = s.padded(o.data)
                    for (t, v) in [(6, 8), (18, 20), (22, 24), (26, 28)] {
                        let mod = FieldCodec.readInt(d, t, 2, signed: true)
                        if mod == 1 || mod == 3 { weapons.insert(FieldCodec.readInt(d, v, 2, signed: true)) }
                    }
                }
            }
            weaponsWithOutfit = weapons
        }
    }

    // MARK: Container-level rules

    private static func checkContainer(_ r: Resource, key: ResourceKey,
                                       add: (LintIssue.Severity, String, String?, String) -> Void) {
        if !(Int(Int16.min)...Int(Int16.max)).contains(r.id) {
            add(.error, "id-range", nil, "Resource ids must fit in 16 bits (−32768…32767)")
        } else if let range = NovaType.slotRange[key.type], !range.contains(r.id) {
            let msg = r.id < range.lowerBound
                ? "The game reserves ids below \(range.lowerBound) for this type and ignores this resource"
                : "The game only loads ids \(range.lowerBound)–\(range.upperBound) for this type and ignores this resource"
            add(.error, "id-range", nil, msg)
        }
        if FieldCodec.macRoman(r.name).count > ResourceSchema.maxNameLength {
            add(.error, "name-length", nil, "The resource name is longer than 255 characters and will be cut off when saved")
        }
        if let min = NovaType.minimumRecordSize[key.type], r.data.count < min {
            add(.warning, "short-record", nil,
                "The record is \(r.data.count) bytes; the game expects \(min) and treats the missing \(min - r.data.count) as zeros")
        }
    }

    private static func checkRecord(_ r: Resource, schema: ResourceSchema,
                                    add: (LintIssue.Severity, String, String?, String) -> Void) {
        if NovaType.minimumRecordSize[schema.type] == nil, r.data.count < schema.minimumSize {
            add(.warning, "short-record", nil, "The record is \(r.data.count) bytes; \(schema.minimumSize) are expected")
        }
        let d = schema.padded(r.data)
        for f in schema.fields {
            for i in 0..<f.count {
                let off = f.offset + i * f.stride
                let label = f.isArray ? "\(f.label) \(i + 1)" : f.label
                switch f.kind {
                case let .cString(n), let .pString(n):
                    if case .cString = f.kind, !hasTerminator(d, off, n) {
                        add(.error, "string-length", f.key, "“\(label)” fills all \(n) bytes with no end marker; it can hold at most \(n - 1) characters")
                    }
                case let .ncb(kind, n):
                    if !hasTerminator(d, off, n) {
                        add(.error, "string-length", f.key, "“\(label)” fills all \(n) bytes with no end marker; it can hold at most \(n - 1) characters")
                    }
                    let text = FieldCodec.readCString(d, off, n)
                    for issue in NCBSyntax.check(text, kind: kind) {
                        add(issue.severity == .error ? .error : .warning, "ncb-syntax", f.key,
                            "“\(label)”: \(issue.message) (position \(issue.offset + 1))")
                    }
                default:
                    if let lo = f.minValue, let v = FieldCodec.readElement(f.kind, from: d, at: off).intValue, v < lo {
                        add(.warning, "value-range", f.key, "“\(label)” is \(v); the minimum is \(lo)")
                    }
                    if let hi = f.maxValue, let v = FieldCodec.readElement(f.kind, from: d, at: off).intValue, v > hi {
                        add(.warning, "value-range", f.key, "“\(label)” is \(v); the maximum is \(hi)")
                    }
                }
            }
        }
    }

    private static func hasTerminator(_ d: Data, _ off: Int, _ n: Int) -> Bool {
        guard off + n <= d.count else { return true }
        return d[(d.startIndex + off)..<(d.startIndex + off + n)].contains(0)
    }

    // MARK: References

    /// Targets whose absence costs the player a picture, sound or line of text
    /// rather than breaking a gameplay link.
    private static let softTypes: Set<FourCharCode> = [NovaType.desc, NovaType.strList, NovaType.pict, NovaType.snd]

    /// Mask PICTs only matter for PICT-based sprites (the Bible: "ignored if the
    /// base image is an rleD/rle8 resource").
    private static let maskSprite: [String: String] = [
        "baseMask": "baseSprite", "altMask": "altSprite", "glowMask": "glowSprite", "lightMask": "lightSprite",
        "weapMask": "weapSprite", "shieldMask": "shieldSprite", "maskID": "spriteID",
    ]

    private static func maskIsIrrelevant(_ r: Resource, field: String, schema: ResourceSchema?,
                                         effective: ResourceCollection) -> Bool {
        guard let schema, schema.type == NovaType.shan || schema.type == NovaType.spin,
              let spriteKey = maskSprite[field], let f = schema.field(spriteKey) else { return false }
        let sprite = FieldCodec.readInt(schema.padded(r.data), f.offset, 2, signed: true)
        return sprite <= 0 || effective.resource(NovaType.rleD, sprite) != nil || effective.resource(NovaType.rle8, sprite) != nil
    }

    private static func checkReferences(_ r: Resource, key: ResourceKey, effective: ResourceCollection,
                                        add: (LintIssue.Severity, String, String?, String) -> Void) {
        let schema = ResourceSchemas.schema(for: r.type)
        for ref in ResourceReferences.references(of: r) where !ref.isOptional {
            guard !ResourceReferences.exists(ref.target, in: effective) else { continue }
            if maskIsIrrelevant(r, field: ref.fieldKey, schema: schema, effective: effective) { continue }
            let label = schema?.field(ref.fieldKey)?.label ?? ref.fieldKey
            let name = ResourceSchemas.displayName(for: ref.target.type)
            switch ref.kind {
            case .script:
                add(.warning, "dangling-script-ref", ref.fieldKey,
                    "“\(label)” refers to \(name) #\(ref.target.id), which doesn't exist")
            default:
                let reserved = ref.target.id > 0 && ref.target.id < 128 && NovaType.slotRange[ref.target.type] != nil
                let severity: LintIssue.Severity = reserved || softTypes.contains(ref.target.type) ? .warning : .error
                add(severity, "dangling-ref", ref.fieldKey,
                    reserved ? "“\(label)” points at \(name) #\(ref.target.id); ids below 128 aren't valid for this type"
                             : "“\(label)” points at \(name) #\(ref.target.id), which doesn't exist")
            }
        }
    }

    // MARK: Type-specific rules

    private static func checkSystem(_ r: Resource, key: ResourceKey, ctx: Context,
                                    add: (LintIssue.Severity, String, String?, String) -> Void) {
        guard let s = ResourceSchemas.schema(for: NovaType.syst), let f = s.field("links") else { return }
        let d = s.padded(r.data)
        var seen = Set<Int>()
        for i in 0..<f.count {
            let target = FieldCodec.readInt(d, f.offset + i * f.stride, 2, signed: true)
            guard target >= 128 else { continue }
            if target == key.id { add(.warning, "self-link", "links", "System links to itself"); continue }
            if !seen.insert(target).inserted { add(.warning, "duplicate-link", "links", "System #\(target) is linked more than once"); continue }
            guard let other = ctx.effective.resource(NovaType.syst, target) else { continue }
            let od = s.padded(other.data)
            let back = (0..<f.count).contains { FieldCodec.readInt(od, f.offset + $0 * f.stride, 2, signed: true) == key.id }
            if !back {
                let name = other.name.isEmpty ? "#\(target)" : "“\(other.name)” (#\(target))"
                add(.warning, "one-way-link", "links",
                    "Hyperlink to \(name) is one-way: that system doesn't link back, so ships can't return the same way")
            }
        }
    }

    private static func checkStellar(key: ResourceKey, ctx: Context,
                                     add: (LintIssue.Severity, String, String?, String) -> Void) {
        if !ctx.stellarsInSystems.contains(key.id) {
            add(.info, "stellar-unplaced", nil, "This stellar isn't in any system's list, so it never appears in space")
        }
    }

    private static func checkShip(_ r: Resource, key: ResourceKey, ctx: Context,
                                  add: (LintIssue.Severity, String, String?, String) -> Void) {
        guard let shan = ctx.effective.resource(NovaType.shan, key.id) else {
            add(.warning, "ship-no-sprite", nil,
                "No ship animation (shän #\(key.id)) exists for this ship, so it will have no picture")
            return
        }
        guard let s = ResourceSchemas.schema(for: NovaType.shan), let f = s.field("baseSprite") else { return }
        let sprite = FieldCodec.readInt(s.padded(shan.data), f.offset, 2, signed: true)
        if sprite <= 0 {
            add(.warning, "ship-no-sprite", nil, "Its ship animation (shän #\(key.id)) has no base sprite set")
        } else if !ResourceReferences.exists(ResourceKey(NovaType.rleD, sprite), in: ctx.effective) {
            add(.warning, "ship-no-sprite", nil,
                "Its ship animation (shän #\(key.id)) uses sprite #\(sprite), which has no rlëD, rlë8 or PICT")
        }
    }

    private static func checkWeapon(key: ResourceKey, ctx: Context,
                                    add: (LintIssue.Severity, String, String?, String) -> Void) {
        if !ctx.weaponsWithOutfit.contains(key.id) {
            add(.info, "weapon-no-outfit", nil,
                "No outfit (oütf) grants this weapon; the game drops weapons without one when the player lands")
        }
    }

    private static func checkStringList(_ r: Resource, add: (LintIssue.Severity, String, String?, String) -> Void) {
        guard r.data.count >= 2 else {
            if !r.data.isEmpty { add(.error, "str-malformed", nil, "String list is too short to hold a count") }
            return
        }
        let declared = Int(FieldCodec.readUInt(r.data, 0, 2))
        let decoded = TextResourceCodec.decodeStringList(r.data).count
        if decoded < declared {
            add(.error, "str-malformed", nil, "The list says it has \(declared) strings but only \(decoded) can be read")
        }
    }
}
