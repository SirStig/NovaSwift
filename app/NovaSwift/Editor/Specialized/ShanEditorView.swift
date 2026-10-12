#if os(macOS)
import SwiftUI
import NovaSwiftKit
import NovaSwiftEngine

/// The four `shän` weapon-hardpoint classes.
private enum PointClass: String, CaseIterable, Identifiable {
    case gun = "Gun", turret = "Turret", guided = "Guided", beam = "Beam"
    var id: String { rawValue }
    var xKey: String { rawValue.lowercased() + "X" }
    var yKey: String { rawValue.lowercased() + "Y" }
    var zKey: String { rawValue.lowercased() + "Z" }
    var exit: WeaponExitType {
        switch self { case .gun: return .gun; case .turret: return .turret; case .guided: return .guided; case .beam: return .beam }
    }
    var color: Color {
        switch self {
        case .gun: return .orange
        case .turret: return .cyan
        case .guided: return .green
        case .beam: return Color(red: 1, green: 0.4, blue: 0.9)
        }
    }
}

/// shän "Layers & Hardpoints": every sprite layer composited frame-synced, with the
/// gun/turret/guided/beam exit points overlaid exactly where the engine puts them
/// (`ShipExitPoints.muzzleOffset`: +y toward the nose, compression, z) for the current
/// heading, and draggable. Drags write straight back to the shän.
struct ShanEditorView: View {
    @ObservedObject var model: EditorModel
    let env: EditorEnv
    let key: ResourceKey

    @StateObject private var loader = ShipLayersLoader()
    @State private var toggles = ShipLayerToggles()
    @State private var heading = 0
    @State private var autoSpin = false
    @State private var zoom: CGFloat = 3
    @State private var showGrid = true
    @State private var visible: Set<String> = Set(PointClass.allCases.map(\.rawValue))
    @State private var drag: (cls: PointClass, index: Int)?
    @State private var dragSerial = 0

    private struct TaskKey: Hashable { let key: ResourceKey; let revision: Int }

    private var shan: ShanRes? { model.effective.resource(NovaType.shan, key.id).map(ShanRes.init) }

