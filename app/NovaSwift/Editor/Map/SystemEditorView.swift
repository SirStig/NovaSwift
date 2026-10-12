#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

struct StellarRec: Identifiable {
    let id: Int
    var name: String
    var x: Int
    var y: Int
    var type: Int
    var govt: Int
    var slot: Int
    var provenance: Provenance
    /// Frame-animation fields of the spöb (nil = still).
    var anim: StellarAnimParams? = nil
    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct SystemExit: Identifiable {
    let id: Int
    var name: String
    var dx: CGFloat
    var dy: CGFloat
}

/// Star System editor: 2D layout of one system's stellars with their real
/// sprites, an inspector for the selected stellar and the system itself, and
/// an optional embedded live game preview that re-renders as you edit.
struct SystemEditorView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var sprites = StellarSpriteCache()
    @StateObject private var preview = EditorPreviewModel()
    @EnvironmentObject private var app: AppModel
    /// Steps animated stellars' frames while the layout canvas is on screen (not observable:
    /// the TimelineView below redraws the canvas).
    @State private var clock = StellarAnimationClock()

    enum Mode: String, CaseIterable { case layout = "Layout", split = "Split", preview = "Preview" }
    enum InspectorTab: String, CaseIterable { case stellar = "Stellar", system = "System" }

    @State private var mode: Mode = .split
    @State private var tab: InspectorTab = .system
    @State private var vp = MapViewport(center: .zero, zoom: 0.25)
    @State private var size = CGSize(width: 600, height: 400)
    @State private var stellars: [StellarRec] = []
    @State private var exits: [SystemExit] = []
    @State private var drag: Drag = .none
    @State private var liveDelta = CGSize.zero
    /// Held by @State (not observed) so hover only redraws the hover layer + readout.
    @State private var hover = MapHoverState()
    @State private var snap = false
    @State private var showRings = true
    @State private var showGrid = true
    @State private var spaceHeld = false
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var lastFit: Int?
    /// System the live preview was last framed for (re-framed only on a switch).
    @State private var previewSystem: Int?
    @State private var derivedRevision = -1
    @State private var derivedSystem: Int?

    private enum Drag {
        case none
        case pan(last: CGPoint)
        case move(id: Int, startWorld: CGPoint, orig: CGPoint)
    }

    private var isDraggingStellar: Bool {
        if case .move = drag { return true }
        return false
    }

    private var systemID: Int? { model.focusedSystemID }
    private var systemKey: ResourceKey? { systemID.map { ResourceKey(NovaType.syst, $0) } }
    private var selectedStellar: StellarRec? {
        guard let k = model.selection, k.type == NovaType.spob else { return nil }
        return stellars.first { $0.id == k.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if systemID == nil || systemKey.flatMap({ model.document.resource($0.type, $0.id) }) == nil {
                emptyState
            } else {
                HStack(spacing: 0) {
                    centre
                    Divider()
                    inspector.frame(width: 310)
                }
            }
        }
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
        .tint(novaAmber)
        .onAppear {
            // First frame: layout from the document (≤16 stellars, cheap). The live
            // preview is requested one tick later so the tool switch paints first.
            sprites.bindHD(app: app, base: model.base)
            refreshDerived(); fitIfNeeded()
            Task { @MainActor in
                await Task.yield()
                schedulePreview()
            }
        }
        .onChange(of: model.revision) { _, _ in
            if model.lastChanged.contains(where: { StellarSpriteCache.relevant.contains($0.type) }) { sprites.invalidate() }
            refreshDerived(); schedulePreview()
        }
        .onChange(of: model.focusedSystemID) { _, _ in refreshDerived(force: true); schedulePreview(); fitIfNeeded(force: true) }
        .onChange(of: mode) { _, m in if m != .layout { schedulePreview() } else { preview.teardown() } }
        .onChange(of: model.selection) { _, k in
            if k?.type == NovaType.spob, stellars.contains(where: { $0.id == k?.id }) { tab = .stellar; centrePreview() }
        }
        .onChange(of: preview.status) { _, s in if s == .ready { centrePreview() } }
        .onDisappear { preview.teardown(); sprites.teardown() }
    }

    // MARK: Derived data

