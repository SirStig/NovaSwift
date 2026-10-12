#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

// MARK: - Numbers

func editorIntRange(_ w: IntWidth, signed: Bool) -> ClosedRange<Int> {
    switch (w, signed) {
    case (.w8, true): return -128...127
    case (.w8, false): return 0...255
    case (.w16, true): return -32768...32767
    case (.w16, false): return 0...65535
    case (.w32, true): return Int(Int32.min)...Int(Int32.max)
    case (.w32, false): return 0...Int(UInt32.max)
    }
}

/// Integer text field with optional stepper. Keeps its own text while focused so
/// partial input ("-", "0x") doesn't fight the model.
struct NumberField: View {
    let value: Int
    var range: ClosedRange<Int> = Int(Int32.min)...Int(Int32.max)
    var hex = false
    var stepper = true
    var width: CGFloat = 84
    var onSet: (Int) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused($focused)
                .foregroundStyle(inRange ? Color.primary : Color.red)
                .onChange(of: text) { _, t in commit(t) }
                .onSubmit { text = format(value) }
            if stepper {
                Stepper("", value: Binding(get: { value }, set: { onSet(clamp($0)) }), in: range)
                    .labelsHidden()
            }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !focused { text = format(v) } }
        .onChange(of: focused) { _, f in if !f { text = format(value) } }
    }

    private var inRange: Bool { parse(text).map { range.contains($0) } ?? false }
    private func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }
    private func format(_ v: Int) -> String { hex ? "0x" + String(v, radix: 16, uppercase: true) : String(v) }
    private func parse(_ t: String) -> Int? {
        let s = t.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
        if hex, let v = Int(s, radix: 16), !s.isEmpty, s.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefABCDEF")) != nil { return v }
        return Int(s)
    }
    private func commit(_ t: String) {
        guard focused, let v = parse(t) else { return }
        let c = clamp(v)
        if c != value { onSet(c) }
    }
}

// MARK: - Flags

