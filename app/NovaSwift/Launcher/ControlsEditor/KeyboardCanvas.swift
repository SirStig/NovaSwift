import SwiftUI

/// A cap outline, usable as a clip and hit shape.
private struct CapShape: InsettableShape {
    let radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> CapShape {
        var s = self
        s.inset += amount
        return s
    }
}

/// The rendered keyboard: every key a rounded cap with a bevelled top face,
/// tinted by the category of the action bound on the visible layer.
struct KeyboardCanvas: View {
    let layout: KeyboardLayout
    let layer: KeyLayer
    /// Every stored token → the actions holding it.
    let holders: [String: [GameAction]]
    let selectedKey: String?
    /// The action armed for capture: its key pulses.
    let selectedAction: GameAction?
    let hoveredAction: GameAction?
    let conflicts: Set<GameAction>
    let onHover: (KeyCap?) -> Void
    let onTap: (KeyCap) -> Void

    var body: some View {
        GeometryReader { geo in
            let margin: CGFloat = 10
            let unit = max(8, min((geo.size.width - margin * 2) / layout.size.width,
                                  (geo.size.height - margin * 2) / layout.size.height, 140))
            let boardW = layout.size.width * unit, boardH = layout.size.height * unit
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: unit * 0.35, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: unit * 0.35, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
                    .frame(width: boardW + unit * 0.5, height: boardH + unit * 0.5)
                    .offset(x: -unit * 0.25, y: -unit * 0.25)
                ForEach(layout.keys) { cap in
                    capView(cap, unit: unit)
                }
            }
            .frame(width: boardW, height: boardH, alignment: .topLeading)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder
    private func capView(_ cap: KeyCap, unit: CGFloat) -> some View {
        let token = cap.token(on: layer)
        let actions = token.flatMap { holders[$0] } ?? []
        let otherLayers = KeyLayer.allCases.filter { $0 != layer }.contains { other in
            cap.token(on: other).flatMap { holders[$0] }?.isEmpty == false
        }
        let view = KeyCapView(
            cap: cap, unit: unit, actions: actions, layerAvailable: token != nil,
            otherLayerBound: otherLayers,
            locked: cap.isBindable && !KeyBindings.isCapturable(cap.token),
            selected: selectedKey == cap.id,
            pulsing: selectedAction.map { actions.contains($0) } ?? false,
            hot: hoveredAction.map { actions.contains($0) } ?? false,
            conflict: !conflicts.isDisjoint(with: actions))
            .frame(width: cap.frame.width * unit, height: cap.frame.height * unit)
        if cap.isBindable {
            CursorButton { onTap(cap) } label: {
                view.contentShape(CapShape(radius: unit * 0.12))
            }
            .editorHover { onHover($0 ? cap : nil) }
            .offset(x: cap.frame.minX * unit, y: cap.frame.minY * unit)
        } else {
            view.offset(x: cap.frame.minX * unit, y: cap.frame.minY * unit)
        }
    }
}

private struct KeyCapView: View {
    let cap: KeyCap
    let unit: CGFloat
    let actions: [GameAction]
    /// False when this layer can't bind the key (e.g. letters on Shift).
    let layerAvailable: Bool
    let otherLayerBound: Bool
    let locked: Bool
    let selected: Bool
    let pulsing: Bool
    let hot: Bool
    let conflict: Bool

    @State private var pulse = false

    private var action: GameAction? { actions.first }
    private var tint: Color? { action?.tint }

    var body: some View {
        let shape = CapShape(radius: unit * 0.14)
        let accent: Color = selected ? novaAmber : (tint ?? novaAmber)
        ZStack {
            // Side wall: the darker rim visible under the top face.
            shape.fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.04)],
                                      startPoint: .top, endPoint: .bottom))
            // Top face.
            shape.fill(faceGradient)
                .overlay(shape.fill(tint?.opacity(0.42) ?? .clear))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .padding(EdgeInsets(top: unit * 0.04, leading: unit * 0.07, bottom: unit * 0.11, trailing: unit * 0.07))
            if locked {
                hatch.clipShape(shape).padding(unit * 0.07)
            }
            legendAndName
                .padding(EdgeInsets(top: unit * 0.1, leading: unit * 0.13, bottom: unit * 0.17, trailing: unit * 0.13))
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: unit * 0.15)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(unit * 0.16)
            }
            if otherLayerBound {
                Circle().fill(novaAmber).frame(width: unit * 0.11, height: unit * 0.11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(unit * 0.15)
            }
            if conflict {
                shape.strokeBorder(.red, lineWidth: 2).padding(unit * 0.03)
            }
            if selected || hot || pulsing {
                shape.strokeBorder(accent.opacity(pulsing && !selected ? (pulse ? 1 : 0.3) : 0.95),
                                   lineWidth: selected ? 2.5 : 2)
            }
        }
        .padding(unit * 0.05)
        .opacity(cap.isBindable ? (layerAvailable ? 1 : 0.45) : 0.4)
        .help(locked ? "The original reserves this key (the Escort Commands group keys 1–4, Caps Lock and F1–F5 can't be captured), so it keeps its fixed role." : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(cap.legend.isEmpty ? "Space" : cap.legend), \(action?.title ?? "unbound")"))
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

    private var faceGradient: LinearGradient {
        let dim = cap.isBindable ? 1.0 : 0.7
        return LinearGradient(colors: [Color(white: 0.27 * dim), Color(white: 0.17 * dim)],
                              startPoint: .top, endPoint: .bottom)
    }

    private var hatch: some View {
        Canvas { ctx, size in
            var p = Path()
            var x = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += max(5, unit * 0.16)
            }
            ctx.stroke(p, with: .color(.white.opacity(0.09)), lineWidth: 1)
        }
    }

    /// Key legend top-left (small), bound action name centred (auto-shrinking, 2 lines).
    private var legendAndName: some View {
        ZStack {
            Text(cap.legend)
                .font(.system(size: unit * (cap.legend.count > 2 ? 0.19 : 0.25), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(action == nil ? 0.8 : 0.6))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: action == nil && cap.legend.count <= 2 ? .center : .topLeading)
            if let action {
                Text(actions.count > 1 ? action.shortName + " +" : action.shortName)
                    .font(.system(size: unit * 0.22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.45)
                    .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, unit * 0.14)
            }
        }
    }
}
