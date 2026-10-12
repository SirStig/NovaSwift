#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Right column: header (identity, provenance, references), lint issues, then the
/// editor that fits the resource type.
struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var ui: EditorUIState
    @ObservedObject var lint: EditorLintModel
    @StateObject private var hover = EditorHoverState()
    /// The resource whose heavy body (big schema forms) has been allowed to build. A click
    /// first paints the header + skeleton, then the form lands on the next frame.
    @State private var settled: ResourceKey?

    /// Forms past this many fields take noticeable time to build; smaller ones render at once.
    private static let deferThreshold = 45

    var body: some View {
        Group {
            if !model.dataReady {
                SkeletonForm(groups: 4)
            } else if let key = model.selection, let res = model.document.resource(key.type, key.id) {
                content(key, res)
            } else {
                EditorEmptyState(icon: "square.and.pencil", title: "Select a resource",
                                 subtitle: "Choose a resource from the list to edit it,\nor press ⌘N to create one.")
            }
        }
        .background(Color(white: 0.13))
    }

    private static func isDialog(_ t: NovaSwiftKit.FourCharCode) -> Bool { t == NovaType.ditl || t == NovaType.dlog }

    private func isHeavy(_ schema: ResourceSchema?) -> Bool {
        (schema?.fields.count ?? 0) >= Self.deferThreshold
    }

    private func content(_ key: ResourceKey, _ res: Resource) -> some View {
        let env = EditorEnv(model: model, cache: store.cache)
        let kind = ResourceSchemas.editorKind(for: key.type)
        let schema = ResourceSchemas.schema(for: key.type)
        let issues = lint.byResource[key] ?? []
        return VStack(spacing: 0) {
            InspectorHeader(model: model, ui: ui, env: env, key: key, res: res)
                .id(key)
            Divider()
            if ui.rawMode || (kind == .raw && !Self.isDialog(key.type)) {
                HexEditorView(key: key, data: res.data, minimumSize: schema?.minimumSize ?? 0, model: model)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if isHeavy(schema) && settled != key {
                                SkeletonForm(groups: 4)
                                    .task(id: key) {
                                        // One frame for the click to register, then build the big form.
                                        await Task.yield()
                                        if !Task.isCancelled { settled = key }
                                    }
                            } else {
                                if !issues.isEmpty { IssueBox(issues: issues, onSelect: { _ in }) }
                                if model.document.provenance(key.type, key.id) == .override {
                                    OverrideDiffPanel(model: model, key: key).id(key)
                                }
                                SpecializedInspectorRouter(model: model, env: env, key: key) {
                                    editor(kind, key, res, schema, env, issues)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: ui.focusField) { _, f in
                        guard let f else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo("field-\(f)", anchor: .center) }
                            ui.focusField = nil
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editor(_ kind: EditorKind, _ key: ResourceKey, _ res: Resource, _ schema: ResourceSchema?,
                        _ env: EditorEnv, _ issues: [LintIssue]) -> some View {
        switch kind {
        case .form:
            if let schema {
                let padded = schema.padded(res.data)
                FormInspector(schema: schema, key: key, data: padded, env: env, hover: hover, issues: issues)
                BytesPanel(data: padded, minimumSize: schema.minimumSize, hover: hover)
            }
        case .text:
            if key.type == NovaType.strList { StringListEditor(key: key, data: res.data, model: model) }
            else if key.type == NovaType.desc { DescEditor(key: key, data: res.data, env: env, model: model) }
            else if key.type == GraphicsEnhancementType.descriptor { RawTextEditor(key: key, data: res.data, model: model) }
            else { SingleStringEditor(key: key, data: res.data, model: model) }
        case .graphic:
            if key.type == NovaType.rleD || key.type == NovaType.rle8 || key.type == NovaType.pict || key.type == NovaType.cicn {
                GraphicEditor(key: key, data: res.data, model: model)
            } else if key.type == NovaType.ppat || key.type == NovaType.ppatAlt {
                PixPatPreview(key: key, data: res.data, model: model)
            } else {
                EditorEmptyState(icon: "photo", title: "No preview for \(key.type.stringValue)", subtitle: "Switch to Raw to edit the bytes.")
                    .frame(minHeight: 200)
            }
        case .sound:
            SoundEditor(key: key, data: res.data, model: model)
        case .raw:
            if Self.isDialog(key.type) { DialogPreviewEditor(model: model, key: key) }
        }
    }
}

struct InspectorHeader: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ui: EditorUIState
    let env: EditorEnv
    let key: ResourceKey
    let res: Resource
    @State private var name = ""
    @State private var showRefs = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let prov = model.document.provenance(key.type, key.id) ?? .base
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(ResourceSchemas.displayName(for: key.type)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("#\(key.id)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                ProvenanceBadge(provenance: prov)
                Spacer()
                if prov == .override {
                    Button { model.document.revertToBase(key.type, key.id) } label: {
                        Label("Revert to Base", systemImage: "arrow.uturn.backward")
                    }.controlSize(.small)
                }
                refsButton
                Toggle(isOn: $ui.rawMode) { Label("Raw", systemImage: "number") }
                    .toggleStyle(.button).controlSize(.small).help("Edit raw bytes")
                Menu {
                    Button("Duplicate") { EditorActions.duplicate(model, key) }
                    if prov.isOwn {
                        Button("Renumber…") { ui.renumberTarget = key }
                        Button("Delete", role: .destructive) { EditorActions.delete(model, key) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .focused($nameFocused)
                .onChange(of: name) { _, v in if nameFocused { model.rename(key, to: v) } }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear { name = res.name }
        .onChange(of: res.name) { _, v in if !nameFocused { name = v } }
    }

    @ViewBuilder private var refsButton: some View {
        if model.referencesReady {
            // The graph is built off-main once per document and patched per edit, so this is a lookup.
            let refs = model.document.references
            let uses = refs.uses(key), usedBy = refs.usedBy(key)
            Button { showRefs = true } label: {
                Label("\(uses.count) · \(usedBy.count)", systemImage: "link")
            }
            .controlSize(.small)
            .help("References: \(uses.count) used by this resource · used by \(usedBy.count)")
            .popover(isPresented: $showRefs, arrowEdge: .bottom) { RefsPopover(env: env, uses: uses, usedBy: usedBy) { showRefs = false } }
            .onChange(of: ui.refsTick) { _, _ in showRefs = true }
        } else {
            // Still indexing references in the background.
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("links").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Indexing references…")
        }
    }
}

struct RefsPopover: View {
    let env: EditorEnv
    let uses: [ResourceReference]
    let usedBy: [ResourceReference]
    var dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section("Uses", uses, outgoing: true)
                section("Used by", usedBy, outgoing: false)
            }.padding(12)
        }
        .frame(width: 360, height: 320)
    }

    @ViewBuilder private func section(_ title: String, _ list: [ResourceReference], outgoing: Bool) -> some View {
        Text("\(title) (\(list.count))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        if list.isEmpty { Text("None").font(.system(size: 12)).foregroundStyle(.tertiary) }
        ForEach(Array(list.enumerated()), id: \.offset) { _, r in
            let other = outgoing ? r.target : r.source
            let exists = env.exists(other.type, other.id)
            Button {
                if exists { env.model.navigate(to: other); dismiss() }
            } label: {
                HStack {
                    Text(other.type.stringValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text(env.label(other.type, other.id)).lineLimit(1).foregroundStyle(exists ? Color.primary : Color.red)
                    Spacer()
                    Text(r.fieldKey + (r.kind == .implicit ? " (implicit)" : "")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct IssueBox: View {
    let issues: [LintIssue]
    var onSelect: (LintIssue) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issues) { i in
                Label(i.message, systemImage: icon(i.severity))
                    .font(.system(size: 11)).foregroundStyle(color(i.severity))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.25)))
    }
    private func icon(_ s: LintIssue.Severity) -> String {
        switch s { case .error: return "xmark.octagon.fill"; case .warning: return "exclamationmark.triangle.fill"; case .info: return "info.circle.fill" }
    }
    private func color(_ s: LintIssue.Severity) -> Color {
        switch s { case .error: return .red; case .warning: return .orange; case .info: return .secondary }
    }
}
#endif