struct FlagsEditor: View {
    let bits: [FlagBit]
    let value: Int
    let width: IntWidth
    var onSet: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !bits.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 3) {
                    ForEach(bits, id: \.mask) { b in
                        Toggle(isOn: Binding(get: { value & b.mask != 0 },
                                             set: { on in onSet(on ? value | b.mask : value & ~b.mask) })) {
                            Text(b.label).font(.system(size: 11)).lineLimit(2)
                        }
                        .toggleStyle(.checkbox)
                        .help(String(format: "0x%X", b.mask))
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Value").font(.system(size: 10)).foregroundStyle(.secondary)
                NumberField(value: value, range: 0...Int(UInt64(1) << UInt64(width.rawValue * 8) - 1), hex: true,
                            stepper: false, width: 100, onSet: onSet)
                let known = bits.reduce(0) { $0 | $1.mask }
                if !bits.isEmpty, value & ~known != 0 {
                    Text(String(format: "unnamed bits 0x%X set", value & ~known))
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// 64-bit Contribute / Require word.
struct Mask64Editor: View {
    let value: UInt64
    var onSet: (UInt64) -> Void
    @State private var open = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                    .font(.system(size: 12, design: .monospaced)).frame(width: 180)
                    .onChange(of: text) { _, t in
                        guard focused else { return }
                        let s = t.lowercased().hasPrefix("0x") ? String(t.dropFirst(2)) : t
                        if let v = UInt64(s, radix: 16), v != value { onSet(v) }
                    }
                Button(open ? "Hide bits" : "Edit bits") { open.toggle() }.buttonStyle(.link).font(.system(size: 11))
            }
            if open {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 16), spacing: 2) {
                    ForEach((0..<64).reversed(), id: \.self) { bit in
                        let on = value & (UInt64(1) << UInt64(bit)) != 0
                        Button { onSet(value ^ (UInt64(1) << UInt64(bit))) } label: {
                            Text("\(bit)").font(.system(size: 9, design: .monospaced))
                                .frame(width: 28, height: 18)
                                .background(on ? novaAmber.opacity(0.85) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(on ? Color.black : Color.secondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear { text = fmt(value) }
        .onChange(of: value) { _, v in if !focused { text = fmt(v) } }
    }
    private func fmt(_ v: UInt64) -> String { "0x" + String(format: "%016llX", v) }
}

// MARK: - Strings

struct StringField: View {
    let value: String
    /// Max Mac Roman bytes the field holds.
    let maxBytes: Int
    var monospaced = false
    var onSet: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            TextField("", text: Binding(get: { value }, set: { onSet($0) }), axis: maxBytes > 80 ? .vertical : .horizontal)
                .lineLimit(1...(maxBytes > 80 ? 5 : 1))
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            let used = FieldCodec.macRoman(value).count
            Text("\(used)/\(maxBytes)").font(.system(size: 9, design: .monospaced))
                .foregroundStyle(used >= maxBytes ? Color.orange : Color.secondary.opacity(0.6))
        }
    }
}

/// NCB expression with live syntax checking and a red-underlined echo.
struct NCBField: View {
    let value: String
    let kind: NCBKind
    let maxBytes: Int
    var onSet: (String) -> Void

    var body: some View {
        let issues = value.isEmpty ? [] : NCBSyntax.check(value, kind: kind)
        VStack(alignment: .leading, spacing: 3) {
            StringField(value: value, maxBytes: maxBytes, monospaced: true, onSet: onSet)
            if !issues.isEmpty {
                Text(underlined(issues)).font(.system(size: 11, design: .monospaced))
                ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
                    Label(i.message, systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(i.severity == .error ? .red : .orange)
                }
            }
        }
    }

    private func underlined(_ issues: [NCBSyntax.Issue]) -> AttributedString {
        var out = AttributedString()
        let chars = Array(value)
        let marks = Set(issues.map(\.offset))
        for (i, c) in chars.enumerated() {
            var a = AttributedString(String(c))
            if marks.contains(i) {
                a.underlineStyle = .single; a.underlineColor = .red; a.foregroundColor = .red
            }
            out.append(a)
        }
        if marks.contains(chars.count) {
            var a = AttributedString("␣"); a.underlineStyle = .single; a.underlineColor = .red; out.append(a)
        }
        return out
    }
}

// MARK: - Colour

struct ColorField: View {
    let r: UInt8, g: UInt8, b: UInt8
    var onSet: (UInt8, UInt8, UInt8) -> Void
    @State private var hex = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
                    onSet(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                          UInt8((ns.blueComponent * 255).rounded()))
                }), supportsOpacity: false).labelsHidden()
            TextField("", text: $hex).textFieldStyle(.roundedBorder).focused($focused)
                .font(.system(size: 12, design: .monospaced)).frame(width: 90)
                .onChange(of: hex) { _, t in
                    guard focused else { return }
                    let s = t.hasPrefix("#") ? String(t.dropFirst()) : t
                    if s.count == 6, let v = UInt32(s, radix: 16) {
                        let (nr, ng, nb) = (UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255))
                        if (nr, ng, nb) != (r, g, b) { onSet(nr, ng, nb) }
                    }
                }
        }
        .onAppear { hex = fmt() }
        .onChange(of: r) { _, _ in if !focused { hex = fmt() } }
        .onChange(of: g) { _, _ in if !focused { hex = fmt() } }
        .onChange(of: b) { _, _ in if !focused { hex = fmt() } }
    }
    private func fmt() -> String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Space-separated hex bytes for fixed-size blob fields.