    private func refreshDerived(force: Bool = false) {
        guard let sid = systemID else { stellars = []; exits = []; return }
        // Skip when the last single edit touched neither systems nor stellars
        // (typing in an unrelated field shouldn't re-read the layout).
        let rev = model.revision
        if !force, derivedSystem == sid, rev == derivedRevision + 1,
           model.lastChanged.allSatisfy({ $0.type != NovaType.syst && $0.type != NovaType.spob }) {
            derivedRevision = rev
            return
        }
        derivedRevision = rev; derivedSystem = sid
        let doc = model.document
        let ids = SystemLinkEditing.stellars(of: doc, sid)
        stellars = ids.enumerated().compactMap { i, id in
            guard let r = doc.resource(NovaType.spob, id) else { return nil }
            let key = ResourceKey(NovaType.spob, id)
            let p = model.pointField("position", key)
            return StellarRec(id: id, name: r.name.isEmpty ? "Stellar #\(id)" : r.name, x: p.0, y: p.1,
                              type: model.intField("type", key, default: -1), govt: model.intField("govt", key, default: -1),
                              slot: i + 1, provenance: doc.provenance(NovaType.spob, id) ?? .base,
                              anim: StellarAnimParams(r))
        }
        // Direct sÿst decodes for this system and its ≤16 neighbours; no NovaGame needed.
        guard let meRes = doc.resource(NovaType.syst, sid) else { exits = []; return }
        let me = SystRes(meRes)
        exits = me.links.compactMap { l in
            guard let r = doc.resource(NovaType.syst, l) else { return nil }
            let o = SystRes(r)
            return SystemExit(id: l, name: o.name, dx: CGFloat(o.x - me.x), dy: CGFloat(o.y - me.y))
        }
    }

    private func schedulePreview() {
        guard mode != .layout, let sid = systemID, model.document.resource(NovaType.syst, sid) != nil else { return }
        let firstLook = previewSystem != sid
        previewSystem = sid
        preview.update(collection: model.effective, systemID: sid, base: model.base)
        // A new system opens framed on its centre, zoomed out enough to show
        // the inner stellars (1× is the in-flight view — mostly empty space).
        if firstLook {
            preview.zoom = 3
            preview.resetCamera()
        }
    }

    private func centrePreview() {
        if let s = selectedStellar { preview.center(onSystemX: Double(s.x), y: Double(s.y)) }
    }

    private func fitIfNeeded(force: Bool = false) {
        guard let sid = systemID, force || lastFit != sid else { return }
        lastFit = sid
        fit()
    }

    private func fit() {
        guard size.width > 20, size.height > 20 else { return }
        var pts = stellars.map(\.point)
        pts.append(.zero)
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = max(400, maxX - minX + 300), h = max(400, maxY - minY + 300)
        vp = MapViewport(center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                         zoom: min(size.width / w, size.height / h))
    }

