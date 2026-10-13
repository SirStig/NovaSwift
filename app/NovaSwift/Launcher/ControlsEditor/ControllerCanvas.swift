import SwiftUI
import GameController

/// Scales a path authored in the 1000×640 art space to whatever rect it is given.
private struct ArtShape: Shape {
    let source: Path
    func path(in rect: CGRect) -> Path {
        source.applying(CGAffineTransform(scaleX: rect.width / PadArt.canvas.width,
                                          y: rect.height / PadArt.canvas.height))
    }
}

/// One margin label in the callout columns.
private struct Callout: Identifiable {
    let id: String
    let button: PadButton?          // nil = a greyed, unpressable note
    let side: PadSide
    let anchor: CGPoint             // art space
    let title: String
    let caption: String
    let tint: Color?
    let bound: Bool
}

/// The drawn controller with Steam-style callouts: the silhouette centred, every
/// control a cursor-pressable hit target, and a leader line from each control
/// out to a label in the left/right margin naming the bound action.
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
            let labelW = min(190, max(96, geo.size.width * 0.18))
            let gutter: CGFloat = 16
            let b = art.bounds
            let s = max(0.2, min((geo.size.width - 2 * (labelW + gutter)) / b.width,
                                 (geo.size.height - 8) / b.height))
            let artW = PadArt.canvas.width * s, artH = PadArt.canvas.height * s
            // Centre the drawn bounds (not the whole authoring grid) in the canvas.
            let ox = (geo.size.width - b.width * s) / 2 - b.minX * s
            let oy = (geo.size.height - b.height * s) / 2 - b.minY * s
            ZStack(alignment: .topLeading) {
                artLayer(art, s: s)
                    .frame(width: artW, height: artH)
                    .offset(x: ox, y: oy)
                calloutLayer(art, s: s, origin: CGPoint(x: ox, y: oy), bounds: b, labelW: labelW, gutter: gutter,
                             size: geo.size)
            }
        }
    }

    // MARK: Art

    private func artLayer(_ art: PadArt, s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(art.controls.filter(\.behindBody)) { control in controlView(control, s: s) }
            ArtShape(source: art.body)
                .fill(LinearGradient(colors: [art.bodyTop, art.bodyBottom], startPoint: .top, endPoint: .bottom))
                .overlay(ArtShape(source: art.body)
                    .fill(LinearGradient(colors: [.white.opacity(0.20), .clear],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))))
                .overlay(ArtShape(source: art.body)
                    .stroke(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.4)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: max(1, 3 * s)))
                .overlay(ArtShape(source: art.body).stroke(.black.opacity(0.45), lineWidth: 16 * s).blur(radius: 8 * s)
                    .clipShape(ArtShape(source: art.body)))
                .shadow(color: .black.opacity(0.55), radius: 16 * s, y: 12 * s)
                .allowsHitTesting(false)
            ForEach(art.decor) { decor in decorView(decor, s: s) }
            ForEach(art.controls.filter { !$0.behindBody }) { control in controlView(control, s: s) }
        }
    }

    private func decorView(_ d: PadDecor, s: CGFloat) -> some View {
        let fill = LinearGradient(colors: [d.top, d.bottom], startPoint: .top, endPoint: .bottom)
        return ZStack {
            switch d.kind {
            case .circle:
                Circle().fill(fill)
                Circle().strokeBorder(.black.opacity(0.5), style: StrokeStyle(lineWidth: max(1, 2 * s), dash: d.dashed ? [5, 4] : []))
            case .roundRect(let r):
                RoundedRectangle(cornerRadius: r * s, style: .continuous).fill(fill)
                RoundedRectangle(cornerRadius: r * s, style: .continuous)
                    .strokeBorder(.white.opacity(d.dashed ? 0.18 : 0.1), style: StrokeStyle(lineWidth: max(1, 1.5 * s), dash: d.dashed ? [5, 4] : []))
            }
            if let label = d.label {
                Text(label).font(.system(size: max(7, 17 * s), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: d.rect.width * s, height: d.rect.height * s)
        .offset(x: d.rect.minX * s, y: d.rect.minY * s)
        .allowsHitTesting(false)
    }

    // MARK: Controls

    private func boundAction(_ b: PadButton) -> GameAction? { bindings.action(for: b) }

    private func controlView(_ c: PadControl, s: CGFloat) -> some View {
        let action = boundAction(c.button)
        let view = PadControlView(
            control: c, scale: s, categoryTint: action?.tint,
            pressed: pressed.contains(c.button), selected: selectedButton == c.button,
            pulsing: selectedAction.map { bindings.button(for: $0) == c.button } ?? false,
            hot: hoveredAction.map { bindings.button(for: $0) == c.button } ?? false)
            .frame(width: c.size.width * s, height: c.size.height * s)
        return CursorButton { onTap(c.button) } label: { view.contentShape(Rectangle()) }
            .editorHover { onHover($0 ? c.button : nil) }
            .accessibilityLabel(Text("\(style.name(c.button)), \(action?.title ?? "unbound")"))
            .offset(x: c.frame.minX * s, y: c.frame.minY * s)
    }

    // MARK: Callouts

    private func calloutLayer(_ art: PadArt, s: CGFloat, origin: CGPoint, bounds: CGRect, labelW: CGFloat,
                              gutter: CGFloat, size: CGSize) -> some View {
        let items = callouts(art)
        let artLeft = origin.x + bounds.minX * s, artRight = origin.x + bounds.maxX * s
        let rowH: CGFloat = 40, gap: CGFloat = 5
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * s, y: origin.y + p.y * s) }

        // Stack each side's labels top to bottom, never closer than a row, and
        // pull the pile back up if it would run off the bottom.
        func place(_ side: PadSide) -> [(Callout, CGFloat)] {
            let sorted = items.filter { $0.side == side }.sorted { $0.anchor.y < $1.anchor.y }
            // Spread evenly over the pad's height (never tighter than a row), so
            // sorted-by-anchor labels give leaders that fan out without crossing.
            let top = origin.y + bounds.minY * s, span = max(bounds.height * s, CGFloat(sorted.count) * (rowH + gap))
            let step = sorted.count > 1 ? (span - rowH) / CGFloat(sorted.count - 1) : 0
            var ys = sorted.indices.map { sorted.count > 1 ? top + rowH / 2 + CGFloat($0) * step : screen(sorted[$0].anchor).y }
            let overflow = (ys.last ?? 0) + rowH / 2 + 2 - size.height
            if overflow > 0 { ys = ys.map { $0 - overflow } }
            return Array(zip(sorted, ys))
        }
        let left = place(.left), right = place(.right)

        return ZStack(alignment: .topLeading) {
            ForEach(left + right, id: \.0.id) { item, y in
                let isLeft = item.side == .left
                let edgeX = isLeft ? artLeft - gutter : artRight + gutter
                let a = screen(item.anchor)
                let active = item.button != nil && (item.button == selectedButton
                    || item.button == selectedAction.flatMap { bindings.button(for: $0) }
                    || item.button == hoveredAction.flatMap { bindings.button(for: $0) })
                Path { p in
                    p.move(to: CGPoint(x: edgeX, y: y))
                    p.addLine(to: CGPoint(x: edgeX + (isLeft ? 12 : -12), y: y))
                    p.addLine(to: a)
                }
                .stroke(active ? novaAmber : .white.opacity(item.button == nil ? 0.16 : 0.32),
                        style: StrokeStyle(lineWidth: active ? 2 : 1, lineCap: .round, lineJoin: .round,
                                           dash: item.button == nil ? [3, 3] : []))
                .allowsHitTesting(false)
                Circle().fill(active ? novaAmber : (item.tint ?? .white.opacity(0.5)))
                    .frame(width: 7, height: 7).position(a).allowsHitTesting(false)
                calloutLabel(item, isLeft: isLeft, width: labelW, height: rowH, active: active)
                    .position(x: isLeft ? edgeX - labelW / 2 : edgeX + labelW / 2, y: y)
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

    private func callouts(_ art: PadArt) -> [Callout] {
        var out: [Callout] = art.controls.map { c in
            let action = boundAction(c.button)
            var caption = livePad.map { c.button.displayName(on: $0) } ?? style.name(c.button)
            if let role = c.fixedRole { caption += " · stick: \(role)" }
            return Callout(id: c.id, button: c.button, side: c.side, anchor: anchor(of: c),
                           title: action?.title ?? "Unbound", caption: caption,
                           tint: action?.tint, bound: action != nil)
        }
        out += art.notes.map {
            Callout(id: $0.id.uuidString, button: nil, side: $0.side, anchor: $0.anchor, title: $0.text,
                    caption: "not bindable here", tint: nil, bound: false)
        }
        return out
    }

    /// Where a leader line meets a control: its edge facing the margin.
    private func anchor(of c: PadControl) -> CGPoint {
        switch c.kind {
        case .trigger, .bumper:
            return CGPoint(x: c.center.x + (c.side == .left ? -c.size.width * 0.38 : c.size.width * 0.38), y: c.center.y)
        default:
            return c.center
        }
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

// MARK: - One control

private struct PadControlView: View {
    let control: PadControl
    let scale: CGFloat
    /// Category of the bound action, drawn as a rim.
    let categoryTint: Color?
    let pressed: Bool
    let selected: Bool
    let pulsing: Bool
    let hot: Bool

    @State private var pulse = false

    private var isDpad: Bool { if case .dpadArm = control.kind { return true } else { return false } }

    var body: some View {
        ZStack {
            face
            if let categoryTint, !isDpad {
                rim.strokeBorder(categoryTint, lineWidth: max(2, 3 * scale)).opacity(0.95)
            }
            if pressed { rim.fill(.white.opacity(0.45)) }
            if selected || hot || pulsing {
                rim.strokeBorder(selected ? novaAmber : (categoryTint ?? novaAmber),
                                 lineWidth: max(2, 3 * scale))
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

    /// The control's outline, also its hit shape.
    private var rim: AnyInsettableShape {
        switch control.kind {
        case .round, .stick: return AnyInsettableShape(Circle())
        case .bumper: return AnyInsettableShape(RoundedRectangle(cornerRadius: 22 * scale, style: .continuous))
        case .trigger: return AnyInsettableShape(triggerShape)
        case .dpadArm: return AnyInsettableShape(RoundedRectangle(cornerRadius: 9 * scale, style: .continuous))
        }
    }

    private var triggerShape: UnevenRoundedRectangle {
        let big = 44 * scale, small = 12 * scale, foot = 8 * scale
        return control.mirrored
            ? UnevenRoundedRectangle(topLeadingRadius: small, bottomLeadingRadius: foot, bottomTrailingRadius: foot, topTrailingRadius: big, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: foot, bottomTrailingRadius: foot, topTrailingRadius: small, style: .continuous)
    }

    private var plastic: LinearGradient {
        LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var face: some View {
        switch control.kind {
        case .round:
            ZStack {
                Circle().fill(control.fill.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(1), $0.opacity(0.7)], startPoint: .top, endPoint: .bottom)) }
                              ?? AnyShapeStyle(plastic))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.35, y: 0.28),
                                             startRadius: 0, endRadius: 28 * scale))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.4)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: max(1, 2 * scale))
                if let symbol = control.symbol {
                    Image(systemName: symbol).font(.system(size: 17 * scale, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                } else {
                    Text(control.glyph).font(.system(size: 28 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(control.glyphColor)
                }
            }
        case .stick:
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.12)], center: .topLeading,
                                             startRadius: 2, endRadius: 80 * scale))
                Circle().strokeBorder(.black.opacity(0.6), lineWidth: max(1, 2 * scale))
                Circle().inset(by: 12 * scale).stroke(.white.opacity(0.14), lineWidth: max(1, 1.5 * scale))
                Circle().inset(by: 24 * scale).fill(RadialGradient(colors: [Color(white: 0.08), Color(white: 0.26)],
                                                                  center: .center, startRadius: 1, endRadius: 24 * scale))
                Text(control.glyph.isEmpty ? (control.button == .leftThumbstickButton ? "L3" : "R3") : control.glyph)
                    .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        case .bumper:
            ZStack {
                RoundedRectangle(cornerRadius: 22 * scale, style: .continuous).fill(plastic)
                RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: max(1, 1.5 * scale))
                Text(control.glyph).font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .trigger:
            ZStack {
                triggerShape.fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                triggerShape.strokeBorder(.white.opacity(0.28), lineWidth: max(1, 1.5 * scale))
                Text(control.glyph).font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8)).offset(y: -6 * scale)
            }
        case .dpadArm(let dir):
            ZStack {
                // The cross itself is one decor shape; an arm only tints when bound.
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill((categoryTint ?? .clear).opacity(0.38))
                Image(systemName: dpadSymbol(dir)).font(.system(size: 13 * scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
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
