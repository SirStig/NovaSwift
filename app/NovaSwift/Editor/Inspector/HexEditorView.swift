#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Editable offset / hex / ASCII view of a resource's raw bytes. Rows are lazy, so
/// large pictures and sounds stay cheap.
struct HexEditorView: View {
    let key: ResourceKey
    let data: Data
    let minimumSize: Int
    @ObservedObject var model: EditorModel

    @State private var sel: Int?
    @State private var text = ""
    @State private var count = 1
    @FocusState private var cellFocused: Bool

    private let perRow = 16

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<max(1, (data.count + perRow - 1) / perRow), id: \.self) { r in row(r) }
                }
                .padding(10)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(data.count) bytes").font(.system(size: 11, design: .monospaced))
            if minimumSize > 0 {
                Text("schema minimum \(minimumSize)").font(.system(size: 11)).foregroundStyle(data.count < minimumSize ? .orange : .secondary)
                if data.count < minimumSize {
                    Button("Pad") { write(data + Data(count: minimumSize - data.count), "Pad to minimum") }.controlSize(.small)
                }
            }
            Spacer()
            Stepper("×\(count)", value: $count, in: 1...256).font(.system(size: 11))
            Button { insert() } label: { Label("Insert", systemImage: "plus.square") }.controlSize(.small)
            Button { remove() } label: { Label("Delete", systemImage: "minus.square") }.controlSize(.small).disabled(sel == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func row(_ r: Int) -> some View {
        let start = r * perRow
        let end = min(start + perRow, data.count)
        return HStack(alignment: .center, spacing: 0) {
            Text(String(format: "%06X", start)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<perRow, id: \.self) { c in
                    let i = start + c
                    if i < end { cell(i) } else { Color.clear.frame(width: 22, height: 17) }
                    if c == 7 { Spacer().frame(width: 6) }
                }
            }
            Text(ascii(start, end)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .frame(height: 19)
    }

    @ViewBuilder private func cell(_ i: Int) -> some View {
        if sel == i {
            TextField(String(format: "%02X", data[data.startIndex + i]), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 22, height: 17)
                .background(novaAmber.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                .focused($cellFocused)
                .onChange(of: text) { _, t in typed(t, at: i) }
                .onAppear { cellFocused = true }
        } else {
            Text(String(format: "%02X", data[data.startIndex + i]))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 22, height: 17)
                .foregroundStyle(data[data.startIndex + i] == 0 ? Color.secondary.opacity(0.5) : Color.primary)
                .contentShape(Rectangle())
                .onTapGesture { select(i) }
        }
    }

    private func select(_ i: Int) {
        sel = i
        text = ""
        cellFocused = true
    }

    private func typed(_ t: String, at i: Int) {
        let clean = String(t.uppercased().filter { $0.isHexDigit }.suffix(2))
        if clean != t { text = clean; return }
        guard clean.count == 2, let b = UInt8(clean, radix: 16), i < data.count else { return }
        if data[data.startIndex + i] != b {
            var d = data; d[d.startIndex + i] = b
            write(d, "Edit bytes", coalesce: "hex/\(key)/\(i)")
        }
        if i + 1 < data.count { select(i + 1) } else { sel = nil }
    }

    private func insert() {
        var d = data
        let at = min(sel ?? d.count, d.count)
        d.insert(contentsOf: Data(count: count), at: d.startIndex + at)
        write(d, "Insert bytes")
    }

    private func remove() {
        guard let s = sel, s < data.count else { return }
        var d = data
        let n = min(count, d.count - s)
        d.removeSubrange((d.startIndex + s)..<(d.startIndex + s + n))
        sel = nil
        write(d, "Delete bytes")
    }

    private func write(_ d: Data, _ label: String, coalesce: String? = nil) {
        model.writeData(d, for: key, label: label, coalesce: coalesce)
    }

    private func ascii(_ a: Int, _ b: Int) -> String {
        String((a..<b).map { i -> Character in
            let v = data[data.startIndex + i]
            return v >= 32 && v < 127 ? Character(UnicodeScalar(v)) : "·"
        })
    }
}
#endif
