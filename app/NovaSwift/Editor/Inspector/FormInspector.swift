#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Schema-driven form: collapsible group sections, two-column field rows.
struct FormInspector: View {
    let schema: ResourceSchema
    let key: ResourceKey
    let data: Data
    let env: EditorEnv
    let hover: EditorHoverState
    let issues: [LintIssue]
    @State private var collapsed: Set<String> = []

    var body: some View {
        let fieldIssues = Dictionary(grouping: issues.filter { $0.fieldKey != nil }, by: { $0.fieldKey! })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(schema.groups, id: \.self) { g in
                let fields = schema.fields(in: g)
                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(g) },
                                                    set: { if $0 { collapsed.remove(g) } else { collapsed.insert(g) } })) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(fields) { f in
                            FieldRow(schema: schema, field: f, key: key, data: data, env: env, hover: hover,
                                     issues: fieldIssues[f.key] ?? [])
                        }
                    }
                    .padding(.top, 6).padding(.bottom, 10)
                } label: {
                    Text(g.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .tracking(0.6)
                }
                Divider().opacity(0.5)
            }
        }
    }
}

struct FieldRow: View {
    let schema: ResourceSchema
    let field: SchemaField
    let key: ResourceKey
    let data: Data
    let env: EditorEnv
    let hover: EditorHoverState
    let issues: [LintIssue]
    @State private var showHelp = false

    static let labelWidth: CGFloat = 200

    var body: some View {
        let selectorField = field.contextual.flatMap { schema.field($0.selector) }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            labelView(selectorField: selectorField)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<field.count, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if field.isArray {
                            Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                        }
                        element(i, selectorField: selectorField)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .id("field-\(field.key)")
        .onHover { inside in
            hover.range = inside ? field.offset..<(field.offset + max(1, field.byteSpan)) : nil
        }
    }

    // MARK: Label

    private func meaning(_ i: Int, _ selectorField: SchemaField?) -> ContextualValue.Meaning? {
        guard let ctx = field.contextual, let sf = selectorField else { return nil }
        let sv = FieldCodec.read(sf, from: data)
        let v: Int
        if case let .array(a) = sv { v = a.indices.contains(i) ? (a[i].intValue ?? 0) : 0 } else { v = sv.intValue ?? 0 }
        return ctx.meaning(for: v)
    }