struct BlobField: View {
    let value: Data
    var onSet: (Data) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(parse(text) == nil ? Color.red : Color.primary)
            .onChange(of: text) { _, t in
                guard focused, let d = parse(t), d.count == value.count, d != value else { return }
                onSet(d)
            }
            .onAppear { text = fmt(value) }
            .onChange(of: value) { _, v in if !focused { text = fmt(v) } }
    }
    private func fmt(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private func parse(_ t: String) -> Data? {
        let hex = t.filter { !$0.isWhitespace }
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}

// MARK: - Reference / option picker

/// Picker for ref fields and for numeric fields with named values or id-encoding
/// ranges (`ValueOption`). `value` is the stored number; with `refType`, the
/// resource id is `value + base`.
struct ValuePicker: View {
    let env: EditorEnv
    let refType: NovaSwiftKit.FourCharCode?
    var base: Int = 0
    /// Value written for "None".
    var noneValue: Int = -1
    /// Stored values below/at which the field means "no reference".
    var isNone: (Int) -> Bool = { $0 <= 0 }
    var options: [ValueOption] = []
    var range: ClosedRange<Int> = -32768...32767
    let value: Int
    var onSet: (Int) -> Void

    @State private var open = false
    @State private var query = ""

    private var matchedOption: ValueOption? { options.first { $0.contains(value) } }
    private var target: (type: NovaSwiftKit.FourCharCode, id: Int)? {
        if let o = matchedOption { return o.refType.map { ($0, o.payload(for: value)) } }
        if let t = refType, !isNone(value) { return (t, value + base) }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { open = true } label: {
                HStack(spacing: 4) {
                    Text(display).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(missing ? Color.red : Color.primary)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).frame(minWidth: 160, maxWidth: 280, minHeight: 22)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { popover }
            if showRaw {
                NumberField(value: value, range: range, stepper: false, width: 70, onSet: onSet)
            }
            if let t = target, env.exists(t.type, t.id) {
                Button { env.jump(t.type, t.id) } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.plain).foregroundStyle(novaAmber).help("Go to \(t.type.stringValue) #\(t.id)")
            }
        }
    }

    private var showRaw: Bool {
        if let o = matchedOption { return !o.isExact }
        return refType == nil
    }

    private var missing: Bool {
        if let t = target { return !env.exists(t.type, t.id) }
        return false
    }

    private var display: String {
        if let o = matchedOption {
            if let t = o.refType { return "\(o.label) → \(env.label(t, o.payload(for: value)))" }
            return o.isExact ? o.label : "\(o.label) (\(value))"
        }
        if let t = refType { return isNone(value) ? "None" : env.label(t, value + base) }
        return "\(value)"
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query).textFieldStyle(.roundedBorder).padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if refType != nil && !options.contains(where: { $0.contains(noneValue) }) {
                        row("None", sub: nil, current: refType != nil && isNone(value) && matchedOption == nil) { set(noneValue) }
                    }
                    ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                        if matches(o.label) {
                            row(o.label, sub: o.isExact ? "\(o.start)" : "\(o.start)…\(o.end == .max ? "∞" : String(o.end))",
                                current: o.contains(value)) { set(o.contains(value) ? value : o.start) }
                        }
                    }
                    if let t = refType {
                        ForEach(filtered(t), id: \.key) { e in
                            row(e.name.isEmpty ? "#\(e.key.id)" : "#\(e.key.id)  \(e.name)", sub: nil,
                                current: matchedOption == nil && value + base == e.key.id) {
                                set(e.key.id - base)
                            }
                        }
                    }
                }
            }
            .frame(width: 320, height: 300)
        }
    }

    private func set(_ v: Int) { onSet(v); open = false }
    private func matches(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query.lowercased()) }

    private func filtered(_ t: NovaSwiftKit.FourCharCode) -> [PluginDocument.BrowserEntry] {
        let all = env.cache.entries(t, env.model)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [PluginDocument.BrowserEntry] = []
        for e in all {
            if q.isEmpty || e.name.lowercased().contains(q) || String(e.key.id).contains(q) { out.append(e) }
            if out.count >= 300 { break }
        }
        return out
    }

    private func row(_ title: String, sub: String?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "checkmark").opacity(current ? 1 : 0).font(.system(size: 10)).frame(width: 14)
                Text(title).lineLimit(1)
                Spacer()
                if let sub { Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
