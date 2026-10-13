import SwiftUI
import GameController

/// A path authored in millimetres, scaled to points and shifted so `origin`
/// (the art's top-left, in mm) lands at the view's top-left.
private struct ArtPath: Shape {
    let source: Path
    let scale: CGFloat
    let origin: CGPoint
    func path(in rect: CGRect) -> Path {
        source.applying(CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
    }
}

/// Type erasure that keeps `strokeBorder` (an inset stroke, so highlights never
/// spill past the control's own outline).
private struct AnyInsettableShape: InsettableShape {
    private let build: (CGRect, CGFloat) -> Path
    private var inset: CGFloat = 0
    init<S: InsettableShape>(_ shape: S) { build = { rect, amount in shape.inset(by: amount).path(in: rect) } }
    func path(in rect: CGRect) -> Path { build(rect, inset) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { var s = self; s.inset += amount; return s }
}

/// The d-pad plate: one cross (two overlapping bars), not four squares.
private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let t = rect.width * 0.34, r = t * 0.3
        var p = Path()
        p.addRoundedRect(in: CGRect(x: rect.midX - t / 2, y: rect.minY, width: t, height: rect.height),
                         cornerSize: CGSize(width: r, height: r))
        p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.midY - t / 2, width: rect.width, height: t),
                         cornerSize: CGSize(width: r, height: r))
        return p
    }
}

/// A control's own outline (also its hit shape). `mm` = points per millimetre.
private func rimShape(_ c: PadControl, mm: CGFloat) -> AnyInsettableShape {
    switch c.kind {
    case .round, .stick: return AnyInsettableShape(Circle())
    case .pill, .bumper: return AnyInsettableShape(Capsule())
    case .dpadArm: return AnyInsettableShape(RoundedRectangle(cornerRadius: 1.2 * mm, style: .continuous))
    case .trigger:
        let big = 9 * mm, small = 3 * mm, foot = 2 * mm
        return AnyInsettableShape(c.mirrored
            ? UnevenRoundedRectangle(topLeadingRadius: small, bottomLeadingRadius: foot, bottomTrailingRadius: foot, topTrailingRadius: big, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: foot, bottomTrailingRadius: foot, topTrailingRadius: small, style: .continuous))
    }
}

/// One margin label in the callout columns.
private struct Callout: Identifiable {
    let id: String
    let button: PadButton?          // nil = a greyed, unpressable note
    let side: PadSide
    let anchor: CGPoint             // mm
    let title: String
    let caption: String
    let tint: Color?
    let bound: Bool
}

// MARK: - Segment intersection (leader crossing check)

