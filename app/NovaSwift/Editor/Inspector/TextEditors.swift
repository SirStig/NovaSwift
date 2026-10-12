#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// STR# — counted list of Pascal strings.
struct StringListEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    var body: some View {
        let rows = TextResourceCodec.decodeStringList(data)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(rows.count) string\(rows.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { var r = rows; r.append(""); commit(r, "Add string") } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
            }
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        .frame(width: 26, alignment: .trailing).padding(.top, 5)
                    TextField("", text: Binding(get: { TextResourceCodec.display(rows[i]) },
                                                set: { v in var r = TextResourceCodec.decodeStringList(model.document.resource(key.type, key.id)?.data ?? data)
                                                    guard r.indices.contains(i) else { return }
                                                    r[i] = TextResourceCodec.stored(v); commit(r, "Edit string \(i + 1)", coalesce: "strl/\(key)/\(i)") }),
                              axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    VStack(spacing: 0) {
                        Button { move(rows, i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { move(rows, i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == rows.count - 1)
                    }.buttonStyle(.plain).font(.system(size: 9))
                    Button { var r = rows; r.remove(at: i); commit(r, "Remove string \(i + 1)") } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 5)
                }
            }
        }
    }

    private func move(_ rows: [String], _ i: Int, _ d: Int) {
        var r = rows; r.swapAt(i, i + d); commit(r, "Reorder strings")
    }

    private func commit(_ rows: [String], _ label: String, coalesce: String? = nil) {
        model.writeData(TextResourceCodec.encodeStringList(rows), for: key, label: label, coalesce: coalesce)
    }
}

/// STR — one Pascal string.
struct SingleStringEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    var body: some View {
        let s = TextResourceCodec.display(TextResourceCodec.decodeString(data))
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(get: { s }, set: { v in
                model.writeData(TextResourceCodec.encodeString(TextResourceCodec.stored(v)), for: key,
                                label: "Edit text", coalesce: "str/\(key)")
            }))
            .font(.system(size: 13)).frame(minHeight: 120)
            .scrollContentBackground(.hidden).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text("\(FieldCodec.macRoman(TextResourceCodec.stored(s)).count)/255 bytes")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// JSON-ish text (HD graphics descriptors).
struct RawTextEditor: View {
    let key: ResourceKey
    let data: Data
    @ObservedObject var model: EditorModel

    var body: some View {
        let s = String(decoding: data, as: UTF8.self)
        let valid = (try? JSONSerialization.jsonObject(with: data)) != nil
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(get: { s }, set: { v in
                model.writeData(Data(v.utf8), for: key, label: "Edit text", coalesce: "txt/\(key)")
            }))
            .font(.system(size: 12, design: .monospaced)).frame(minHeight: 220)
            .scrollContentBackground(.hidden).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Label(valid ? "Valid JSON" : "Not valid JSON", systemImage: valid ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(valid ? Color.green : Color.orange)
        }
    }
}

/// dësc — description text plus picture / movie / flags trailer.
struct DescEditor: View {
    let key: ResourceKey
    let data: Data
    let env: EditorEnv
    @ObservedObject var model: EditorModel

    var body: some View {
        let rec = DescRecord(data)
        VStack(alignment: .leading, spacing: 12) {
            Text("TEXT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            TextEditor(text: Binding(get: { TextResourceCodec.display(rec.text) }, set: { v in
                var r = DescRecord(model.document.resource(key.type, key.id)?.data ?? data)
                r.text = TextResourceCodec.stored(v)
                commit(r, "Edit description", coalesce: "desc/\(key)")
            }))
            .font(.system(size: 13)).frame(minHeight: 160)
            .scrollContentBackground(.hidden).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            Text("PREVIEW").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            Text(preview(TextResourceCodec.display(rec.text)))
                .font(.custom("Geneva", size: 12).monospaced())
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
                .textSelection(.enabled)
            Text("Amber text marks substitution codes and {conditionals} the game expands at display time.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            Text("MEDIA").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            row("Picture") {
                ValuePicker(env: env, refType: NovaType.pict, noneValue: 0, isNone: { $0 <= 0 }, value: rec.pictureID) { v in
                    var r = rec; r.pictureID = v; commit(r, "Set picture")
                }
            }
            row("Movie file") {
                StringField(value: rec.movieFile, maxBytes: DescRecord.movieFieldSize - 1) { v in
                    var r = DescRecord(model.document.resource(key.type, key.id)?.data ?? data)
                    r.movieFile = v; commit(r, "Set movie", coalesce: "descmovie/\(key)")
                }.frame(maxWidth: 260)
            }
            row("Flags") {
                VStack(alignment: .leading, spacing: 3) {
                    flag("Show movie after text", DescRecord.showMovieAfter, rec)
                    flag("Double-size movie", DescRecord.doubleSizeMovie, rec)
                    flag("Cinematic (letterboxed) movie", DescRecord.cinematicMovie, rec)
                }
            }
        }
    }

    private func flag(_ title: String, _ mask: Int, _ rec: DescRecord) -> some View {
        Toggle(title, isOn: Binding(get: { rec.flags & mask != 0 }, set: { on in
            var r = rec; r.flags = on ? r.flags | mask : r.flags & ~mask; commit(r, "Edit flags")
        })).toggleStyle(.checkbox).font(.system(size: 12))
    }

    private func row<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(t).font(.system(size: 12)).frame(width: 90, alignment: .leading)
            c()
        }
    }

    private func commit(_ r: DescRecord, _ label: String, coalesce: String? = nil) {
        model.writeData(r.encode(), for: key, label: label, coalesce: coalesce)
    }

    /// Compiled once (not per keystroke / body pass).
    private static let codeRegex = try? NSRegularExpression(pattern: #"\^[A-Za-z0-9]{1,3}|\{[^}]*\}|<[^>\n]{1,40}>"#)

    private func preview(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        guard let re = Self.codeRegex else { return out }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].foregroundColor = novaAmber
        }
        return out
    }
}
#endif
