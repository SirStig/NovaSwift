#if os(macOS)
import SwiftUI
import NovaSwiftKit

// Small schema-backed controls shared by the galaxy and system inspectors.
// Every control reads straight from the document and writes through
// `EditorModel.setValue`, so undo/redo/dirty/preview all stay in step.

extension EditorModel {
    func intField(_ field: String, _ key: ResourceKey, default d: Int = 0) -> Int {
        readValue(field, of: key)?.intValue ?? d
    }
    func stringField(_ field: String, _ key: ResourceKey) -> String {
        readValue(field, of: key)?.stringValue ?? ""
    }
    func arrayField(_ field: String, _ key: ResourceKey) -> [Int] {
        if case let .array(vs)? = readValue(field, of: key) { return vs.map { $0.intValue ?? -1 } }
        return []
    }
    func pointField(_ field: String, _ key: ResourceKey) -> (Int, Int) {
        if case let .point(x, y)? = readValue(field, of: key) { return (x, y) }
        return (0, 0)
    }
    func setArray(_ values: [Int], field: String, of key: ResourceKey) {
        setValue(.array(values.map { .int($0) }), field: field, of: key)
    }

    /// Rename a resource (undoable, coalesced per resource).
    func renameResource(_ key: ResourceKey, to name: String) {
        guard let r = document.resource(key.type, key.id), r.name != name else { return }
        document.put(Resource(type: key.type, id: key.id, name: name, attributes: r.attributes, data: r.data),
                     label: "Rename \(key)", coalesce: "name/\(key)")
    }

    /// Display name of any resource ("Name" or "type #id").
    func displayName(_ type: NovaSwiftKit.FourCharCode, _ id: Int) -> String {
        if let r = document.resource(type, id), !r.name.isEmpty { return r.name }
        return "\(type.stringValue) #\(id)"
    }

    func entries(_ type: NovaSwiftKit.FourCharCode) -> [(id: Int, name: String)] {
        document.effective.resources(of: type).map { ($0.id, $0.name.isEmpty ? "#\($0.id)" : $0.name) }
    }

    /// Show a resource in the shell's resource browser.
    func showInResources(_ key: ResourceKey) {
        selectedType = key.type
        selection = key
        tool = .resources
    }

    func openSystemEditor(_ id: Int) {
        focusedSystemID = id
        tool = .system
    }
}

struct MapIntRow: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    let label: String
    var width: CGFloat = 64
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField("", value: Binding(get: { model.intField(field, key) },
                                         set: { model.setValue(.int($0), field: field, of: key) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: width).font(.system(size: 11, design: .monospaced))
        }
    }
}

struct MapPointRow: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    let label: String
    var body: some View {
        let p = model.pointField(field, key)
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField("x", value: Binding(get: { p.0 }, set: { model.setValue(.point($0, p.1), field: field, of: key) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 58)
            TextField("y", value: Binding(get: { p.1 }, set: { model.setValue(.point(p.0, $0), field: field, of: key) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 58)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

struct MapTextRow: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    let label: String
    var mono = true
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: Binding(get: { model.stringField(field, key) },
                                        set: { model.setValue(.string($0), field: field, of: key) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
        }
    }
}

struct MapNameRow: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    var body: some View {
        TextField("Name", text: Binding(get: { model.document.resource(key.type, key.id)?.name ?? "" },
                                        set: { model.renameResource(key, to: $0) }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, weight: .semibold))
    }
}

/// Picker for an id-valued field. `noneValues` are shown as the "none" label.
struct MapRefPicker: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    let label: String
    let refType: NovaSwiftKit.FourCharCode
    var noneLabel = "None"
    var noneValue = -1
    /// Index into an array field (nil = scalar field).
    var element: Int? = nil

    private func current() -> Int {
        if let e = element { let a = model.arrayField(field, key); return e < a.count ? a[e] : noneValue }
        return model.intField(field, key, default: noneValue)
    }
    private func set(_ v: Int) {
        if let e = element {
            var a = model.arrayField(field, key)
            while a.count <= e { a.append(noneValue) }
            a[e] = v
            model.setArray(a, field: field, of: key)
        } else {
            model.setValue(.int(v), field: field, of: key)
        }
    }

    var body: some View {
        let cur = current()
        let opts = model.entries(refType)
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("", selection: Binding(get: { cur }, set: { set($0) })) {
                Text(noneLabel).tag(noneValue)
                if cur != noneValue, !opts.contains(where: { $0.id == cur }) { Text("#\(cur) (missing)").tag(cur) }
                ForEach(opts, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(maxWidth: 170)
        }
    }
}

/// Checkbox list for a flag-set field, labels from the schema.
struct MapFlagToggles: View {
    @ObservedObject var model: EditorModel
    let key: ResourceKey
    let field: String
    var only: Set<Int>? = nil

    var body: some View {
        let schema = ResourceSchemas.schema(for: key.type)
        let bits = schema?.field(field)?.flagBits ?? []
        let cur = model.intField(field, key)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bits.filter { only == nil || only!.contains($0.mask) }, id: \.mask) { b in
                Toggle(isOn: Binding(get: { cur & b.mask != 0 },
                                     set: { on in model.setValue(.int(on ? cur | b.mask : cur & ~b.mask), field: field, of: key) })) {
                    Text(b.label).font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}
#endif