/// Twice the signed area of triangle abc: >0 when c is left of a→b.
private func orient(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

/// True when segments p1–p2 and p3–p4 properly cross (touching at a shared
/// endpoint or running collinear doesn't count).
private func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
    let d1 = orient(p3, p4, p1), d2 = orient(p3, p4, p2)
    let d3 = orient(p1, p2, p3), d4 = orient(p1, p2, p4)
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

/// Do two elbow leaders (each label → gutter → anchor) cross?
private func leadersCross(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
    for i in 0..<(a.count - 1) {
        for j in 0..<(b.count - 1) where segmentsCross(a[i], a[i + 1], b[j], b[j + 1]) { return true }
    }
    return false
}

/// Shrink a shell toward a point just above its centre. A normal inset pinches
/// the grip valley; this scale stays one simple polygon. Distances are millimetres.
private func insetPath(_ source: Path, dist: CGFloat) -> Path {
    let bb = source.boundingRect
    let c = CGPoint(x: bb.midX, y: bb.midY - bb.height * 0.05)
    let kx = min(0.985, max(0.86, 1 - dist / max(8, bb.width * 0.5)))
    let ky = min(0.985, max(0.86, 1 - dist / max(8, bb.height * 0.5)))
    let transform = CGAffineTransform(a: kx, b: 0, c: 0, d: ky,
                                      tx: (1 - kx) * c.x,
                                      ty: (c.y - 0.35) - ky * c.y)
    return source.applying(transform)
}

/// The drawn controller with Steam-style callouts: the silhouette near the top
/// of the canvas, every control a cursor-pressable hit target, and an elbow
/// leader from each control to a label in the left/right margin.
struct ControllerCanvas: View {
    let style: PadStyle
    let bindings: PadBindings
    /// The connected pad when it is of this style's family — its own control
    /// names then label the callouts.
    let livePad: GCExtendedGamepad?
    let pressed: Set<PadButton>
    let selectedButton: PadButton?
    let selectedAction: GameAction?
    let hoveredAction: GameAction?
    let onHover: (PadButton?) -> Void
    let onTap: (PadButton) -> Void

    var body: some View {
        GeometryReader { geo in
            let art = style.art
            let b = art.bounds
            let labelW = min(190, max(96, geo.size.width * 0.17))
            let gutter: CGFloat = 40
            // Fit the pad (triggers included) between the label columns; top-aligned.
            let s = max(1, min((geo.size.width - 2 * (labelW + gutter)) / b.width, (geo.size.height - 8) / b.height))
            let ox = (geo.size.width - b.width * s) / 2 - b.minX * s
            let oy = 4 - b.minY * s
            ZStack(alignment: .topLeading) {
                artLayer(art, bounds: b, s: s)
                    .frame(width: b.width * s, height: b.height * s, alignment: .topLeading)
                    .offset(x: ox + b.minX * s, y: oy + b.minY * s)
                calloutLayer(art, s: s, origin: CGPoint(x: ox, y: oy), labelW: labelW, size: geo.size)
            }
        }
    }

    // MARK: Art

    private func artLayer(_ art: PadArt, bounds b: CGRect, s: CGFloat) -> some View {
        let origin = b.origin
        let bodyShape = ArtPath(source: art.body, scale: s, origin: origin)
        let caseShape = ArtPath(source: insetPath(art.body, dist: 3.6), scale: s, origin: origin)
        let lipShape = ArtPath(source: insetPath(art.body, dist: 1.15), scale: s, origin: origin)
        let inside = art.decor.filter { !$0.spills }
        let outside = art.decor.filter(\.spills)
        return ZStack(alignment: .topLeading) {
            // Triggers and bumpers sit behind the shell, so the body covers their lower half.
            ForEach(art.controls.filter(\.isTrigger)) { c in
                controlView(c, bounds: b, s: s)
            }
            ForEach(art.controls.filter(\.isBumper)) { c in
                controlView(c, bounds: b, s: s)
            }
            bodyShape
                .fill(art.bodyBottom)
                .overlay(bodyShape.fill(Color.black.opacity(0.35)))
                .offset(y: 3.4 * s)
                .allowsHitTesting(false)
            bodyShape
                .fill(LinearGradient(colors: [art.bodyTop, art.bodyBottom], startPoint: .top, endPoint: .bottom))
                .overlay(bodyShape.stroke(Color.white.opacity(0.28), lineWidth: max(1, 0.9 * s)))
                .allowsHitTesting(false)
            caseShape
                .fill(LinearGradient(colors: [art.caseTop, art.caseBottom], startPoint: .top, endPoint: .bottom))
                .overlay(caseShape.stroke(Color.black.opacity(0.28), lineWidth: max(0.6, 0.7 * s)))
                .allowsHitTesting(false)
            lipShape
                .stroke(Color.white.opacity(0.16), lineWidth: max(0.5, 0.55 * s))
                .allowsHitTesting(false)
            ZStack(alignment: .topLeading) {
                ForEach(inside) { decorView($0, bounds: b, s: s) }
            }
            .mask(bodyShape)
            .allowsHitTesting(false)
            ForEach(outside) { decorView($0, bounds: b, s: s) }
                .allowsHitTesting(false)
            ForEach(art.controls.filter { !$0.isShoulder }) { c in controlView(c, bounds: b, s: s) }
            // Shoulder names paint after the shell, so the body doesn't slice them.
            ForEach(art.controls.filter(\.isShoulder)) { c in
                Text(c.glyph)
                    .font(.system(size: (c.isTrigger ? 3.4 : 3.2) * s, weight: .bold, design: .rounded))
                    .foregroundStyle(c.glyphColor)
                    .rotationEffect(.degrees(c.rotation))
                    .position(x: (c.center.x - b.minX) * s, y: (c.center.y - b.minY) * s)
                    .allowsHitTesting(false)
            }
        }
    }

    private func decorView(_ d: PadDecor, bounds b: CGRect, s: CGFloat) -> some View {
        let fill = LinearGradient(colors: [d.top, d.bottom], startPoint: .top, endPoint: .bottom)
        let dash: [CGFloat] = d.dashed ? [4, 3] : []
        return ZStack {
            switch d.kind {
            case .circle:
                Circle().fill(fill)
                Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.14)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: max(1, 0.5 * s))
            case .roundRect(let r):
                RoundedRectangle(cornerRadius: r * s, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: r * s, style: .continuous)
                    .strokeBorder(.white.opacity(d.dashed ? 0.2 : 0.1), style: StrokeStyle(lineWidth: max(1, 0.35 * s), dash: dash))
            case .cross:
                CrossShape().fill(fill)
                CrossShape().stroke(.black.opacity(0.5), lineWidth: max(1, 0.35 * s))
            }
            if let label = d.label {
                Text(label).font(.system(size: max(7, 3.4 * s), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: d.rect.width * s, height: d.rect.height * s)
        .position(x: (d.rect.midX - b.minX) * s, y: (d.rect.midY - b.minY) * s)
    }

    // MARK: Controls

    private func controlView(_ c: PadControl, bounds b: CGRect, s: CGFloat) -> some View {
        let action = bindings.action(for: c.button)
        let view = PadControlView(
            control: c, mm: s, categoryTint: action?.tint,
            pressed: pressed.contains(c.button), selected: selectedButton == c.button,
            pulsing: selectedAction.map { bindings.button(for: $0) == c.button } ?? false,
            hot: hoveredAction.map { bindings.button(for: $0) == c.button } ?? false)
            .frame(width: c.size.width * s, height: c.size.height * s)
            .rotationEffect(.degrees(c.rotation))
        return CursorButton { onTap(c.button) } label: { view.contentShape(rimShape(c, mm: s)) }
            .editorHover { onHover($0 ? c.button : nil) }
            .accessibilityLabel(Text("\(style.name(c.button)), \(action?.title ?? "unbound")"))
            .position(x: (c.center.x - b.minX) * s, y: (c.center.y - b.minY) * s)
    }

    // MARK: Callouts

    /// Where a leader meets a control (mm): the edge facing its label column —
    /// never the centre, which carries the glyph.
    private func anchor(of c: PadControl) -> CGPoint {
        let dir: CGFloat = c.side == .left ? -1 : 1
        let w = c.size.width, h = c.size.height
        switch c.kind {
        case .round, .stick, .pill:
            return CGPoint(x: c.center.x + dir * w / 2, y: c.center.y)
        case .bumper:
            let dx = dir * w * 0.46
            return CGPoint(x: c.center.x + dx, y: c.center.y + dx * CGFloat(sin(c.rotation * .pi / 180)))
        case .trigger:
            // The part that shows above the bumper.
            return CGPoint(x: c.center.x + dir * w * 0.44, y: c.center.y - h * 0.38)
        case .dpadArm(let d):
            switch d {
            case .up: return CGPoint(x: c.center.x, y: c.center.y - h / 2)
            case .down: return CGPoint(x: c.center.x, y: c.center.y + h / 2)
            case .left, .right:
                let outward = (d == .left) == (c.side == .left)
                // The arm facing the label is reached at its end; the other one over its top edge.
                return outward ? CGPoint(x: c.center.x + (d == .left ? -w / 2 : w / 2), y: c.center.y)
                               : CGPoint(x: c.center.x, y: c.center.y - h / 2)
            }
        }
    }

    private func callouts(_ art: PadArt) -> [Callout] {
        var out: [Callout] = art.controls.map { c in
            let action = bindings.action(for: c.button)
            var caption = livePad.map { c.button.displayName(on: $0) } ?? style.name(c.button)
            if let role = c.fixedRole { caption += " · stick: \(role)" }
            return Callout(id: c.id, button: c.button, side: c.side, anchor: anchor(of: c),
                           title: action?.title ?? "Unbound", caption: caption,
                           tint: action?.tint, bound: action != nil)
        }
        out += art.notes.map {
            Callout(id: $0.id, button: nil, side: $0.side, anchor: $0.anchor, title: $0.text,
                    caption: "not bindable here", tint: nil, bound: false)
        }
        return out
    }

    private func calloutLayer(_ art: PadArt, s: CGFloat, origin: CGPoint, labelW: CGFloat, size: CGSize) -> some View {
        let items = callouts(art)
        let body = art.body.boundingRect
        let rowH: CGFloat = 40, gap: CGFloat = 5
        func scr(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * s, y: origin.y + p.y * s) }
        // Leaders run horizontally from the label to a gutter just outside the
        // body, then straight to the anchor.
        let gutterL = origin.x + body.minX * s - 12, gutterR = origin.x + body.maxX * s + 12
        let labelEdgeL = gutterL - 24, labelEdgeR = gutterR + 24
        let top = rowH / 2 + 4
        let bottom = max(top, min(size.height - rowH / 2 - 2, origin.y + art.bounds.maxY * s))

        func place(_ side: PadSide) -> [(Callout, CGFloat)] {
            let isLeft = side == .left
            let sorted = items.filter { $0.side == side }.sorted {
                $0.anchor.y != $1.anchor.y ? $0.anchor.y < $1.anchor.y : ($0.anchor.x != $1.anchor.x ? $0.anchor.x < $1.anchor.x : $0.id < $1.id)
            }
            let n = sorted.count
            guard n > 0 else { return [] }
            let span = max(bottom - top, CGFloat(n - 1) * (rowH + gap))
            let ys: [CGFloat] = (0..<n).map { n > 1 ? top + CGFloat($0) * span / CGFloat(n - 1) : top }
            func line(_ item: Callout, _ y: CGFloat) -> [CGPoint] {
                [CGPoint(x: isLeft ? labelEdgeL : labelEdgeR, y: y), CGPoint(x: isLeft ? gutterL : gutterR, y: y), scr(item.anchor)]
            }
            // order[slot] = index into `sorted`; swap slots until no two leaders cross.
            var order = Array(0..<n)
            for _ in 0..<200 {
                var pair: (Int, Int)?
                search: for a in 0..<n {
                    for c in (a + 1)..<max(n, a + 1) where leadersCross(line(sorted[order[a]], ys[a]), line(sorted[order[c]], ys[c])) {
                        pair = (a, c)
                        break search
                    }
                }
                guard let pair else { break }
                order.swapAt(pair.0, pair.1)
            }
            return (0..<n).map { (sorted[order[$0]], ys[$0]) }
        }
        let placed = place(.left) + place(.right)

        return ZStack(alignment: .topLeading) {
            ForEach(placed, id: \.0.id) { item, y in
                let isLeft = item.side == .left
                let a = scr(item.anchor)
                let active = item.button != nil && (item.button == selectedButton
                    || item.button == selectedAction.flatMap { bindings.button(for: $0) }
                    || item.button == hoveredAction.flatMap { bindings.button(for: $0) })
                Path { p in
                    p.move(to: CGPoint(x: isLeft ? labelEdgeL : labelEdgeR, y: y))
                    p.addLine(to: CGPoint(x: isLeft ? gutterL : gutterR, y: y))
                    p.addLine(to: a)
                }
                .stroke(active ? novaAmber : .white.opacity(item.button == nil ? 0.18 : 0.34),
                        style: StrokeStyle(lineWidth: active ? 2 : 1, lineCap: .round, lineJoin: .round,
                                           dash: item.button == nil ? [3, 3] : []))
                .allowsHitTesting(false)
                Circle().fill(active ? novaAmber : (item.tint ?? .white.opacity(0.6)))
                    .frame(width: 6, height: 6).position(a).allowsHitTesting(false)
                calloutLabel(item, isLeft: isLeft, width: labelW, height: rowH, active: active)
                    .position(x: isLeft ? labelEdgeL - labelW / 2 : labelEdgeR + labelW / 2, y: y)
            }
        }
    }

    @ViewBuilder
    private func calloutLabel(_ item: Callout, isLeft: Bool, width: CGFloat, height: CGFloat, active: Bool) -> some View {
        let content = VStack(alignment: isLeft ? .trailing : .leading, spacing: 1) {
            Text(item.title)
                .novaFont(.caption, weight: .semibold)
                .foregroundStyle(item.bound ? Color.white : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(item.caption)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height, alignment: isLeft ? .trailing : .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(active ? novaAmber.opacity(0.16) : Color.white.opacity(item.button == nil ? 0.02 : 0.06)))
        .overlay(alignment: isLeft ? .trailing : .leading) {
            if let tint = item.tint {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? novaAmber : .white.opacity(0.1)))
        if let button = item.button {
            CursorButton { onTap(button) } label: { content.contentShape(Rectangle()) }
                .editorHover { onHover($0 ? button : nil) }
        } else {
            content
        }
    }
}

// MARK: - One control

private struct PadControlView: View {
    let control: PadControl
    /// Points per millimetre.
    let mm: CGFloat
    /// Category of the bound action; tints the control itself.
    let categoryTint: Color?
    let pressed: Bool
    let selected: Bool
    let pulsing: Bool
    let hot: Bool

    @State private var pulse = false

    var body: some View {
        let rim = rimShape(control, mm: mm)
        ZStack {
            face
            // Bound = the control itself takes its category's colour.
            if let categoryTint { rim.fill(categoryTint.opacity(0.42)) }
            if pressed { rim.fill(.white.opacity(0.5)) }
            if selected || hot || pulsing {
                // Inset stroke: never outside the control's own outline.
                rim.strokeBorder(selected ? novaAmber : (categoryTint ?? novaAmber), lineWidth: 2)
                    .opacity(pulsing && !selected ? (pulse ? 1 : 0.25) : 1)
            }
        }
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .onAppear { updatePulse() }
        .onChange(of: pulsing) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        if pulsing {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(nil) { pulse = false }
        }
    }

    private var plastic: LinearGradient {
        LinearGradient(colors: [Color(white: 0.36), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
    }

    private var line: CGFloat { max(1, 0.35 * mm) }

    @ViewBuilder
    private var face: some View {
        let w = control.size.width * mm, h = control.size.height * mm
        switch control.kind {
        case .round:
            ZStack {
                Circle().fill(control.fill.map { AnyShapeStyle(LinearGradient(colors: [$0, $0.opacity(0.7)], startPoint: .top, endPoint: .bottom)) }
                              ?? AnyShapeStyle(plastic))
                // Dome: a soft highlight up-left.
                Circle().fill(RadialGradient(colors: [.white.opacity(0.38), .clear], center: UnitPoint(x: 0.35, y: 0.28),
                                             startRadius: 0, endRadius: w * 0.55))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .black.opacity(0.45)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: line)
                if let symbol = control.symbol {
                    Image(systemName: symbol).font(.system(size: w * 0.48, weight: .bold)).foregroundStyle(control.glyphColor)
                } else {
                    Text(control.glyph).font(.system(size: w * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(control.glyphColor)
                }
            }
        case .stick:
            ZStack {
                // Concave cap: darker in the middle, lit rim, highlight at the top-left lip.
                Circle().fill(RadialGradient(colors: [Color(white: 0.12), Color(white: 0.34)], center: .center,
                                             startRadius: 0, endRadius: w * 0.5))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.6)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: line * 1.4)
                Circle().inset(by: w * 0.2).stroke(.white.opacity(0.1), lineWidth: line)
                Text(control.button == .leftThumbstickButton ? "L3" : "R3")
                    .font(.system(size: w * 0.26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        case .pill:
            let cap = control.fill ?? Color(white: 0.22)
            ZStack {
                Capsule().fill(LinearGradient(colors: [cap, cap.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(.white.opacity(0.3), lineWidth: line)
                if let symbol = control.symbol {
                    Image(systemName: symbol).font(.system(size: h * 0.7, weight: .bold)).foregroundStyle(control.glyphColor)
                }
            }
        case .bumper:
            let cap = control.fill ?? Color(white: 0.36)
            ZStack {
                Capsule().fill(LinearGradient(colors: [cap, cap.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(Color.white.opacity(0.32), lineWidth: line)
            }
        case .trigger:
            let cap = control.fill ?? Color(white: 0.24)
            let shape = rimShape(control, mm: mm)
            ZStack {
                shape.fill(LinearGradient(colors: [cap, cap.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: line)
            }
        case .dpadArm(let dir):
            // The cross is one decor plate; the arm only carries its arrow.
            Image(systemName: dpadSymbol(dir)).font(.system(size: min(w, h) * 0.38, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func dpadSymbol(_ dir: PadControl.DpadDir) -> String {
        switch dir {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case .left: return "arrowtriangle.left.fill"
        case .right: return "arrowtriangle.right.fill"
        }
    }
}
