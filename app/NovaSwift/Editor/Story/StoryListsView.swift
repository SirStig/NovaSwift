#if os(macOS)
import SwiftUI
import NovaSwiftKit

/// Left region: segmented switch between the bit index and the mission/cron list.
struct StoryLeftPane: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ui.left) {
                ForEach(StoryUIState.Left.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch ui.left {
            case .bits: StoryBitList(model: model, analysis: analysis, ui: ui)
            case .missions: StoryNodeList(model: model, analysis: analysis, ui: ui)
            }
        }
        .background(Color(white: 0.115))
    }
}

func storyStatusColor(_ s: ControlBitIndex.Status) -> Color {
    switch s {
    case .ok: return .green
    case .setNeverTested: return .orange
    case .testedNeverSet, .onlySetByUnreachable: return .red
    }
}

func storyStatusText(_ s: ControlBitIndex.Status) -> String {
    switch s {
    case .ok: return "OK"
    case .setNeverTested: return "Set, never tested"
    case .testedNeverSet: return "Dead gate: tested, never set"
    case .onlySetByUnreachable: return "Dead gate: only set by unreachable missions"
    }
}

// MARK: - Bits

struct StoryBitList: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState
    @State private var freeCount = 3
    @State private var freeRuns: [Int] = []
    @State private var showFree = false

    private var filtered: [StoryBitRow] {
        let q = ui.bitSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return analysis.rows.filter { r in
            switch ui.bitFilter {
            case .all: break
            case .deadGate: if r.status != .testedNeverSet && r.status != .onlySetByUnreachable { return false }
            case .unused: if r.status != .setNeverTested { return false }
            case .touched: if !r.touched { return false }
            }
            if q.isEmpty { return true }
            if String(r.bit).hasPrefix(q.hasPrefix("b") ? String(q.dropFirst()) : q) { return true }
            let n = analysis.note(r.bit)
            return n.name.lowercased().contains(q) || n.note.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Bit number, name or note", text: $ui.bitSearch).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 6))
                Picker("", selection: $ui.bitFilter) {
                    ForEach(BitFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
            }
            .padding(10)
            headerRow
            let rows = filtered
            List(rows, selection: Binding(get: { ui.selectedBit }, set: { if let b = $0 { ui.select(bit: b) } })) { r in
                StoryBitRowView(row: r, note: analysis.note(r.bit))
                    .tag(r.bit)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Text("\(rows.count) of \(analysis.rows.count) bits").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { showFree.toggle() } label: { Label("Find free bits", systemImage: "number.square") }
                    .controlSize(.small)
                    .popover(isPresented: $showFree, arrowEdge: .top) { freeBitsPopover }
            }
            .padding(8)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("BIT").frame(width: 46, alignment: .leading)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "square.and.pencil").frame(width: 26).help("Setters / clearers / togglers")
            Image(systemName: "questionmark.diamond").frame(width: 26).help("Testers")
            Spacer().frame(width: 14)
        }
        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.5)
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private var freeBitsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find free bits").font(.headline)
            Text("Runs of consecutive bits that nothing in the loaded data (base, plug-ins, this document) tests or sets.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper("Consecutive bits: \(freeCount)", value: $freeCount, in: 1...64)
            Button("Search") { freeRuns = analysis.index.freeRuns(count: freeCount, limit: 12) }
                .buttonStyle(.borderedProminent).tint(novaAmber)
            if !freeRuns.isEmpty {
                Divider()
                ForEach(freeRuns, id: \.self) { s in
                    Button {
                        ui.left = .bits; ui.select(bit: s); showFree = false
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle")
                            Text(freeCount == 1 ? "b\(s)" : "b\(s) – b\(s + freeCount - 1)").font(.system(size: 12, design: .monospaced))
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14).frame(width: 260)
    }
}

struct StoryBitRowView: View {
    let row: StoryBitRow
    let note: BitNotes.Note
    var body: some View {
        HStack(spacing: 6) {
            Text("b\(row.bit)").font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 46, alignment: .leading)
            Text(note.name.isEmpty ? "" : note.name).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.setters)").font(.system(size: 11, design: .monospaced)).frame(width: 26)
                .foregroundStyle(row.setters == 0 ? .red.opacity(0.9) : .primary)
            Text("\(row.testers)").font(.system(size: 11, design: .monospaced)).frame(width: 26)
                .foregroundStyle(row.testers == 0 ? .orange : .primary)
            Circle().fill(storyStatusColor(row.status)).frame(width: 7, height: 7).frame(width: 14)
                .help(storyStatusText(row.status))
        }
        .overlay(alignment: .leading) {
            if row.touched { Rectangle().fill(novaAmber).frame(width: 2).offset(x: -8) }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Missions & crons

struct StoryNodeList: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState

    private var filtered: [StoryGraph.Node] {
        let q = ui.nodeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return analysis.graph.nodes.filter { n in
            switch ui.nodeFilter {
            case .all: break
            case .missions: if n.isCron { return false }
            case .crons: if !n.isCron { return false }
            case .touched: if !n.touched { return false }
            case .unreachable: if !n.unreachable { return false }
            case .deadEnd: if !n.deadEnd { return false }
            }
            if let s = ui.storyline, n.storyline != s { return false }
            if q.isEmpty { return true }
            return n.name.lowercased().contains(q) || String(n.key.id) == q
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Name or id", text: $ui.nodeSearch).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Picker("", selection: $ui.nodeFilter) {
                        ForEach(NodeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                    Picker("", selection: $ui.storyline) {
                        Text("All storylines").tag(String?.none)
                        ForEach(analysis.storylines, id: \.self) { Text($0).tag(String?.some($0)) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
            .padding(10)
            let nodes = filtered
            List(nodes, selection: Binding(get: { ui.selectedNode }, set: { if let k = $0 { ui.select(node: k, focus: true) } })) { n in
                HStack(spacing: 6) {
                    Image(systemName: n.isCron ? "clock.arrow.circlepath" : "scroll")
                        .foregroundStyle(n.isCron ? Color.purple.opacity(0.8) : novaAmber.opacity(0.85)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(n.name.isEmpty ? "#\(n.key.id)" : n.name).font(.system(size: 12)).lineLimit(1)
                        Text("#\(n.key.id)" + (n.storyline.map { " · \($0)" } ?? ""))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if n.unreachable { Image(systemName: "lock.slash").foregroundStyle(.red).help("Unreachable: requires a bit nobody can set") }
                    if n.deadEnd { Image(systemName: "arrow.down.to.line").foregroundStyle(.orange).help("Sets bits nothing tests") }
                    if n.touched { Circle().fill(novaAmber).frame(width: 6, height: 6) }
                }
                .tag(n.key)
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            }
            .listStyle(.plain)
            Divider()
            Text("\(nodes.count) of \(analysis.graph.nodes.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
#endif
