#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

/// Per-(graph, selection, filters) derived flags, memoized so panning never
/// re-evaluates filters. Reference type: mutated from inside `Canvas`.
final class StoryGraphScene {
    struct Key: Equatable {
        var generation: Int; var inspect: StoryInspect; var search: String
        var onlyComponent: Bool; var isolated: Bool; var storyline: String?
    }
    var key: Key?
    var hidden: [Bool] = []
    /// Dimmed (non-matching search / not in selection neighbourhood).
    var dim: [Bool] = []
    var hotEdge: [Bool] = []
    var hotNode: [Bool] = []
    var matches: [Int] = []
    var visibleBounds = CGRect.zero

    func update(_ g: StoryGraph, _ k: Key, bitRefs: (Int) -> Set<ResourceKey>) {
        if key == k { return }
        key = k
        let n = g.nodes.count
        hidden = Array(repeating: false, count: n)
        dim = Array(repeating: false, count: n)
        hotNode = Array(repeating: false, count: n)
        hotEdge = Array(repeating: false, count: g.edges.count)
        var selIdx: Int?
        if case let .node(key) = k.inspect { selIdx = g.indexByKey[key] }
        let comp = selIdx.map { g.nodes[$0].component }
        for (i, node) in g.nodes.enumerated() {
            if node.isolated && !k.isolated { hidden[i] = true }
            if let s = k.storyline, node.storyline != s { hidden[i] = true }
            if k.onlyComponent, let c = comp, node.component != c { hidden[i] = true }
        }
        // Selection neighbourhood.
        switch k.inspect {
        case let .node(key):
            if let s = g.indexByKey[key] {
                hotNode[s] = true
                for ei in g.outgoing[s] { hotEdge[ei] = true; hotNode[g.edges[ei].to] = true }
                for ei in g.incoming[s] { hotEdge[ei] = true; hotNode[g.edges[ei].from] = true }
            }
        case let .bit(b):
            for key in bitRefs(b) { if let i = g.indexByKey[key] { hotNode[i] = true } }
            for (ei, e) in g.edges.enumerated() where e.bit == b { hotEdge[ei] = true; hotNode[e.from] = true; hotNode[e.to] = true }
        case .none: break
        }
        let q = k.search.lowercased()
        matches = []
        if !q.isEmpty {
            for (i, node) in g.nodes.enumerated() where !hidden[i] {
                if node.name.lowercased().contains(q) || String(node.key.id) == q || (node.storyline?.lowercased().contains(q) ?? false) {
                    matches.append(i)
                }
            }
            let m = Set(matches)
            for i in 0..<n where !m.contains(i) { dim[i] = true }
        } else if k.inspect != .none {
            for i in 0..<n where !hotNode[i] { dim[i] = true }
        }
        var r = CGRect.null
        for (i, node) in g.nodes.enumerated() where !hidden[i] {
            r = r.union(CGRect(x: CGFloat(node.x), y: CGFloat(node.y) - 17, width: StoryGraphView.nodeW, height: 34))
        }
        visibleBounds = r
    }
}