    private func flash(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toast = nil } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(novaAmber)
            MapSearchPicker(items: {
                model.entries(NovaType.syst)
            }, onPick: { model.focusedSystemID = $0 }) {
                HStack(spacing: 4) {
                    Text(systemID.map { model.displayName(NovaType.syst, $0) } ?? "Choose a system\u{2026}")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            if let sid = systemID {
                Text("#\(sid)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button { model.tool = .galaxy } label: { Image(systemName: "map") }.help("Show on the galaxy map")
            }
            Spacer()
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(novaAmber)
            Text("Pick a star system to edit").font(.headline)
            Text("Choose one above, or double-click a system on the galaxy map.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Galaxy Map") { model.tool = .galaxy }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Centre

    @ViewBuilder private var centre: some View {
        switch mode {
        case .layout: layoutPane
        case .preview: previewPane
        case .split:
            VSplitView {
                layoutPane.frame(minHeight: 180)
                previewPane.frame(minHeight: 160)
            }
        }
    }

    private var previewPane: some View {
        EditorLivePreviewView(model: preview)
            .overlay(alignment: .topLeading) {
                Text("LIVE PREVIEW").font(.system(size: 9, weight: .bold)).foregroundStyle(novaAmber.opacity(0.8))
                    .padding(6)
            }
    }

    private var layoutPane: some View {
        ZStack {
            // Modest 12 fps clock, paused unless an animated stellar is actually on screen.
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !needsAnimationClock)) { tl in
                Canvas(rendersAsynchronously: false) { ctx, sz in draw(&ctx, sz, date: tl.date) }
            }
                .background(Color(white: 0.04))
                .background(GeometryReader { g in
                    Color.clear.onAppear { size = g.size; fitIfNeeded() }.onChange(of: g.size) { _, s in size = s }
                })
            StellarHoverLayer(hover: hover, stellars: stellars, vp: vp, suppressed: isDraggingStellar,
                              extent: { halfExtent($0) })
            MapInputSurface(
                onDown: { down($0) }, onDrag: { dragged($0) }, onUp: { up($0) },
                onMove: { moved($0) },
                onScroll: { p, d, precise, mod in
                    if precise && !mod { vp.pan(byScreen: d) }
                    else { vp.zoom(by: exp(d.height * (precise ? 0.01 : 0.05)), around: p, size: size, range: 0.02...4) }
                },
                onMagnify: { p, m in vp.zoom(by: 1 + m, around: p, size: size, range: 0.02...4) },
                onPan: { vp.pan(byScreen: $0) },
                onSpace: { spaceHeld = $0 },
                onKey: { key in
                    if key == "delete", let s = selectedStellar { removeFromSystem(s.id); return true }
                    return false
                },
                menu: { contextItems(at: $0) },
                cursor: spaceHeld ? .openHand : nil)
            VStack {
                HStack {
                    palette
                    Spacer()
                }
                .padding(10)
                Spacer()
                statusLine
            }
        }
        .clipped()
    }

    private var palette: some View {
        MapPalette {
            HStack(spacing: 2) {
                MapToolButton(symbol: "plus.circle", label: "New stellar at view centre", active: false) { createStellar(at: vp.center) }
                MapSearchPicker(items: { addableStellars() }, onPick: { addExisting($0) }) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 13))
                        .frame(width: 28, height: 26).foregroundStyle(.white.opacity(0.85))
                }
                .help("Add an existing stellar to this system")
                Divider().frame(height: 18)
                MapToolButton(symbol: "grid", label: "Snap to grid (10 units)", active: snap) { snap.toggle() }
                MapToolButton(symbol: "number", label: "Grid lines", active: showGrid) { showGrid.toggle() }
                MapToolButton(symbol: "circle.dashed", label: "Distance rings", active: showRings) { showRings.toggle() }
                MapToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", label: "Fit system", active: false) { fit() }
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 14) {
            MapCursorReadout(hover: hover, vp: vp, size: size, showRadius: true)
            Text(String(format: "zoom %.0f%%", vp.zoom * 100)).font(.system(size: 10, design: .monospaced))
            Text("\(stellars.count)/\(SystemLinkEditing.maxStellars) stellars").font(.system(size: 10))
            if let s = selectedStellar { Text("selected: \(s.name)").font(.system(size: 10)).foregroundStyle(novaAmber) }
            if let t = toast { Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(novaAmber).lineLimit(1) }
            Spacer()
            Text("Drag a stellar to move \u{2022} space+drag: pan \u{2022} scroll: zoom").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.8))
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let sid = systemID {
                        if tab == .stellar {
                            if let s = selectedStellar {
                                DeferredContent {
                                    StellarInspector(model: model, sprites: sprites, systemID: sid, stellar: s,
                                                     onRemove: { removeFromSystem($0) }, onDelete: { deleteStellar($0) },
                                                     onDuplicate: { duplicateStellar($0) })
                                } placeholder: { SkeletonForm(groups: 4) }
                                .id(s.id)
                            } else {
                                stellarList(sid)
                            }
                        } else {
                            // The panel builds dozens of pickers; show a skeleton for the
                            // first frame so opening the tool / tab is instant.
                            DeferredContent {
                                SystemPanel(model: model, systemID: sid, onSelectStellar: { id in
                                    model.selection = ResourceKey(NovaType.spob, id); tab = .stellar
                                })
                            } placeholder: { SkeletonForm(groups: 4) }
                            .id(sid)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(white: 0.105))
    }

    private func stellarList(_ sid: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STELLARS").font(.system(size: 10, weight: .semibold)).foregroundStyle(novaAmber)
            if stellars.isEmpty { Text("This system has no stellars.").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(stellars) { s in
                Button { model.selection = ResourceKey(NovaType.spob, s.id) } label: {
                    HStack {
                        Text("\(s.slot)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 18)
                        Text(s.name).font(.system(size: 12))
                        Spacer()
                        Text("(\(s.x), \(s.y))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack {
                Button { createStellar(at: vp.center) } label: { Label("New Stellar", systemImage: "plus") }
                MapSearchPicker(items: { addableStellars() }, onPick: { addExisting($0) }) {
                    Label("Add Existing\u{2026}", systemImage: "square.and.arrow.down.on.square")
                }
            }
            .font(.system(size: 11))
        }
    }

    // MARK: Actions

    private func addableStellars() -> [(id: Int, name: String)] {
        let here = Set(stellars.map(\.id))
        return model.entries(NovaType.spob).filter { !here.contains($0.id) }
    }

    private func addExisting(_ spob: Int) {
        guard let sid = systemID else { return }
        if SystemLinkEditing.addStellar(model.document, system: sid, spob: spob) {
            model.selection = ResourceKey(NovaType.spob, spob)
        } else { flash("No free nav slot (max \(SystemLinkEditing.maxStellars) stellars)") }
    }

    private func createStellar(at w: CGPoint) {
        guard let sid = systemID else { return }
        guard stellars.count < SystemLinkEditing.maxStellars else { flash("This system already has 16 stellars"); return }
        let doc = model.document
        var made: Int?
        doc.withGroup("New stellar") {
            guard let id = try? doc.create(NovaType.spob, name: "New Planet") else { return }
            let key = ResourceKey(NovaType.spob, id)
            let p = snap ? CGPoint(x: (w.x / 10).rounded() * 10, y: (w.y / 10).rounded() * 10) : CGPoint(x: w.x.rounded(), y: w.y.rounded())
            model.setValue(.point(Int(p.x), Int(p.y)), field: "position", of: key)
            model.setValue(.int(0), field: "type", of: key)
            model.setValue(.int(0x1), field: "flags", of: key)
            _ = SystemLinkEditing.addStellar(doc, system: sid, spob: id)
            made = id
        }
        if let id = made { model.selection = ResourceKey(NovaType.spob, id); flash("Created stellar #\(id)") }
        else { flash("No free spöb id") }
    }

    private func removeFromSystem(_ id: Int) {
        guard let sid = systemID else { return }
        SystemLinkEditing.removeStellar(model.document, system: sid, spob: id)
        if model.selection?.id == id { model.selection = nil }
    }

    private func deleteStellar(_ id: Int) {
        guard let sid = systemID else { return }
        let doc = model.document
        switch doc.provenance(NovaType.spob, id) {
        case .new:
            doc.withGroup("Delete stellar") {
                SystemLinkEditing.removeStellar(doc, system: sid, spob: id)
                doc.remove(NovaType.spob, id)
            }
            model.selection = nil
        case .override:
            doc.revertToBase(NovaType.spob, id)
        default:
            flash("Base-game stellars can't be deleted by a plug-in; remove it from this system instead.")
        }
    }

    private func duplicateStellar(_ id: Int) {
        guard let sid = systemID, stellars.count < SystemLinkEditing.maxStellars else { flash("No free nav slot"); return }
        let doc = model.document
        doc.withGroup("Duplicate stellar") {
            guard let new = try? doc.duplicate(NovaType.spob, id) else { return }
            let key = ResourceKey(NovaType.spob, new)
            let p = model.pointField("position", key)
            model.setValue(.point(p.0 + 80, p.1 + 80), field: "position", of: key)
            _ = SystemLinkEditing.addStellar(doc, system: sid, spob: new)
            model.selection = key
        }
    }

    private func contextItems(at p: CGPoint) -> [MapMenuItem] {
        let w = vp.toWorld(p, size)
        if let id = stellarAt(p) {
            model.selection = ResourceKey(NovaType.spob, id)
            return [
                MapMenuItem(title: "Center Preview Here", symbol: "scope", action: { centrePreview() }),
                MapMenuItem(title: "Show in Resources", symbol: "list.bullet.rectangle", action: { model.showInResources(ResourceKey(NovaType.spob, id)) }),
                MapMenuItem(title: "Duplicate", symbol: "plus.square.on.square", action: { duplicateStellar(id) }),
                .separator,
                MapMenuItem(title: "Remove from System", symbol: "minus.circle", destructive: true, action: { removeFromSystem(id) }),
            ]
        }
        return [
            MapMenuItem(title: "New Stellar Here", symbol: "plus.circle", action: { createStellar(at: w) }),
            MapMenuItem(title: "Fit System", symbol: "arrow.up.left.and.down.right.magnifyingglass", action: { fit() }),
        ]
    }

    // MARK: Input

    private func halfExtent(_ s: StellarRec) -> CGFloat {
        if let e = sprites.entry(type: s.type, collection: model.effective) { return max(e.size.width, e.size.height) / 2 }
        return 24
    }

    private func stellarAt(_ p: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for s in stellars {
            var w = s.point
            if case let .move(id, _, _) = drag, id == s.id { w.x += liveDelta.width; w.y += liveDelta.height }
            let sp = vp.toScreen(w, size)
            let r = max(halfExtent(s) * vp.zoom, 12)
            let d = hypot(sp.x - p.x, sp.y - p.y)
            if d <= r, d < (best?.1 ?? .infinity) { best = (s.id, d) }
        }
        return best?.0
    }

    private func down(_ e: MapPointer) {
        let p = e.location
        if spaceHeld { drag = .pan(last: p); return }
        if let id = stellarAt(p), let s = stellars.first(where: { $0.id == id }) {
            model.selection = ResourceKey(NovaType.spob, id)
            tab = .stellar
            liveDelta = .zero
            drag = .move(id: id, startWorld: vp.toWorld(p, size), orig: s.point)
        } else {
            drag = .pan(last: p)
        }
    }

    private func dragged(_ e: MapPointer) {
        let p = e.location
        hover.screen = p
        switch drag {
        case .none: break
        case let .pan(last):
            vp.pan(byScreen: CGSize(width: p.x - last.x, height: p.y - last.y)); drag = .pan(last: p)
        case let .move(_, startWorld, orig):
            let w = vp.toWorld(p, size)
            var nx = orig.x + (w.x - startWorld.x), ny = orig.y + (w.y - startWorld.y)
            if snap { nx = (nx / 10).rounded() * 10; ny = (ny / 10).rounded() * 10 } else { nx = nx.rounded(); ny = ny.rounded() }
            liveDelta = CGSize(width: nx - orig.x, height: ny - orig.y)
        }
    }

    private func up(_ e: MapPointer) {
        defer { drag = .none; liveDelta = .zero }
        if case let .move(id, _, orig) = drag, abs(liveDelta.width) >= 1 || abs(liveDelta.height) >= 1 {
            let nx = Int(max(-32768, min(32767, orig.x + liveDelta.width)))
            let ny = Int(max(-32768, min(32767, orig.y + liveDelta.height)))
            model.document.withGroup("Move stellar") {
                _ = model.setValue(.point(nx, ny), field: "position", of: ResourceKey(NovaType.spob, id))
            }
        }
    }

    private func moved(_ p: CGPoint) {
        hover.screen = p
        let h = stellarAt(p)
        if h != hover.system { hover.system = h }
    }

    // MARK: Drawing

    private func niceStep(_ target: CGFloat) -> CGFloat {
        let steps: [CGFloat] = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
        return steps.first { $0 >= target } ?? 10000
    }

    /// A stellar's centre is inside the canvas (plus a margin for its sprite).
    private func isVisible(_ s: StellarRec, margin: CGFloat = 80) -> Bool {
        let p = vp.toScreen(s.point, size)
        return p.x > -margin && p.y > -margin && p.x < size.width + margin && p.y < size.height + margin
    }

    /// Whether the animation clock needs to run: some visible stellar has a multi-frame
    /// sheet and an authored animation (looked up without starting decodes).
    private var needsAnimationClock: Bool {
        mode != .preview && stellars.contains { s in
            s.anim != nil && (sprites.peek(type: s.type)?.isAnimatable ?? false) && isVisible(s)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize, date: Date) {
        _ = sprites.version
        clock.advance(to: date)
        let o = vp.toScreen(.zero, sz)
        let tl = vp.toWorld(.zero, sz), br = vp.toWorld(CGPoint(x: sz.width, y: sz.height), sz)

        if showGrid {
            let step = niceStep(70 / vp.zoom)
            var g = Path()
            var x = (tl.x / step).rounded(.down) * step
            while x <= br.x { let sx = vp.toScreen(CGPoint(x: x, y: 0), sz).x; g.move(to: CGPoint(x: sx, y: 0)); g.addLine(to: CGPoint(x: sx, y: sz.height)); x += step }
            var y = (tl.y / step).rounded(.down) * step
            while y <= br.y { let sy = vp.toScreen(CGPoint(x: 0, y: y), sz).y; g.move(to: CGPoint(x: 0, y: sy)); g.addLine(to: CGPoint(x: sz.width, y: sy)); y += step }
            ctx.stroke(g, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
        }
        // Axes.
        var ax = Path()
        ax.move(to: CGPoint(x: 0, y: o.y)); ax.addLine(to: CGPoint(x: sz.width, y: o.y))
        ax.move(to: CGPoint(x: o.x, y: 0)); ax.addLine(to: CGPoint(x: o.x, y: sz.height))
        ctx.stroke(ax, with: .color(.white.opacity(0.12)), lineWidth: 1)

        if showRings {
            let step = niceStep(130 / vp.zoom)
            let maxR = hypot(max(abs(tl.x), abs(br.x)), max(abs(tl.y), abs(br.y)))
            var r = step, n = 0
            while r <= maxR, n < 40 {
                let sr = r * vp.zoom
                ctx.stroke(Path(ellipseIn: CGRect(x: o.x - sr, y: o.y - sr, width: sr * 2, height: sr * 2)),
                           with: .color(novaAmber.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                ctx.draw(Text("\(Int(r))").font(.system(size: 9, design: .monospaced)).foregroundColor(novaAmber.opacity(0.45)),
                         at: CGPoint(x: o.x + sr + 3, y: o.y - 7), anchor: .leading)
                r += step; n += 1
            }
        }
        // System centre (the star / jump origin).
        ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(.yellow.opacity(0.7)))

        // Hyperlink exits.
        // Exits sit on the canvas border along the ray from the system centre,
        // so they never land among the stellars when zoomed out.
        let inset = CGRect(origin: .zero, size: sz).insetBy(dx: 46, dy: 38)
        let c0 = vp.toScreen(.zero, sz)
        let origin = CGPoint(x: min(max(c0.x, inset.minX), inset.maxX), y: min(max(c0.y, inset.minY), inset.maxY))
        var placedLabels: [CGRect] = []
        for e in exits {
            let len = max(1, hypot(e.dx, e.dy))
            let dir = CGPoint(x: e.dx / len, y: e.dy / len)
            let tx = dir.x > 0 ? (inset.maxX - origin.x) / dir.x : dir.x < 0 ? (inset.minX - origin.x) / dir.x : .infinity
            let ty = dir.y > 0 ? (inset.maxY - origin.y) / dir.y : dir.y < 0 ? (inset.minY - origin.y) / dir.y : .infinity
            let t = max(0, min(tx, ty))
            let p = CGPoint(x: origin.x + dir.x * t, y: origin.y + dir.y * t)
            let ang = atan2(dir.y, dir.x)
            var arrow = Path()
            arrow.move(to: CGPoint(x: p.x + cos(ang) * 11, y: p.y + sin(ang) * 11))
            arrow.addLine(to: CGPoint(x: p.x + cos(ang + 2.5) * 9, y: p.y + sin(ang + 2.5) * 9))
            arrow.addLine(to: CGPoint(x: p.x + cos(ang - 2.5) * 9, y: p.y + sin(ang - 2.5) * 9))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(.cyan.opacity(0.75)))
            let lp = CGPoint(x: p.x - cos(ang) * 14, y: p.y - sin(ang) * 14 + (sin(ang) > 0 ? -10 : 10))
            let lw = CGFloat(e.name.count) * 5.6 + 6
            let box = CGRect(x: lp.x - lw / 2, y: lp.y - 7, width: lw, height: 14)
            if !placedLabels.contains(where: { $0.intersects(box) }) {
                placedLabels.append(box)
                ctx.draw(Text(e.name).font(.system(size: 10)).foregroundColor(.cyan.opacity(0.85)), at: lp, anchor: .center)
            }
        }

        // Stellars.
        for s in stellars {
            var w = s.point
            var dragging = false
            if case let .move(id, _, _) = drag, id == s.id { w.x += liveDelta.width; w.y += liveDelta.height; dragging = true }
            let p = vp.toScreen(w, sz)
            let entry = sprites.entry(type: s.type, collection: model.effective)
            let selected = model.selection == ResourceKey(NovaType.spob, s.id)
            var half: CGFloat = 14
            if let e = entry {
                // At least 28 pt on screen: the fit for a system with a far-out
                // wormhole is ~5%, which would shrink planets to specks.
                let scale = max(vp.zoom, 28 / max(1, max(e.size.width, e.size.height)))
                let r = CGRect(x: p.x - e.size.width * scale / 2, y: p.y - e.size.height * scale / 2,
                               width: e.size.width * scale, height: e.size.height * scale)
                var shown = e.image
                if let anim = s.anim, e.isAnimatable, isVisible(s) {
                    let f = clock.frame(spob: s.id, params: anim, frameCount: e.frames.count)
                    shown = e.frames[f]
                }
                ctx.draw(ctx.resolve(Image(decorative: shown, scale: 1)), in: r)
                half = max(r.width, r.height) / 2
            } else {
                // Sprite still decoding (or none for this type): government-coloured disc.
                let tint = GalaxyMapData.shared.color(s.govt)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)), with: .color(tint.opacity(0.35)))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)),
                           with: .color(tint), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(tint))
            }
            if selected || dragging {
                let rr = max(half, 10) + 4
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(novaAmber), lineWidth: selected ? 2 : 1)
            }
            switch s.provenance {
            case .new: ctx.fill(Path(ellipseIn: CGRect(x: p.x + max(half, 8) * 0.7, y: p.y - max(half, 8) - 2, width: 6, height: 6)), with: .color(.green))
            case .override: ctx.fill(Path(ellipseIn: CGRect(x: p.x + max(half, 8) * 0.7, y: p.y - max(half, 8) - 2, width: 6, height: 6)), with: .color(.orange))
            default: break
            }
            // Below the sprite, or above it when that spot is taken.
            let text = "\(s.slot). \(s.name)"
            let lw = CGFloat(text.count) * 5.6 + 6
            var lp = CGPoint(x: p.x, y: p.y + max(half, 8) + 12)
            var box = CGRect(x: lp.x - lw / 2, y: lp.y - 7, width: lw, height: 14)
            if placedLabels.contains(where: { $0.intersects(box) }) {
                lp.y = p.y - max(half, 8) - 12
                box.origin.y = lp.y - 7
            }
            placedLabels.append(box)
            ctx.draw(Text(text).font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? novaAmber : .white.opacity(0.85)),
                     at: lp, anchor: .center)
        }

        // Scale bar.
        let step = niceStep(100 / vp.zoom)
        let barY = sz.height - 40, barX: CGFloat = 16
        let len = step * vp.zoom
        var bar = Path()
        bar.move(to: CGPoint(x: barX, y: barY)); bar.addLine(to: CGPoint(x: barX + len, y: barY))
        bar.move(to: CGPoint(x: barX, y: barY - 4)); bar.addLine(to: CGPoint(x: barX, y: barY + 4))
        bar.move(to: CGPoint(x: barX + len, y: barY - 4)); bar.addLine(to: CGPoint(x: barX + len, y: barY + 4))
        ctx.stroke(bar, with: .color(.white.opacity(0.7)), lineWidth: 1.2)
        ctx.draw(Text("\(Int(step)) units").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7)),
                 at: CGPoint(x: barX + len / 2, y: barY - 10), anchor: .center)
    }
}

/// Hover ring for the stellar under the pointer, drawn in its own layer so mouse
/// moves don't redraw the layout canvas.
struct StellarHoverLayer: View {
    @ObservedObject var hover: MapHoverState
    let stellars: [StellarRec]
    let vp: MapViewport
    let suppressed: Bool
    let extent: (StellarRec) -> CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, sz in
            guard !suppressed, let id = hover.system, let s = stellars.first(where: { $0.id == id }) else { return }
            let p = vp.toScreen(s.point, sz)
            let half = max(extent(s) * vp.zoom, 14)
            let rr = max(half, 10) + 4
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
#endif
