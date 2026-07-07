import SwiftUI

/// On-screen touch controls (the "virtual cockpit"): a turn pad on the left,
/// thrust + fire on the right. Press-and-hold semantics feed the shared
/// `InputController`. Works with touch and mouse alike.
struct TouchControlsOverlay: View {
    let input: InputController

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                turnPad
                Spacer()
                actionPad
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private var turnPad: some View {
        HStack(spacing: 16) {
            HoldButton(onChange: input.setTurnLeft) {
                ControlGlyph(system: "arrow.turn.up.left")
            }
            HoldButton(onChange: input.setTurnRight) {
                ControlGlyph(system: "arrow.turn.up.right")
            }
        }
    }

    private var actionPad: some View {
        HStack(spacing: 16) {
            HoldButton(onChange: input.setFirePrimary) {
                ControlGlyph(system: "flame.fill", tint: .orange)
            }
            HoldButton(onChange: input.setThrust) {
                ControlGlyph(system: "chevron.up.circle.fill", tint: .cyan, size: 88)
            }
        }
    }
}

/// A circular control button glyph.
private struct ControlGlyph: View {
    let system: String
    var tint: Color = .white
    var size: CGFloat = 72
    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

/// A button that reports press-down and press-up as a boolean, for hold controls.
struct HoldButton<Label: View>: View {
    let onChange: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.55 : 1)
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onChange(true) } }
                    .onEnded { _ in pressed = false; onChange(false) }
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}
