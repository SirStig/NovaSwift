#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// "Changes vs. base": at the top of an overridden resource's inspector, every field (or string)
/// where this plug-in differs from the record it replaces, old → new in plain language, with a
/// per-field revert. Diffing one record is cheap but still runs off the main actor in a task keyed
/// by data revision, so typing in the form updates it live without touching the first frame.
struct OverrideDiffPanel: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    @State private var payload: Payload?
    @State private var open = true

    struct SimpleChange: Hashable, Sendable { let label: String; let old: String; let new: String }

    enum Payload: Sendable {
        case fields([FieldChange])
        case strings([StringChange])
        case simple([SimpleChange])

        var count: Int {
            switch self {
            case let .fields(a): return a.count
            case let .strings(a): return a.count
            case let .simple(a): return a.count
            }
        }
    }

    private struct TaskKey: Hashable { let key: ResourceKey; let rev: Int }

    var body: some View {
        Group {
            if let p = payload, p.count > 0 {
                DisclosureGroup(isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 6) { rows(p) }
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plusminus.circle").foregroundStyle(novaAmber)
                        Text("Changes vs. base").font(.system(size: 12, weight: .semibold))
                        Text("\(p.count) \(unit(p))\(p.count == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(novaAmber.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(novaAmber.opacity(0.25)))
            }
        }
        .task(id: TaskKey(key: key, rev: model.dataRevision)) { await compute() }
    }

    private func unit(_ p: Payload) -> String {
        switch p {
        case .fields: return "field"
        case .strings: return "string"
        case .simple: return "part"
        }
    }

    // MARK: Rows

    @ViewBuilder private func rows(_ p: Payload) -> some View {
        switch p {
        case let .fields(list):
            ForEach(list) { c in fieldRow(c) }
        case let .strings(list):
            ForEach(list) { c in stringRow(c) }
        case let .simple(list):
            ForEach(list, id: \.self) { c in simpleRow(c) }
        }
    }

    private func fieldRow(_ c: FieldChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.label).font(.system(size: 12)).lineLimit(2)
                Text(c.group).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            if c.flagDeltas.isEmpty {
                valueChange(c.oldText, c.newText)
            } else {
                ChipFlow(spacing: 4) {
                    ForEach(c.flagDeltas, id: \.self) { d in
                        Text((d.added ? "+" : "−") + d.label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .foregroundStyle(d.added ? Color.green : Color.red)
                            .background((d.added ? Color.green : Color.red).opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 4)
            Button { model.setValue(c.oldValue, field: c.key, of: key) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Revert “\(c.label)” to the base value (\(c.oldText))")
        }
    }

    private func stringRow(_ c: StringChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("#\(c.index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            valueChange(c.old.map(shorten) ?? "(none)", c.new.map(shorten) ?? "(removed)")
            Spacer(minLength: 4)
            Button { revertString(c) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Revert string \(c.index + 1) to the base text")
        }
    }

    private func simpleRow(_ c: SimpleChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(c.label).font(.system(size: 12)).frame(width: 170, alignment: .leading)
            valueChange(c.old, c.new)
            Spacer(minLength: 0)
        }
    }

    private func valueChange(_ old: String, _ new: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(old).font(.system(size: 11)).foregroundStyle(.secondary).strikethrough(true, color: Color.secondary.opacity(0.5))
                .textSelection(.enabled)
            Text(new).font(.system(size: 11, weight: .medium)).foregroundStyle(novaAmber)
                .textSelection(.enabled)
        }
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shorten(_ s: String) -> String {
        let t = TextResourceCodec.display(s)
        return t.count > 160 ? String(t.prefix(160)) + "…" : t
    }

    private func revertString(_ c: StringChange) {
        guard let cur = model.document.resource(key.type, key.id) else { return }
        var list = TextResourceCodec.decodeStringList(cur.data)
        if let old = c.old {
            while list.count <= c.index { list.append("") }
            list[c.index] = old
        } else if list.indices.contains(c.index) {
            list.remove(at: c.index)
        }
        model.writeData(TextResourceCodec.encodeStringList(list), for: key, label: "Revert string \(c.index + 1)")
    }

    // MARK: Compute

    private func compute() async {
        guard let layerRes = model.document.layerResource(key.type, key.id),
              let baseRes = model.base.resource(key.type, key.id) else { payload = nil; return }
        let eff = model.effective
        let k = key
        let out = await Task.detached(priority: .userInitiated) {
            Self.diff(key: k, base: baseRes, current: layerRes, eff: eff)
        }.value
        if Task.isCancelled { return }
        payload = out
    }

    nonisolated private static func diff(key: ResourceKey, base: Resource, current: Resource,
                                         eff: ResourceCollection) -> Payload? {
        if let schema = ResourceSchemas.schema(for: key.type), schema.editorKind == .form {
            let ch = ResourceDiff.fieldChanges(schema: schema, base: base.data, new: current.data) { t, id in
                eff.resource(t, id)?.name
            }
            return .fields(ch)
        }
        switch key.type {
        case NovaType.strList:
            return .strings(ResourceDiff.stringChanges(base: TextResourceCodec.decodeStringList(base.data),
                                                       new: TextResourceCodec.decodeStringList(current.data)))
        case NovaType.desc:
            let o = DescRecord(base.data), n = DescRecord(current.data)
            var out: [SimpleChange] = []
            if o.text != n.text { out.append(.init(label: "Text", old: TextResourceCodec.display(o.text), new: TextResourceCodec.display(n.text))) }
            if o.pictureID != n.pictureID { out.append(.init(label: "Picture", old: "PICT #\(o.pictureID)", new: "PICT #\(n.pictureID)")) }
            if o.movieFile != n.movieFile { out.append(.init(label: "Movie file", old: o.movieFile, new: n.movieFile)) }
            if o.flags != n.flags { out.append(.init(label: "Flags", old: String(format: "0x%lX", o.flags), new: String(format: "0x%lX", n.flags))) }
            return .simple(out)
        default:
            if key.type.stringValue == "STR " {
                let o = TextResourceCodec.decodeString(base.data), n = TextResourceCodec.decodeString(current.data)
                return o == n ? nil : .simple([.init(label: "Text", old: TextResourceCodec.display(o), new: TextResourceCodec.display(n))])
            }
            return nil
        }
    }
}
#endif
