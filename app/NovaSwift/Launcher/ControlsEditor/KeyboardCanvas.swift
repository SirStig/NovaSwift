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
            // The board's panel is a quarter-unit larger on every side; fit that
            // whole panel and pin it to the top so nothing floats in empty space.
            let unit = max(8, min(geo.size.width / (layout.size.width + 0.5),
                                  geo.size.height / (layout.size.height + 0.5), 140))
            let panelW = (layout.size.width + 0.5) * unit, panelH = (layout.size.height + 0.5) * unit
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: unit * 0.35, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: unit * 0.35, style: .continuous)
                        .strokeBorder(.white.opacity(0.08)))
                    .frame(width: panelW, height: panelH)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.keys) { cap in
                        capView(cap, unit: unit)
                    }
                }
                .frame(width: layout.size.width * unit, height: layout.size.height * unit, alignment: .topLeading)
                .offset(x: unit * 0.25, y: unit * 0.25)
            }
            .frame(width: panelW, height: panelH, alignment: .topLeading)
            .position(x: geo.size.width / 2, y: panelH / 2)
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
                .padding(EdgeInsets(top: unit * 0.07, leading: unit * 0.08, bottom: unit * 0.13, trailing: unit * 0.06))
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
        .help(locked ? "The original reserves this key (the Escort Commands group keys 1–4, Caps Lock and F1–F5 can't be captured), so it keeps its fixed role." : (cap.frame.height < 0.9 ? (action?.title ?? "") : ""))
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

    /// One name size for the whole board (derived from the unit), so "Menu" and
    /// "Fire 2" read alike. Names live below a reserved legend band and never
    /// share pixels with the legend; half-height keys drop the name and keep
    /// legend + tint (the full title is in the tooltip).
    private var legendAndName: some View {
        let faceH = cap.frame.height * unit - unit * 0.15
        let half = cap.frame.height < 0.9
        return Group {
            if let action, !half {
                VStack(spacing: 0) {
                    Text(cap.legend)
                        .font(.system(size: min(unit * 0.19, faceH * 0.24), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: faceH * 0.30, alignment: .topLeading)
                    Text(action.shortName)
                        .font(.system(size: max(8, unit * 0.165), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                Text(cap.legend)
                    .font(.system(size: half ? max(9, unit * 0.24) : unit * (cap.legend.count > 2 ? 0.19 : 0.25),
                                  weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(action == nil ? 0.8 : 0.95))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: action == nil && cap.legend.count <= 2 ? .center : .topLeading)
            }
        }
    }
}