struct StoryGraphView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var analysis: StoryAnalysisModel
    @ObservedObject var ui: StoryUIState

    static let nodeW: CGFloat = 176
    static let nodeH: CGFloat = 34

    @State private var scene = StoryGraphScene()
    @State private var size = CGSize(width: 800, height: 600)
    @State private var dragLast: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var govtColors: [Int: Color] = [:]
    @State private var govtRevision = -1
    @State private var fitted = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(white: 0.085)
                Canvas(rendersAsynchronously: false) { ctx, sz in draw(&ctx, sz) }
                MapInputSurface(
                    onDown: { p in dragStart = p.location; dragLast = p.location },
                    onDrag: { p in
                        if let l = dragLast { ui.viewport.pan(byScreen: CGSize(width: p.location.x - l.x, height: p.location.y - l.y)) }
                        dragLast = p.location
                    },
                    onUp: { p in
                        defer { dragLast = nil; dragStart = nil }
                        guard let s = dragStart, hypot(p.location.x - s.x, p.location.y - s.y) < 4 else { return }
                        if let i = nodeAt(p.location) {
                            let k = analysis.graph.nodes[i].key
                            ui.select(node: k)
                            if p.clickCount >= 2 { model.showInResources(k) }
                        } else { ui.inspect = .none }
                    },
                    onScroll: { p, d, precise, mod in
                        if precise && !mod { ui.viewport.pan(byScreen: d) }
                        else { ui.viewport.zoom(by: exp(d.height * (precise ? 0.01 : 0.05)), around: p, size: size, range: 0.03...3) }
                    },
                    onMagnify: { p, m in ui.viewport.zoom(by: 1 + m, around: p, size: size, range: 0.03...3) },
                    onPan: { ui.viewport.pan(byScreen: $0) },
                    onKey: { key in if key == "escape" { ui.inspect = .none; return true }; return false })
                controls
                if !analysis.hasResult {
                    EditorLoadingOverlay(label: "Analysing story\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if analysis.graph.nodes.isEmpty {
                    EditorEmptyState(icon: "point.3.connected.trianglepath.dotted",
                                     title: analysis.isComputing ? "Analysing story\u{2026}" : "No missions or crons",
                                     subtitle: "Edges appear where one mission sets a control bit another mission tests.")
                        .allowsHitTesting(false)
                }
                EditorRefreshStrip(active: analysis.isComputing && analysis.hasResult)
            }
            .onAppear { size = geo.size; fitIfNeeded(force: false) }
            .onChange(of: geo.size) { _, s in size = s }
        }
        .clipped()
        .onChange(of: analysis.generation) { _, _ in fitIfNeeded(force: false) }
        .onChange(of: ui.fitTick) { _, _ in fitIfNeeded(force: true) }
        .onChange(of: ui.focusKey) { _, k in
            guard let k, let i = analysis.graph.indexByKey[k] else { return }
            let n = analysis.graph.nodes[i]
            ui.viewport.center = CGPoint(x: CGFloat(n.x) + Self.nodeW / 2, y: CGFloat(n.y))
            ui.viewport.zoom = max(ui.viewport.zoom, 0.8)
            ui.focusKey = nil
        }
        .onChange(of: ui.colorMode) { _, _ in loadGovtColors() }
        .onChange(of: model.revision) { _, _ in if ui.colorMode == .government { loadGovtColors() } }
    }

    // MARK: Fit

    private func fitIfNeeded(force: Bool) {
        let g = analysis.graph
        guard !g.nodes.isEmpty else { return }
        if !force && fitted >= 0 { return }
        fitted = analysis.generation
        updateScene()
        var r = scene.visibleBounds
        if r.isNull || r.isEmpty { r = CGRect(x: 0, y: 0, width: CGFloat(g.bounds.width), height: CGFloat(g.bounds.height)) }
        let z = min(size.width / max(r.width, 1), size.height / max(r.height, 1)) * 0.94
        ui.viewport.zoom = min(max(z, 0.03), 1.2)
        ui.viewport.center = CGPoint(x: r.midX, y: r.midY)
    }

    private func updateScene() {
        let g = analysis.graph
        let idx = analysis.index
        scene.update(g, .init(generation: analysis.generation, inspect: ui.inspect, search: ui.graphSearch,
                              onlyComponent: ui.onlyComponent, isolated: ui.showIsolated, storyline: ui.storyline),
                     bitRefs: { b in Set(idx.references(bit: b).map(\.key)) })
    }

    /// Government colours are computed off-main (NovaGame + palette) and applied
    /// when ready; nodes show neutral grey until then.
    private func loadGovtColors() {
        guard ui.colorMode == .government, govtRevision != model.revision else { return }
        let rev = model.revision
        govtRevision = rev
        let eff = model.effective
        Task {
            let out = await Task.detached(priority: .userInitiated) { () -> [Int: Color] in
                let game = NovaGame(eff)
                let pal = GovernmentPalette(game: game)
                var out: [Int: Color] = [:]
                for g in game.govts() { out[g.id] = pal.color(for: g.id) }
                return out
            }.value
            if govtRevision == rev { govtColors = out }
        }
    }

    // MARK: Drawing

    private func color(_ n: StoryGraph.Node) -> Color {
        switch ui.colorMode {
        case .storyline:
            guard let s = n.storyline else { return n.isCron ? Color(red: 0.55, green: 0.5, blue: 0.75) : Color(white: 0.5) }
            var h: UInt32 = 5381
            for u in s.unicodeScalars { h = h &* 33 &+ u.value }
            return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.82)
        case .government:
            return n.govt.flatMap { govtColors[$0] } ?? Color(white: 0.5)
        case .plugin:
            return n.touched ? novaAmber : Color(white: 0.42)
        }
    }

    private func shortName(_ n: StoryGraph.Node) -> String {
        var s = n.name
        if let i = s.firstIndex(of: ";") { s = String(s[..<i]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "\(n.isCron ? "cron" : "mission") #\(n.key.id)" }
        return s.count > 25 ? String(s.prefix(24)) + "…" : s
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        updateScene()
        let g = analysis.graph
        let vp = ui.viewport
        let z = vp.zoom
        let tl = vp.toWorld(.zero, sz), br = vp.toWorld(CGPoint(x: sz.width, y: sz.height), sz)
        let view = CGRect(x: tl.x - Self.nodeW, y: tl.y - 40, width: br.x - tl.x + 2 * Self.nodeW, height: br.y - tl.y + 80)
        let selected: Int? = ui.selectedNode.flatMap { g.indexByKey[$0] }
        let anySel = ui.inspect != .none || !ui.graphSearch.isEmpty

        // Edges (culled by their bounding box).
        for (ei, e) in g.edges.enumerated() {
            let a = g.nodes[e.from], b = g.nodes[e.to]
            if scene.hidden[e.from] || scene.hidden[e.to] { continue }
            let hot = scene.hotEdge[ei]
            let p0 = CGPoint(x: CGFloat(a.x) + Self.nodeW, y: CGFloat(a.y))
            let p1 = CGPoint(x: CGFloat(b.x), y: CGFloat(b.y))
            let bb = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            if !bb.intersects(view) && !bb.insetBy(dx: -1, dy: -1).intersects(view) { continue }
            if anySel && !hot && z < 0.35 { continue }
            let s0 = vp.toScreen(p0, sz), s1 = vp.toScreen(p1, sz)
            var path = Path()
            path.move(to: s0)
            let dx = max(40 * z, abs(s1.x - s0.x) * 0.45)
            path.addCurve(to: s1, control1: CGPoint(x: s0.x + dx, y: s0.y), control2: CGPoint(x: s1.x - dx, y: s1.y))
            let base: Color
            switch e.kind {
            case .enables: base = Color(white: 0.55)
            case .disables: base = Color(red: 0.9, green: 0.35, blue: 0.3)
            case .starts: base = Color(red: 0.35, green: 0.75, blue: 0.9)
            }
            let col = hot ? novaAmber : base.opacity(anySel ? 0.12 : (z < 0.25 ? 0.22 : 0.4))
            let style = StrokeStyle(lineWidth: hot ? 2 : 1, dash: e.kind == .disables ? [4, 3] : [])
            ctx.stroke(path, with: .color(col), style: style)
            if hot && z > 0.5 {
                let mid = CGPoint(x: (s0.x + s1.x) / 2, y: (s0.y + s1.y) / 2)
                let label = e.bit >= 0 ? "b\(e.bit)" : "starts"
                ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(novaAmber), at: mid)
            }
        }

        // Nodes.
        for (i, n) in g.nodes.enumerated() {
            if scene.hidden[i] { continue }
            let w = CGRect(x: CGFloat(n.x), y: CGFloat(n.y) - Self.nodeH / 2, width: Self.nodeW, height: Self.nodeH)
            if !w.intersects(view) { continue }
            let s0 = vp.toScreen(w.origin, sz)
            let r = CGRect(x: s0.x, y: s0.y, width: w.width * z, height: w.height * z)
            let dim = scene.dim[i]
            let c = color(n)
            if r.width < 9 {
                ctx.fill(Path(ellipseIn: r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2).insetBy(dx: -1, dy: -1)),
                         with: .color(c.opacity(dim ? 0.2 : 0.95)))
                if i == selected { ctx.stroke(Path(ellipseIn: r.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 1.5) }
                continue
            }
            let radius = n.isCron ? r.height / 2 : 5 * z
            let shape = Path(roundedRect: r, cornerRadius: radius)
            ctx.fill(shape, with: .color(Color(white: dim ? 0.11 : 0.17)))
            ctx.fill(Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: max(3, 5 * z), height: r.height), cornerRadius: radius),
                     with: .color(c.opacity(dim ? 0.25 : 1)))
            var border: Color = Color(white: 0.3)
            var bw: CGFloat = 1
            if n.touched { border = novaAmber; bw = 1.5 }
            if n.unreachable { border = .red; bw = 1.5 }
            if i == selected { border = .white; bw = 2.5 }
            else if scene.hotNode[i] && ui.inspect != .none { border = novaAmber; bw = 2 }
            ctx.stroke(shape, with: .color(border.opacity(dim ? 0.3 : 1)), lineWidth: bw)
            if n.deadEnd && !dim {
                var tri = Path()
                tri.move(to: CGPoint(x: r.maxX - 9 * z, y: r.minY)); tri.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                tri.addLine(to: CGPoint(x: r.maxX, y: r.minY + 9 * z)); tri.closeSubpath()
                ctx.fill(tri, with: .color(.orange))
            }
            if z >= 0.5 {
                ctx.draw(Text(shortName(n)).font(.system(size: 10.5 * min(z, 1.6), weight: .medium))
                    .foregroundColor(.white.opacity(dim ? 0.3 : 0.92)),
                         at: CGPoint(x: r.minX + 9 * z, y: r.midY - (z > 0.9 ? 5 * z : 0)), anchor: .leading)
                if z > 0.9 {
                    ctx.draw(Text("\(n.isCron ? "crön" : "mïsn") #\(n.key.id)").font(.system(size: 8.5 * min(z, 1.6), design: .monospaced))
                        .foregroundColor(.white.opacity(dim ? 0.2 : 0.45)),
                             at: CGPoint(x: r.minX + 9 * z, y: r.midY + 7 * z), anchor: .leading)
                }
            }
        }
    }

    private func nodeAt(_ p: CGPoint) -> Int? {
        let g = analysis.graph
        let w = ui.viewport.toWorld(p, size)
        let pad = max(0, 4 / ui.viewport.zoom)
        for i in g.nodes.indices.reversed() {
            if i < scene.hidden.count, scene.hidden[i] { continue }
            let n = g.nodes[i]
            if w.x >= CGFloat(n.x) - pad, w.x <= CGFloat(n.x) + Self.nodeW + pad,
               w.y >= CGFloat(n.y) - Self.nodeH / 2 - pad, w.y <= CGFloat(n.y) + Self.nodeH / 2 + pad { return i }
        }
        return nil
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Two flexible rows: the graph column can be narrow (side panes take
            // the rest), so nothing here may demand a fixed total width.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find mission…", text: $ui.graphSearch)
                            .textFieldStyle(.plain)
                            .frame(minWidth: 80, maxWidth: .infinity)
                            .onSubmit {
                                updateScene()
                                if let i = scene.matches.first { ui.focusKey = analysis.graph.nodes[i].key; ui.select(node: analysis.graph.nodes[i].key) }
                            }
                        if !ui.graphSearch.isEmpty {
                            Text("\(scene.matches.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Button { ui.graphSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 6))
                    Toggle(isOn: $ui.onlyComponent) { Image(systemName: "circle.hexagongrid") }
                        .toggleStyle(.button).help("Only the selection's connected component")
                    Toggle(isOn: $ui.showIsolated) { Image(systemName: "circle.dotted") }
                        .toggleStyle(.button).help("Show missions with no bit connections")
                    Button { ui.fitTick += 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Fit graph")
                    if analysis.isComputing { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 8) {
                    Picker("", selection: $ui.colorMode) {
                        ForEach(StoryColorMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().help("Colour nodes by")
                    Menu {
                        Button("All storylines") { ui.storyline = nil }
                        Divider()
                        ForEach(analysis.storylines, id: \.self) { s in Button(s) { ui.storyline = s } }
                    } label: { Label(ui.storyline ?? "All storylines", systemImage: "line.3.horizontal.decrease.circle").lineLimit(1) }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: 220, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
            .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.06)))
            HStack(spacing: 10) {
                legend(Color(red: 0.9, green: 0.2, blue: 0.2), "Unreachable")
                legend(.orange, "Dead end")
                legend(novaAmber, "Plug-in")
                let g = analysis.graph
                Text("\(g.nodes.count - g.nodes.filter(\.isolated).count) linked · \(g.edges.count) edges" + (g.hubBits.isEmpty ? "" : " · \(g.hubBits.count) hub bits hidden"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .help("\(g.nodes.count - g.nodes.filter(\.isolated).count) linked · \(g.edges.count) edges · \(g.hubBits.count) hub bits hidden")
            }
            .padding(.horizontal, 10)
        }
        .padding(10)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).stroke(c, lineWidth: 1.5).frame(width: 12, height: 8)
            Text(t).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
#endif
