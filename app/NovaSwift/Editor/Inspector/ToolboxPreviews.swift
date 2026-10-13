#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Classic Mac Toolbox resource types the game doesn't model but plug-ins (and Nova.rez) carry.
enum ToolboxType {
    static let text = NovaSwiftKit.FourCharCode("TEXT")!
    static let alrt = NovaSwiftKit.FourCharCode("ALRT")!
    static let menu = NovaSwiftKit.FourCharCode("MENU")!
    static let cntl = NovaSwiftKit.FourCharCode("CNTL")!
    /// Resources whose bytes are a whole image file (ImageIO decodes them as-is).
    static let imageFiles: Set<NovaSwiftKit.FourCharCode> = [NovaSwiftKit.FourCharCode("PNG ")!, NovaSwiftKit.FourCharCode("PNGf")!, NovaSwiftKit.FourCharCode("icns")!]
}

/// `TEXT`: unprefixed Mac Roman text with CR line endings.
struct MacTextEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    var body: some View {
        let s = TextResourceCodec.display(String(data: data, encoding: .macOSRoman) ?? "")
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(get: { s }, set: { v in
                model.writeData(Data(FieldCodec.macRoman(TextResourceCodec.stored(v))), for: key,
                                label: "Edit text", coalesce: "txt/\(key)")
            }))
            .font(.system(size: 13)).frame(minHeight: 220)
            .scrollContentBackground(.hidden).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text("\(data.count) bytes · Mac Roman").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Big-endian reads that return nil past the end instead of trapping.
private struct ToolboxReader {
    let b: [UInt8]
    init(_ d: Data) { b = [UInt8](d) }
    func u8(_ p: Int) -> Int? { p >= 0 && p < b.count ? Int(b[p]) : nil }
    func i16(_ p: Int) -> Int? {
        guard p >= 0, p + 2 <= b.count else { return nil }
        return Int(Int16(bitPattern: UInt16(b[p]) << 8 | UInt16(b[p + 1])))
    }
    func u32(_ p: Int) -> Int? {
        guard let hi = i16(p), let lo = i16(p + 2) else { return nil }
        return (hi & 0xFFFF) << 16 | (lo & 0xFFFF)
    }
    /// Pascal string at `p`; returns the string and the offset just past it.
    func pstr(_ p: Int) -> (String, Int)? {
        guard let n = u8(p), p + 1 + n <= b.count else { return nil }
        return (String(bytes: b[(p + 1)..<(p + 1 + n)], encoding: .macOSRoman) ?? "", p + 1 + n)
    }
}

/// `MENU`: header, title, then items (name, icon, key equivalent, mark, style) up to a
/// zero-length name. Read-only; edit through Raw.
struct MenuPreview: View {
    let data: Data

    private struct Item: Identifiable { let id: Int; let name: String; let key: String; let mark: String; let enabled: Bool }

    var body: some View {
        let r = ToolboxReader(data)
        let flags = r.u32(10) ?? 0
        let title = r.pstr(14)
        let items = parseItems(r, from: title?.1 ?? data.count, flags: flags)
        VStack(alignment: .leading, spacing: 10) {
            Text("MENU id \(r.i16(0) ?? 0) · proc \(r.i16(6) ?? 0) · \(items.count) item\(items.count == 1 ? "" : "s")\((flags & 1) == 0 ? " · menu disabled" : "")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title?.0.isEmpty == false ? title!.0 : "(untitled)")
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ForEach(items) { item in
                    if item.name == "-" {
                        Divider().padding(.vertical, 3)
                    } else {
                        HStack {
                            Text(item.mark).frame(width: 14)
                            Text(item.name)
                            Spacer()
                            if !item.key.isEmpty { Text("⌘\(item.key)").foregroundStyle(.secondary) }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(item.enabled ? .primary : .tertiary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                    }
                }
            }
            .frame(width: 280, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
            Text("Read-only preview. Switch to Raw to edit the bytes.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func parseItems(_ r: ToolboxReader, from start: Int, flags: Int) -> [Item] {
        var out: [Item] = [], p = start
        while let (name, next) = r.pstr(p), !name.isEmpty, out.count < 512 {
            guard let keyByte = r.u8(next + 1), let markByte = r.u8(next + 2) else { break }
            func ch(_ v: Int) -> String {
                v == 0 ? "" : String(bytes: [UInt8(v)], encoding: .macOSRoman) ?? ""
            }
            // Flag bit 0 is the menu itself; item n's enable bit is n (items past 31 are always enabled).
            let n = out.count + 1
            out.append(Item(id: n, name: name, key: ch(keyByte), mark: ch(markByte),
                            enabled: n > 31 || flags & (1 << n) != 0))
            p = next + 4
        }
        return out
    }
}

/// `CNTL`: bounds, value, visibility, max/min, proc id (control kind), refCon, title.
struct ControlPreview: View {
    let data: Data

    var body: some View {
        let r = ToolboxReader(data)
        let top = r.i16(0) ?? 0, left = r.i16(2) ?? 0, bottom = r.i16(4) ?? 0, right = r.i16(6) ?? 0
        let proc = r.i16(16) ?? 0
        let rows: [(String, String)] = [
            ("Title", r.pstr(22)?.0 ?? ""),
            ("Kind", "\(Self.kind(proc)) (proc \(proc))"),
            ("Bounds", "\(left),\(top) → \(right),\(bottom)  (\(right - left)×\(bottom - top))"),
            ("Value", "\(r.i16(8) ?? 0)  (min \(r.i16(14) ?? 0), max \(r.i16(12) ?? 0))"),
            ("Visible", (r.u8(10) ?? 0) != 0 ? "Yes" : "No"),
            ("RefCon", String(format: "0x%08X", r.u32(18) ?? 0)),
        ]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(row.1).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            Text("Read-only preview. Switch to Raw to edit the bytes.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    /// Standard CDEF variants (proc id = CDEF id × 16 + variation).
    private static func kind(_ proc: Int) -> String {
        switch proc {
        case 0: return "Push button"
        case 1: return "Checkbox"
        case 2: return "Radio button"
        case 16: return "Scroll bar"
        case 1008...1015: return "Pop-up menu"
        default: return "Custom"
        }
    }
}
#endif