    private func labelView(selectorField: SchemaField?) -> some View {
        let dynamic = field.contextual != nil ? meaning(0, selectorField)?.label : nil
        return HStack(spacing: 4) {
            if let worst = issues.map(\.severity).max() {
                Image(systemName: worst == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(worst == .error ? .red : .orange)
                    .help(issues.map(\.message).joined(separator: "\n"))
            }
            Text(field.contextual != nil && !field.isArray ? (dynamic ?? field.label) : field.label)
                .font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(field.help.isEmpty ? field.label : field.help)
            if !field.help.isEmpty {
                Button { showHelp = true } label: { Image(systemName: "info.circle").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .popover(isPresented: $showHelp) {
                        Text(field.help).font(.system(size: 12)).padding(12).frame(width: 300, alignment: .leading)
                    }
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
    }

    // MARK: Elements

    private func commit(_ new: FieldValue, index i: Int) {
        let value: FieldValue
        if field.isArray {
            var items: [FieldValue]
            if case let .array(a)? = env.model.readValue(field.key, of: key) { items = a } else { items = [] }
            while items.count < field.count { items.append(Self.zero(field.kind)) }
            items[i] = new
            value = .array(items)
        } else { value = new }
        env.model.setValue(value, field: field.key, of: key)
    }

    static func zero(_ kind: FieldKind) -> FieldValue {
        switch kind {
        case .cString, .pString, .ncb: return .string("")
        case .color: return .color(r: 0, g: 0, b: 0)
        case .blob(let n): return .bytes(Data(count: n))
        case .point: return .point(0, 0)
        case .rect: return .rect(0, 0, 0, 0)
        case .mask64: return .uint64(0)
        default: return .int(0)
        }
    }

    private func current(_ i: Int) -> FieldValue {
        let v = FieldCodec.read(field, from: data)
        if case let .array(a) = v { return a.indices.contains(i) ? a[i] : Self.zero(field.kind) }
        return v
    }

    @ViewBuilder private func element(_ i: Int, selectorField: SchemaField?) -> some View {
        let value = current(i)
        let m = meaning(i, selectorField)
        let set: (FieldValue) -> Void = { commit($0, index: i) }
        let iv = value.intValue ?? 0

        if let m {
            contextual(m, value: iv, set: set)
        } else {
            switch field.kind {
            case let .int(w, signed):
                if field.options.isEmpty { intEditor(iv, w, signed, set) } else { optionEditor(iv, field.options, editorIntRange(w, signed: signed), set) }
            case let .enumeration(w, signed):
                optionEditor(iv, field.options, editorIntRange(w, signed: signed), set)
            case let .bits(_, _, width):
                let r = 0...((1 << width) - 1)
                if field.options.isEmpty { NumberField(value: iv, range: r) { set(.int($0)) } }
                else { optionEditor(iv, field.options, r, set) }
            case let .flags(w):
                FlagsEditor(bits: field.flagBits, value: iv, width: w) { set(.int($0)) }
            case let .ref(type, base):
                ValuePicker(env: env, refType: type, base: base, noneValue: -1,
                            isNone: { base != 0 ? $0 < 0 : $0 <= 0 }, options: field.options, value: iv) { set(.int($0)) }
            case let .cString(n):
                StringField(value: value.stringValue ?? "", maxBytes: n - 1) { set(.string($0)) }
            case let .pString(n):
                StringField(value: value.stringValue ?? "", maxBytes: min(255, n - 1)) { set(.string($0)) }
            case let .ncb(kind, n):
                NCBField(value: value.stringValue ?? "", kind: kind, maxBytes: n - 1) { set(.string($0)) }
            case .color:
                if case let .color(r, g, b) = value { ColorField(r: r, g: g, b: b) { set(.color(r: $0, g: $1, b: $2)) } }
            case .blob:
                if case let .bytes(d) = value { BlobField(value: d) { set(.bytes($0)) } }
            case .point:
                if case let .point(x, y) = value {
                    HStack(spacing: 8) {
                        labeled("x") { NumberField(value: x, range: -32768...32767, stepper: false, width: 64) { set(.point($0, y)) } }
                        labeled("y") { NumberField(value: y, range: -32768...32767, stepper: false, width: 64) { set(.point(x, $0)) } }
                    }
                }
            case .rect:
                if case let .rect(t, l, b, r) = value {
                    HStack(spacing: 8) {
                        labeled("top") { NumberField(value: t, range: -32768...32767, stepper: false, width: 56) { set(.rect($0, l, b, r)) } }
                        labeled("left") { NumberField(value: l, range: -32768...32767, stepper: false, width: 56) { set(.rect(t, $0, b, r)) } }
                        labeled("bottom") { NumberField(value: b, range: -32768...32767, stepper: false, width: 56) { set(.rect(t, l, $0, r)) } }
                        labeled("right") { NumberField(value: r, range: -32768...32767, stepper: false, width: 56) { set(.rect(t, l, b, $0)) } }
                    }
                }
            case .mask64:
                if case let .uint64(v) = value { Mask64Editor(value: v) { set(.uint64($0)) } }
            }
        }
    }

    private func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 3) { Text(t).font(.system(size: 10)).foregroundStyle(.secondary); c() }
    }

    private func intEditor(_ v: Int, _ w: IntWidth, _ signed: Bool, _ set: @escaping (FieldValue) -> Void) -> some View {
        let full = editorIntRange(w, signed: signed)
        let lo = max(field.minValue ?? full.lowerBound, full.lowerBound)
        let hi = min(field.maxValue ?? full.upperBound, full.upperBound)
        return NumberField(value: v, range: lo...max(lo, hi)) { set(.int($0)) }
    }

    private func optionEditor(_ v: Int, _ opts: [ValueOption], _ range: ClosedRange<Int>,
                              _ set: @escaping (FieldValue) -> Void) -> some View {
        ValuePicker(env: env, refType: nil, options: opts, range: range, value: v) { set(.int($0)) }
    }

    @ViewBuilder private func contextual(_ m: ContextualValue.Meaning, value v: Int,
                                         set: @escaping (FieldValue) -> Void) -> some View {
        let width: IntWidth = { if case let .int(w, _) = field.kind { return w }
            if case let .ref = field.kind { return .w16 }
            if case let .flags(w) = field.kind { return w }
            if case let .enumeration(w, _) = field.kind { return w }
            return .w16 }()
        let signed: Bool = { if case let .int(_, s) = field.kind { return s }
            if case let .enumeration(_, s) = field.kind { return s }
            return true }()
        VStack(alignment: .leading, spacing: 3) {
            if !m.flagBits.isEmpty {
                FlagsEditor(bits: m.flagBits, value: v, width: width) { set(.int($0)) }
            } else if let t = m.refType {
                ValuePicker(env: env, refType: t, base: m.idBase, noneValue: m.minValue - 1,
                            isNone: { $0 < m.minValue }, value: v) { set(.int($0)) }
            } else {
                NumberField(value: v, range: editorIntRange(width, signed: signed)) { set(.int($0)) }
            }
            if !m.help.isEmpty { Text(m.help).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
}

/// Live byte view under the form: highlights the field being hovered.
struct BytesPanel: View {
    let data: Data
    let minimumSize: Int
    @ObservedObject var hover: EditorHoverState
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            let range = hover.range
            let shown = min(data.count, 512)
            Text(attributed(range: range, shown: shown))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if data.count > shown {
                Text("… \(data.count - shown) more bytes (use Raw)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: {
            Text("BYTES · \(data.count) (minimum \(minimumSize))").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).tracking(0.6)
        }
    }

    private func attributed(range: Range<Int>?, shown: Int) -> AttributedString {
        var out = AttributedString()
        for i in 0..<shown {
            var a = AttributedString(String(format: "%02X", data[data.startIndex + i]) + (i % 16 == 15 ? "\n" : " "))
            if let r = range, r.contains(i) {
                a.backgroundColor = novaAmber.opacity(0.5); a.foregroundColor = .white
            }
            out.append(a)
        }
        return out
    }
}
#endif
