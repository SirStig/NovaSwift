#if os(macOS)
import SwiftUI
import AppKit
import NovaSwiftKit

/// Galaxy Map editor: a Canvas-based pannable/zoomable view of every `sÿst`
/// in the effective collection, with drag-to-move, hyperlink drawing, system
/// creation/deletion and nebula editing. All edits go through the document
/// (one undo step per gesture). Orientation matches the in-game map: x right,
/// y DOWN, nebulae placed by top-left + extent.
struct GalaxyEditorView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var data = GalaxyMapData.shared
    /// Hover lives in its own object (held by @State, which does NOT observe it) so a
    /// mouse move redraws only the hover layer + coordinate readout, never this whole view.
    @State private var hover = MapHoverState()

    enum GTool: Hashable { case select, link, unlink, newSystem, delete, nebula }
    private enum Drag {
        case none
        case pan(last: CGPoint)
        case click(start: CGPoint, last: CGPoint, moved: Bool)
        case move(anchor: Int, startWorld: CGPoint, ids: Set<Int>)
        case marquee(start: CGPoint, base: Set<Int>)
        case link(from: Int)
        case nebMove(id: Int, startWorld: CGPoint, orig: CGRect)
        case nebResize(id: Int, corner: Int, orig: CGRect)
        case nebCreate(startWorld: CGPoint)
    }

    @State private var vp = MapViewport(center: .zero, zoom: 0.3)
    @State private var size = CGSize(width: 800, height: 600)
    @State private var tool: GTool = .select
    @State private var selection: Set<Int> = []
    @State private var selectedNebula: Int?
    @State private var drag: Drag = .none
    @State private var moveDelta = CGSize.zero
    @State private var marquee: CGRect?
    @State private var linkTo: CGPoint?
    @State private var nebLive: (id: Int, rect: CGRect)?
    @State private var nebNew: CGRect?
    @State private var spaceHeld = false
    @State private var snap = false
    @State private var showLegend = true
    @State private var showNames = true
    @State private var onlyTouched = false
    @State private var search = ""
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var newSystemAt: CGPoint?
    @State private var newSystemName = ""
    @State private var didFit = false

    private let gridStep: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Canvas(rendersAsynchronously: false) { ctx, sz in draw(&ctx, sz) }
                    .background(Color(white: 0.055))
                    .background(GeometryReader { g in
                        Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
                    })
                GalaxyHoverLayer(hover: hover, data: data, vp: vp, dotRadius: dotRadius,
                                 selection: selection, suppressed: isDraggingSystems)
                surface
                overlays
                VStack(spacing: 0) {
                    EditorRefreshStrip(active: data.isBuilding && data.hasLoaded)
                    Spacer()
                }
                if !data.hasLoaded {
                    EditorLoadingOverlay(label: "Loading galaxy\u{2026}")
                }
            }
            .clipped()
            Divider()
            GalaxyInspector(model: model, data: data, selection: selection, nebula: selectedNebula,
                            onSelect: { focus($0, zoomIn: false) },
                            onLink: { link($0, $1) }, onUnlink: { unlink($0, $1) },
                            onDelete: { deleteSystems($0) }, onDeleteNebula: { deleteNebula($0) })
                .frame(width: 290)
        }
        .background(Color(white: 0.09))
        .preferredColorScheme(.dark)
        .tint(novaAmber)
        .onAppear {
            // The first frame renders immediately (canvas + loading overlay); the
            // snapshot is built off-main and `onChange(of: data.hasLoaded)` fits the view.
            data.refresh(model)
            fitInitialIfReady()
        }
        .onChange(of: data.hasLoaded) { _, loaded in if loaded { fitInitialIfReady() } }
        .onChange(of: model.revision) { _, _ in data.refresh(model) }
        .onChange(of: data.version) { _, _ in
            // Drop selections that no longer exist once fresh geometry has landed.
            guard data.hasLoaded, !data.isBuilding else { return }
            if !selection.isEmpty {
                let kept = selection.filter { data.system($0) != nil }
                if kept != selection { selection = kept }
            }
            if let n = selectedNebula, !data.nebulae.contains(where: { $0.id == n }) { selectedNebula = nil }
        }
        .onChange(of: ObjectIdentifier(model.document)) { _, _ in
            selection = []; selectedNebula = nil; didFit = false
            data.refresh(model)
            fitInitialIfReady()
        }
        .alert("New Star System", isPresented: Binding(get: { newSystemAt != nil }, set: { if !$0 { newSystemAt = nil } })) {
            TextField("Name", text: $newSystemName)
            Button("Create") { if let p = newSystemAt { createSystem(at: p, name: newSystemName) }; newSystemAt = nil }
            Button("Cancel", role: .cancel) { newSystemAt = nil }
        }
    }

    // MARK: Input

    private var surface: some View {
        MapInputSurface(
            onDown: { down($0) }, onDrag: { dragged($0) }, onUp: { up($0) },
            onMove: { moved($0) },
            onScroll: { p, d, precise, mod in
                if precise && !mod { vp.pan(byScreen: CGSize(width: d.width, height: d.height)) }
                else { vp.zoom(by: exp(d.height * (precise ? 0.01 : 0.05)), around: p, size: size, range: 0.04...12) }
            },
            onMagnify: { p, m in vp.zoom(by: 1 + m, around: p, size: size, range: 0.04...12) },
            onPan: { vp.pan(byScreen: $0) },
            onSpace: { spaceHeld = $0 },
            onKey: { key in
                switch key {
                case "delete":
                    if tool == .nebula, let n = selectedNebula { deleteNebula(n); return true }
                    if !selection.isEmpty { deleteSystems(Array(selection)); return true }
                    if let n = selectedNebula { deleteNebula(n); return true }
                    return false
                case "escape":
                    drag = .none; moveDelta = .zero; marquee = nil; linkTo = nil; nebLive = nil; nebNew = nil
                    selection = []; selectedNebula = nil
                    return true
                default: return false
                }
            },
            menu: { contextItems(at: $0) },
            cursor: spaceHeld ? .openHand : (tool == .select ? nil : .crosshair))
    }

    private func fitInitialIfReady() {
        guard data.hasLoaded, !didFit else { return }
        didFit = true
        if let f = model.focusedSystemID, data.system(f) != nil { focus(f, zoomIn: true) } else { fit() }
    }

    private var isDraggingSystems: Bool {
        if case .move = drag { return true }
        return false
    }

    private func world(_ p: CGPoint) -> CGPoint { vp.toWorld(p, size) }
    private func snapped(_ v: CGFloat) -> CGFloat { snap ? (v / gridStep).rounded() * gridStep : v.rounded() }
    private var hitRadius: CGFloat { max(7, dotRadius + 3) }
    private var dotRadius: CGFloat { min(max(1.8 + vp.zoom * 1.6, 2.5), 7) }

    private func down(_ e: MapPointer) {
        let p = e.location
        if spaceHeld { drag = .pan(last: p); return }
        let hit = data.systemAt(screen: p, vp: vp, size: size, radius: hitRadius)
        switch tool {
        case .select:
            if let hit {
                if e.clickCount >= 2 { model.openSystemEditor(hit); return }
                if e.shift {
                    if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) }
                    drag = .none
                    return
                }
                if !selection.contains(hit) { selection = [hit] }
                selectedNebula = nil
                moveDelta = .zero
                drag = .move(anchor: hit, startWorld: world(p), ids: selection)
            } else {
                let base = e.shift ? selection : []
                if !e.shift { selection = [] }
                selectedNebula = nil
                drag = .marquee(start: p, base: base)
            }
        case .link:
            if let hit { selection = [hit]; drag = .link(from: hit); linkTo = p }
            else { drag = .pan(last: p) }
        case .unlink, .newSystem, .delete:
            drag = .click(start: p, last: p, moved: false)
        case .nebula:
            let w = world(p)
            if let (id, corner, rect) = nebulaHandle(at: p) {
                selectedNebula = id; selection = []
                drag = .nebResize(id: id, corner: corner, orig: rect)
            } else if let n = nebula(at: w) {
                selectedNebula = n.id; selection = []
                drag = .nebMove(id: n.id, startWorld: w, orig: n.rect)
            } else if hit != nil {
                drag = .pan(last: p)
            } else {
                selectedNebula = nil
                drag = .nebCreate(startWorld: CGPoint(x: snapped(w.x), y: snapped(w.y)))
            }
        }
    }

    private func dragged(_ e: MapPointer) {
        let p = e.location
        hover.screen = p
        switch drag {
        case .none: break
        case let .pan(last):
            vp.pan(byScreen: CGSize(width: p.x - last.x, height: p.y - last.y)); drag = .pan(last: p)
        case let .click(start, last, moved):
            let m = moved || hypot(p.x - start.x, p.y - start.y) > 4
            if m { vp.pan(byScreen: CGSize(width: p.x - last.x, height: p.y - last.y)) }
            drag = .click(start: start, last: p, moved: m)
        case let .move(anchor, startWorld, _):
            let w = world(p)
            var d = CGSize(width: w.x - startWorld.x, height: w.y - startWorld.y)
            if let a = data.system(anchor) {
                d.width = snapped(a.x + d.width) - a.x
                d.height = snapped(a.y + d.height) - a.y
            }
            moveDelta = d
        case let .marquee(start, base):
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee = r
            var sel = base
            for s in data.systems {
                let sp = vp.toScreen(s.point, size)
                if r.contains(sp), !(onlyTouched && !visibleWhenFiltered(s)) { sel.insert(s.id) }
            }
            selection = sel
        case .link:
            linkTo = p
        case let .nebMove(id, startWorld, orig):
            let w = world(p)
            nebLive = (id, CGRect(x: snapped(orig.minX + w.x - startWorld.x), y: snapped(orig.minY + w.y - startWorld.y),
                                  width: orig.width, height: orig.height))
        case let .nebResize(id, corner, orig):
            let w = world(p)
            let wx = snapped(w.x), wy = snapped(w.y)
            var minX = orig.minX, minY = orig.minY, maxX = orig.maxX, maxY = orig.maxY
            if corner == 0 || corner == 2 { minX = wx } else { maxX = wx }
            if corner == 0 || corner == 1 { minY = wy } else { maxY = wy }
            nebLive = (id, CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(4, abs(maxX - minX)), height: max(4, abs(maxY - minY))))
        case let .nebCreate(startWorld):
            let w = world(p)
            let wx = snapped(w.x), wy = snapped(w.y)
            nebNew = CGRect(x: min(startWorld.x, wx), y: min(startWorld.y, wy), width: abs(wx - startWorld.x), height: abs(wy - startWorld.y))
        }
    }

    private func up(_ e: MapPointer) {
        let p = e.location
        defer {
            drag = .none; moveDelta = .zero; marquee = nil; linkTo = nil; nebLive = nil; nebNew = nil
        }
        switch drag {
        case let .move(_, _, ids):
            let d = moveDelta
            guard abs(d.width) >= 1 || abs(d.height) >= 1 else { return }
            moveSystems(ids, by: d)
        case let .link(from):
            if let to = data.systemAt(screen: p, vp: vp, size: size, radius: hitRadius + 3), to != from { link(from, to) }
        case let .click(_, _, moved):
            guard !moved else { return }
            let hit = data.systemAt(screen: p, vp: vp, size: size, radius: hitRadius)
            switch tool {
            case .unlink:
                if let l = data.linkAt(screen: p, vp: vp, size: size, tolerance: 6) { unlink(l.a, l.b) }
            case .newSystem:
                if hit == nil { newSystemName = ""; newSystemAt = world(p) }
            case .delete:
                if let hit { deleteSystems(selection.contains(hit) ? Array(selection) : [hit]) }
                else if let n = nebula(at: world(p)) { deleteNebula(n.id) }
            default: break
            }
        case .nebMove, .nebResize:
            if let n = nebLive { commitNebula(n.id, n.rect) }
        case .nebCreate:
            if let r = nebNew, r.width >= 8, r.height >= 8 { createNebula(r) }
        default: break
        }
    }

    private func moved(_ p: CGPoint) {
        hover.screen = p
        let h = data.systemAt(screen: p, vp: vp, size: size, radius: hitRadius)
        if h != hover.system { hover.system = h }
        let l = (h == nil && (tool == .unlink)) ? data.linkAt(screen: p, vp: vp, size: size, tolerance: 6) : nil
        if l != hover.link { hover.link = l }
    }

    // MARK: Actions

    private func flash(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toast = nil } }
    }

    private func clampI16(_ v: CGFloat) -> Int { Int(max(-32768, min(32767, v.rounded()))) }

    private func moveSystems(_ ids: Set<Int>, by d: CGSize) {
        let dx = Int(d.width.rounded()), dy = Int(d.height.rounded())
        model.document.withGroup(ids.count == 1 ? "Move system" : "Move \(ids.count) systems") {
            for id in ids {
                guard let s = data.system(id) else { continue }
                model.setValue(.point(clampI16(s.x) + dx, clampI16(s.y) + dy), field: "position", of: ResourceKey(NovaType.syst, id))
            }
        }
        // Optimistic: patch the moved systems into the snapshot right now so the
        // canvas never shows the old position between the drop and the next refresh.
        data.refresh(model)
    }

    private func link(_ a: Int, _ b: Int) {
        let result = SystemLinkEditing.link(model.document, a, b)
        data.refresh(model)
        switch result {
        case .linked: flash("Linked \(data.system(a)?.name ?? "\(a)") \u{2194} \(data.system(b)?.name ?? "\(b)")")
        case .alreadyLinked: flash("Already linked")
        case let .full(sid): flash("\(data.system(sid)?.name ?? "System \(sid)") has no free hyperlink slot (max 16)")
        case .invalid: flash("Can't link those systems")
        }
    }

    private func unlink(_ a: Int, _ b: Int) {
        if SystemLinkEditing.unlink(model.document, a, b) {
            data.refresh(model)
            flash("Unlinked \(data.system(a)?.name ?? "\(a)") from \(data.system(b)?.name ?? "\(b)")")
        }
    }

    private func createSystem(at w: CGPoint, name: String) {
        let doc = model.document
        var newID: Int?
        doc.withGroup("New system") {
            guard let id = try? doc.create(NovaType.syst, name: name.isEmpty ? "New System" : name) else { return }
            let key = ResourceKey(NovaType.syst, id)
            model.setValue(.point(clampI16(snapped(w.x)), clampI16(snapped(w.y))), field: "position", of: key)
            model.setValue(.int(1), field: "avgShips", of: key)
            newID = id
        }
        data.refresh(model)
        if let id = newID { selection = [id]; flash("Created system #\(id)") }
        else { flash("No free sÿst id") }
    }

    private func deleteSystems(_ ids: [Int]) {
        let doc = model.document
        var removed = 0, blocked = 0
        doc.withGroup(ids.count == 1 ? "Delete system" : "Delete \(ids.count) systems") {
            for id in ids {
                switch doc.provenance(NovaType.syst, id) {
                case .new:
                    SystemLinkEditing.unlinkAll(doc, id)
                    doc.remove(NovaType.syst, id); removed += 1
                case .override:
                    doc.revertToBase(NovaType.syst, id); removed += 1
                default: blocked += 1
                }
            }
        }
        data.refresh(model)
        selection.subtract(ids)
        if blocked > 0 {
            flash("Base-game systems can't be removed by a plug-in (diff layers only). Unlink them or gate them with a visibility test instead.")
        } else if removed > 0 { flash(removed == 1 ? "Deleted" : "Deleted \(removed) systems") }
    }

    private func createNebula(_ r: CGRect) {
        let doc = model.document
        var made: Int?
        doc.withGroup("New nebula") {
            guard let id = try? doc.create(NovaType.nebula, name: "New Nebula") else { return }
            let key = ResourceKey(NovaType.nebula, id)
            model.setValue(.point(clampI16(r.minX), clampI16(r.minY)), field: "position", of: key)
            model.setValue(.point(clampI16(r.width), clampI16(r.height)), field: "size", of: key)
            made = id
        }
        if let id = made {
            data.refresh(model); selectedNebula = id
            flash("Created nëbu #\(id). Its art is PICT \(9502 + 7 * (id - 128)) (add one to show an image).")
        }
    }

    private func commitNebula(_ id: Int, _ r: CGRect) {
        let key = ResourceKey(NovaType.nebula, id)
        model.document.withGroup("Edit nebula") {
            model.setValue(.point(clampI16(r.minX), clampI16(r.minY)), field: "position", of: key)
            model.setValue(.point(clampI16(r.width), clampI16(r.height)), field: "size", of: key)
        }
        data.refresh(model)
    }

    private func deleteNebula(_ id: Int) {
        let doc = model.document
        switch doc.provenance(NovaType.nebula, id) {
        case .new: doc.remove(NovaType.nebula, id); selectedNebula = nil; data.refresh(model)
        case .override: doc.revertToBase(NovaType.nebula, id); selectedNebula = nil; data.refresh(model)
        default: flash("Base-game nebulae can't be removed by a plug-in; move or resize it instead.")
        }
    }

    // MARK: View control

    private func fit() {
        let b = data.bounds
        guard size.width > 10, size.height > 10 else { return }
        let z = min(size.width / b.width, size.height / b.height) * 0.9
        vp = MapViewport(center: CGPoint(x: b.midX, y: b.midY), zoom: min(max(z, 0.04), 4))
    }

    private func focus(_ id: Int, zoomIn: Bool) {
        guard let s = data.system(id) else { return }
        vp.center = s.point
        if zoomIn || vp.zoom < 1.2 { vp.zoom = max(vp.zoom, 1.5) }
        selection = [id]
    }

    private func visibleWhenFiltered(_ s: MapSystem) -> Bool {
        guard onlyTouched else { return true }
        if s.touched { return true }
        // Keep direct neighbours of touched systems for context.
        for l in s.links { if let n = data.system(l), n.touched { return true } }
        return false
    }

    private func nebula(at w: CGPoint) -> MapNebulaRec? {
        if let n = selectedNebula, let r = data.nebulae.first(where: { $0.id == n }), r.rect.contains(w) { return r }
        return data.nebulae.reversed().first { $0.rect.contains(w) }
    }

    private func nebulaHandle(at p: CGPoint) -> (Int, Int, CGRect)? {
        guard let id = selectedNebula, let n = data.nebulae.first(where: { $0.id == id }) else { return nil }
        let r = nebLive?.id == id ? nebLive!.rect : n.rect
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        for (i, c) in corners.enumerated() {
            let s = vp.toScreen(c, size)
            if hypot(s.x - p.x, s.y - p.y) < 10 { return (id, i, n.rect) }
        }
        return nil
    }

    // MARK: Context menu

    private func contextItems(at p: CGPoint) -> [MapMenuItem] {
        let hit = data.systemAt(screen: p, vp: vp, size: size, radius: hitRadius + 2)
        if let id = hit, let s = data.system(id) {
            if !selection.contains(id) { selection = [id] }
            let targets = selection.contains(id) ? Array(selection) : [id]
            let linked = Set(s.links)
            let near = data.nearest(to: id, count: 14, excluding: linked)
            var items: [MapMenuItem] = [
                MapMenuItem(title: "Open \"\(s.name)\" in System Editor", symbol: "scope", action: { model.openSystemEditor(id) }),
                MapMenuItem(title: "Show in Resources", symbol: "list.bullet.rectangle", action: { model.showInResources(ResourceKey(NovaType.syst, id)) }),
                .separator,
                MapMenuItem(title: "Link to\u{2026}", symbol: "link", disabled: near.isEmpty,
                            children: near.map { n in MapMenuItem(title: "\(n.name)  (#\(n.id))", action: { link(id, n.id) }) }),
                MapMenuItem(title: "Unlink from\u{2026}", symbol: "scissors", disabled: linked.isEmpty,
                            children: s.links.compactMap { data.system($0) }.map { n in
                                MapMenuItem(title: "\(n.name)  (#\(n.id))", action: { unlink(id, n.id) })
                            }),
                .separator,
            ]
            items.append(MapMenuItem(title: targets.count > 1 ? "Delete \(targets.count) Systems" : "Delete System",
                                     symbol: "trash", destructive: true, action: { deleteSystems(targets) }))
            return items
        }
        let w = world(p)
        if let n = nebula(at: w) {
            return [
                MapMenuItem(title: "Show \"\(n.name)\" in Resources", symbol: "list.bullet.rectangle",
                            action: { model.showInResources(ResourceKey(NovaType.nebula, n.id)) }),
                .separator,
                MapMenuItem(title: "Delete Nebula", symbol: "trash", destructive: true, action: { deleteNebula(n.id) }),
            ]
        }
        return [
            MapMenuItem(title: "New System Here\u{2026}", symbol: "plus.circle", action: { newSystemName = ""; newSystemAt = w }),
            MapMenuItem(title: "Fit All Systems", symbol: "arrow.up.left.and.down.right.magnifyingglass", action: { fit() }),
        ]
    }

    // MARK: Drawing

    private func pos(_ s: MapSystem, moving: Set<Int>) -> CGPoint {
        if moving.contains(s.id) { return CGPoint(x: s.x + moveDelta.width, y: s.y + moveDelta.height) }
        return s.point
    }

    private func draw(_ ctx: inout GraphicsContext, _ sz: CGSize) {
        _ = data.version
        guard data.hasLoaded || !data.systems.isEmpty else { return }
        let moving: Set<Int>
        if case let .move(_, _, ids) = drag { moving = ids } else { moving = [] }
        let view = CGRect(origin: .zero, size: sz).insetBy(dx: -40, dy: -40)

        // Grid while snapping.
        if snap, vp.zoom * gridStep >= 8 {
            var g = Path()
            let tl = world(.zero), br = world(CGPoint(x: sz.width, y: sz.height))
            var x = (tl.x / gridStep).rounded(.down) * gridStep
            while x <= br.x { let sx = vp.toScreen(CGPoint(x: x, y: 0), sz).x; g.move(to: CGPoint(x: sx, y: 0)); g.addLine(to: CGPoint(x: sx, y: sz.height)); x += gridStep }
            var y = (tl.y / gridStep).rounded(.down) * gridStep
            while y <= br.y { let sy = vp.toScreen(CGPoint(x: 0, y: y), sz).y; g.move(to: CGPoint(x: 0, y: sy)); g.addLine(to: CGPoint(x: sz.width, y: sy)); y += gridStep }
            ctx.stroke(g, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
        }
        // Origin crosshair.
        let o = vp.toScreen(.zero, sz)
        var axes = Path()
        axes.move(to: CGPoint(x: o.x - 6, y: o.y)); axes.addLine(to: CGPoint(x: o.x + 6, y: o.y))
        axes.move(to: CGPoint(x: o.x, y: o.y - 6)); axes.addLine(to: CGPoint(x: o.x, y: o.y + 6))
        ctx.stroke(axes, with: .color(.white.opacity(0.15)), lineWidth: 1)

        // Nebulae.
        for n in data.nebulae {
            var r = n.rect
            if let l = nebLive, l.id == n.id { r = l.rect }
            let tl = vp.toScreen(r.origin, sz)
            let sr = CGRect(x: tl.x, y: tl.y, width: r.width * vp.zoom, height: r.height * vp.zoom)
            guard sr.intersects(view) else { continue }
            if let img = data.nebulaImages[n.id] {
                var c = ctx; c.opacity = tool == .nebula ? 0.5 : 0.3
                c.draw(c.resolve(Image(decorative: img, scale: 1)), in: sr)
            } else {
                ctx.fill(Path(sr), with: .color(Color(red: 0.55, green: 0.3, blue: 0.9).opacity(0.10)))
            }
            let isSel = selectedNebula == n.id
            if tool == .nebula || isSel || n.touched {
                ctx.stroke(Path(sr), with: .color(isSel ? novaAmber : Color.purple.opacity(0.5)),
                           style: StrokeStyle(lineWidth: isSel ? 1.5 : 1, dash: [5, 4]))
                if tool == .nebula || vp.zoom > 0.6 {
                    ctx.draw(Text(n.name).font(.system(size: 10)).foregroundColor(.purple.opacity(0.9)),
                             at: CGPoint(x: sr.minX + 4, y: sr.minY + 3), anchor: .topLeading)
                }
            }
            if isSel && tool == .nebula {
                for c in [CGPoint(x: sr.minX, y: sr.minY), CGPoint(x: sr.maxX, y: sr.minY),
                          CGPoint(x: sr.minX, y: sr.maxY), CGPoint(x: sr.maxX, y: sr.maxY)] {
                    let h = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                    ctx.fill(Path(h), with: .color(novaAmber)); ctx.stroke(Path(h), with: .color(.black), lineWidth: 1)
                }
            }
        }
        if let r = nebNew {
            let tl = vp.toScreen(r.origin, sz)
            let sr = CGRect(x: tl.x, y: tl.y, width: r.width * vp.zoom, height: r.height * vp.zoom)
            ctx.fill(Path(sr), with: .color(.purple.opacity(0.15)))
            ctx.stroke(Path(sr), with: .color(.purple), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        // Links.
        var normal = Path(), hot = Path(), oneWay = Path(), dim = Path()
        for l in data.pairs {
            guard let ai = data.index[l.a], let bi = data.index[l.b] else { continue }
            let sa = data.systems[ai], sb = data.systems[bi]
            let a = vp.toScreen(pos(sa, moving: moving), sz), b = vp.toScreen(pos(sb, moving: moving), sz)
            let bb = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard bb.intersects(view) else { continue }
            let fa = visibleWhenFiltered(sa), fb = visibleWhenFiltered(sb)
            if onlyTouched && !(sa.touched || sb.touched) {
                if fa && fb { dim.move(to: a); dim.addLine(to: b) }
                continue
            }
            if l.oneWay { oneWay.move(to: a); oneWay.addLine(to: b) }
            else if sa.touched || sb.touched || selection.contains(l.a) || selection.contains(l.b) { hot.move(to: a); hot.addLine(to: b) }
            else { normal.move(to: a); normal.addLine(to: b) }
        }
        ctx.stroke(dim, with: .color(.white.opacity(0.08)), lineWidth: 0.8)
        ctx.stroke(normal, with: .color(.white.opacity(onlyTouched ? 0.12 : 0.28)), lineWidth: 1)
        ctx.stroke(hot, with: .color(novaAmber.opacity(0.75)), lineWidth: 1.4)
        ctx.stroke(oneWay, with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        // Rubber band.
        if case let .link(from) = drag, let s = data.system(from), let t = linkTo {
            var end = t
            if let h = data.systemAt(screen: t, vp: vp, size: size, radius: hitRadius + 3), h != from, let hs = data.system(h) {
                end = vp.toScreen(hs.point, sz)
                ctx.stroke(Path(ellipseIn: CGRect(x: end.x - 9, y: end.y - 9, width: 18, height: 18)), with: .color(.green), lineWidth: 2)
            }
            var p = Path(); p.move(to: vp.toScreen(s.point, sz)); p.addLine(to: end)
            ctx.stroke(p, with: .color(novaAmber), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }

        // Systems: one combined Path per (government, dimmed) fill and per ring
        // colour, so a frame costs a handful of draw calls instead of one per dot.
        // Selected / hovered systems and their names are drawn separately.
        struct FillKey: Hashable { let govt: Int; let dim: Bool }
        let r = dotRadius
        let labelZoom: CGFloat = 1.0
        let wantLabels = showNames && vp.zoom >= labelZoom
        var fills: [FillKey: Path] = [:]
        var newRing = Path(), overrideRing = Path()
        var labels: [(String, CGPoint, Bool)] = []   // (name, anchor, dim)
        for s in data.systems {
            let p = vp.toScreen(pos(s, moving: moving), sz)
            guard view.contains(p) else { continue }
            let visible = visibleWhenFiltered(s)
            let dim = onlyTouched && !s.touched
            if dim && !visible { continue }
            fills[FillKey(govt: s.govt, dim: dim), default: Path()]
                .addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            switch s.provenance {
            case .new: newRing.addEllipse(in: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
            case .override: overrideRing.addEllipse(in: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
            default: break
            }
            if wantLabels, visible, labels.count < 600, !selection.contains(s.id) {
                labels.append((s.name, CGPoint(x: p.x, y: p.y + r + 7), dim))
            }
        }
        for (k, path) in fills {
            ctx.fill(path, with: .color(data.color(k.govt).opacity(k.dim ? 0.3 : 1.0)))
        }
        ctx.stroke(newRing, with: .color(.green), lineWidth: 1.5)
        ctx.stroke(overrideRing, with: .color(.orange), lineWidth: 1.5)
        for (name, at, dim) in labels {
            ctx.draw(Text(name).font(.system(size: 10)).foregroundColor(.white.opacity(dim ? 0.26 : 0.85)),
                     at: at, anchor: .center)
        }
        // Selection (iterates the selection set, not every system).
        for id in selection {
            guard let s = data.system(id) else { continue }
            let p = vp.toScreen(pos(s, moving: moving), sz)
            guard view.contains(p) else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r - 5, y: p.y - r - 5, width: (r + 5) * 2, height: (r + 5) * 2)), with: .color(novaAmber.opacity(0.25)))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 4, y: p.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2)), with: .color(novaAmber), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(data.color(s.govt)))
            ctx.draw(Text(s.name).font(.system(size: 10, weight: .semibold)).foregroundColor(novaAmber),
                     at: CGPoint(x: p.x, y: p.y + r + 7), anchor: .center)
        }

        if let m = marquee {
            ctx.fill(Path(m), with: .color(novaAmber.opacity(0.08)))
            ctx.stroke(Path(m), with: .color(novaAmber.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    Spacer()
                    topBar
                }
                .padding(10)
                Spacer()
            }
            HStack {
                VStack { palette.padding(.leading, 10).padding(.top, 10); Spacer() }
                Spacer()
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if showLegend { legend }
                    Spacer()
                }
                .padding(10)
                statusLine
            }
            if !searchResults.isEmpty {
                VStack { HStack { Spacer(); searchList }.padding(.trailing, 10).padding(.top, 48); Spacer() }
            }
        }
    }

    private var palette: some View {
        MapPalette {
            VStack(spacing: 2) {
                MapToolButton(symbol: "cursorarrow", label: "Select / Move (drag systems, marquee, shift to add; double-click opens)", active: tool == .select) { tool = .select }
                MapToolButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", label: "Link: drag from one system to another", active: tool == .link) { tool = .link }
                MapToolButton(symbol: "scissors", label: "Unlink: click a hyperlink", active: tool == .unlink) { tool = .unlink }
                MapToolButton(symbol: "plus.circle", label: "New System: click the map", active: tool == .newSystem) { tool = .newSystem }
                MapToolButton(symbol: "trash", label: "Delete: click a system or nebula", active: tool == .delete) { tool = .delete }
                MapToolButton(symbol: "cloud", label: "Nebula: drag to create, drag to move, handles to resize", active: tool == .nebula) { tool = .nebula }
            }
        }
    }

    private var topBar: some View {
        MapPalette {
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Find system", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 120)
                        .onSubmit { if let f = searchResults.first { pick(f.id) } }
                }
                .padding(.horizontal, 6).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                Divider().frame(height: 18)
                MapToolButton(symbol: "grid", label: "Snap to grid (10 units)", active: snap) { snap.toggle() }
                MapToolButton(symbol: "textformat", label: "System names", active: showNames) { showNames.toggle() }
                MapToolButton(symbol: "list.bullet.below.rectangle", label: "Government legend", active: showLegend) { showLegend.toggle() }
                MapToolButton(symbol: "line.3.horizontal.decrease.circle", label: "Show only plug-in-touched systems", active: onlyTouched) { onlyTouched.toggle() }
                Divider().frame(height: 18)
                MapToolButton(symbol: "minus.magnifyingglass", label: "Zoom out", active: false) { vp.zoom(by: 0.7, around: CGPoint(x: size.width / 2, y: size.height / 2), size: size, range: 0.04...12) }
                MapToolButton(symbol: "plus.magnifyingglass", label: "Zoom in", active: false) { vp.zoom(by: 1.4, around: CGPoint(x: size.width / 2, y: size.height / 2), size: size, range: 0.04...12) }
                MapToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", label: "Fit all systems", active: false) { fit() }
                Divider().frame(height: 18)
                MapToolButton(symbol: "arrow.uturn.backward", label: "Undo", active: false) { model.undo() }
                MapToolButton(symbol: "arrow.uturn.forward", label: "Redo", active: false) { model.redo() }
            }
        }
    }

    private var searchResults: [MapSystem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return Array(data.systems.filter { $0.name.lowercased().contains(q) || String($0.id) == q }.prefix(8))
    }

    private var searchList: some View {
        MapPalette {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(searchResults) { s in
                    Button { pick(s.id) } label: {
                        HStack {
                            Circle().fill(data.color(s.govt)).frame(width: 8, height: 8)
                            Text(s.name).font(.system(size: 12))
                            Spacer()
                            Text("#\(s.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).frame(width: 220).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pick(_ id: Int) { search = ""; focus(id, zoomIn: true) }

    private var legend: some View {
        let rows = data.govts.filter { $0.count > 0 }.sorted { $0.count > $1.count }.prefix(14)
        return MapPalette {
            VStack(alignment: .leading, spacing: 3) {
                Text("GOVERNMENTS").font(.system(size: 9, weight: .semibold)).foregroundStyle(novaAmber.opacity(0.8))
                ForEach(Array(rows)) { g in
                    HStack(spacing: 6) {
                        Circle().fill(g.color).frame(width: 8, height: 8)
                        Text(g.name).font(.system(size: 10)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(g.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Circle().stroke(.green, lineWidth: 1.5).frame(width: 8, height: 8); Text("new").font(.system(size: 10))
                    Circle().stroke(.orange, lineWidth: 1.5).frame(width: 8, height: 8); Text("override").font(.system(size: 10))
                }
                .padding(.top, 2)
            }
            .frame(width: 150)
            .padding(4)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 14) {
            MapCursorReadout(hover: hover, vp: vp, size: size, showRadius: false)
            Text(String(format: "zoom %.0f%%", vp.zoom * 100)).font(.system(size: 10, design: .monospaced))
            Text("\(selection.count) selected").font(.system(size: 10))
            Text("\(data.systems.count) systems").font(.system(size: 10)).foregroundStyle(.secondary)
            if let t = toast { Text(t).font(.system(size: 10, weight: .medium)).foregroundStyle(novaAmber).lineLimit(1) }
            Spacer()
            Text(toolHint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.8))
    }

    private var toolHint: String {
        switch tool {
        case .select: return "Drag: move \u{2022} empty drag: marquee \u{2022} space+drag: pan \u{2022} scroll: zoom \u{2022} dbl-click: system editor"
        case .link: return "Drag from a system to another to link them"
        case .unlink: return "Click a hyperlink to remove it (both directions)"
        case .newSystem: return "Click to place a new system"
        case .delete: return "Click a system or nebula to delete it"
        case .nebula: return "Drag on empty space to create \u{2022} drag to move \u{2022} corner handles resize"
        }
    }
}

// MARK: - Hover (isolated from the main view's invalidation)

/// Pointer-hover state for the map editors. Held in `@State` by the owning view
/// (which does not subscribe to it); only `GalaxyHoverLayer` / `MapCursorReadout`
/// observe it, so mouse moves never re-evaluate the heavy parent body.
final class MapHoverState: ObservableObject {
    @Published var screen: CGPoint?
    @Published var system: Int?
    @Published var link: MapLinkPair?
}

/// "x … y …" cursor readout for the status bar.
struct MapCursorReadout: View {
    @ObservedObject var hover: MapHoverState
    let vp: MapViewport
    let size: CGSize
    var showRadius: Bool

    var body: some View {
        if let h = hover.screen {
            let w = vp.toWorld(h, size)
            Text(showRadius ? String(format: "x %.0f  y %.0f  r %.0f", w.x, w.y, hypot(w.x, w.y))
                            : String(format: "x %.0f  y %.0f", w.x, w.y))
                .font(.system(size: 10, design: .monospaced))
        }
    }
}

/// Draws just the hover ring / name / hovered hyperlink over the main canvas.
struct GalaxyHoverLayer: View {
    @ObservedObject var hover: MapHoverState
    let data: GalaxyMapData
    let vp: MapViewport
    let dotRadius: CGFloat
    let selection: Set<Int>
    let suppressed: Bool

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, sz in
            guard !suppressed else { return }
            if let hl = hover.link, let ai = data.index[hl.a], let bi = data.index[hl.b] {
                var p = Path()
                p.move(to: vp.toScreen(data.systems[ai].point, sz)); p.addLine(to: vp.toScreen(data.systems[bi].point, sz))
                ctx.stroke(p, with: .color(.red), lineWidth: 3)
            }
            if let id = hover.system, let s = data.system(id) {
                let p = vp.toScreen(s.point, sz)
                let r = dotRadius
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)),
                           with: .color(.white), lineWidth: 1)
                if !selection.contains(id) {
                    ctx.draw(Text(s.name).font(.system(size: 10)).foregroundColor(.white.opacity(0.95)),
                             at: CGPoint(x: p.x, y: p.y + r + 7), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