    private func exitPoints(_ s: ShanRes) -> ShipExitPoints {
        func conv(_ p: [ShanExitPoint]) -> [Vec2] { p.map { Vec2(Double($0.x), Double($0.y)) } }
        func zs(_ p: [ShanExitPoint]) -> [Double] { p.map { Double($0.z) } }
        return ShipExitPoints(gun: conv(s.gunPoints), turret: conv(s.turretPoints), guided: conv(s.guidedPoints),
                              beam: conv(s.beamPoints), gunZ: zs(s.gunPoints), turretZ: zs(s.turretPoints),
                              guidedZ: zs(s.guidedPoints), beamZ: zs(s.beamPoints),
                              upCompress: (Double(s.upCompress.x), Double(s.upCompress.y)),
                              downCompress: (Double(s.downCompress.x), Double(s.downCompress.y)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = shan {
                canvas(s).frame(height: 380)
                controls(s)
                pointTable(s)
                compression
            } else {
                EditorEmptyState(icon: "scope", title: "No shän data", subtitle: "Use Form or Raw.")
            }
        }
        .task(id: TaskKey(key: key, revision: model.revision)) { await loader.load(model: model, id: key.id) }
    }

    // MARK: Canvas

    private func canvas(_ s: ShanRes) -> some View {
        let ep = exitPoints(s)
        let headings = max(1, loader.layers?.headings ?? s.framesPerSet)
        return GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !autoSpin && !s.hasAltLayer)) { tl in
                let h = autoSpin ? ShipCompositor.spinHeading(tl.date, headings: headings, turnsPerSecond: 0.12) : heading % headings
                Canvas { ctx, size in
                    if showGrid { drawGrid(ctx, size, center) }
                    if let layers = loader.layers {
                        ShipCompositor.draw(ctx, center: center, zoom: zoom, layers: layers, heading: h,
                                            altStep: ShipCompositor.altStep(tl.date, shan: s), toggles: toggles)
                    }
                    drawPoints(ctx, center: center, ep: ep, heading: h, headings: headings)
                }
            }
            .background { Color.black.opacity(0.5) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragChanged(g, center: center, ep: ep, headings: headings) }
                .onEnded { _ in drag = nil })
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize, _ c: CGPoint) {
        let step = 8 * zoom
        guard step > 6 else { return }
        var p = Path()
        var x = c.x.truncatingRemainder(dividingBy: step)
        while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
        var y = c.y.truncatingRemainder(dividingBy: step)
        while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        var axes = Path()
        axes.move(to: CGPoint(x: c.x, y: 0)); axes.addLine(to: CGPoint(x: c.x, y: size.height))
        axes.move(to: CGPoint(x: 0, y: c.y)); axes.addLine(to: CGPoint(x: size.width, y: c.y))
        ctx.stroke(axes, with: .color(.white.opacity(0.18)), lineWidth: 1)
    }

    private func screenPos(_ v: Vec2, _ c: CGPoint) -> CGPoint { CGPoint(x: c.x + v.x * zoom, y: c.y - v.y * zoom) }

    private func angle(_ heading: Int, _ headings: Int) -> Double { Double(heading) / Double(headings) * 2 * .pi }

    private func drawPoints(_ ctx: GraphicsContext, center: CGPoint, ep: ShipExitPoints, heading: Int, headings: Int) {
        let a = angle(heading, headings)
        // nose arrow
        let nose = screenPos(Vec2.heading(a) * 40, center)
        var arrow = Path(); arrow.move(to: center); arrow.addLine(to: nose)
        ctx.stroke(arrow, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for cls in PointClass.allCases where visible.contains(cls.rawValue) {
            let pts = ep.points(for: cls.exit)
            for i in 0..<pts.count {
                let authored = !(pts[i].x == 0 && pts[i].y == 0)
                let p = screenPos(ep.muzzleOffset(type: cls.exit, index: i, angle: a, nose: 0), center)
                let r: CGFloat = (drag?.cls == cls && drag?.index == i) ? 7 : 5
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                if authored { ctx.fill(Path(ellipseIn: rect), with: .color(cls.color.opacity(0.9))) }
                ctx.stroke(Path(ellipseIn: rect), with: .color(cls.color.opacity(authored ? 1 : 0.4)), lineWidth: 1.5)
                ctx.draw(Text("\(cls.rawValue.prefix(1))\(i + 1)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white), at: CGPoint(x: p.x + 11, y: p.y - 9))
            }
        }
    }

    // MARK: Dragging

    private func dragChanged(_ g: DragGesture.Value, center: CGPoint, ep: ShipExitPoints, headings: Int) {
        let a = angle(heading, headings)
        if drag == nil {
            // grab the nearest visible point within 14 px
            var best: (PointClass, Int, CGFloat)?
            for cls in PointClass.allCases where visible.contains(cls.rawValue) {
                let n = ep.points(for: cls.exit).count
                for i in 0..<n {
                    let p = screenPos(ep.muzzleOffset(type: cls.exit, index: i, angle: a, nose: 0), center)
                    let d = hypot(p.x - g.startLocation.x, p.y - g.startLocation.y)
                    if d < 14, d < (best?.2 ?? .infinity) { best = (cls, i, d) }
                }
            }
            guard let b = best else { return }
            drag = (b.0, b.1)
            dragSerial += 1
            autoSpin = false
        }
        guard let d = drag else { return }
        let z = Double(zValue(d.cls, d.index))
        let wx = Double(g.location.x - center.x) / Double(zoom)
        let wyTotal = Double(center.y - g.location.y) / Double(zoom)
        let wy = wyTotal - z
        guard let s = shan else { return }
        let up = wy > 0
        let cx = max(0.01, Double(up ? s.upCompress.x : s.downCompress.x) / 100)
        let cy = max(0.01, Double(up ? s.upCompress.y : s.downCompress.y) / 100)
        let ux = wx / cx, uy = wy / cy
        let fx = sin(a), fy = cos(a)       // forward (nose) in the y-up world
        let rx = cos(a), ry = -sin(a)      // ship's right
        let lx = ux * rx + uy * ry, ly = ux * fx + uy * fy
        writePoint(d.cls, d.index, x: Int(lx.rounded()), y: Int(ly.rounded()))
    }

    private func zValue(_ cls: PointClass, _ i: Int) -> Int {
        guard case let .array(a)? = model.readValue(cls.zKey, of: key), a.indices.contains(i) else { return 0 }
        return a[i].intValue ?? 0
    }

    private func writePoint(_ cls: PointClass, _ i: Int, x: Int? = nil, y: Int? = nil, z: Int? = nil) {
        guard let res = model.document.resource(key.type, key.id), let schema = ResourceSchemas.schema(for: key.type) else { return }
        var data = schema.padded(res.data)
        func set(_ k: String, _ v: Int?) {
            guard let v, case var .array(arr)? = schema.read(k, from: data), arr.indices.contains(i) else { return }
            arr[i] = .int(max(-32768, min(32767, v)))
            schema.write(.array(arr), key: k, into: &data)
        }
        set(cls.xKey, x); set(cls.yKey, y); set(cls.zKey, z)
        guard data != res.data else { return }
        let serial = drag != nil ? dragSerial : 0
        model.writeData(data, for: key, label: "Move \(cls.rawValue.lowercased()) exit \(i + 1)",
                        coalesce: "shan-pt/\(key.id)/\(cls.rawValue)/\(i)/\(serial)")
    }

    // MARK: Controls

    private func controls(_ s: ShanRes) -> some View {
        SpecSection(title: "View") {
            HStack(alignment: .top, spacing: 18) {
                ShipStageControls(layers: loader.layers, toggles: $toggles, heading: $heading, autoSpin: $autoSpin)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Zoom").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $zoom, in: 1...8, step: 0.5).frame(width: 140)
                        Text("\(SpecFormat.num(Double(zoom)))×").font(.system(size: 10, design: .monospaced)) }
                    Toggle("Grid (8 px)", isOn: $showGrid).toggleStyle(.checkbox).controlSize(.small)
                    Text("Hardpoints").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(PointClass.allCases) { c in
                        Toggle(isOn: Binding(get: { visible.contains(c.rawValue) },
                                             set: { if $0 { visible.insert(c.rawValue) } else { visible.remove(c.rawValue) } })) {
                            HStack(spacing: 5) { Circle().fill(c.color).frame(width: 8, height: 8); Text(c.rawValue).font(.system(size: 11)) }
                        }.toggleStyle(.checkbox).controlSize(.small)
                    }
                    Text("Drag a point to move it. Dashed outline = unauthored (0, 0): shots leave from the hull centre. Engine glow and running lights are overlay sprites, not points.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pointTable(_ s: ShanRes) -> some View {
        SpecSection(title: "Exit points", trailing: "x right, y toward the nose, z screen-up drop (sprite px)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PointClass.allCases) { cls in
                    let pts: [ShanExitPoint] = {
                        switch cls { case .gun: return s.gunPoints; case .turret: return s.turretPoints
                        case .guided: return s.guidedPoints; case .beam: return s.beamPoints }
                    }()
                    ForEach(0..<pts.count, id: \.self) { i in
                        HStack(spacing: 6) {
                            Circle().fill(cls.color).frame(width: 8, height: 8)
                            Text("\(cls.rawValue) \(i + 1)").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                            axis("x", pts[i].x) { writePoint(cls, i, x: $0) }
                            axis("y", pts[i].y) { writePoint(cls, i, y: $0) }
                            axis("z", pts[i].z) { writePoint(cls, i, z: $0) }
                        }
                    }
                }
            }
        }
    }

    private func axis(_ name: String, _ value: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            NumberField(value: value, range: -32768...32767, stepper: false, width: 58, onSet: set)
        }
    }

    private var compression: some View {
        SpecSection(title: "Perspective compression", trailing: "% — 100 = none; squishes points of a ¾-view hull") {
            VStack(spacing: 5) {
                InlineStat(model: model, key: key, field: "upCompressX", label: "Facing up, x")
                InlineStat(model: model, key: key, field: "upCompressY", label: "Facing up, y")
                InlineStat(model: model, key: key, field: "downCompressX", label: "Facing down, x")
                InlineStat(model: model, key: key, field: "downCompressY", label: "Facing down, y")
            }
        }
    }
}
#endif
