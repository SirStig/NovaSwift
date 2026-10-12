#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Right region: bit detail or the selected mission/cron card.
struct StoryRightPane: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState

    var body: some View {
        Group {
            switch ui.inspect {
            case .none:
                EditorEmptyState(icon: "sidebar.right", title: "Nothing selected",
                                 subtitle: "Pick a bit, a mission or a cron to see where it is used and edit it here.")
            case let .bit(b):
                StoryBitDetail(model: model, analysis: analysis, ui: ui, bit: b)
            case let .node(k):
                StoryResourceCard(model: model, analysis: analysis, ui: ui, key: k)
            }
        }
        .background(Color(white: 0.115))
    }
}

struct StorySectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        Label(title.uppercased(), systemImage: icon)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
    }
}

/// "b123" pill; click selects the bit in the index.
struct BitChip: View {
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState
    let bit: Int
    var tint: Color = .secondary
    var negated = false
    var body: some View {
        let name = analysis.note(bit).name
        Button {
            ui.left = .bits; ui.select(bit: bit)
        } label: {
            HStack(spacing: 3) {
                Text((negated ? "!" : "") + "b\(bit)").font(.system(size: 11, weight: .medium, design: .monospaced))
                if !name.isEmpty { Text(name).font(.system(size: 10)).lineLimit(1) }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(name.isEmpty ? "Show bit \(bit)" : "\(name) (bit \(bit))")
    }
}

/// Simple wrapping layout for chips.
struct StoryFlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > b.minX, x + sz.width > b.maxX { x = b.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Bit detail

struct StoryBitDetail: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState
    let bit: Int

    var body: some View {
        let idx = analysis.index
        let status = idx.status(of: bit)
        let note = analysis.note(bit)
        let testers = idx.testers(of: bit), writers = idx.writers(of: bit)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Bit \(bit)").font(.system(size: 20, weight: .semibold, design: .monospaced))
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(storyStatusColor(status)).frame(width: 8, height: 8)
                        Text(storyStatusText(status)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if idx.references(bit: bit).isEmpty {
                    Label("Nothing uses this bit. It is free to allocate.", systemImage: "checkmark.seal")
                        .font(.system(size: 11)).foregroundStyle(.green)
                } else if status == .testedNeverSet {
                    Label("Tested but no resource ever sets it, so everything gated on it can never happen (unless a pilot already has it).",
                          systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
                } else if status == .onlySetByUnreachable {
                    Label("Every setter is a mission or cron that cannot itself become available.",
                          systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
                } else if status == .setNeverTested {
                    Label("Set but never tested. Harmless, or a leftover.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    StorySectionHeader(icon: "tag", title: "Name & notes")
                    TextField("Name (e.g. “Met Vellos”)", text: Binding(get: { note.name },
                        set: { var n = note; n.name = $0; analysis.setNote(bit, n, model: model) }))
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: Binding(get: { note.note },
                        set: { var n = note; n.note = $0; analysis.setNote(bit, n, model: model) }))
                        .font(.system(size: 12)).frame(minHeight: 70, maxHeight: 130)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    Text("Saved in the plug-in as an NSbt resource the original game ignores.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                refSection(title: "Tested by (\(testers.count))", icon: "questionmark.diamond", refs: testers)
                refSection(title: "Set / cleared / toggled by (\(writers.count))", icon: "square.and.pencil", refs: writers)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func refSection(title: String, icon: String, refs: [ControlBitIndex.Reference]) -> some View {
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                StorySectionHeader(icon: icon, title: title)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(refs.sorted { ($0.key.type.rawValue, $0.key.id) < ($1.key.type.rawValue, $1.key.id) }.prefix(300)) { r in
                        RefRow(model: model, analysis: analysis, ui: ui, ref: r)
                    }
                    if refs.count > 300 { Text("… \(refs.count - 300) more").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

struct RefRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState
    let ref: ControlBitIndex.Reference

    private var roleText: String {
        switch ref.role {
        case .test: return ref.negated ? "needs clear" : "needs set"
        case .set: return "sets"
        case .clear: return "clears"
        case .toggle: return "toggles"
        }
    }
    private var roleColor: Color {
        switch ref.role {
        case .test: return .cyan
        case .set: return .green
        case .clear: return .red
        case .toggle: return .purple
        }
    }

    var body: some View {
        let inGraph = analysis.graph.indexByKey[ref.key] != nil
        HStack(spacing: 6) {
            Text(roleText).font(.system(size: 9, weight: .semibold)).foregroundStyle(roleColor)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayName(ref.key.type, ref.key.id)).font(.system(size: 12)).lineLimit(1)
                Text("\(ResourceSchemas.displayName(for: ref.key.type)) #\(ref.key.id) · \(ref.fieldLabel)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if inGraph {
                Button { ui.select(node: ref.key, focus: true) } label: { Image(systemName: "scope") }
                    .help("Select and centre in the graph")
            }
            Button { model.showInResources(ref.key) } label: { Image(systemName: "arrow.up.right.square") }
                .help("Open in Resources")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if inGraph { ui.select(node: ref.key, focus: true) } else { model.showInResources(ref.key) } }
    }
}

// MARK: - Mission / cron card

struct StoryResourceCard: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState
    let key: ResourceKey

    @State private var cache = EditorBrowseCache()
    @StateObject private var hover = EditorHoverState()
    @State private var collapsed: Set<String> = ["Auxiliary Ships", "Requirements", "Buttons", "Flags", "Cargo", "Special Ships", "Payment", "Rewards", "Time & Abort", "Placement"]

    private static let missionOrder = ["Availability", "Scripts", "Descriptions", "Destinations", "Cargo", "Special Ships", "Payment", "Rewards",
                                       "Time & Abort", "Auxiliary Ships", "Requirements", "Buttons", "Flags", "Text"]
    private static let cronOrder = ["Schedule", "Scripts", "News", "Requirements", "Flags"]
    private static let icons: [String: String] = [
        "Availability": "mappin.and.ellipse", "Scripts": "curlybraces", "Descriptions": "text.alignleft",
        "Destinations": "location", "Cargo": "shippingbox", "Special Ships": "airplane", "Payment": "creditcard",
        "Rewards": "rosette", "Time & Abort": "timer", "Auxiliary Ships": "airplane.circle", "Requirements": "checklist",
        "Buttons": "rectangle.and.hand.point.up.left", "Flags": "flag", "Text": "text.quote", "Schedule": "calendar", "News": "newspaper",
    ]
    /// dësc-valued mission fields, in reading order.
    static let descFields: [(key: String, label: String)] = [
        ("briefText", "Briefing (offer & accept dialog)"), ("quickBrief", "Quick brief (I key)"),
        ("loadCargText", "Load cargo"), ("dumpCargoText", "Drop cargo"), ("compText", "Completion"),
        ("failText", "Failure"), ("refuseText", "Refusal"), ("shipDoneText", "Special ship done"),
    ]

    var body: some View {
        let r = model.document.resource(key.type, key.id)
        let isMission = key.type == NovaType.mission
        if let r, let schema = ResourceSchemas.schema(for: key.type) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(r, schema: schema, isMission: isMission)
                    flowSection
                    bitsSection
                    let env = EditorEnv(model: model, cache: cache)
                    let order = isMission ? Self.missionOrder : Self.cronOrder
                    ForEach(order, id: \.self) { g in
                        if g == "Descriptions", isMission {
                            section(g) { descriptions(schema: schema, r: r, env: env) }
                        } else {
                            let hide = isMission ? Set(Self.descFields.map(\.key)) : []
                            let fields = schema.fields(in: g).filter { !hide.contains($0.key) }
                            if !fields.isEmpty {
                                section(g) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        ForEach(fields) { f in
                                            FieldRow(schema: schema, field: f, key: key, data: r.data, env: env, hover: hover, issues: [])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .id(key)
        } else {
            EditorEmptyState(icon: "questionmark.folder", title: "\(key) no longer exists")
        }
    }

    // MARK: Header

    private func header(_ r: Resource, schema: ResourceSchema, isMission: Bool) -> some View {
        let node = analysis.graph.indexByKey[key].map { analysis.graph.nodes[$0] }
        let prov = model.document.provenance(key.type, key.id) ?? .base
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isMission ? "scroll.fill" : "clock.arrow.circlepath").foregroundStyle(novaAmber)
                Text("\(schema.displayName) #\(key.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(prov.badgeText).font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(prov.badgeColor, in: Capsule())
                if let s = node?.storyline {
                    Button { ui.storyline = s; ui.left = .missions } label: { Label(s, systemImage: "books.vertical") }
                        .buttonStyle(.borderless).font(.system(size: 10)).help("Filter to the \(s) storyline")
                }
                Spacer()
            }
            MapNameRow(model: model, key: key)
            HStack {
                if isMission {
                    Button { model.requestMissionTest(key.id) } label: { Label("Test this mission", systemImage: "play.fill").foregroundStyle(.black) }
                        .buttonStyle(.borderedProminent).tint(novaAmber)
                        .help("Start the game where it is offered, force its availability bits and accept it")
                }
                Button { model.showInResources(key) } label: { Label("Open in Resources", systemImage: "arrow.up.right.square") }
                Button { ui.focusKey = key } label: { Label("Show in graph", systemImage: "scope") }
                Spacer()
            }
            .controlSize(.small)
            if node?.unreachable == true {
                Label("Unreachable: its availability needs a bit that no reachable resource sets.", systemImage: "lock.slash")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            if node?.deadEnd == true {
                Label("Dead end: the bits it sets are never tested.", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Flow & bits

    @ViewBuilder private var flowSection: some View {
        if let i = analysis.graph.indexByKey[key] {
            let g = analysis.graph
            let ins = g.incoming[i].map { g.edges[$0] }, outs = g.outgoing[i].map { g.edges[$0] }
            if !ins.isEmpty || !outs.isEmpty {
                section("Flow", icon: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        edgeList("Unlocked by", ins, other: \.from)
                        edgeList("Unlocks", outs, other: \.to)
                    }
                }
            }
        }
    }

    private func edgeList(_ title: String, _ edges: [StoryGraph.Edge], other: KeyPath<StoryGraph.Edge, Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !edges.isEmpty { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
            ForEach(Array(edges.prefix(40).enumerated()), id: \.offset) { _, e in
                let n = analysis.graph.nodes[e[keyPath: other]]
                HStack(spacing: 6) {
                    Button { ui.select(node: n.key, focus: true) } label: {
                        Text(n.name.isEmpty ? "#\(n.key.id)" : n.name).font(.system(size: 12)).lineLimit(1)
                    }.buttonStyle(.link)
                    Spacer()
                    if e.bit >= 0 {
                        BitChip(analysis: analysis, ui: ui, bit: e.bit, tint: e.kind == .disables ? .red : .green)
                    } else {
                        Text("starts").font(.system(size: 10)).foregroundStyle(.cyan)
                    }
                }
            }
            if edges.count > 40 { Text("… \(edges.count - 40) more").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }

    @ViewBuilder private var bitsSection: some View {
        let refs = analysis.index.references(of: key)
        if !refs.isEmpty {
            section("Control bits", icon: "number") {
                VStack(alignment: .leading, spacing: 6) {
                    let tests = refs.filter(\.isTest), writes = refs.filter { !$0.isTest }
                    if !tests.isEmpty {
                        Text("Tests").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        StoryFlowLayout { ForEach(tests) { BitChip(analysis: analysis, ui: ui, bit: $0.bit, tint: .cyan, negated: $0.negated) } }
                    }
                    if !writes.isEmpty {
                        Text("Writes").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        StoryFlowLayout {
                            ForEach(writes) {
                                BitChip(analysis: analysis, ui: ui, bit: $0.bit,
                                        tint: $0.role == .set ? .green : $0.role == .clear ? .red : .purple, negated: $0.role == .clear)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Descriptions

    private func descriptions(schema: ResourceSchema, r: Resource, env: EditorEnv) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.descFields, id: \.key) { d in
                if let f = schema.field(d.key) {
                    let id = model.intField(d.key, key, default: -1)
                    VStack(alignment: .leading, spacing: 5) {
                        FieldRow(schema: schema, field: f, key: key, data: r.data, env: env, hover: hover, issues: [])
                        if id >= 128 || id > 0, model.document.resource(NovaType.desc, id) != nil {
                            StoryDescEditor(model: model, descID: id)
                        } else {
                            Button { createDesc(d.key, label: d.label) } label: { Label("Create description", systemImage: "plus.circle") }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func createDesc(_ fieldKey: String, label: String) {
        let doc = model.document
        let id = doc.nextFreeID(NovaType.desc, from: 4000)
        let base = model.document.resource(key.type, key.id)?.name.split(separator: ";").first.map(String.init) ?? "Mission \(key.id)"
        doc.withGroup("Create mission description") {
            if (try? doc.create(NovaType.desc, id: id, name: "\(base) – \(label)")) != nil {
                model.setValue(.int(id), field: fieldKey, of: key)
            }
        }
    }

    // MARK: Section chrome

    private func section<C: View>(_ title: String, icon: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        let open = !collapsed.contains(title)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { collapsed.insert(title) } else { collapsed.remove(title) }
            } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                    StorySectionHeader(icon: icon ?? Self.icons[title] ?? "square", title: title)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { content().padding(.leading, 4) }
            Divider().opacity(0.5)
        }
    }
}

/// Inline editor for one dësc (text only; use Resources for picture/movie).
struct StoryDescEditor: View {
    @ObservedObject var model: EditorModel
    let descID: Int

    var body: some View {
        let key = ResourceKey(NovaType.desc, descID)
        let rec = DescRecord(model.document.resource(key.type, key.id)?.data ?? Data())
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: Binding(get: { TextResourceCodec.display(rec.text) }, set: { v in
                var r = DescRecord(model.document.resource(key.type, key.id)?.data ?? Data())
                r.text = TextResourceCodec.stored(v)
                model.writeData(r.encode(), for: key, label: "Edit description", coalesce: "desc/\(key)")
            }))
            .font(.system(size: 12)).frame(minHeight: 70, maxHeight: 200)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Text("dësc #\(descID)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                let bits = ControlBitIndex.descBits(in: rec.text)
                if !bits.isEmpty {
                    Text("tests " + bits.map { "b\($0.bit)" }.joined(separator: " ")).font(.system(size: 9)).foregroundStyle(.cyan)
                }
                Spacer()
                Button { model.showInResources(key) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open in Resources (picture, movie, flags)")
            }
        }
    }
}
#endif
