import SwiftUI
import GameController

/// The radial menu drawn while an action wheel is held open (see
/// `GameControllerInput`). Purely a display of `ActionWheelState`: it is never
/// hit-testable and registers no cursor targets — the right stick picks the
/// slot and releasing the trigger fires it. The game keeps running behind it.
struct ActionWheelOverlay: View {
    /// True while flight owns the pad; the wheel never shows over a menu.
    let isFlying: Bool

    @ObservedObject private var state = ActionWheelState.shared
    @ObservedObject private var padState = PadState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if isFlying, let wheel = state.openWheel {
                // Low on the trigger's side, clear of the ship at screen centre.
                let d = min(320, min(geo.size.width, geo.size.height) * 0.52)
                let margin = max(24, min(geo.size.width, geo.size.height) * 0.05)
                let x = wheel.opensOnRight ? geo.size.width - margin - d / 2 : margin + d / 2
                let y = max(d / 2 + margin, geo.size.height - margin - d / 2)
                WheelFace(wheel: wheel, highlighted: state.highlighted, diameter: d, cancelGlyph: cancelGlyph)
                    .frame(width: d, height: d)
                    .position(x: x, y: y)
                    .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.92, anchor: wheel.opensOnRight ? .bottomTrailing : .bottomLeading)
                            .combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.openWheel?.id)
        .allowsHitTesting(false)
    }

    /// The connected pad's own symbol for Ⓑ, else its name.
    private var cancelGlyph: AnyView {
        let pad = padState.pad
        if let name = PadButton.buttonB.symbolName(on: pad) {
            return AnyView(Image(systemName: name).foregroundStyle(novaAmber))
        }
        return AnyView(Text(PadButton.buttonB.displayName(on: pad)).foregroundStyle(novaAmber))
    }
}

private struct WheelFace: View {
    let wheel: ActionWheel
    let highlighted: Int?
    let diameter: CGFloat
    let cancelGlyph: AnyView

    private var count: Int { max(1, wheel.slots.count) }
    private var step: Double { 2 * .pi / Double(count) }
    private var outer: CGFloat { diameter / 2 }
    private var inner: CGFloat { outer * 0.38 }

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.6))
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18)

            ForEach(Array(wheel.slots.enumerated()), id: \.offset) { i, action in
                let on = highlighted == i
                WedgeShape(index: i, count: count, inner: inner * 1.02, outer: outer * (on ? 1.0 : 0.97))
                    .fill(on ? novaAmber.opacity(0.92) : Color.white.opacity(0.06))
                    .overlay(WedgeShape(index: i, count: count, inner: inner * 1.02, outer: outer * (on ? 1.0 : 0.97))
                        .stroke(.white.opacity(on ? 0.5 : 0.1), lineWidth: 1))
                    .scaleEffect(on ? 1.05 : 1, anchor: .center)
                    .zIndex(on ? 1 : 0)
                slotLabel(action, index: i, on: on)
            }

            hub
        }
        .animation(.easeOut(duration: 0.08), value: highlighted)
    }

    private func slotLabel(_ action: GameAction, index: Int, on: Bool) -> some View {
        let a = Double(index) * step
        let r = (inner + outer) / 2 * (on ? 1.05 : 1)
        return VStack(spacing: 2) {
            Image(systemName: action.icon)
                .font(.system(size: diameter * 0.065, weight: .semibold))
            Text(action.shortName)
                .font(.system(size: max(8, diameter * 0.03), weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
        .frame(width: diameter * 0.2)
        .offset(x: CGFloat(sin(a)) * r, y: -CGFloat(cos(a)) * r)
    }

    /// Centre hub: wheel name, what releasing will do, and the controls hint.
    private var hub: some View {
        let picked = highlighted.flatMap { wheel.slots.indices.contains($0) ? wheel.slots[$0] : nil }
        return VStack(spacing: 3) {
            Text(wheel.title.uppercased())
                .font(.system(size: max(8, diameter * 0.028), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(novaAmber)
            Text(picked?.title ?? "Flick the right stick")
                .font(.system(size: max(10, diameter * 0.04), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            HStack(spacing: 3) {
                Text("Release to use ·")
                cancelGlyph
                Text("cancel")
            }
            .font(.system(size: max(8, diameter * 0.026), weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: inner * 1.7)
    }
}

/// An annular sector centred on slot `index` (slot 0 at the top, clockwise),
/// sized to fill the wheel's square frame. Flattened to line segments so the
/// y-down arc-direction quirks of `addArc` never come into it.
private struct WedgeShape: Shape {
    let index: Int, count: Int
    let inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let step = 2 * Double.pi / Double(count)
        let gap = 0.012                      // hairline between wedges
        let a0 = Double(index) * step - step / 2 + gap
        let a1 = Double(index) * step + step / 2 - gap
        let n = 16
        func pt(_ a: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: c.x + CGFloat(sin(a)) * r, y: c.y - CGFloat(cos(a)) * r)
        }
        var p = Path()
        p.move(to: pt(a0, outer))
        for k in 1...n { p.addLine(to: pt(a0 + (a1 - a0) * Double(k) / Double(n), outer)) }
        for k in 0...n { p.addLine(to: pt(a1 - (a1 - a0) * Double(k) / Double(n), inner)) }
        p.closeSubpath()
        return p
    }
}
